# zpaq-std Phase 0 vectors

These are the reference fragments produced by zpaq-std's own
`fragment_buffer()` (the function that is byte-identical to the inline
fragmentation loop in `Jidac::add()`), with the default `-fragment 6`:

- `MIN_FRAGMENT = 64 << 6` = 4096
- `MAX_FRAGMENT = 8128 << 6` = 520192
- threshold `1 << (22 - 6)` = 65536
- order-1 predictor, multipliers 314159265 / 271828182

Generated from zpaq-std commit `b8ad717` (2026-11-08, v2.7.0 tree), with the
patch `osrep-fragment-vectors.patch`:

```sh
cp -a /path/to/zpaq-std /tmp/zpaq-vectors
cd /tmp/zpaq-vectors
patch -p1 < osrep-fragment-vectors.patch
make -j8
OSREP_FRAG_VECTORS=file OSREP_FRAG_N=6 ./zpaq-std > file.tsv
```

Columns:

| column | meaning |
|---|---|
| `offset` | byte offset of the fragment in the file |
| `size` | fragment length |
| `hits` | number of bytes equal to the order-1 prediction |
| `sha1` | SHA-1 of the fragment (40 hex chars) |
| `o1` | leftover 256-byte order-1 context (512 hex chars) |

`tests/zpaq_cdc_vectors.sh` builds `tools/zpaq-vectors/cdc_dump.c` against
`src/c/osrep_cdc.c` and compares OSREP's chunk boundaries with the `offset`
and `size` columns for the five `tests/corpus` files.

Result (2026-11-10): **identical boundaries** on all five files, so OSREP's
order-1 CDC is already the zpaq fragmenter at `-fragment 6`. The SHA-1 and
the `hits`/`o1` state are not implemented in OSREP yet; they are the next
Phase 0/1 items.

## Multi-version corpora

Full vectors for the two dedup corpora are in `vectors/`:

| file | tar | SHA-256 | fragments | OSREP CDC |
|---|---|---|---:|---:|
| `multiver.tsv` | `versions.tar`, 125 MB, 4 zpaq-std snapshots | `fb214be8…c8e4` | 1775 | identical |
| `pja.tsv` | `pja.tar`, 33 MB, 5 PJA snapshots | `dad3b5de…b176` | 503 | identical |

`vectors/CORPORA.sha256` has the full tar hashes. These are reference data for
the SHA-1/o1 work; the automated test uses only the generated `tests/corpus`
files.


## Integration into `add()` (Phase 1)

`osrep-fragment-integration.patch` replaces the inline fragmentation loop of
`Jidac::add()`/`add2()` with the OSREP API:

- `osrep_frag_state_reset()` per fragment;
- `osrep_frag_state_push()` per byte for the rolling hash and the order-1
  state;
- `osrep_sha1()` over the fragment buffer;
- `hits` and `o1` copied back for zpaq's data-type analysis.

Apply it **after** `osrep-fragment-vectors.patch` and build with the two OSREP
objects:

```sh
cc -O2 -std=c99 -I/path/omega-srep/src/c -c /path/omega-srep/src/c/osrep_sha1.c
cc -O2 -std=c99 -I/path/omega-srep/src/c -c /path/omega-srep/src/c/osrep_fragment.c
make CPPFLAGS=-I/path/omega-srep/src/c \
     LDLIBS="-lm $PWD/osrep_sha1.o $PWD/osrep_fragment.o"
```

`integration-test.sh BASELINE INTEGRATED DATA` compares both binaries with
`-touch`/`-timestamp` fixed.

Results (2026-11-10, same zpaq-std commit `b8ad717`, v2.7.2):

| input | methods | archive |
|---|---|---|
| `tests/corpus` (7 files, 10,7 MB) | `-m0`, `-m1`, `-m5` | byte-identical |
| `versions.tar` (125 MB, one file) | `-m1` | byte-identical (15.293.533 bytes) |

Times on the 125 MB file: baseline ~0.78 s, integrated ~0.76 s. The exact
fragmenter is a drop-in for the main loop, not just for the helper.
