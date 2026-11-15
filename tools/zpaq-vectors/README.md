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


## The `-osrep` switch (delivery patch)

`osrep-fragmenter-zpaq-std-2.7.2.patch` applies to zpaq-std 2.7.2 (`b8ad717`)
on its own (the vectors patch is not needed) and replaces the earlier
prototype that read `OSREP_FRAG_MODE`/`OSREP_FRAG_AVG` from the environment.

- `a ... -osrep` (EXPERIMENTAL) cuts fragments with OSREP's fragmenter:
  a gear CDC (64-byte window), min A/2, zpaq's max, one threshold, plus cuts
  after tar headers and zip local headers (`OSREP_FRAG_F_FORMAT`). Without it
  zpaq-std's code is unchanged: the unrolled loop, `add2_scan()` and the
  SHA-1 stay as they were.
- `-fragment N` means what it means for zpaq: an average of 2^N KiB, with
  `MAX_FRAGMENT` as maximum (`osrep_frag_params_osrep(&p, N, blocksize)`).
  `-osrep` without `-fragment` uses N=3 (8 KiB); zpaq's own default stays 6.
  N must be 0..21. With `-stdin` zpaq forces N=6, for `-osrep` too.
- Both fragmenting paths take the switch: the plain loop of `add2()` (used
  with `-noturbo`, streams and images, and in the ANCIENT `add()`) and
  `add2_scan()` (the `-turbo` workers). The OSREP state starts fresh at every
  cut, so both give the same fragments with any number of threads.
- The sources are copied into `compressors/osrep/` and built by the Makefile
  like the other C codecs. `../zpaq-vendor/make-vendor.sh OUTDIR` builds the
  tarball to vendor, with `VENDOR.md` (version, commit, sha256 per file).

```sh
cp -a /path/to/zpaq-std /tmp/zpaq-osrep && cd /tmp/zpaq-osrep
git apply /path/omega-srep/tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.7.2.patch
make -j8
./zpaq-std a out.zpaq versions.tar -m1 -osrep
```

`osrep-switch-test.sh BASELINE PATCHED versions.tar pja.tar` checks it
(2026-11-12, all passed):

- without `-osrep`, `-m0`/`-m1`/`-m5`, with and without `-noturbo`, on
  `tests/corpus` and `versions.tar`: byte-identical to the baseline;
- with `-osrep`, without `-fragment` and with 0, 3 and 6, on the three
  corpora: the same archive with the default threads, `-t1`, `-t8` and
  `-noturbo`; without `-fragment` it is the archive of `-fragment 3`;
- the baseline extracts every `-osrep` archive to the original bytes.

`fragment_dump FILE N 0 zpaq|osrep` gives the same cuts, `hits`, SHA-1 and
`o1` on x64, x86 (`-m32`) and arm64 for N=0/3/6 on both tars.

Sizes and times: `docs/zpaq-osrep-mode.md`.

## zpaq-std 2.11.0

`osrep-fragmenter-zpaq-std-2.11.0.patch` is the same switch for zpaq-std
2.11.0 (`6b165e3`, zpaqfranz 65.20 merged): `git apply` on a clean 2.11.0
tree. Besides the 2.7.2 hunks (moved; the `Makefile` one adds `OSREPSRC`
after 2.10.0's longer `LZ6SRC`), with `-sa`/`-sae`/`-sat` the check of whether
a file is already partly in the archive cuts it with `osrep_fragment_buffer()`
when `-osrep` is on. `osrep-switch-test.sh` against the 2.11.0 baseline:
fails=0 (2026-11-15); the archives are also the same with `-turbochunk 1`/`7`
and 2, 3 or 8 threads.

`make_weakspots.py` builds the corpora for zpaq's own weak spots from real
files, with a fixed seed: a 512 MiB disk-like image and a v2 with 350
scattered changes, a tree and the same tree with one byte inserted at the
start of every file, and database-like files of 4/8/16 KiB pages in four
versions. Version k gets the mtime 2024-k-01 (zpaq skips a file with the
same size and date).

`bench_fair.py` and `bench_versions.py` also print the time of `l` and the
time and peak RSS of `x` (with `--xextra` switches), and `bench_versions.py`
the time and RSS of the last `a` alone (one more version on top of the
archive). `frag_stats gearS N FLAGS` is the gear of `-osrep` with min
A >> S. Results: `bench-2110-*.tsv` and `docs/zpaq-osrep-mode.md`
("zpaq-std 2.11.0").

## Fragmenter analysis without zpaq

`frag_stats MODE N FLAGS < list` cuts every listed file, dedups the
fragments by SHA-1 and prints fragments, unique bytes, mean size, an index
estimate (24 bytes per unique fragment + 4 per reference) and the cut + SHA-1
time. `osrep 3 42` is what `-osrep -fragment 3` cuts; `osrep 3 0` the plain
gear CDC. `frag_sim` and `frag_speed` (experiment 2) compare cut policies
and speeds; `bench_formataware.py` and `formataware-prototype.patch` are the
experiment 3 prototype (FNV mode, `OSREP_FRAG_FLAGS`), kept with its results.
Reports: `docs/experiments/frag-normalized.md`, `frag-formataware.md`,
`frag-adaptive.md`.

`bench_fair.py` (tars) and `bench_versions.py` (folders of versions) build
the final table of `docs/zpaq-osrep-mode.md`: zpaq `-fragment N` against
`-osrep -fragment N`, both averaging 2^N KiB; fragment `d` leaves `-fragment`
out (zpaq N=6, `-osrep` N=3), `--extra` passes switches such as `-threads 4`.
