#!/usr/bin/env bash
# Regression for the VM-spill options and the low-memory decode path.
#
# v1.0.6 fixed two things this covers: `-vmfile=`/`-vmblock=` were
# unreachable (swallowed by the `-v` verbosity case, so they always
# failed with "Invalid option"), and Future-LZ/Index-LZ decompression
# could hang forever when spilling a match too large for one VM block.
#
# This runs a full round-trip per method with a deliberately small VM
# block and a low `-mem`, which forces the spill path, and asserts the
# options are accepted and the output is bit-exact. It is intentionally
# small (no multi-GB repro) so it can gate every release.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -x bin/osrep ]] || make bin/osrep

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Repetitive input so the encoder emits real matches (what the spill
# path deals with) rather than an all-literals archive.
python3 - "$TMP/in.bin" <<'PY'
import sys
unit = bytes((i * 7 + 11) & 0xFF for i in range(65536))
block = unit + b'OMEGA-SREP-VM-REGRESSION' * 512
open(sys.argv[1], 'wb').write(block * 6)
PY

pass=0; fail=0
for m in m0 m1 m2 m3 m4 m5; do
    ./bin/osrep -$m "$TMP/in.bin" "$TMP/$m.osr" >/dev/null 2>&1 || { echo "FAIL -$m compress"; fail=$((fail+1)); continue; }
    # Low memory + tiny VM block: exercises save_to_disk/restore_from_disk.
    rm -f "$TMP/$m.vm"
    if out=$(./bin/osrep -d -mem8mb -vmblock=64kb -vmfile="$TMP/$m.vm" "$TMP/$m.osr" "$TMP/$m.out" 2>&1); then
        if cmp -s "$TMP/in.bin" "$TMP/$m.out"; then pass=$((pass+1)); else echo "FAIL -$m round-trip"; fail=$((fail+1)); fi
    else
        echo "FAIL -$m decode: $(echo "$out" | tail -1)"; fail=$((fail+1))
    fi
    # Same archive with default options must also round-trip.
    if ./bin/osrep -d "$TMP/$m.osr" "$TMP/$m.out2" >/dev/null 2>&1 && cmp -s "$TMP/in.bin" "$TMP/$m.out2"; then
        pass=$((pass+1))
    else
        echo "FAIL -$m default decode"; fail=$((fail+1))
    fi
done

# Options must be accepted, not rejected as "Invalid option".
if ./bin/osrep -d -vmblock=4mb "$TMP/m3.osr" "$TMP/x.out" 2>&1 | grep -qi "invalid option"; then
    echo "FAIL: -vmblock= rejected"; fail=$((fail+1))
else
    pass=$((pass+1))
fi
if ./bin/osrep -d -vmfile="$TMP/y.vm" "$TMP/m3.osr" "$TMP/y.out" 2>&1 | grep -qi "invalid option"; then
    echo "FAIL: -vmfile= rejected"; fail=$((fail+1))
else
    pass=$((pass+1))
fi

echo "vm_options_regression: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
