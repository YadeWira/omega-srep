# Changelog

All notable changes to Omega SREP since the fork point from upstream
SREP 3.93a beta (Bulat Ziganshin, October 2014).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com).
Versions follow `1.<minor>.<patch>` for stable releases and
`1.0a-beta.N` for pre-1.0 betas.

## [1.0.4] — 2026-07-12

### Fixed

- **`-dup` mode's internal dedup lookup hash sped up 15-25%, real numbers, zero output impact.** `docs/dup-mode-design.md` claimed this hash was VMAC ("fastest, matches FA"); confirmed false as shipped -- it has always been a plain byte-at-a-time 64-bit FNV-1a (`chunk_hash()`, `Compression/SREP/dedup.cpp`), unrelated to VMAC/`-hash=`/`-m1`/`-m2`'s CDC path. FNV-1a's serial per-byte dependency chain has no word/SIMD parallelism. Replaced with a small hand-rolled word-at-a-time (8 bytes/iteration) 64-bit hash, same file, same two call sites, no signature change -- avoided vendoring a third-party hash (e.g. XXH3) given this project's own track record of finding real bugs in vendored/hand-written hash code this cycle (VMAC, CRC32, SHA1). Pressure-tested in isolation first (avalanche ~32/64 bits average across 1M-flip sample, 0 collisions across 1M realistic ~4-16KiB chunks, clean tail-byte handling at every length 0-16 bytes) before wiring in.
  - This hash is never persisted to the archive (`.dupref` records chunk index/length, not hash values) -- zero on-disk format impact, confirmed via a direct before/after archive byte-diff (bit-for-bit identical) and a dedup-body-size invariance check against `docs/dup-bench.md`'s corpus (33,554,432-byte body, meta blob, and final archive size all exactly unchanged).
  - **Also corrected a misleading comment** at `dedup.cpp` claiming collisions are "resolved by byte-comparing... before claiming a duplicate" as if unconditional. In fact this only happens when `--dup-paranoid` is passed (default: off) -- the default, non-paranoid streaming path (the only path the real CLI uses, per `dup_wrapper.cpp`) trusts the hash outright on a lookup hit, with no fallback verification. This isn't a new risk introduced by the swap (FNV-1a had the exact same unmitigated ~2^-64-per-pair exposure in that path), but it means the new hash's tail-byte handling specifically needed real test coverage that didn't exist before -- added as `tests/dup_hash_swap_test.sh`, exercising `osrep -dup` (no `--dup-paranoid`) against forced-tiny (`--chunk-avg=8 --chunk-min=1 --chunk-max=16`) chunks across `-m3`/`-m4`/`-m5`, plus a real-dedup-hit case and a `--dup-paranoid` control.
  - Speed measured directly on the isolated dedup pre-pass (`dedup_test split-encode`, 5-rep medians): **24.5% faster** on a 128MiB compressible corpus (32MiB block × 4, `docs/dup-bench.md`'s own generator), **14.9% faster** on 128MiB of incompressible random data (every chunk a lookup miss, the pre-pass's worst case). Reported both, not averaged, since hit/miss ratio changes which code path dominates.
  - Full existing suite (`dedup_xtest`, `dup_roundtrip`, `dup_native_roundtrip`, `dup_gear_hash_test`, `dup_corruption_fuzz`) plus the new test green; `tests/local_hardening.sh` 4/4 stages clean.

## [1.0.3] — 2026-07-12

### Fixed

- **`-hash=sha1` failed decompression checksum verification on 32-bit
  builds** (Bug #3, the last documented open bug for the 32-bit
  target). Root cause: `tomcrypt_macros.h`'s `STORE32H`/`LOAD32H` --
  LibTomCrypt's big-endian load/store macros, used only by `sha1.c`
  (`md5.c` uses the separate little-endian `L`-suffixed macros;
  `sha512.c`'s `STORE64H`/`LOAD64H` asm is gated `__x86_64__`-only, so
  it never hits this on 32-bit) -- had hand-written GCC extended
  asm that read/wrote through a pointer-held register operand with no
  memory clobber declared, the same undeclared-side-effect bug class
  as the VMAC (F6.12) and CRC32 fixes already shipped this cycle. Fixed
  with an explicit `"memory"` clobber; the same defensive fix applied
  to the `__x86_64__`-only `STORE64H`/`LOAD64H` (used by `sha512.c`)
  even though no failure was observed there, matching the
  `poly_step_func` bonus-hardening precedent. Verified: the real
  failing case round-trips correctly (30-cell Wine matrix, 29/30 --
  the one gap being the already-documented `-m0` Wine allocation
  flake, confirmed unrelated by retry); the stored digest for `"abc"`
  matches the official SHA1 known-answer vector byte-for-byte; x86_64
  confirmed byte-identical before/after for both `-hash=sha1` and
  `-hash=sha512` across a 30-cell `--seed`-fixed matrix; full suite
  (`roundtrip.sh` 30/30, `local_hardening.sh` 4/4) clean. See
  `docs/32bit-support.md` Bug #3 for the full writeup. 32-bit support
  now works for every mode with every hash.

