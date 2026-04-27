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
- **Supported platforms:** Windows 10/11 x64 and Linux x64 only. The
  historical 32-bit, big-endian, FreeBSD, and macOS branches are gone — that
  margin will be spent on real improvements.
- **Binary name:** `osrep` (replaces `srep`).
- **Version line:** Omega SREP starts a new lineage at `1.0a beta`.
- **Dictionary cap relaxed.** As a side effect of dropping the 32-bit
  build, the in-memory REP dictionary (`-dBYTES`) is no longer pinned
  near 2 GB. `-d3gb`, `-d4gb`, and beyond have been smoke-tested for
  round-trip correctness on x86_64 — the only remaining cap is the
  available RAM on the host.
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
  of the unique-chunk stream. On a 128 MiB corpus of repeated 32 MiB
  blocks, peak decompress RSS drops 67% (53 MiB → 17 MiB) for 0.3%
  archive bloat. See `docs/dup-bench.md`. `-dup` is incompatible with
  `-m0`; pair it with `-m3`/`-m4`/`-m5` for best results. Tunables:
  `--chunk-avg=N`, `--chunk-min=N`, `--chunk-max=N`, `--chunk-buf=N`
  (defaults match FA: avg 4 KiB, min 1 KiB, max 16 KiB, buf 8 MiB).

The compression algorithm itself is otherwise unchanged. Algorithm-level
improvements beyond `-dup` are tracked separately.

## Build

```bash
  $ make
  # make install
```

A `PREFIX` may be provided to the `make` argument. Tested on Debian Linux
with `g++`/`clang++`. On non-x86_64 targets the build fails by design at the
preprocessor.

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
