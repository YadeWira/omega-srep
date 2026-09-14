# Omega SREP `.osr` archive format

This document is the on-disk format specification for archives
produced by `osrep`. It covers the standard `.osr` structure
inherited from upstream SREP 3.93a (with the magic-bytes change to
"OSRP") and the F5 additions: the optional `ODUP` trailer and the
`.dupref` meta blob layout used by `-dup` mode.

All multi-byte integer fields are **little-endian**. Omega SREP is
declared x86_64-only; portability work for big-endian targets is out
of scope.

## 1. Standard `.osr` archive (no `-dup`)

```
+---------------------+-------------------------------------------------------+
| archive header      |  16 bytes (4 × uint32 LE)                             |
+---------------------+-------------------------------------------------------+
| hash seed           |  hash_seed_size bytes (0 for md5/sha1/sha512/-hash-)  |
+---------------------+-------------------------------------------------------+
| blocks              |  v1-v3: per block = header → match list → literals    |
|                     |  v4:    per block = header → literals, then one       |
|                     |         concatenated match list for all blocks        |
+---------------------+-------------------------------------------------------+
| block-size table    |  v4 only: N × uint32 (match-list size of each block)  |
+---------------------+-------------------------------------------------------+
| footer              |  v4 only: 24 bytes (6 × uint32 LE)                    |
+---------------------+-------------------------------------------------------+
```

### 1.1 Archive header (16 bytes = 4 × uint32 LE)

| offset | field | value |
|-------:|-------|-------|
| 0 | `header[0]` | `BULAT_ZIGANSHIN_SIGNATURE` = `0x26351817` (constant) |
| 4 | `header[1]` | `SREP_SIGNATURE` = `0x5052534F` (`"OSRP"` LE) |
| 8 | `header[2]` | packed version/hash selector, see below |
| 12 | `header[3]` | `BASE_LEN` — the match-length base needed to decode records |

`header[2]` is four 8-bit fields:

| bits | field | meaning |
|-----:|-------|---------|
| 0–7 | `format_version` | 1–4 (see below) |
| 8–15 | `hash_num` | hash-descriptor index: `md5`=0, disabled=1, `sha1`=2, `sha512`=3, `vmac`=4, `siphash`=5 |
| 16–23 | `hash_seed_size` | bytes of seed that follow the header |
| 24–31 | `hash_size − 16` | digest bytes per block, stored offset by 16 |

There is **no filesize field** anywhere in the archive. In particular
`header[3]` is the match base, not an input size: for I/O-LZ (v1/v2) it
is `min(min_match, dict_min_match)`; for v3/v4 it is 0.

`format_version` is chosen at compress time as:

| value | encoder flags | decoder path | match records |
|------:|---------------|--------------|---------------|
| 1 | `ROUND_MATCHES` + I/O-LZ (`o` suffix, `-m3` family) | I/O-LZ | 3 STATs |
| 2 | I/O-LZ (`o` suffix) without `ROUND_MATCHES` | I/O-LZ | 4 STATs |
| 3 | Future-LZ (`f` suffix) | Future-LZ | 4 STATs |
| 4 | Index-LZ — the default (no `f`/`o` suffix) | Index-LZ | 4 STATs |

So v1/v2 are the `o` (I/O-LZ) variants and v4 is the default for every
unsuffixed method: the version says how the archive stores its match
lists, not which match finder (`-m0`…`-m5`) produced them.

Per-hash sizes (`hash_size` / `hash_seed_size`):

| `-hash=` | `hash_num` | seed bytes | digest bytes |
|----------|-----------:|-----------:|-------------:|
| `md5` | 0 | 0 | 16 |
| disabled (`-hash-`) | 1 | 0 | 16 (field left unfilled) |
| `sha1` | 2 | 0 | 20 |
| `sha512` | 3 | 0 | 64 |
| `vmac` (default) | 4 | 32 | 16 |
| `siphash` | 5 | 16 | 8 |

### 1.2 Hash seed (variable)

Raw bytes of the hash key chosen at compress time (per-archive random
material; `--seed=N` makes it deterministic). Size = `hash_seed_size`
from `header[2]`, and it is 0 for the unkeyed hashes. The decompressor
uses it to re-key its hash so per-block digests match the encoder's.

### 1.3 Block

Each block is a 12-byte header (3 × uint32 LE), then `hash_size` digest
bytes, then the match list, then the literal bytes:

