#!/bin/bash
# OREP streaming / API edge cases: builds tests/orep_edge.lpr native (C core)
# and reference (-dOREP_NO_NATIVE), runs both, and checks that their stream
# digests ("D ..." lines) are the same.
#
#   tests/orep_edge.sh [build dir] [quick]   (default: builds into $TMPDIR)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${TMPDIR:?set TMPDIR}/orep-edge.$$
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
B=${1:-}
MODE=${2:-}
if [ -z "$B" ]; then
  B=$W/build
  "$ROOT/scripts/build_orep.sh" "$B" >/dev/null || { echo "build failed"; exit 1; }
fi
ulimit -f 1000000
FPC=${FPC:-fpc}
mkdir -p "$W/nat" "$W/ref"
[ -f "$B/nat/orep_core.o" ] || { echo "no $B/nat/orep_core.o"; exit 1; }
$FPC -O2 -Fu"$ROOT/src/orep" -Fo"$B/nat" -Fl"$B/nat" -FU"$W/nat" \
  -o"$W/nat/orep_edge" "$ROOT/tests/orep_edge.lpr" >"$W/nat/fpc.log" 2>&1 ||
  { cat "$W/nat/fpc.log"; echo "FAIL: build (native)"; exit 1; }
$FPC -O2 -dOREP_NO_NATIVE -Fu"$ROOT/src/orep" -FU"$W/ref" \
  -o"$W/ref/orep_edge" "$ROOT/tests/orep_edge.lpr" >"$W/ref/fpc.log" 2>&1 ||
  { cat "$W/ref/fpc.log"; echo "FAIL: build (reference)"; exit 1; }
fail=0
echo "== native"
"$W/nat/orep_edge" $MODE > "$W/nat.out"; rc=$?
grep -v '^D ' "$W/nat.out"
[ $rc -eq 0 ] || { echo "FAIL: native checks (rc=$rc)"; fail=1; }
echo "== reference (all Pascal)"
"$W/ref/orep_edge" $MODE > "$W/ref.out"; rc=$?
grep -v '^D ' "$W/ref.out"
[ $rc -eq 0 ] || { echo "FAIL: reference checks (rc=$rc)"; fail=1; }
grep '^D ' "$W/nat.out" > "$W/nat.d"
grep '^D ' "$W/ref.out" > "$W/ref.d"
n=$(wc -l < "$W/nat.d" | tr -d ' ')
if cmp -s "$W/nat.d" "$W/ref.d"; then
  echo "native == reference: $n stream digests"
else
  echo "FAIL: native and reference streams differ:"
  diff "$W/nat.d" "$W/ref.d" | head -20
  fail=1
fi
[ "$n" -gt 100 ] || { echo "FAIL: only $n digests"; fail=1; }
if [ $fail -eq 0 ]; then echo "orep_edge: all checks passed"; else exit 1; fi
