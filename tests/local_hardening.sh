#!/usr/bin/env bash
#
# tests/local_hardening.sh -- local replacement for the deleted
# .github/workflows/ci.yml.
#
# Push/PR-triggered GitHub Actions CI never fired on this repo (root
# cause suspected account-level; see CHANGELOG.md's [Unreleased]
# "Removed" section and docs/research-notes.md). This script wires
# together everything that CI used to cover, plus the manual
# sanitizer / libFuzzer / Windows-cross-build gates that were
# previously only documented (docs/sanitizer-runs.md,
# docs/windows-build.md, the fuzz harness build-comments) and run by
# hand before a release.
#
# Stages (run in order, each one must fully pass before the next
# starts):
#   1. Baseline build (Makefile) + the full existing shell-script test
#      suite -- the same suite ci.yml ran, plus fuzz_regression.sh.
#   2. Rebuild with ASAN+UBSAN, rerun the same suite under the
#      combined-sanitizer env-var pattern documented in
#      docs/sanitizer-runs.md ("ASAN+UBSAN combined run").
#   3. Compile the 3 libFuzzer harnesses and soak each one, seeded
#      from its own corpus dir, for HARDEN_FUZZ_SECONDS (default 40s,
#      override via env). Any crash/hang/OOM fails the stage.
#   4. Cross-compile via CMake + mingw-w64 and smoke-test the
#      resulting osrep.exe under Wine (--help + a tiny round-trip).
#      If mingw-w64 or cmake is missing, the whole stage is skipped
#      with a loud warning. If Wine specifically is missing, the
#      cross-build still runs (that alone is a useful smoke test) but
#      the runtime check is skipped with its own loud warning.
#
# Fails fast: the first failing command anywhere aborts the whole
# script immediately (bash `set -e`) with a clearly labeled error
# naming the stage, the failing command, and its exit code. A
# one-line PASS/FAIL/SKIP summary for every stage is printed at the
# end regardless of where execution stopped.
#
# Tunables (env vars):
#   HARDEN_FUZZ_SECONDS   libFuzzer soak duration per harness, in
#                         seconds. Default 40 (3 harnesses -> ~2 min).
#
# Exit code: 0 iff every stage that was reached PASSED (stages
# skipped for a missing optional tool do not fail the run).

set -Eeuo pipefail

# ---------------------------------------------------------------- #
# Setup
# ---------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

NPROC="$(command -v nproc >/dev/null 2>&1 && nproc || echo 4)"
HARDEN_FUZZ_SECONDS="${HARDEN_FUZZ_SECONDS:-40}"

RUN_TMPROOT="$(mktemp -d -t osrep-local-hardening-XXXXXX)"
LOGDIR="$RUN_TMPROOT/logs"
mkdir -p "$LOGDIR"

START_TS=$(date +%s)

STAGE_ORDER=(s1 s2 s3 s4)
declare -A STAGE_LABEL=(
  [s1]="Stage 1: baseline build + full test suite"
  [s2]="Stage 2: ASAN+UBSAN rebuild + full test suite"
  [s3]="Stage 3: libFuzzer soak (3 harnesses x ${HARDEN_FUZZ_SECONDS}s)"
  [s4]="Stage 4: mingw-w64 cross-build + Wine smoke test"
)
declare -A STAGE_STATUS
for s in "${STAGE_ORDER[@]}"; do STAGE_STATUS[$s]="NOT RUN"; done
CURRENT_STAGE=""

# ---------------------------------------------------------------- #
# Small helpers
# ---------------------------------------------------------------- #

section() {
    echo
    echo "==================================================================="
    echo "== $*"
    echo "==================================================================="
}

note() {
    echo "  NOTE: $*"
}

warn_loud() {
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "!! WARNING: $*" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
}

# run_logged DESC LOGFILE cmd...
# Runs cmd with stdout+stderr captured to LOGFILE. On failure, prints
# the tail of the log (for immediate context) and returns 1 -- this
# is a plain top-level statement everywhere it's called, so bash's
# `set -e` aborts the enclosing stage function right after, which is
# what drives the fail-fast behavior.
run_logged() {
    local desc="$1" logfile="$2"
    shift 2
    echo "  -> $desc"
    echo "     log: $logfile"
    if ! "$@" >"$logfile" 2>&1; then
        echo "     FAILED. Last 40 lines of log:" >&2
        tail -n 40 "$logfile" >&2 || true
        return 1
    fi
}