```
+----------------------+----------------------+----------------------+
| literal_bytes (4)    | origsize      (4)    | statsize      (4)    |
+----------------------+----------------------+----------------------+
| block hash digest (hash_size bytes)                                |
+--------------------------------------------------------------------+
| match list (statsize bytes; whole STATS_PER_MATCH × uint32 records)|
+--------------------------------------------------------------------+
| literal bytes (literal_bytes bytes; the block's non-match data)    |
+--------------------------------------------------------------------+
```

| field | meaning |
|-------|---------|
| `header[0]` = `literal_bytes` | how many literal bytes this block contributes |
| `header[1]` = `origsize` | uncompressed size of this block |
| `header[2]` = `statsize` | match-list bytes in this block; **forced to 0 for v4**, where the size comes from the block-size table instead |

The **match list** is a sequence of records, each
`STATS_PER_MATCH(ROUND_MATCHES)` uint32s — 3 for v1 (round matches), 4
otherwise. The trailing literals after the last record are not a record;
the decoder copies whatever literals remain. `statsize` is therefore
always a whole number of records.

Where the match list physically sits depends on the version:

* **v1/v2/v3** — inline, per block, between the digest and the literals.
* **v4** — per-block regions hold only `header` + literals (with
  `statsize = 0`); a **single match list** covering all blocks, in block
  order, is written after the last block, followed by the block-size
  table and the footer (§1.4).

### 1.4 Index footer (v4 only)

After the last block (and, for v4, after the single match list) come the
block-size table and a 24-byte footer.

**Block-size table** — `N` × uint32, one per block, each holding that
block's match-list size in bytes. `N` is derived, not stored:
`N = (footer_size − 24) / 4`.

**Footer** — 24 bytes = 6 × uint32 LE, the very last bytes of the file:

| offset | field | value |
|-------:|-------|-------|
| 0 | `total_stat_size` low 32 | total match-list bytes across all blocks |
| 4 | `total_stat_size` high 32 | high half of that uint64 total |
| 8 | `footer_size` | `24 + table_size` |
| 12 | `footer_version` | `1` (only version defined) |
| 16 | `~SREP_SIGNATURE` | `0xAFADACB0` |
| 20 | `~BULAT_ZIGANSHIN_SIGNATURE` | `0xD9CAE7E8` |

Decoder: seek to `EOF − 24`, read the footer, validate the two inverted
signatures and `footer_version`, then `stat_size = footer[0] |
(footer[1] << 32)`, seek to `EOF − footer_size − stat_size` and read the
match list, then read the table, then seek back to the first block.

### 1.5 End of stream

* **v1/v2/v3** — no terminator block is written. The decoder reads block
  headers until **EOF** (a zero-length read), with the pending-match heap
  drained (`lz_matches.size() == 1`, the loop barrier).
* **v4** — the block count comes from the footer's table; the decoder
  stops after exactly `N` blocks and does not rely on EOF.

An older revision of this document claimed a zero-length "end-of-archive
block" is emitted; the encoder does not write one.

### 1.6 Byte order and layout assumptions

Every integer is written straight out of native memory, so the format is
fixed **little-endian**: `STAT` is a 4-byte `uint32`, and 64-bit totals
are stored as two little-endian uint32 halves. There is no padding or
alignment in the file. The build refuses non-x86 hosts, so this is not
conditional on the host.


## 2. `-dup` archive (with ODUP trailer)

When compressed with `osrep -dup ...`, the archive is the standard
form above followed by an ODUP trailer:

```
+-----------------------------------+
| standard .osr archive (Section 1) |  body.osr_size bytes
| -- compresses the unique-chunk    |
|    body, NOT the original input   |
+-----------------------------------+
| meta blob (.dupref)               |  meta_size bytes
+-----------------------------------+
| meta_size (uint64 LE)             |  8 bytes
+-----------------------------------+
| ODUP magic                        |  4 bytes ("ODUP" ASCII)
+-----------------------------------+
```

Decoder algorithm:

1. Read last 4 bytes; if `≠ "ODUP"`, treat as standard `.osr` and
   skip steps 2–4.
2. Read `meta_size` uint64 LE at filesize − 12.
3. Validate that `meta[0..3] == "DUPR"` (Section 3.1). If not,
   refuse the archive — the ODUP+DUPR magic-pair guard makes
   accidental misidentification ≈1/2^64.
4. Read meta blob and slice off the trailing 12+meta_size bytes.
   The remainder is the standard `.osr` archive containing the
   unique-chunk body. Decompress it via the standard path and feed
   the result to the dedup post-pass (Section 3.3).

