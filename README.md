# Omega SREP

**Omega SREP** is a fork and continuation of [SREP (SuperREP)](https://web.archive.org/web/20161223135216/http://freearc.org/research/SREP.aspx),
the huge-dictionary LZ77 preprocessor originally authored by Bulat Ziganshin.
Upstream SREP froze at **3.93a beta (October 11, 2014)**; Omega SREP picks up
the lineage with a clean break — new file format, new identity, modern target
platforms.

**Since 2.0.0 the released binaries are the Rust implementation** in `crates/`.
The original C++ in `Compression/` has not been deleted and is not dead code:
it is the oracle the Rust port is tested against. Every ported module is diffed
byte-for-byte against the C++ binary rather than merely round-tripped through
itself, which is why it stays buildable and in-tree. It is simply no longer
released, and stays at its last shipped version, **1.0.7**. See
`docs/rust-port.md`.

## What is different from upstream SREP

- **New file extension:** `.osr` (replaces `.srep`).
- **No backward compatibility** with `.srep` files. The on-disk magic bytes
  changed from `"SREP"` to `"OSRP"` — old archives must be decompressed with
  the upstream tool first.
- **Container v5 is the default since 2.0.0**, written with a single `OSR5`
  magic: varint records, CRC-32C integrity, and `-dup` metadata located
  through a footer rather than an appended trailer. `--format=v4` writes the
  `OSRP` container the 1.0.x releases read and stays supported permanently as
  the interoperability escape hatch; both are always readable, so the option
  only selects what `osrep` *writes*.

  **What the v5 container buys you is `--verify`:** checking an archive is
  sound without reconstructing it. v1-v4 carry no checksum anywhere, so the
  only way to check one of those is to decompress the whole thing. `--verify`
  validates the CRC-32Cs, the framing, the block counts and every match record
  in one read of the archive, and says plainly what it does not cover (the
  stored block bytes carry no checksum, so damage inside a literal run still
  needs a `-d`). The cost scales with the *archive* while a decompress scales
  with the *original*, so the gap grows with the compression ratio: measured
  5x on a barely-compressible 733 MiB archive, 180x on one the same size
  holding 5.75 GiB of deduplicated backup.

  Be honest about the rest of the ledger: on real data a v5 archive is only
  about **0.1%** smaller than a v4 one, and both containers are equally
  protected against payload corruption, because the per-block digest does that
  work in v4 too. v5's integrity edge over v4 is narrow and specific -- the
  `-dup` metadata, which v4 leaves unchecksummed (see
  `docs/format-spec-v5.md` §1.1).

  This is the breaking change in 2.0.0, and it breaks loudly rather than
  quietly: a 1.0.x binary handed a v5 archive exits 4 with *"Not an Omega SREP
  compressed file (.osr)"* and writes no output. It cannot mistake one for the
  other.
- **Supported platforms:** Linux x64 and Windows x64/x86. The Rust builds
  target **Windows 7 and later** — the toolchain is pinned to Rust 1.77.2,
  the last release supporting Win7 for `*-pc-windows-gnu`, and both Windows
  binaries are verified on a real Windows 7 SP1 machine each release, not
  only cross-compiled. (The C++ build needs Windows 10/11, or the KB2999226
  Universal C Runtime on an older target.) The historical big-endian,
  FreeBSD, and macOS branches are gone.
- **Binary name:** `osrep` (replaces `srep`).
- **Version line:** Omega SREP starts a new lineage at `1.0a beta`.
  First stable release: `1.0.0`.
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

The released binary — the Rust implementation:

```bash
  $ cargo build --release
  # install -m755 target/release/osrep /usr/local/bin/
```

The toolchain is pinned in `rust-toolchain.toml` to **1.77.2**, deliberately:
it is the last Rust release that supports Windows 7 for `*-pc-windows-gnu`
(1.78 raised the floor to Windows 10). The Windows binaries cross-compile
from Linux with the same MinGW-w64 toolchain the C++ uses — `.cargo/config.toml`
wires up the linkers, so no Visual Studio is required:

```bash
  $ cargo build --release --target x86_64-pc-windows-gnu
  $ cargo build --release --target i686-pc-windows-gnu
```

The C++ oracle — needed only to run the differential tests, not to use
`osrep`:

```bash
  $ make            # produces bin/osrep
  # make install
```

A `PREFIX` may be provided to the `make` argument. Tested on Debian Linux
with `g++`/`clang++`. On non-x86 targets the build fails by design at
the preprocessor. For Windows, see `docs/windows-build.md` (FOSS
MinGW-w64 toolchain, no Visual Studio needed) and `docs/32bit-support.md`
for the opt-in 32-bit (i686) cross-compile path.

Point the CLI-level test scripts at either build with `OSREP_BIN`; that is
how the Rust port is run through the suite the C++ was developed against.

One thing that surprises people: `cargo build --release` lands a ~760 KB
binary in `target/release/`, while the released assets, built with an explicit
`--target`, are ~2.4 MB. The code is identical — cargo defaults
`split-debuginfo` differently in the two cases, so the explicit-target build
embeds debug info the plain one leaves in separate files. The releases are
shipped unstripped on purpose, so a backtrace from a user is symbolicated.

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