# resolve_cxx: mirror the Makefile's own CXX_CANDIDATE fallback chain
# (which c++ -> which g++ -> which clang++ -> g++) so the manually
# -compiled bin/dedup_test in stage 2 uses the same compiler the
# Makefile would pick for bin/osrep on this host.
resolve_cxx() {
    command -v c++ 2>/dev/null || command -v g++ 2>/dev/null || command -v clang++ 2>/dev/null || echo g++
}

# ---------------------------------------------------------------- #
# Stage 1: baseline build + full existing test suite
# ---------------------------------------------------------------- #

stage1_baseline() {
    section "${STAGE_LABEL[s1]}"

    run_logged "make clean" "$LOGDIR/s1-clean.log" make clean
    run_logged "make bin/osrep bin/dedup_test" "$LOGDIR/s1-build.log" \
        make -j"$NPROC" bin/osrep bin/dedup_test

    echo "  -> running full test suite (unsanitized baseline)"
    bash tests/roundtrip.sh
    OSREP_FUZZ_DUP=1 bash tests/fuzz.sh 10
    bash tests/dedup_xtest.sh
    bash tests/dup_roundtrip.sh
    bash tests/dup_native_roundtrip.sh
    bash tests/dup_corruption_fuzz.sh
    bash tests/dup_concurrency.sh
    bash tests/fuzz_regression.sh

    STAGE_STATUS[s1]="PASS"
}

# ---------------------------------------------------------------- #
# Stage 2: ASAN+UBSAN rebuild + full existing test suite
# ---------------------------------------------------------------- #

stage2_sanitizer() {
    section "${STAGE_LABEL[s2]}"
    note "docs/sanitizer-runs.md documents an ASAN-only build as the"
    note "primary gate, plus a separate \"ASAN+UBSAN combined run\""
    note "section for exercising both sanitizers at once (plain"
    note "-fsanitize=address,undefined + UBSAN halt_on_error=0, since"
    note "halt_on_error=1 aborts on known-accepted unaligned-read noise"
    note "in vendored VMAC/SipHash on x86_64). This stage uses that"
    note "combined variant."

    run_logged "make clean" "$LOGDIR/s2-clean.log" make clean
    run_logged "make bin/osrep (ASAN+UBSAN)" "$LOGDIR/s2-build-osrep.log" \
        make -j"$NPROC" bin/osrep \
        CFLAGS="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer" \
        LDFLAGS="-lpthread -lstdc++ -fsanitize=address,undefined" \
        STATIC=""

    # Makefile gap discovered while building this script: the
    # bin/dedup_test rule hardcodes its own compile line and does not
    # reference $(CFLAGS)/$(LDFLAGS) at all, so the documented
    # recipe `make bin/osrep bin/dedup_test CFLAGS=... LDFLAGS=...`
    # silently produces an *uninstrumented* dedup_test (verified: `nm
    # bin/dedup_test | grep asan` is empty after that invocation).
    # That means dedup_xtest.sh and fuzz_regression.sh -- both of
    # which exercise bin/dedup_test, not bin/osrep -- would get zero
    # sanitizer coverage under the documented recipe. Compile it
    # directly instead so this stage actually covers it.
    note "Makefile's bin/dedup_test rule ignores CFLAGS/LDFLAGS (real gap,"
    note "not fixed here -- see script comments); compiling it directly"
    note "with sanitizer flags instead so dedup_xtest.sh/fuzz_regression.sh"
    note "actually get ASAN+UBSAN coverage."
    local cxx
    cxx="$(resolve_cxx)"
    run_logged "compile bin/dedup_test (ASAN+UBSAN, direct)" \
        "$LOGDIR/s2-build-dedup_test.log" \
        "$cxx" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
        -Wall -Wextra -Wno-unused-parameter \
        tests/dedup_test.cpp -lstdc++ -fsanitize=address,undefined \
        -o bin/dedup_test

    echo "  -> running full test suite under ASAN+UBSAN"
    export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1"
    export UBSAN_OPTIONS="halt_on_error=0:print_stacktrace=0"
    bash tests/roundtrip.sh
    OSREP_FUZZ_DUP=1 bash tests/fuzz.sh 5
    bash tests/dedup_xtest.sh
    bash tests/dup_roundtrip.sh
    bash tests/dup_native_roundtrip.sh
    bash tests/dup_corruption_fuzz.sh
    bash tests/dup_concurrency.sh
    bash tests/fuzz_regression.sh
    unset ASAN_OPTIONS UBSAN_OPTIONS

    STAGE_STATUS[s2]="PASS"
}

