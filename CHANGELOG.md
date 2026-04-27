# Changelog

All notable changes to Omega SREP since the fork point from upstream
SREP 3.93a beta (Bulat Ziganshin, October 2014).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com).
Versions follow `1.<minor>.<patch>` for stable releases and
`1.0a-beta.N` for pre-1.0 betas.

## [1.0a-beta.3] — 2026-04-27 (pre-release)

### Fixed (correctness, surfaced during 1.0a-beta.2 soak)

- **>2 GiB seek silently truncated decompression on Windows MinGW.**
  `decode_streaming` used `fseeko((off_t)offset, ...)` for ref
  expansion; `off_t` stayed 32-bit on MinGW despite
  `-D_FILE_OFFSET_BITS=64`, so offsets > 2 GiB silently overflowed
  and the output was written to the wrong position. On a 3.7 GiB
  doubled-tar input the decompressed file came out 46 MB short
  (exactly the dedup-removed amount) and `cmp` failed. Fix: new
  portable `osrep_fseek64` helper that maps to `_fseeki64` on
  Windows and `fseeko` + int64_t on POSIX. Same fix applied to
  `encode_streaming` paranoid mode and the `dup_wrapper` archive
  trailer-sniff sites. Verified end-to-end on Linux with the
  original failing input (`cat data.tar data.tar`): output now
  byte-identical to source. (`ad75b34`)

- **`std::bad_alloc` abort on corrupted `.dupref` chunk_count.**
  `decode()` and `decode_streaming()` called
  `records.reserve((size_t)chunk_count)` with no bound check;
  libFuzzer found a crashing input in 4 executions
  (chunk_count = `0xFFFFFFFFFFFFFFFE` triggers
  `std::bad_alloc`, which unwinds across the `extern "C"`
  fuzzer-driver boundary and aborts). Fix: validate
  `chunk_count <= (blob_size - HEADER_SIZE) / 2` and
  `unique_count <= chunk_count` before any allocation. 81.9M-run
  re-fuzz at 272k execs/sec found no further crashes. Captured
  reproducer kept in `tests/fuzz-regression/` and replayed in CI
  via `tests/fuzz_regression.sh`. (`f11d6a3`)

### Added

- **`tests/fuzz_decode.cc`** — coverage-guided libFuzzer harness
  for `osrep_dedup::decode`. Builds with
  `clang++ -fsanitize=fuzzer,address,undefined`. Complements the
  hand-crafted `tests/dup_corruption_fuzz.sh`.
- **`tests/fuzz_regression.sh`** — replays every captured-and-
  fixed fuzz artifact in `tests/fuzz-regression/` against the
  current decoder. Wired to CI; first sample is
  `bad_alloc_chunk_count_uint64_max`.
- **`tests/fuzz_decode_streaming.cc`** — libFuzzer harness for the
  file-based decoder (`osrep_dedup::decode_streaming`). Splits each
  input into `meta_len` (uint32 LE) + meta blob + body bytes; body
  is materialized to a per-process temp file. Targets the seek-
  back ref-expansion path that `fuzz_decode.cc` cannot reach.
- **`tests/fuzz_encode_split.cc`** — libFuzzer harness for the
  in-memory two-output encoder (`osrep_dedup::encode_split`). Also
  round-trips the produced meta blob back through `decode()` on
  every successful encode, doubling the parser coverage from each
  encoder-found input.
- **`tests/multi_corpus_bench.sh`** + **`docs/multi-corpus-bench.md`**
  — F6.10 comparative benchmark against upstream SREP 3.92 and FA
  0.11 across three corpora (synth-128M, enwik8, 1.79 GiB tarball).
  Confirms `osrep -m4` produces byte-equal archives to upstream
  `srep -m4` on every corpus (fork parity), `-dup` cuts decompress
  RSS by 66% on long-range-dup corpora at +0.28% archive bloat,
  and Omega's `-dup` ratio matches FA 0.11's `-dup` reference impl
  within 0.5%-of-input.
- **`CMakeLists.txt`** + **`docs/msvc-build.md`** — F6.8 native
  MSVC build path. Existing Makefile remains the primary path;
  CMake is the alternative for Visual Studio / Build Tools 2022
  users so they can build a native `cl.exe` `osrep.exe` without
  going through MinGW. Configures and builds clean with GCC + clang
  on Linux as a smoke test; cl.exe verification is by hand.
- **`Compression/LZMA2/MultiThreading/Synchronization.h`** — gate
  on the `Handle.h` LZMA-SDK shim widened to also exclude `_MSC_VER`
  (it was previously only excluding `__MINGW32__`, which would have
  failed a native-MSVC build on a missing-include).

