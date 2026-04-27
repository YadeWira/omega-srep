# Changelog

All notable changes to Omega SREP since the fork point from upstream
SREP 3.93a beta (Bulat Ziganshin, October 2014).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com).
Versions follow `1.<minor>.<patch>` for stable releases and
`1.0a-beta.N` for pre-1.0 betas.

## [1.0a-beta.2] — 2026-04-27 (pre-release)

### Added

- **`-dup` mode (FA-style dedup pre-pass).** Native flag on the
  `osrep` binary; auto-detected on decompression via the trailing
  `ODUP` magic. Streaming end-to-end (per-buffer CDC, seek-based
  ref expansion on decode), so peak RAM is independent of input
  size. On a 128 MiB corpus of repeated 32 MiB blocks: -65.6%
  decompress RSS reduction with 0.3% archive bloat. Bench numbers
  at three scales (128 / 256 / 512 MiB) in `docs/dup-bench.md`.
- **`--dup-paranoid`** opt-in flag. Byte-compares each candidate
  dedup hit against the previously-written unique chunk via
  `fseek` + `fread`, eliminating the 64-bit hash collision window
  (~1e-7 per million chunks) at the cost of one disk seek per
  dedup hit. RAM overhead negligible.
- **`--chunk-{avg,min,max,buf}=N`** tunables for the CDC pipeline.
  Defaults match FA 0.11: avg 4 KiB, min 1 KiB, max 16 KiB, buf 8
  MiB. Validation rejects 0 values and `max < min`.
- **POSIX `mmap(2)` real implementation** (Linux). Replaces the
  no-op stub the upstream Linux build had.
- **Race-safe tempfiles via `mkstemp(3)`** (`GetTempFileName` on
  Windows). Honors `$TMPDIR` / `$TMP` / `$TEMP`. Replaces the
  deprecated `tempnam(3)` upstream used.
- **Documentation:** `docs/dup-mode-design.md` (design spec),
  `docs/dup-bench.md` (bench results), `docs/research-notes.md`
  (history, threading analysis, F3.3 closure).

### Changed

- **File extension:** `.srep` → `.osr`.
- **On-disk magic:** `"SREP"` (`0x50455253`) → `"OSRP"`
  (`0x5052534F` LE).
- **Binary name:** `srep` → `osrep`.
- **Targets narrowed** to Windows 10/11 x64 + Linux x64 only. The
  build fails by design at the preprocessor on any other target.
- **Dictionary cap relaxed:** the 32-bit-era 2 GiB ceiling is gone.
  `-d3gb`, `-d4gb`, `-d8gb` smoke-tested for round-trip on x86_64.

### Fixed

- **`-m5` SIGSEGV** on near-random inputs of 449 KiB – 4 MiB. Heap
  overflow in `SliceHash::prepare_buffer`
  (`Compression/SREP/hash_table.cpp:62`) — outer loop bound changed
  from `p < buf+size` to `p + L <= buf+size`. Confirmed via
  AddressSanitizer; pre-existing in upstream 3.93a beta.

### Tests

- **160 tests across 7 suites in CI** (was 30 at fork point):
  `roundtrip` (30) + `fuzz` incl. -dup (70) + `dedup_xtest` (4) +
  `dup_roundtrip` (5) + `dup_native_roundtrip` (16) +
  `dup_corruption_fuzz` (27) + `dup_concurrency` (8).
- **Opt-in pre-release tests:** `dup_realworld.sh` (623 MiB tar of
  /usr/bin, 5 configs all round-trip), stress fuzz at 64 MiB and
  128 MiB seeds, 16-way concurrent compress.

### Windows build (verified 2026-04-27)

End-to-end build + smoke-test on Windows 11 Pro x64 with MinGW-w64
(scoop's gcc 15.2.0). Previously unverified.

- New `Compression/LZMA2/C/ThreadsWin32.{h,c}` ports the missing
  Win32 threading primitives that upstream SREP referenced but never
  shipped. Modeled on the modern (26.x) LZMA SDK Threads.h Win32
  path; ABI-compatible with the 2008-era ThreadsUnix API the C++
  wrapper layer expects.
- Makefile detects MinGW/MSYS via `uname -s` and switches to
  `-DFREEARC_WIN -DUNICODE -D_UNICODE` plus Windows linker libs
  (`-lole32 -luuid -lshell32 -ladvapi32`).
- `dup_wrapper` switched to `osrep_make_unique_tempfile_path` so
  `-dup` finds %TEMP% on Windows instead of failing on `/tmp`.
- Native MSVC build remains untested (still needs the LZMA SDK
  `Handle.h` shim).

Smoke results on Windows: round-trip suite 18/18, random fuzz 30/30
(5 seeds × 6 methods), manual `-dup -m4` round-trip of 1 MiB
redundant text → 809 byte archive (round-trip clean). The
`dup_native_roundtrip.sh` script's inline Python uses POSIX-style
`/tmp/tmp.X` paths from `mktemp -d` that don't translate cleanly
through Git-Bash; the script needs path-translation polish to run
in CI. The binary itself was validated by manual round-trip.

### Sanitizer hygiene (verified 2026-04-27)

Built with `-fsanitize=address` and ran the full 7-suite test set;
all 120 tests pass with no memory-safety issues. One UBSAN finding
fixed (misaligned uint64_t store in `VHash::compute`, commit
`a17cc3c`). Vendored crypto (VMAC, SipHash) trips UBSAN's strict
unaligned-access checks for intentional x86_64 perf reads — these
are documented as NOT bugs on the current target. Upstream SREP's
exit-time leaks in `srep_main` are unchanged. See
`docs/sanitizer-runs.md` for the full record and reproduction
commands.

### Known limitations (gating items for v1.0 stable)

- Test harness scripts (`dup_native_roundtrip.sh`,
  `dup_corruption_fuzz.sh`, `dup_concurrency.sh`,
  `dup_realworld.sh`) need path-translation tweaks for Git-Bash on
  Windows. Binary works; tests don't all run yet.
- `-dup` peak RAM is bounded by the chunk table size (~23 KiB per
  MiB of input at default chunk parameters); for petabyte-scale
  inputs the chunk table itself becomes the limit.
- Per-run hash seed in SREP makes archive bytes non-reproducible
  across two compressions of the same input. Round-trip is
  deterministic; the archive is not.
- Fuzz coverage is shallow versus a true AFL/libFuzzer setup. Soak
  windows beyond 128 MiB are opt-in via env vars.

## Pre-fork

Upstream SREP froze at **3.93a beta (2014-10-11)**. See
`docs/research-notes.md` for the abandonment history and the
relationship to FA 0.11.
