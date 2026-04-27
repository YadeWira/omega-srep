#!/usr/bin/env bash
# Concurrency stress for `osrep -dup`. Runs N instances in parallel
# on N different inputs, verifies all complete successfully, and
# checks every round-trip byte-by-byte. Catches tempfile collisions,
# shared-state bugs, and any os-level resource leaks the wrapper
# might have.
#
# `make_tempfile` in dup_wrapper.cpp uses mkstemp(3) which is
# supposed to be race-safe; this test confirms the mechanism actually
# behaves under load.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -x bin/osrep ]] || make bin/osrep

N="${OSREP_CONCURRENCY_N:-8}"
SIZE_BYTES="${OSREP_CONCURRENCY_SIZE:-$((4 * 1024 * 1024))}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build N distinct inputs. Each gets a unique seed so no two are
# byte-identical (verifying the harness, not osrep).
for i in $(seq 1 "$N"); do
    python3 -c "
import random, sys
random.seed($i * 7919)
unit = bytes(random.choices(b'omega-srep dup concurrency test ', k=64))
size = $SIZE_BYTES
out = (unit * (size // 64 + 1))[:size]
sys.stdout.buffer.write(out)
" > "$WORK/in_$i.bin"
done

# Launch N concurrent compresses. Each writes to its own input/
# output paths, so a collision could only happen via the mkstemp
# body tempfile inside dup_wrapper.
echo "launching $N concurrent compresses (size=$SIZE_BYTES)..."
pids=()
for i in $(seq 1 "$N"); do
    ./bin/osrep -dup -m4 "$WORK/in_$i.bin" "$WORK/out_$i.osr" >/dev/null 2>&1 &
    pids+=("$!")
done

fail=0
for i in $(seq 0 $((N - 1))); do
    wait "${pids[$i]}"
    rc=$?
    if (( rc != 0 )); then
        echo "FAIL  worker $((i + 1)) compress rc=$rc"
        fail=$((fail + 1))
    fi
done
if (( fail > 0 )); then
    echo "passed=0 failed=$fail (compress)"
    exit 1
fi

# Concurrent decompresses (same N, same archives).
echo "launching $N concurrent decompresses..."
pids=()
for i in $(seq 1 "$N"); do
    ./bin/osrep -d "$WORK/out_$i.osr" "$WORK/dec_$i.bin" >/dev/null 2>&1 &
    pids+=("$!")
done
for i in $(seq 0 $((N - 1))); do
    wait "${pids[$i]}"
    rc=$?
    if (( rc != 0 )); then
        echo "FAIL  worker $((i + 1)) decompress rc=$rc"
        fail=$((fail + 1))
    fi
done

# Byte-compare all round-trips.
passed=0
for i in $(seq 1 "$N"); do
    if cmp -s "$WORK/in_$i.bin" "$WORK/dec_$i.bin"; then
        passed=$((passed + 1))
    else
        echo "FAIL  worker $i byte mismatch"
        fail=$((fail + 1))
    fi
done

echo
echo "passed=$passed failed=$fail (over $N parallel workers, size=$SIZE_BYTES)"
exit $(( fail == 0 ? 0 : 1 ))