### Process notes

- The two correctness fixes above were both surfaced during the
  intentional soak window of 1.0a-beta.2 — exactly the scenario
  that justifies a soak before promoting to v1.0. Tagging
  1.0a-beta.3 to (a) ship a binary that has the fixes, (b) reset
  the soak clock with the corrected build, (c) stop confusing
  users who downloaded the original 1.0a-beta.2 release assets.
- Main / asset binaries on the GitHub release have been carrying
  the fixes since `ad75b34` and `f11d6a3` were pushed; this tag
  makes that explicit.

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

### Multi-GB soak fuzz (verified 2026-04-27)

`OSREP_FUZZ_MAX_SIZE=$((1024*1024*1024)) OSREP_FUZZ_DUP=1 bash
tests/fuzz.sh 5 9000` — 5 random seeds × 7 configs (`-m0`/`-m1`/
`-m2`/`-m3`/`-m4`/`-m5` plus `-dup -m4`) at input sizes up to 1
GiB. **35/35 round-trips pass.** Confirms the F5.3c streaming
encoder/decoder scales correctly across a 4× range beyond the
documented 256 MiB bench.

### Format spec (added 2026-04-27)

`docs/format-spec.md` documents the on-disk `.osr` archive layout
(header / hash seed / blocks / footer), the ODUP trailer scheme
that `-dup` mode appends, and the `.dupref` meta blob structure
used by the dedup post-pass. Aimed at future implementers and
third-party tools so the format is no longer derive-from-source.

### CI on GitHub Actions verified (2026-04-27, partial)

The `.github/workflows/ci.yml` workflow runs **green on
ubuntu-latest** in 22-24 seconds, exercising the full 7-suite test
set (roundtrip / fuzz / dedup_xtest / dup_roundtrip /
dup_native_roundtrip / dup_corruption_fuzz / dup_concurrency).
First successful run: `25003756810` (commit `4ccc0ae`); second
verified run: `25003925350` (commit `6ec63e8`, on `actions/
checkout@v4`).

`workflow_dispatch` was added to the trigger list so anyone can
re-run via `gh workflow run "CI" --ref main`. **Push triggers do
not auto-fire** because `YadeWira/omega-srep` is technically a
fork of `Intensity/srep` and GitHub disables push-event workflow
runs on forks by default. To enable automatic CI on every push,
the maintainer can either:

  1. Detach the fork (Repo Settings → General → bottom → "Leave
     fork network"). Recommended — upstream froze in 2014 and
     Omega is an independent lineage.
  2. Manually invoke `gh workflow run "CI" --ref main` per release.

Workflow file is otherwise upstream-policy-clean: uses
`actions/checkout@v4`, no third-party actions, no secrets, runs
fully on stock ubuntu-latest tooling.

### Reproducible archives via `--seed=N` (added 2026-04-27)

New CLI flag `--seed=N` (uint64, accepts decimal or `0x` hex)
substitutes the cryptographic_prng-generated per-archive hash seed
with deterministic xorshift64 bytes derived from the user-supplied
value. Same seed + same input now produces **byte-identical
archive bytes** across runs.

Use cases this unblocks:

- Content-addressed storage that hashes archive bytes
- Reproducible-build pipelines (Debian, Nix, etc.)
- Pipeline caching keyed on archive checksum
- Diff-friendly archives (`bsdiff`, `xdelta3`)

Default behavior unchanged when `--seed=N` is not given (random
per-run, matches upstream SREP). Test added to
`tests/dup_native_roundtrip.sh`: same seed -> identical, different
seed -> different, no seed -> different, round-trip preserved.

### Upstream-parity comparison (independent test, 2026-04-27)

User-supplied benchmark on real 1.79 GiB tar with `-m5f -a0`
comparing SREP 3.92 beta vs Omega 1.0a-beta.2 on Windows:

  - compsize: byte-identical (`1,052,227,610` both)
  - compress wall-clock: 12.587s vs 11.736s (-6.8%)
  - compress peak RSS: 168 MB vs 136 MB (-19.0%)
  - decompress wall-clock: 1.082s vs 1.124s (+3.9%, within noise)
  - downstream zpaqfranz `-m3`: 773,584,661 vs 773,584,622 bytes
    (delta 39 bytes / 0.000005% — pure arithmetic-coder noise)

Confirms F5 work and identity rebase did not introduce algorithmic
regressions: the body of LZ matches Omega emits is identical to
upstream's. Differences are confined to magic bytes (4) and the
~3.6 KiB of per-run random hash material. Documented at
`docs/upstream-comparison.md`.

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
