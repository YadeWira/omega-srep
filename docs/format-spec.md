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
+-----------------+
| archive header  |  16 bytes
+-----------------+
| hash seed       |  variable; size declared in header[2] high half
+-----------------+
| block 1         |
+-----------------+
| block 2         |
+-----------------+
|     ...         |
+-----------------+
| block N         |
+-----------------+
| footer          |  20 bytes
+-----------------+
```

### 1.1 Archive header (16 bytes = 4 × uint32 LE)

| offset | size | field           | value(s)                              |
|-------:|-----:|-----------------|---------------------------------------|
|      0 |    4 | filesize_low    | low 32 bits of filesize_when_compressed |
|      4 |    4 | magic           | `0x5052534F` (`"OSRP"` LE)             |
|      8 |    4 | format_version_packed | low 16: format version 1–4; high 16: hash_seed_size in bytes |
|     12 |    4 | filesize_high   | high 32 bits of filesize_when_compressed |

`filesize_when_compressed` (uint64 split across header[0] and
header[3]) records the original input size at compress time. Used
by the decompressor for progress reporting and sanity checks.

`format_version`:

| value | meaning |
|------:|---------|
|     1 | round-matches; in-memory REP variant (`-m0`) |
|     2 | content-defined chunking (`-m1`/`-m2`) |
|     3 | Future-LZ output (`-mNf` flag) |
|     4 | Index-LZ output (default for `-m3`/`-m4`/`-m5`) |

`hash_seed_size`: number of bytes that follow the header for the
per-archive hash-key material (e.g. VMAC = 16 bytes, SHA-1 = 0).
Read off the high 16 bits of `format_version_packed`.

### 1.2 Hash seed (variable)

Raw bytes of the hash key chosen at compress time (per-archive
random material). Size = `hash_seed_size` from the header. The
decompressor uses this to seed its hash function so digests match
the encoder's.

### 1.3 Block (variable)

Each block follows a 12-byte header (3 × uint32 LE) plus a hash
digest plus the compressed block body:

```
+--------------------+----------------------+----------------------+
| origsize  (uint32) | compsize  (uint32)   | statsize  (uint32)   |
+--------------------+----------------------+----------------------+
| hash digest (hash_size bytes; per the hash chosen by -hash=)     |
+------------------------------------------------------------------+
| compressed body (compsize bytes)                                 |
+------------------------------------------------------------------+
| stat block (statsize bytes; encoded LZ matches)                  |
+------------------------------------------------------------------+
```

A block of size 0 (`origsize = 0`) is the end-of-archive marker; the
decompressor stops reading blocks here.

### 1.4 Footer (20 bytes = 5 × uint32 LE)

| offset | size | field            | value(s)                              |
|-------:|-----:|------------------|---------------------------------------|
|      0 |    4 | compsize_low     | low 32 bits of total compressed size  |
|      4 |    4 | compsize_high    | high 32 bits of total compressed size |
|      8 |    4 | stat_size_total  | total stat-block bytes across blocks  |
|     12 |    4 | footer_version   | `1` (only version defined)            |
|     16 |    4 | footer_magic     | `~0x5052534F` = `0xAFADACB0`           |

The decompressor seeks to end-of-file − 20 bytes, validates
`footer_magic == ~OSRP`, then walks back to find the start of the
block stream.

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
Round-trip is deterministic; the archive is not. Adding `--seed=N`
for byte-stable output is on the v1.x roadmap but not implemented
today.
