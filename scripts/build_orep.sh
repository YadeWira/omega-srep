#!/bin/sh
# Build the OREP CLI for the host (Linux x86_64): native (C core) and
# reference (all Pascal, -dOREP_NO_NATIVE).
#
#   scripts/build_orep.sh <out dir>      -> <out>/orep, <out>/orep-ref
set -eu
OUT=${1:?usage: build_orep.sh <out dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-gcc}
FPC=${FPC:-fpc}
CFLAGS="-O2 -fno-builtin -ffreestanding -fno-stack-protector -fno-pic \
 -fno-tree-loop-distribute-patterns -fno-asynchronous-unwind-tables"
mkdir -p "$OUT/nat" "$OUT/ref"
OUT=$(cd "$OUT" && pwd)
$CC $CFLAGS -c "$ROOT/src/c/orep_core.c" -o "$OUT/nat/orep_core.o"
if nm "$OUT/nat/orep_core.o" | grep -q ' U '; then
  echo "orep_core.o has undefined symbols:" >&2
  nm "$OUT/nat/orep_core.o" | grep ' U ' >&2
  exit 1
fi
$FPC -O3 -Xs -Fu"$ROOT/src/orep" -Fo"$OUT/nat" -Fl"$OUT/nat" -FU"$OUT/nat" \
  -o"$OUT/orep" "$ROOT/src/orep/orep_cli.lpr" >"$OUT/nat/fpc.log" 2>&1 || {
  cat "$OUT/nat/fpc.log"; exit 1; }
$FPC -O3 -Xs -dOREP_NO_NATIVE -Fu"$ROOT/src/orep" -FU"$OUT/ref" \
  -o"$OUT/orep-ref" "$ROOT/src/orep/orep_cli.lpr" >"$OUT/ref/fpc.log" 2>&1 || {
  cat "$OUT/ref/fpc.log"; exit 1; }
grep -i 'warning\|note' "$OUT/nat/fpc.log" "$OUT/ref/fpc.log" | grep -v 'Hint' || true
echo "$OUT/orep $OUT/orep-ref"