## [1.0.2] — 2026-07-12

Follow-up to 1.0.1: closes the Windows PGO gap that release explicitly
left open, using the real Windows VM documented in `CONEXION-IA.md`
instead of the Wine emulation used elsewhere in this project's testing.

### Fixed

- **Windows binaries now ship with a real, Windows-native PGO profile**,
  not the plain-LTO fallback 1.0.1 shipped. 1.0.1 found that reusing
  the Linux-collected profile for the MinGW cross-compile doesn't
  work -- confirmed here to be because `Compression/Common.cpp`'s
  `FREEARC_WIN`-gated code is never even compiled into a
  `FREEARC_UNIX`-targeted instrumented binary, so there's no profile
  data for it to reuse in the first place, not a lookup bug. Fix:
  cross-compile a *Windows-targeted* instrumented binary, run the real
  training workload on the real Windows 10 VM over SSH (not Wine --
  Wine's own emulation startup overhead dominates timings this small
  and made an early plain-vs-PGO comparison meaningless), copy the
  resulting profile data back, and rebuild with `-fprofile-use`
  pointed at it. Automated as `tests/pgo_train_windows_vm.sh`
  (maintainer-only, requires VM access). Verified byte-identical vs.
  the native Linux build across a 60-cell matrix (`--seed` fixed) and
  round-trip decompress. Speed, measured natively on the VM (not
  Wine): `-m5` (exhaustive match search) is a real, reproducible ~40%
  faster -- every PGO rep beat every plain rep, not just a favorable
  median; `-m3` is flat and `-m4` is genuinely noisy at this input
  size, reported honestly rather than cherry-picked. See
  `docs/research-notes.md`'s PGO section for the full story and
  numbers.

## [1.0.1] — 2026-07-11

Speed-focused patch release. No archive-format or CLI-default changes —
every front below is verified byte-for-byte identical to 1.0.0 on the
default path with `--seed` fixed, and a full `tests/local_hardening.sh`
pass (4/4 stages) gates the final commit, same as every release since
1.0.0.

### Added

