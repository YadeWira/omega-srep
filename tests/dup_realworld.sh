#!/usr/bin/env bash
# Real-world corpus round-trip test for stable-release confidence.
#
# Synthetic deterministic inputs (the rest of the test suite) verify
# correctness on patterns we can reason about. Real binaries have
# subtleties — embedded zip files, DWARF debug sections, x86_64
# instruction-stream entropy, padding regions — that surface bugs
# the synthetic tests miss.
#
# Default corpus: tar of /usr/bin on this host (typically 100-700 MiB
# of mixed compiled executables, scripts, symlinks). Override via
# OSREP_REALWORLD_DIR.
#
# Round-trips through:
#   - osrep -m4               (baseline)
#   - osrep -dup -m4          (native streaming -dup)
#   - osrep -dup --dup-paranoid -m4
#   - osrep -dup -m3, -dup -m5
#
# Asserts every config decompresses byte-identical to the original
# tar. Skipped automatically if the source dir doesn't exist.
#
# This test is intentionally NOT in the default CI lane (it depends
# on host filesystem state), but is invocable for pre-release soak.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -x bin/osrep ]] || make bin/osrep

SRC_DIR="${OSREP_REALWORLD_DIR:-/usr/bin}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "SKIP  source dir $SRC_DIR not found"
    exit 0
fi

# Honor TMPDIR. Real-world corpora can be large; on hosts with a
# tmpfs /tmp (typical Linux desktop) you may need to point this at a
# disk-backed location, e.g. TMPDIR=$HOME/.osrep-bench.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

INPUT="$WORK/input.tar"
echo "tar-ing $SRC_DIR -> $INPUT ..."
tar --sort=name --owner=0 --group=0 --mtime='2026-01-01' -cf "$INPUT" "$SRC_DIR" 2>/dev/null
INPUT_SIZE=$(stat -c%s "$INPUT")
echo "input: $INPUT_SIZE bytes ($((INPUT_SIZE / 1024 / 1024)) MiB)"

passed=0
failed=0

run_config() {
    local label="$1"
    local archive="$WORK/${label}.osr"
    local restored="$WORK/${label}.bin"
    shift
    if ! ./bin/osrep "$@" "$INPUT" "$archive" >/dev/null 2>&1; then
        echo "FAIL  $label compress"
        failed=$((failed + 1))
        return
    fi
    if ! ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1; then
        echo "FAIL  $label decompress"
        failed=$((failed + 1))
        return
    fi
    if ! cmp -s "$INPUT" "$restored"; then
        echo "FAIL  $label bytes differ"
        failed=$((failed + 1))
        return
    fi
    arch_sz=$(stat -c%s "$archive")
    ratio=$(python3 -c "print(f'{$arch_sz/$INPUT_SIZE:.3f}')")
    printf "OK    %-32s archive=%d ratio=%s\n" "$label" "$arch_sz" "$ratio"
    passed=$((passed + 1))
    # Free space immediately so subsequent configs don't OOM /tmp on
    # large real-world corpora.
    rm -f "$restored" "$archive"
}

run_config "baseline-m4"      -m4
run_config "dup-m4"           -dup -m4
run_config "dup-m4-paranoid"  -dup --dup-paranoid -m4
run_config "dup-m3"           -dup -m3
run_config "dup-m5"           -dup -m5

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
