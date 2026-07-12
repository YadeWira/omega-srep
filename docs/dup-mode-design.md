# Omega SREP — `-dup` mode design (F5.1)

This document is the design spec for Omega SREP's `-dup` mode, a
content-defined-chunking deduplication pre-pass inspired by FA 0.11
(FreeArc'Next). Implementation follows in F5.2 (encoder), F5.3
(decoder + format), F5.4 (validation bench).

> **Correction (2026-07-12, task 1.0.4):** this doc's "Hash for dedup"
> section below says VMAC was chosen for the internal per-chunk dedup
> hash. That was the plan, but it's not what shipped — the internal
> hash has always been a plain FNV-1a (since as-shipped, replaced with
> a faster word-at-a-time hash in 1.0.4), completely unrelated to VMAC.
> Left the original text below for history; don't treat it as current.



## Why

Two motivations, both quantified:

1. **Memory savings.** Bulat measured FA 0.11 `-m4 -dup` vs `-m4` on
   a 4.7 GB corpus and reported decompression RAM dropping from 735 MB
   to 179 MB (~75% reduction) for ~4% archive bloat. SREP's Future-LZ
   keeps all upcoming matches in RAM until consumed; pulling the
   long-range duplicates out into a static dedup map up front means
   Future-LZ no longer has to track them.
2. **Captures the spirit of the unpublished SREP "data reordering"
   variant** Bulat referenced on encode.su but never released. We
   document this in `docs/research-notes.md`; this design is our take
   on it without his original prototype.

## Pipeline (encoder)

```
input bytes
    |
    v
[ 1. Buffer split ]                  fixed-size buffers (default = bufsize, same as -b)
    |  each buffer ->
    v
[ 2. Content-defined chunking ]      same algorithm as -m1 (rolling hash) or -m2 (order-1 model)
    |  configurable: --chunk-avg / --chunk-min, default avg = 4 KiB, min = 1 KiB
    v
[ 3. VMAC hash per chunk ]           runtime-only, NOT stored in archive
    |
    v
[ 4. Hash table lookup ]             first occurrence wins; later duplicates become refs
    |
    v
[ 5. Recombine into buffers ]        concatenate unique chunks; emit ref-list as side data
    |
    v
[ 6. SREP compress (-mN) ]           existing pipeline (REP / Future-LZ / Index-LZ)
    |
    v
output: [SREP header] [SREP body] [dup map footer] [SREP footer]
```

## Pipeline (decoder)

```
[SREP body]  -> existing SREP decompression -> unique-chunk stream
                                                     |
[dup map footer] ------------------------------------+
                                                     v
                                       reconstruct original by
                                       inlining each ref's bytes
                                                     |
                                                     v
                                                  output
```

The decoder reads the dup map first (fixed-size footer pointed at by a
new field in the SREP header), then streams unique-chunk bytes from
the SREP decoder while expanding refs as they appear.

## Format extension

This is an Omega-only format change; we already declared no compat with
upstream `.srep`, so the bump is free.

| field          | type    | size | notes |
|----------------|---------|------|-------|
| existing magic | uint32  | 4    | `OSRP` (0x5052534F LE) — unchanged |
| format version | uint32  | 4    | bumped from `4` to `5` when `-dup` is active |
| `flags`        | uint32  | 4    | new — bit 0 = `-dup` enabled |
| dup_map_offset | uint64  | 8    | new (when bit 0 set) — byte offset to dup map footer |

The dup map footer layout:

| field          | type    | size | notes |
|----------------|---------|------|-------|
| chunk_count    | uint64  | 8    | total chunks in original input (unique + refs) |
| unique_count   | uint64  | 8    | distinct unique chunks |
| chunk_table    | varlen  | N    | for each chunk: 1 byte tag + payload (tag 0 = unique with uint32 length, tag 1 = ref with varint index) |

Encoded little-endian on x86_64 (we are x86_64-only).

Backwards-incompat: a v4 decoder reading a v5 archive will reject it
at the existing format-version check (`srep.cpp` validates
`format_version <= SREP_FORMAT_VERSION4`). We add v5 to the validation
when `flags & 1` is set, otherwise treat v5 as unknown.

## Open decisions

These are the explicit choices that block F5.2:

1. **Chunk parameters defaults.**
   FA's defaults: average chunk = 4 KiB, min = 1 KiB. We adopt the
   same. Override flags: `--chunk-avg=BYTES`, `--chunk-min=BYTES`.

2. **Hash for dedup.**
   FA uses VMAC. SREP standalone has SHA-1 / VMAC / SipHash already
   linked (see `Compression/_Encryption/`). We pick VMAC to match FA
   and because it is fastest. We do NOT store the hash in the
   archive — the chunk table records reference-by-index, not by hash.
   `--save-sha-hashes`-equivalent is out of scope for v1.

3. **Interaction with `-m0..-m5`.**
   FA's behavior: `-dup` and the REP filter are "a bad idea
   simultaneously", and FA's bundled `fa.ini` strips REP when `-dup`
   is set.
   For Omega: we mirror that. With `-dup`:
     - `-m0` (REP-only) is silently rejected with an error message
       suggesting `-dup -m1` or higher.
     - `-m1`/`-m2` (CDC modes) work but the user is using two CDC
       passes (one for dedup, one for inner SREP); fine but a warning
       is printed.
     - `-m3`/`-m4`/`-m5` are the recommended pairings.

4. **Threading.**
   The dedup pass is embarrassingly parallel per buffer. Reuse the
   existing `-tN` flag (which today gates only `-m1`/`-m2` CDC) to
   thread the dedup hash computation. The hash-table insertion still
   serializes, but lookup before insert can be parallelised. This is
   the only place threading is bought-and-paid-for since we already
   compute hashes in flight.

5. **Memory budget.**
   The dedup hash table sizes proportional to unique-chunk count,
   not input size. For the FA 4.7 GB corpus, that's <100 MB at 4 KiB
   chunks (rule of thumb: 24 bytes per chunk * N_unique). Bound the
   table; if it would exceed `--dup-memory=BYTES` (default 512 MB),
   refuse rather than thrash.

6. **Self-referential safety.**
   A chunk's ref must point only to an earlier chunk in the same
   archive. The format guarantees this (refs use varint index < i
   where i is the current chunk index). The decoder validates and
   errors on malformed refs.

## Validation plan (F5.4)

Replicate Bulat's measurement on our own corpus:

  - Build a 4-5 GB corpus that mixes high-redundancy data (e.g. duplicated
    binary blobs, repeated text from multiple files) — representative of
    installer / backup workloads where `-dup` should win.
  - Compare three configurations on the same corpus:
      A: `-m4` (baseline)
      B: `-m4 -dup` (target)
      C: `-m0 -d4gb` (REP-only, big dictionary, for context)
  - Measure: archive size, peak RSS during compress, peak RSS during
    decompress, wall-clock for both.
  - Success criterion: B's peak decompress RSS < A's by >=50%, with
    archive size bloat <=10%.

## Risks

  - **Format break.** v5 is incompatible with v4. We are already
    incompatible with upstream `.srep`, so the only consequence is
    that `osrep` v1.0a beta `.osr` files won't decompress on a future
    build that drops v5 support. We accept this; we are pre-1.0.
  - **CDC tail.** Content-defined chunking on near-random input
    barely deduplicates anything but pays the hash-table overhead.
    Mitigation: print the dedup ratio; if it's <1%, log a warning that
    `-dup` is wasted on this input.
  - **Hash collisions.** VMAC is 64-bit. For 1M chunks, birthday
    probability of a single collision is ~3e-8. Acceptable in
    practice for content-defined dedup; for cryptographic guarantee
    of integrity (which we do not promise), users can add CRC at the
    SREP layer (already present).
