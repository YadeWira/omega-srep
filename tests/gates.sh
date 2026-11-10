#!/usr/bin/env bash
# Gate runner.
#
#   tests/gates.sh core   the suite that must pass without the oracles: the
#                         golden cases (archives, CLI, hashes), the v6 suite,
#                         its frame self-test and the decoder's crash-replay.
#                         harness_selftest builds the Rust harness, so it is
#                         differential.
#   tests/gates.sh full   core plus the differential suites, which need the
#                         C++ and the Rust oracles (builds them if missing).
#
# Logs go to OSREP_GATES_LOGS (a temp dir otherwise) and every line says the
# tag, the exit code and the last line of its log. The script keeps going and
# exits 1 if anything failed.
#
# Wine runs are not here on purpose: they need a private WINEPREFIX and the
# wrappers, and are part of the release checklist, not of a normal checkout.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

MODE=${1:-core}
case "$MODE" in
    core|full) ;;
    *) printf 'usage: tests/gates.sh core|full\n' >&2; exit 2 ;;
esac

# full needs the archived oracles; fail before the corpus and the core run so
# the instruction is the first thing on screen.
if [ "$MODE" = full ] && [ -z "${OSREP_ORACLES:-}" ]; then
    printf 'FAIL: full needs the archived oracles: extract the tarball from\n' >&2
    printf '  https://github.com/YadeWira/omega-srep/releases/tag/oracle-cxx-1.0.7\n' >&2
    printf 'and set OSREP_ORACLES to the directory that contains cxx/ and rust/\n' >&2
    printf '(see docs/retired-oracles.md).\n' >&2
    exit 2
fi

LOGS="${OSREP_GATES_LOGS:-}"
if [ -z "$LOGS" ]; then
    LOGS="$(mktemp -d)"; CLEAN_LOGS=1
else
    mkdir -p "$LOGS"; CLEAN_LOGS=0
fi
FAILED=0

run() {
    local tag=$1
    shift
    timeout 3600 "$@" > "$LOGS/$tag.log" 2>&1
    local rc=$?
    printf '%-22s rc=%s :: %s\n' "$tag" "$rc" "$(grep -v '^\s*$' "$LOGS/$tag.log" | tail -1)"
    [ "$rc" -eq 0 ] || FAILED=$((FAILED + 1))
}

# The corpus is gitignored; the failures without it are confusing.
if [ ! -f tests/corpus/text.bin ]; then
    printf 'generating tests/corpus with tests/gen_corpus.sh\n'
    bash tests/gen_corpus.sh >/dev/null 2>&1 || {
        printf 'FAIL: cannot generate tests/corpus\n' >&2; exit 1
    }
fi

printf '== core (no oracles)\n'
run golden       bash tests/golden/check.sh
run v6           bash tests/v6_conformance.sh
run v6-frame     bash tests/v6_frame_selftest.sh
run fuzz-replay  bash tests/fuzz_regression.sh

if [ "$MODE" = full ]; then
    printf '== differential (needs C++ and Rust)\n'
    run cargo-build  env -C "$RUST_DIR" cargo build --release --target x86_64-unknown-linux-gnu -p osrep-cli
    run cargo-test   env -C "$RUST_DIR" cargo test --release
    run rust-conf    bash tests/rust_conformance.sh
    run rust-cli     bash tests/rust_cli_conformance.sh
    for s in hash encode decode v5 dup cli container futurelz; do
        run "pas-$s" bash "tests/pascal_${s}_conformance.sh"
    done
    run pas-rustcli  env OSREP_PORT_BIN="$PWD/pascal/bin/osrep-linux-x86_64" bash tests/rust_cli_conformance.sh
    # These two are regressions of the port: run them against the Pascal, not
    # against the C++ oracle (dup_length fails on the C++, which has the bug).
    run m3grid       env OSREP_BIN="$PWD/pascal/bin/osrep-linux-x86_64" bash tests/m3_grid_regress.sh
    run duplen       env OSREP_BIN="$PWD/pascal/bin/osrep-linux-x86_64" bash tests/dup_length_regression.sh
    run tie          bash tests/cxx_sort_tie_divergence.sh
    run realworld    bash tests/real_world_scan_regression.sh
    run selftest     bash tests/harness_selftest.sh
fi

if [ "$CLEAN_LOGS" = 1 ]; then
    if [ "$FAILED" -eq 0 ]; then
        rm -rf "$LOGS"
    else
        printf 'logs kept in %s\n' "$LOGS"
    fi
fi

[ "$FAILED" -eq 0 ] || { printf 'FAILED: %d gate(s)\n' "$FAILED" >&2; exit 1; }
printf '== all gates passed (%s)\n' "$MODE"