- **LTO (`-flto`)** added to the Makefile's `OPTIMISATION` (covers both
  the native Linux build and the MinGW/Windows cross-compile, which
  share the same variable) and to `CMakeLists.txt`'s non-MSVC path
  (compile *and* link options -- CMake's `add_executable` splits these
  into separate steps, unlike the Makefile's single-invocation build).
  Verified byte-identical across a 90-cell matrix (`-m0`-`-m5` x
  `-t1`/`-t4`/`-t8` x all 5 test corpora, `--seed=42`) and a full
  `local_hardening.sh` pass. Honest result: because this codebase
  compiles from just 2 translation units (`Common.cpp` + `srep.cpp`,
  everything else `#include`d in), LTO's benefit here is narrower than
  usual -- 3-rep-median speed comparisons on a 128 MiB corpus showed no
  consistent win (individual modes ranged -8% to +9%, within
  measurement noise on this host). Kept anyway: zero output risk,
  build-time only cost, and a reasonable default for any future
  refactor that does add more translation units.
- **`-fprofile-generate`/`-fprofile-use` (PGO), maintainer-only release
  build step.** New additive Makefile targets (`make bin/osrep-pgo`,
  `make pgo-clean`) and `tests/pgo_train.sh` (trains across all of
  `-m0`..`-m5` at `-t1` and `-t8`, against `tests/corpus/*.bin`, so
  GCC's profile-guided branch/inlining decisions don't overfit to one
  mode -- `-m3`/`-m4`/`-m5` have measurably different hot-loop
  profiles). **Not** wired into `make`/`make all`/`make install` --
  ordinary from-source builds stay a fast single pass with no `.gcda`
  side effects. Verified: byte-identical vs the plain build across a
  60-cell matrix (`-m0`-`-m5` x `-t1`/`-t8` x all 5 corpora) plus the
  full `roundtrip.sh` suite (30/30) run directly against the PGO
  binary. Speed: noisy, no clearly measurable win at this corpus size
  on this host, same honest caveat as LTO above. **Windows binaries
  ship without PGO in this release** -- reusing the Linux-collected
  profile for the MinGW cross-compile was tried and does not work: GCC
  ties `-fprofile-use`'s LTO profile data to the exact function/GIMPLE
  structure recorded during `-fprofile-generate`, and
  `Compression/Common.cpp`'s `FREEARC_WIN`/`FREEARC_UNIX`-gated code
  paths are different enough between the two OS targets that the
  Windows build silently found no usable profile data for most
  functions. A real Windows PGO profile would need its own
  Wine-collected training pass -- filed as a follow-up, not attempted
  here under time pressure with a fix that doesn't actually apply.
- **Thread-count tuning for F3.3e's prepare_buffer stripe pool**
  (`-m3`/`-m5` only). A `-tN` sweep (`-t1`/`-t2`/`-t4`/`-t8`/`-t16`/
  default, 3-rep medians, compressible + incompressible 128 MiB
  corpora) confirmed F3.3e's own "roughly a wash at this host's full
  56-core default" finding reproducibly: the default was never the
  fastest cell in any of the 4 corpus/mode combinations tested, up to
  ~7% slower than the `-t8`-`-t16` range in the worst case. Fixed by
  capping `PrepThreadsCount` (the stripe pool's own worker count, in
  `Compression/SREP/io.cpp`) at a new `PREP_POOL_MAX = 16` constant,
  independent of `-tN`/`NumThreads` itself -- `-m1`/`-m2`'s separate,
  mature CDC thread pool is untouched and still scales uncapped.
  Provably output-safe (stripe assignment is a pure function of stripe
  index, never of thread count) -- verified via a 60-cell byte-identical
  matrix plus a full `local_hardening.sh` pass. Also fixed the
  long-stale `-tN` help text (`srep.cpp`, `dup_wrapper.cpp`), which
  still said "only for -m1/-m2" since before this pool existed. See
  `docs/research-notes.md`'s F3.3e section for the full sweep table.

### Fixed

- `CMakeLists.txt`'s non-MSVC build used `-funroll-loops`; the Makefile
  (the actually-tested, release-binary-building path) uses
  `-funroll-all-loops`, which `docs/32bit-support.md` documents as
  specifically required for `compress_cdc.cpp` to compile at all on
  i686. Not a live bug today (CMake's non-MSVC path is x86_64-only),
  but a real footgun the moment anyone drives an i686 build through
  CMake instead of the documented direct cross-compile. Aligned to
  match the Makefile.

### Considered, declined

- **Bumping the release binaries' compile-time CPU floor** (e.g.
  `-march=x86-64-v2`) above the current `-msse2`. No file in this repo
  documents a minimum CPU generation -- only an OS floor ("Windows
  10/11 x64 and Linux x64") -- and release binaries are prebuilt for
  arbitrary end-user hardware. A higher floor would `SIGILL`-crash on
  older-but-still-x86_64 CPUs with zero test coverage to catch it
  before a user does, which is worse than the byte-diff regressions
  this project's tests are built to catch. `Compression/SREP/hashes.cpp`'s
  `crc32c()` already shows the right pattern for unlocking newer
  instruction sets safely (runtime `__get_cpuid` dispatch, not a
  compile-time floor bump) -- the right lever if this is revisited, and
  out of scope for a speed-focused patch release. `-mtune=generic` and
  the 32-bit build's own `-msse2` floor are both unaffected either way.

## [1.0.0] — 2026-07-11

**First stable release.** Gated purely on `tests/local_hardening.sh`
passing clean (baseline build+full suite, ASAN+UBSAN rebuild+full
suite, 3-harness libFuzzer soak, mingw-w64 cross-build+Wine smoke
test) -- all 4 stages PASS on this exact commit, elapsed 210s. The
calendar soak window (F6.2) and external review post (F6.4) that were
originally planned as additional v1.0 gates were both explicitly
dropped in favor of this automated gate (see `[1.0a-beta.5]` below);
in their place, this release has real independent validation from a
downstream consumer (**ytool**, via the VMAC cross-project
collaboration documented in `docs/32bit-support.md` Bug #5 and the
project wiki) that found and helped fix a genuine cross-arch bug this
week, and confirmed a clean 357/357 regression suite against this
codebase after the fix.

**Known, documented limitations** (not blockers, both intentional
scope decisions):
- `-hash=sha1` fails decompression checksum verification on 32-bit
  builds (Bug #3, `docs/32bit-support.md`) -- avoid it there; every
  other hash and every mode is confirmed working. 32-bit itself
  remains an opt-in, manually-tested target, not the primary one.
- No cloud CI (`.github/workflows/ci.yml` was removed -- push/PR
  triggers never fired on this repo, root cause suspected
  account-level and unresolved). `tests/local_hardening.sh` is the
  intentional replacement and this release's actual gate.

### Added

- **`-bar`: machine-parseable progress for subprocess integration.** Emits
  `PROGRESS <done> <total>` to stderr (plain integers, single space, no
  thousands separators) roughly every 0.5s during compress/decompress,
  plus a guaranteed final line with `done==total`. Independent of `-s`/
  verbosity's own display cadence -- ticks on its own fixed timer, and
  each line is prefixed with `\n` so it always starts on a clean line
  even though the human `-s` progress display never emits its own `\n`
  (it uses `\r` + backspaces to overwrite in place) -- without that, a
  naive `\n`-splitting consumer could see `PROGRESS` text glued onto
  stale human-readable output mid-line. `done`/`total` are always the
  same unit as each other (input bytes for compress, compressed-stream
  bytes for decompress) though not necessarily the same unit across the
  two directions. Adopted from **ytool**'s own `-bar` flag/format
  (already consumed in production by zpaq-std, which embeds ytool as a
  subprocess) at ytool's suggestion, following up on the earlier VMAC
  cross-project collaboration -- same flag name and line format
  intentionally, so a consumer that already parses ytool's `-bar`
  output recognizes osrep for free with no changes.

## [1.0a-beta.7] — 2026-07-10 (pre-release)

Small hardening follow-up to beta.6, same day, requested by a
downstream consumer (ytool) so their shallow-clone build pipeline has
a tag to pin to. No behavior change on the default path -- verified
byte-for-byte identical on x86_64.

### Fixed

- **VMAC's generic 128-bit ADD128/PMUL64 fallback was miscompiled by
  GCC's strict-aliasing optimizer on i686, producing wrong checksums
  (not a crash) on the 32-bit build.** Found via real cross-project
  collaboration with another SREP-derived project (ytool) that migrated
  to omega-srep and hit a genuine cross-arch decode failure on real
  Windows hardware (did not reproduce under Wine at all). Reproduced
  with zero LZ matches involved (`-m1` on 186483 bytes of pure literal
  content), ruling out match-finding/CDC/Future-LZ entirely, and with
  every method `-m0`-`-m5`; switching to `-hash=md5` made it pass,
  isolating it to VMAC specifically. Root cause: `vmac.c`'s
  `__i386__` branch never defines its own `ADD128`/`MUL64`/`PMUL64`
  (only `GET_REVERSED_64`), so i386 silently uses the file's generic
  portable-C fallback -- and GCC's `-O2`+ strict-aliasing optimizations
  miscompile it (bisected: `-O1` and `-O3 -fno-strict-aliasing` both
  fix it, `-O3` alone doesn't). Same bug *class* as the `poly_step_func`
  issue from F6.12 (pointer-cast buffers nearby confusing the aliasing
  analysis), different macro this time. Fixed with a source-level
  `#pragma GCC optimize ("no-strict-aliasing")` gated to
  `__GNUC__ && __i386__` only -- x86_64 is untouched (it has its own
  asm `ADD128`/`MUL64`, never reaches the fallback). Verified
  byte-for-byte identical x86_64 output, the real failing archive now
  decodes correctly on i686 with a byte-identical hash, and a full
  120-cell matrix (`-m0`-`-m5` × 4 hashes × 5 corpus files) passes
  clean under Wine. See `docs/32bit-support.md` Bug #5.

## [1.0a-beta.6] — 2026-07-10 (pre-release)

Small hardening follow-up to beta.5, same day. No behavior change on
the default path — this is a portability-robustness fix, verified
byte-for-byte identical on x86_64.

### Fixed

- **SSE4.2 hardware CRC32 asm had the same undeclared-register-modification
  risk as the VMAC bug fixed in F6.12.** Flagged by a cross-project code
  review (a different SREP fork shares this exact function) and
  independently confirmed. `a_mm_crc32_u8` (`Compression/SREP/hashes.cpp`,
  used by `-m1`/`-m2`'s CDC rolling hash on any SSE4.2 CPU, 32- or 64-bit —
  a live path, not dead code) declared its byte-sized operand with a `"rm"`
  constraint, which allows GCC to pick a non-byte-addressable register
  (esi/edi/ebp/esp on i386 have no 8-bit sub-register) — this project's own
  build only avoided it by accident of the compiler currently choosing
  memory instead. Fixed: `"rm"` → `"qm"` (byte-addressable registers only,
  valid on both architectures), plus a defensive `"cc"` clobber. Verified
  byte-for-byte identical x86_64 output and a real 10/10 `-m1`/`-m2`
  round-trip pass on the 32-bit build under Wine. See `docs/32bit-support.md`
  Bug #4.

## [1.0a-beta.5] — 2026-07-10 (pre-release)

Algorithmic + hardening + release-process snapshot since 1.0a-beta.4.
`osrep -m4` and `osrep -dup -m4` (no new flags) produce byte-identical
archives to beta.4 on the same input + params — every change that
touches match-search or hashing internals (F3.3e, the VMAC fix) was
verified byte-for-byte unchanged on the default path before being
shipped. The two genuinely new, opt-in behaviors are `--chunk-hash=gear`
(F5.6) and 32-bit build support (F6.12) — neither is on by default.

### Added

- **32-bit (i686) build support, opt-in (F6.12).** Re-enabled the
  `_32_or_64`/`_32_only` hooks that were hardcoded off when this fork
  scoped itself to x86_64-only, and widened the `#error` guards in
  `Compression/Common.h`/`srep.cpp` to also accept i686. Building and
  running 32-bit for the first time surfaced two real bugs: (1) `-d`/
  `-mem=` values >= 4 GiB silently wrapped to a smaller value instead
  of failing or clamping (`parse_mem_option` was narrowing through
  `size_t` before its own clamp could see the real value) — fixed by
  using the already-existing `parseMem64`. (2) the bundled third-party
  VMAC hash (the *default* hash, and the one `-m0`/`-m1`/`-m2`/`-m3`
  use internally regardless of `-hash=`) crashed on every 32-bit build
  — root-caused to a GCC extended-asm bug in `vmac.c`'s hand-written
  MMX loop (`nh_16_func`: ESI/EDI/ECX modified by the asm but declared
  as plain read-only inputs, letting `-O2+`'s `-fipa-ra` skip a
  register reload across two back-to-back calls) — fixed with the
  correct `"+"`-operand declaration; same defensive fix applied to a
  second, currently-dormant instance of the same bug class in
  `poly_step_func`. Both fixes verified against Krovetz's published
  VMAC known-answer vectors and re-confirmed on a real Windows 7 x64
  VM (not just Wine). One separate, pre-existing bug found and left
  open: `-hash=sha1` fails decompression checksum verification on
  32-bit (unrelated to the VMAC fix, not yet root-caused) — avoid it
  on 32-bit until fixed. Every other hash and every compression mode
  is confirmed working. See `docs/32bit-support.md` for the full
  writeup and evidence.

- **`--chunk-hash=gear` opt-in CDC hash for `-dup` (F5.6).** The
  default FNV chunker (`h=h*PRIME+byte`, reset only at cuts) has no
  fixed window, so it silently misses duplicate content that isn't
  aligned to the `--chunk-buf` reset grid. Gear-hash CDC
  (`h=(h<<1)+GEAR[byte]`) has an implicit ~64-byte content window that
  finds these duplicates regardless of offset — confirmed on a real
  misaligned 8MiB duplicate: `fnv` dedup-body ratio 1.0000 (found
  nothing) vs `gear` 0.6064 (recovered 96.1%). Opt-in only — default
  behavior (`--chunk-hash=fnv`, i.e. no flag) is byte-for-byte
  unchanged, no `.dupref` format change. Note: final `osrep -dup`
  archive size looks nearly identical either way, because SREP's own
  match finder independently recovers what the CDC pre-pass misses —
  the real benefit is `-dup` actually delivering its bounded-RAM
  purpose for misaligned duplicates, not smaller archives; measure
  dedup-body ratio directly (see `tests/dup_gear_hash_test.sh`), not
  final archive size, to see the effect. Two real limitations found by
  review: a `--chunk-avg<64` collapse-to-fixed-size bug (fixed in this
  same change) and a periodic-content edge case where the degenerate-input
  safeguard reintroduces alignment-dependence (documented, not fixed —
  filed as F5.6a). See `docs/research-notes.md` F5.6 sections.

- **Stripe-parallel `prepare_buffer` for `-m3`/`-m5` (F3.3e).** A
  profiling spike (gated `-pc` instrumentation, matching the existing
  diagnostic-counter pattern) measured `HashTable::prepare_buffer`'s
  digest-precompute (`-m3`) and SliceHash (`-m5`) loops at 25–69% of
  BG-thread active time — well above a "worth it" bar — so they're now
  striped across worker threads (`Compression/SREP/hash_table.cpp`,
  `io.cpp`), reusing the same `MultipleProcessingThreads<Job>` template
  already used by `-m1`/`-m2`. Zero changes to the match-search core.
  Verified byte-for-byte identical output vs unmodified code with
  `--seed` fixed (naive comparison without `--seed` is misleading —
  output is intentionally non-deterministic run-to-run otherwise), full
  test suite clean. ~13–18% faster on a 512MiB compressible-text buffer
  at moderate thread counts; noisier and roughly a wash at this host's
  full 56-core default — thread-count tuning independent of `-tN` is a
  follow-up, not done here. See `docs/research-notes.md` F3.3e.

- **`tests/local_hardening.sh` (F6.11).** Wires together everything
  cloud CI used to cover, plus the manual sanitizer/libFuzzer/Windows
  gates that were previously only documented and run by hand: (1)
  baseline build + full test suite, (2) ASAN+UBSAN rebuild + full test
  suite, (3) all 3 libFuzzer harnesses soaked from their existing
  corpora (`HARDEN_FUZZ_SECONDS`, default 40s each), (4) CMake +
  mingw-w64 cross-build with a Wine smoke test (`--help` + a minimal
  round-trip). Fails fast with a labeled stage/command/exit-code on
  the first failure; optional-tool stages (mingw-w64/cmake, Wine) skip
  loudly rather than silently passing. ~3.5 min end-to-end on this
  host. Building it surfaced two real, previously-unknown bugs, both
  specific to Linux-hosted mingw-w64 cross-compilation (invisible on
  native Windows/NTFS, so never caught before):
    - `Compression/Common.cpp:1052` includes `<ShObjIdl.h>`
      (mixed-case); mingw-w64's headers only ship lowercase
      `shobjidl.h`, so this only fails on a case-sensitive filesystem.
      Worked around in the script with a 1-line shim header, not fixed
      at the source.
    - `CMakeLists.txt`'s static-link gate is
      `CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT WIN32`, which
      excludes the one case that most wants `-static` (GNU/mingw
      targeting Windows) — the cross-compiled `osrep.exe` ends up
      dynamically linked against `libstdc++`/`libgcc_s`, unlike the
      Makefile-built release binaries. Worked around in the script by
      copying the two runtime DLLs alongside the exe for the Wine
      smoke test; the gate itself is still `AND NOT WIN32` and should
      be fixed to `AND NOT MSVC`.

### Changed

- **Dropped the F6.2 soak window as a v1.0 stable gate.** F6.2 was a
  passive 2-4 week calendar wait (see `docs/upstream-comparison.md`)
  before declaring v1.0 stable, meant to let real/adversarial usage
  surface regressions the test suite didn't catch. Decided this isn't
  worth gating a release on: `tests/local_hardening.sh` (F6.11) now
  runs the full build+test suite, an ASAN+UBSAN rebuild, a 3-harness
  libFuzzer soak, and a Windows cross-build/Wine smoke test on every
  push-equivalent check — the automated coverage the soak window was
  meant to approximate over time now runs on demand instead. v1.0
  stable readiness is gated on `tests/local_hardening.sh` passing
  clean, not on elapsed calendar time.

- **Dropped F6.4 (external community review post) as a v1.0 stable
  gate.** F6.4 was a plan to post to encode.su/r/cpp/r/compression
  asking for pre-1.0 review before promoting beta.4 to stable. Decided
  v1.0 stable no longer waits on that either — the three drafts stay
  in `docs/review-call-for-feedback.md` for optional, unhurried use if
  wanted later, but nothing about the release timeline depends on
  them being published. Combined with the F6.2 drop above, v1.0 stable
  readiness is now gated purely on `tests/local_hardening.sh` passing
  clean, with no external-facing or calendar-based precondition.

### Removed

- **GitHub Actions CI workflow (`.github/workflows/ci.yml`).** Push/PR
  -triggered CI never fired on this repo. Two fix attempts: (1)
  confirmed Actions were already enabled at the repo level
  (`enabled: true`, `allowed_actions: "all"`); (2) detached the repo
  from its former fork parent (`Intensity/srep`) via GitHub Support,
  confirmed via API (`fork: false`) — pushing after the detach still
  produced **zero check-suites**, ruling out both repo-level config
  and fork status as the cause. Root cause is suspected account-level
  (billing/Actions spending limit, or a GitHub App install
  restriction) and needs dashboard access this token doesn't have.
  Decided to stop relying on cloud CI as a safety net and lean on the
  local test suite (`tests/*.sh`) instead — all still pass, run before
  every push. Revisit if external contributors start submitting PRs
  and the account-level blocker gets resolved separately.

## [1.0a-beta.4] — 2026-04-27 (pre-release)

Tooling + portability snapshot. No behavior change for users running
the shipped binaries — `osrep -m4` and `osrep -dup -m4` produce
byte-equal output to 1.0a-beta.3 (verified via the new F6.10
multi-corpus bench, which round-trips byte-for-byte against upstream
SREP 3.92). The bump exists so the release tarball + binaries stay
in sync with the source tree, which has materially grown since
beta.3 with the F6.7 fuzz expansion, F6.8 alternative CMake build
path, and F6.10 comparative bench.

### Added

- **F6.10 multi-corpus comparative bench**
  (`tests/multi_corpus_bench.sh`, `docs/multi-corpus-bench.md`).
  Runs Omega vs upstream SREP 3.92 vs FA 0.11 across three corpora
  (synth-128M, enwik8, 1.79 GiB tarball). 15/15 cells round-trip
  OK. Confirms `osrep -m4` produces byte-equal archives to
  `srep64 -m4` on every corpus (fork parity), `-dup` cuts decompress
  RSS by 66% on long-range-dup corpora at +0.28% archive bloat,
  and Omega's `-dup` ratio matches FA 0.11's reference impl within
  0.5%-of-input.
- **F6.8 alternative build path via CMake** (`CMakeLists.txt`,
  `docs/windows-build.md`). Existing Makefile remains the primary
  path (CI uses it; release binaries are built from it). CMake is
  toolchain-agnostic -- works with GCC, clang, MinGW-w64,
  llvm-mingw; the supported Windows path is MinGW-w64 via scoop
  or MSYS2, all FOSS. Configures + builds clean with GCC 14 and
  clang 19 on Linux as a portability smoke test. The accompanying
  source-level audit found a single MSVC-affecting issue
  (`Handle.h` include gate in `Synchronization.h` was widening
  the include for native MSVC; widened to also exclude
  `_MSC_VER`). MinGW + Linux behavior unchanged.
- **F6.7 fuzz coverage expansion**
  (`tests/fuzz_decode_streaming.cc`, `tests/fuzz_encode_split.cc`).
  Two new libFuzzer harnesses cover the file-based seek-back
  decoder and the in-memory two-output encoder. 5-min soaks on
  each: zero crashes / leaks / hangs.

### Process notes

- All changes since beta.3 are tooling / portability / coverage —
  no code-path or on-disk-format changes. Archives produced by
  beta.3 are identical to archives produced by beta.4 on the same
  input + same params (verified by the F6.10 bench cells running
  cmp on round-trip output).

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
