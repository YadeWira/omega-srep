# Omega SREP

**Omega SREP** is a fork and continuation of [SREP (SuperREP)](https://web.archive.org/web/20161223135216/http://freearc.org/research/SREP.aspx),
the huge-dictionary LZ77 preprocessor originally authored by Bulat Ziganshin.
Upstream SREP froze at **3.93a beta (October 11, 2014)**; Omega SREP picks up
the lineage with a clean break — new file format, new identity, modern target
platforms.

## What is different from upstream SREP

- **New file extension:** `.osr` (replaces `.srep`).
- **No backward compatibility** with `.srep` files. The on-disk magic bytes
  changed from `"SREP"` to `"OSRP"` — old archives must be decompressed with
  the upstream tool first.
- **Supported platforms:** Windows 10/11 x64 and Linux x64 (primary,
  tested target). 32-bit x86 (i686) is also supported as an **opt-in**
  build — see `docs/32bit-support.md` for the cross-compile command,
  what's confirmed working, and one known issue (`-hash=sha1`) to
  avoid there. The historical big-endian, FreeBSD, and macOS branches
  are gone.
- **Binary name:** `osrep` (replaces `srep`).
- **Version line:** Omega SREP starts a new lineage at `1.0a beta`,
  currently `1.0a-beta.5`.
- **Dictionary cap relaxed (x86_64).** The in-memory REP dictionary
  (`-dBYTES`) is no longer pinned near 2 GB on the primary 64-bit
  build. `-d3gb`, `-d4gb`, and beyond have been smoke-tested for
  round-trip correctness — the only remaining cap is the available RAM
  on the host. (The opt-in 32-bit build keeps a real, address-space-driven
  cap — see `docs/32bit-support.md`.)
- **`-dup` mode (FA-style dedup pre-pass).** Omega SREP adds a
  content-defined-chunking + dedup stage in front of the existing
  SREP encoder, after FA 0.11's design. Pass `-dup` on the command
  line to enable it; decompression auto-detects the ODUP trailer:

  ```bash
  osrep -dup -m4 backup.tar backup.osr
  osrep -d backup.osr backup.tar
  ```

  Long-range duplicates are stripped to a small chunk-table footer
  before SREP sees the data, so SREP's working set drops to the size
  of the unique-chunk stream. The dedup pre-pass and post-pass both
  stream (per-buffer CDC, seek-based ref expansion on decode), so
  peak RAM is independent of input size. On a 128 MiB corpus of
  repeated 32 MiB blocks, end-to-end peak decompress RSS drops
  ≈66% (54 MiB → 18 MiB) for 0.3% archive bloat. See
  `docs/dup-bench.md`. `-dup` is incompatible with `-m0`; pair it
  with `-m3`/`-m4`/`-m5` for best results. Tunables: `--chunk-avg=N`,
  `--chunk-min=N`, `--chunk-max=N`, `--chunk-buf=N` (defaults match
  FA: avg 4 KiB, min 1 KiB, max 16 KiB, buf 8 MiB), and
  `--chunk-hash=fnv|gear` — the default `fnv` chunk-boundary hash has
  no fixed window, so it can miss duplicate content that isn't aligned
  to the `--chunk-buf` grid; the opt-in `gear` hash (FastCDC-style,
  with an implicit content window) finds those too, at no cost to the
  default path or the on-disk format. See `docs/research-notes.md`
  (F5.6 sections) for the measurements behind this.

  **`--dup-paranoid`:** the streaming encoder normally trusts the
  64-bit chunk hash to identify duplicates (collision rate of order
  1e-7 per million chunks; the design doc accepts this). For
  archival workloads where any silent corruption is unacceptable,
  `--dup-paranoid` opens the body file r+w and byte-compares each
  candidate dedup hit against the previously-written unique chunk
  via `fseek` + `fread`. Cost: one disk seek per dedup hit. RAM
  overhead is negligible (~12 bytes per unique chunk).

  **Decoder robustness:** the decompressor auto-detects the ODUP
  trailer and additionally validates that the meta blob starts with
  the `DUPR` magic — the combined probability of a non-dup archive
  being misidentified is ~1/2^64. The `tests/dup_corruption_fuzz.sh`
  suite exercises 27 deliberate-corruption variants (magic flips,
  truncations, out-of-range size fields, mid-meta byte-flips); every
  variant is required to error cleanly with no crash and no silent
  wrong output before each release.

The compression algorithm itself is otherwise unchanged. Algorithm-level
improvements beyond `-dup` are tracked separately.

**Empirical parity vs upstream:** an independent run on a real
1.79 GiB tar with `-m5f -a0` produces a **byte-identical compsize**
between SREP 3.92 and Omega 1.0a-beta.2 (1,052,227,610 bytes both).
Performance is essentially equivalent (-7% wall, -19% RAM on
compress; ~4% within noise on decompress). Downstream zpaq pipelines
produce archives within 0.000005% of each other at `-m3`. See
`docs/upstream-comparison.md` for the full data and reasoning.

## Build

```bash
  $ make
  # make install
```

A `PREFIX` may be provided to the `make` argument. Tested on Debian Linux
with `g++`/`clang++`. On non-x86 targets the build fails by design at
the preprocessor. For Windows, see `docs/windows-build.md` (FOSS
MinGW-w64 toolchain, no Visual Studio needed) and `docs/32bit-support.md`
for the opt-in 32-bit (i686) cross-compile path.

## Description

Original SREP description (web archive):
<https://web.archive.org/web/20161223135216/http://freearc.org/research/SREP.aspx>

## Last upstream commit (for the historical record)

```
changeset:   3011:48624cadaac2
tag:         tip
date:        Sun Nov 16 15:58:12 2014 +0300
summary:     Compression: a few more fixes
```

## Credits

- Bulat Ziganshin — original author of SREP / SuperREP and FreeArc.
- The repackage of the last upstream Mercurial commit lives at
  <https://github.com/Intensity/srep>; Omega SREP is built on top of it.