## 3. `.dupref` meta blob

The meta blob describes how to reconstruct the original input from
the unique-chunk body. It has a fixed 24-byte header followed by a
variable-length chunk table.

### 3.1 Header (24 bytes)

| offset | size | field         | value(s)                          |
|-------:|-----:|---------------|-----------------------------------|
|      0 |    4 | magic         | `0x52505544` (`"DUPR"` LE)         |
|      4 |    4 | version       | `1`                                |
|      8 |    8 | chunk_count   | uint64 LE — total chunks in input  |
|     16 |    8 | unique_count  | uint64 LE — distinct unique chunks |

### 3.2 Chunk table (variable)

`chunk_count` records, in input order:

```
+------+ -- 1 byte tag: 0 = unique, 1 = ref
| tag  |
+------+
```

For `tag == 0` (unique):

```
+--------------+ -- uint32 LE: byte length of this unique chunk
| length       |
+--------------+
```

For `tag == 1` (ref):

```
+--------------+ -- LEB128 unsigned varint: index into the unique
| ref_index    |    list (must be < unique_count)
+--------------+
```

LEB128 decoding: read bytes; each contributes 7 low bits to the
result, shifted by `7 * byte_index`; high bit set means "another
byte follows", high bit clear means "this is the last byte". Refs
exceeding 64 bits or pointing past `unique_count` MUST be rejected
as corrupt.

### 3.3 Unique-chunk body

The unique-chunk body lives in the standard `.osr` archive that
precedes the meta blob (Section 2). It is the simple concatenation
of the unique chunks in order of first appearance.

To reconstruct the original input:

```
out_pos = 0
unique_offsets = []   # (offset_in_body, length) per unique chunk
for record in chunk_table:
    if record.tag == 0:                            # unique
        copy body[unique_offsets.size_so_far .. +length] to out
        unique_offsets.append((out_pos, length))
        out_pos += length
    else:                                          # ref
        offset, length = unique_offsets[record.ref_index]
        copy out[offset .. offset+length] to out
        out_pos += length
```

The `dedup::decode_streaming` implementation (`Compression/SREP/dedup.cpp`)
uses the inverse operation: it streams unique chunks from the body
to the output sequentially, and on each ref `fseek`s back into the
output to copy previously-written bytes forward. Peak RAM is
independent of input size.

## 4. CDC parameters (informational)

These are encoder-side only — they do not appear in the format and
the decoder does not need them. Documented here so implementations
can reproduce the same chunk boundaries on identical inputs:

| parameter | default | meaning |
|-----------|--------:|---------|
| chunk-avg | 4 KiB   | rolling-hash threshold; ≈ average chunk size |
| chunk-min | 1 KiB   | minimum chunk size before boundary checks fire |
| chunk-max | 16 KiB  | maximum chunk size before forced cut |
| chunk-buf | 8 MiB   | buffer-bounded CDC: rolling hash resets each buffer |

Rolling hash is FNV-style: `h = h * 0x100000001B3 + byte` (uint64
wrap). Boundary triggers when `(h & (avg-1)) == 0` (avg is a power
of 2). Buffer-bounded CDC is required for the dedup to find
long-range duplicates of identical multi-MiB blocks; without it,
chunk boundaries depend on the rolling hash trajectory across the
whole input and rarely align.

## 5. Compatibility

- Omega SREP `.osr` files **are not compatible** with upstream
  SREP `.srep`. Magic bytes were intentionally changed (commit
  `09543d3`) to enforce the no-retro-compat decision.
- The ODUP trailer is detected by sniffing the last 4 bytes; an
  archive without it decompresses as a standard `.osr`. Old-style
  consumers (no ODUP awareness) reading an ODUP archive will fail
  with a clean format-violation error somewhere in the trailing
  bytes — they are not silently misinterpreted.
- `format_version` 5 is **reserved** for an inline-header variant
  of `-dup` (per the original `docs/dup-mode-design.md`); the
  current implementation uses the trailer instead, so v5 has no
  defined meaning today and decoders should reject it.

## 6. Reproducibility note

`hash_seed_size` bytes are per-archive random material, so two
compressions of the same input produce different `.osr` bytes.
Round-trip is deterministic; the archive is not. Pass `--seed=N`
(since v1.0a-beta.2) to derive the per-archive hash seed
deterministically from `N` instead of a PRNG, making the output
byte-stable for a given input + toolchain.