# ---------------------------------------------------------------- #
# Stage 3: libFuzzer soak (3 harnesses)
# ---------------------------------------------------------------- #

stage3_fuzz_soak() {
    section "${STAGE_LABEL[s3]}"

    if ! command -v clang++ >/dev/null 2>&1; then
        echo "clang++ not found; libFuzzer harnesses require it." >&2
        return 1
    fi

    mkdir -p tests/fuzz-artifacts

    # NOTE: tests/fuzz_decode.cc's own build-comment omits `-I .`,
    # which actually makes that exact documented command fail (its
    # `#include "Compression/SREP/dedup.cpp"` cannot resolve without
    # the repo root on the include path). Confirmed by trying the
    # comment's literal command before writing this script.
    # fuzz_decode_streaming.cc / fuzz_encode_split.cc's comments
    # already include `-I .`. Using `-I . -I Compression -I
    # Compression/SREP` for all three, uniformly, since that's what
    # actually compiles.
    note "fuzz_decode.cc's own build-comment is missing -I . (verified"
    note "broken as literally written); using -I . for all 3 harnesses."

    local common_flags=(-O1 -g -fsanitize=fuzzer,address,undefined -I . -I Compression -I Compression/SREP)

    run_logged "compile fuzz_decode" "$LOGDIR/s3-build-fuzz_decode.log" \
        clang++ "${common_flags[@]}" tests/fuzz_decode.cc -o bin/fuzz_decode
    run_logged "compile fuzz_decode_streaming" "$LOGDIR/s3-build-fuzz_decode_streaming.log" \
        clang++ "${common_flags[@]}" tests/fuzz_decode_streaming.cc -o bin/fuzz_decode_streaming
    run_logged "compile fuzz_encode_split" "$LOGDIR/s3-build-fuzz_encode_split.log" \
        clang++ "${common_flags[@]}" tests/fuzz_encode_split.cc -o bin/fuzz_encode_split

    echo "  -> soaking each harness for ${HARDEN_FUZZ_SECONDS}s (HARDEN_FUZZ_SECONDS to override)"

    run_logged "fuzz_decode soak" "$LOGDIR/s3-run-fuzz_decode.log" \
        bin/fuzz_decode -max_total_time="$HARDEN_FUZZ_SECONDS" -max_len=16777216 \
        -artifact_prefix=tests/fuzz-artifacts/ tests/fuzz-corpus

    run_logged "fuzz_decode_streaming soak" "$LOGDIR/s3-run-fuzz_decode_streaming.log" \
        bin/fuzz_decode_streaming -max_total_time="$HARDEN_FUZZ_SECONDS" -max_len=16777216 \
        -artifact_prefix=tests/fuzz-artifacts/ tests/fuzz-corpus-decode-streaming

    run_logged "fuzz_encode_split soak" "$LOGDIR/s3-run-fuzz_encode_split.log" \
        bin/fuzz_encode_split -max_total_time="$HARDEN_FUZZ_SECONDS" -max_len=16777216 \
        -artifact_prefix=tests/fuzz-artifacts/ tests/fuzz-corpus-encode-split

    # Belt-and-suspenders: libFuzzer exits non-zero on a crash (which
    # run_logged already turns into a stage failure), but also fail
    # loudly if a crash/oom/timeout artifact was left behind by a run
    # that somehow still exited 0.
    shopt -s nullglob
    local artifacts=(tests/fuzz-artifacts/*)
    shopt -u nullglob
    if (( ${#artifacts[@]} > 0 )); then
        echo "libFuzzer left artifacts behind -- treating as a crash:" >&2
        printf '  %s\n' "${artifacts[@]}" >&2
        return 1
    fi

    STAGE_STATUS[s3]="PASS"
}

# ---------------------------------------------------------------- #
# Stage 4: Windows cross-build (CMake + mingw-w64) + Wine smoke test
# ---------------------------------------------------------------- #

stage4_mingw_wine() {
    section "${STAGE_LABEL[s4]}"

    if ! command -v cmake >/dev/null 2>&1 || ! command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1; then
        warn_loud "cmake and/or x86_64-w64-mingw32-g++ (mingw-w64) not found -- SKIPPING Windows cross-build smoke test entirely. This stage did NOT run, it did not silently pass."
        STAGE_STATUS[s4]="SKIP (mingw-w64/cmake not installed)"
        return 0
    fi

    local build_dir="$RUN_TMPROOT/build-mingw"
    local shim_dir="$RUN_TMPROOT/mingw-shim"
    local toolchain_file="$RUN_TMPROOT/mingw-toolchain.cmake"
    mkdir -p "$shim_dir"

    # Real bug found while building this script (Linux-only, cosmetic
    # on native Windows): Compression/Common.cpp:1052 does
    # `#include <ShObjIdl.h>` (mixed case) inside a
    # `!defined(__GNUC__) || __GNUC__>=4` branch that mingw-w64 GCC
    # also takes. mingw-w64's headers only ship the lowercase
    # `shobjidl.h`, so this only breaks on a case-sensitive filesystem
    # (i.e. cross-compiling from Linux) -- invisible on native
    # Windows/NTFS, which is why it's never been caught before.
    # Not fixed in the source (out of scope for this script); worked
    # around here with a 1-line shim header on the include path so
    # the cross-build smoke test can actually run.
    note "working around Common.cpp:1052's #include <ShObjIdl.h>"
    note "(mixed-case) -- mingw-w64 only ships lowercase shobjidl.h,"
    note "which only breaks on a case-sensitive fs (Linux-hosted"
    note "cross-compile). Injecting a 1-line shim header, not editing"
    note "the source."
    printf '#include <shobjidl.h>\n' > "$shim_dir/ShObjIdl.h"

    cat > "$toolchain_file" <<'EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER   x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER  x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

    local gen_args=()
    if command -v ninja >/dev/null 2>&1; then
        gen_args=(-G Ninja)
    else
        note "ninja not found; using CMake's default Makefile generator" \
             "(docs/windows-build.md's -G Ninja is orthogonal to the" \
             "mingw cross-compile question)."
    fi

    run_logged "cmake configure (mingw-w64 toolchain)" "$LOGDIR/s4-configure.log" \
        cmake -B "$build_dir" "${gen_args[@]}" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
        -DCMAKE_CXX_FLAGS="-I$shim_dir" -DCMAKE_C_FLAGS="-I$shim_dir"

    run_logged "cmake --build" "$LOGDIR/s4-build.log" \
        cmake --build "$build_dir" -j"$NPROC"

    if [[ ! -f "$build_dir/osrep.exe" ]]; then
        echo "cmake build reported success but $build_dir/osrep.exe is missing" >&2
        return 1
    fi
    echo "  -> built: $build_dir/osrep.exe"

    if ! command -v wine >/dev/null 2>&1; then
        warn_loud "wine not found -- SKIPPING runtime smoke test of osrep.exe. The mingw cross-build itself succeeded (see above); only the Wine-based execution check is skipped, not silently marked as passed."
        STAGE_STATUS[s4]="PASS (build-only; wine not installed, runtime smoke skipped)"
        return 0
    fi

    # Real bug found while building this script: CMakeLists.txt's
    # `-static` link gate is `GNU AND NOT WIN32`, which excludes the
    # one case (GNU/mingw compiler targeting Windows) that most wants
    # it. The resulting osrep.exe is dynamically linked against
    # libstdc++/libgcc_s, unlike the Makefile-built release binaries.
    # Not fixed in CMakeLists.txt here; worked around by copying the
    # two runtime DLLs next to the exe so the Wine smoke test can run.
    note "CMakeLists.txt's -static gate is 'GNU AND NOT WIN32', which"
    note "excludes mingw-targeting-Windows -- the exe is dynamically"
    note "linked. Copying runtime DLLs next to it so Wine can load it."
    local libstdcxx_dll libgcc_dll
    libstdcxx_dll="$(x86_64-w64-mingw32-g++ -print-file-name=libstdc++-6.dll)"
    libgcc_dll="$(x86_64-w64-mingw32-g++ -print-file-name=libgcc_s_seh-1.dll)"
    if [[ -f "$libstdcxx_dll" ]]; then cp "$libstdcxx_dll" "$build_dir/"; fi
    if [[ -f "$libgcc_dll" ]]; then cp "$libgcc_dll" "$build_dir/"; fi

    echo "  -> Wine smoke test: --help"
    export WINEDEBUG=-all
    run_logged "wine osrep.exe --help" "$LOGDIR/s4-wine-help.log" \
        env -C "$build_dir" timeout 30 wine ./osrep.exe --help
    if ! grep -qi "Omega SREP" "$LOGDIR/s4-wine-help.log"; then
        echo "wine ran osrep.exe --help but expected banner text was not found" >&2
        return 1
    fi

    echo "  -> Wine smoke test: minimal round-trip"
    head -c 65536 /dev/urandom > "$build_dir/smoke-in.bin"
    run_logged "wine osrep.exe -m4 (compress)" "$LOGDIR/s4-wine-compress.log" \
        env -C "$build_dir" timeout 30 wine ./osrep.exe -m4 smoke-in.bin smoke-in.osr
    run_logged "wine osrep.exe -d (decompress)" "$LOGDIR/s4-wine-decompress.log" \
        env -C "$build_dir" timeout 30 wine ./osrep.exe -d smoke-in.osr smoke-out.bin
    if ! cmp -s "$build_dir/smoke-in.bin" "$build_dir/smoke-out.bin"; then
        echo "Wine round-trip mismatch: smoke-in.bin != smoke-out.bin" >&2
        return 1
    fi
    unset WINEDEBUG

    STAGE_STATUS[s4]="PASS"
}

# ---------------------------------------------------------------- #
# Traps: clear labeled error on failure, PASS/FAIL/SKIP summary
# always printed at the end.
# ---------------------------------------------------------------- #

on_err() {
    local ec=$?
    echo >&2
    echo "===================================================================" >&2
    echo "FATAL: ${STAGE_LABEL[$CURRENT_STAGE]:-<unknown stage>} FAILED" >&2
    echo "  failing command: $BASH_COMMAND" >&2
    echo "  at line:         ${BASH_LINENO[0]:-?}" >&2
    echo "  exit code:       $ec" >&2
    echo "===================================================================" >&2
}
trap on_err ERR

on_exit() {
    local ec=$?
    if [[ -n "$CURRENT_STAGE" && "${STAGE_STATUS[$CURRENT_STAGE]}" == "NOT RUN" ]]; then
        if (( ec != 0 )); then
            STAGE_STATUS[$CURRENT_STAGE]="FAIL"
        fi
    fi

    local end_ts elapsed
    end_ts=$(date +%s)
    elapsed=$(( end_ts - START_TS ))

    echo
    echo "==================================================================="
    echo "local_hardening.sh summary (elapsed ${elapsed}s)"
    echo "==================================================================="
    for s in "${STAGE_ORDER[@]}"; do
        printf '  %-58s %s\n' "${STAGE_LABEL[$s]}" "${STAGE_STATUS[$s]}"
    done
    echo "==================================================================="

    # Keep logs (and the mingw build tree) around for post-mortem on
    # failure; on a clean pass there's nothing worth digging through,
    # so don't leak ~30MB/run into /tmp indefinitely.
    if (( ec == 0 )); then
        rm -rf "$RUN_TMPROOT"
    else
        echo "run tmp dir / logs kept for inspection: $RUN_TMPROOT" >&2
    fi

    exit "$ec"
}
trap on_exit EXIT

# ---------------------------------------------------------------- #
# Main
# ---------------------------------------------------------------- #

echo "tests/local_hardening.sh starting in $ROOT"
echo "HARDEN_FUZZ_SECONDS=$HARDEN_FUZZ_SECONDS  (override to change libFuzzer soak length)"
echo "run tmp dir / logs: $RUN_TMPROOT"

CURRENT_STAGE=s1
stage1_baseline

CURRENT_STAGE=s2
stage2_sanitizer

CURRENT_STAGE=s3
stage3_fuzz_soak

CURRENT_STAGE=s4
stage4_mingw_wine

# All stages reached and passed (or were cleanly skipped). Restore
# bin/osrep and bin/dedup_test to a normal, non-sanitizer-instrumented
# build so the repo isn't left in a state where the last thing in
# bin/ is an ASAN binary. Best-effort / non-fatal: this is cleanup,
# not a gate, so a failure here doesn't flip the overall PASS result.
section "Restoring plain (non-sanitizer) build in bin/"
if make clean >"$LOGDIR/restore-clean.log" 2>&1 && \
   make -j"$NPROC" bin/osrep bin/dedup_test >"$LOGDIR/restore-build.log" 2>&1; then
    echo "  bin/osrep, bin/dedup_test rebuilt without sanitizers."
else
    echo "  WARNING: could not restore plain build (non-fatal; see $LOGDIR/restore-*.log)" >&2
fi

CURRENT_STAGE=""
echo
echo "All stages complete."
