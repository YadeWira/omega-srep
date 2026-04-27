#!/usr/bin/env bash
# Replay every captured-and-fixed crash artifact in tests/fuzz-regression/
# through bin/dedup_test decode. A pass means the decoder rejects the
# input cleanly (non-zero exit, no SIGSEGV/SIGABRT/SIGBUS) without
# crashing.
#
# Add new regression samples by:
#   mv tests/fuzz-artifacts/crash-<hash> tests/fuzz-regression/<descriptive-name>
# after the underlying bug is fixed.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d tests/fuzz-regression ]]; then
    echo "no regression samples yet"
    exit 0
fi
shopt -s nullglob
samples=( tests/fuzz-regression/* )
shopt -u nullglob
if (( ${#samples[@]} == 0 )); then
    echo "no regression samples yet"
    exit 0
fi

[[ -x bin/dedup_test ]] || make bin/dedup_test

passed=0
failed=0
for f in "${samples[@]}"; do
    name="$(basename "$f")"
    rm -f /tmp/fuzz_replay_out.bin
    set +e
    timeout 5 ./bin/dedup_test decode "$f" /tmp/fuzz_replay_out.bin >/dev/null 2>&1
    rc=$?
    set -e
    case "$rc" in
        139|134|136)
            echo "FAIL  $name  (rc=$rc, CRASH -- bug regressed!)"
            failed=$((failed + 1)) ;;
        124)
            echo "FAIL  $name  (timeout -- bug regressed!)"
            failed=$((failed + 1)) ;;
        *)
            echo "OK    $name  (rc=$rc, clean reject)"
            passed=$((passed + 1)) ;;
    esac
done

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
