#!/usr/bin/env bash
# Memory budget: -memN lowers the block size so the LZ tables fit, and the
# archive stays identical for every -t (the block size must not depend on the
# thread count).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-mem.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CORPUS="$TMP/corpus"
BUILD="$TMP/build"
UNITS="$TMP/units"
mkdir -p "$CORPUS" "$BUILD" "$UNITS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building with fpc + native CDC =="
CC=${CC:-cc}
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_cdc.c" -o "$BUILD/osrep_cdc.o" || fail "cc osrep_cdc.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_match.c" -o "$BUILD/osrep_match.o" || fail "cc osrep_match.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_crc_native.c" -o "$BUILD/osrep_crc_native.o" || \
  fail "cc osrep_crc_native.c"
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$BUILD" -FU"$UNITS" -FE"$BUILD" \
  "$ROOT/src/pascal/osrep.lpr" >"$TMP/fpc.log" 2>&1 || {
  cat "$TMP/fpc.log"
  fail "fpc build"
}
BIN="$BUILD/osrep"
[ -x "$BIN" ] || fail "binary was not produced"

echo "== corpus =="
if ! bash "$ROOT/tests/gen_corpus.sh" "$CORPUS" >"$TMP/corpus.log" 2>&1; then
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
fi

echo "== -mem picks the block size and round-trips =="
# budget_mb expected_block_size; the model sizes for 8 threads.
for spec in "16 65536" "64 524288" "128 1048576"; do
  set -- $spec
  budget=$1
  block=$2
  out="$TMP/mem$budget.osr"
  "$BIN" -m5 "-mem$budget" "$CORPUS/mixed.bin" "$out" || fail "-mem$budget encode"
  "$BIN" --verify "$out" || fail "-mem$budget verify"
  info="$("$BIN" -i "$out")"
  printf '%s\n' "$info" | grep -qx "max_match=$block" || \
    fail "-mem$budget max_match (want $block): $info"
  "$BIN" -d "$out" "$TMP/mem$budget.out" || fail "-mem$budget decode"
  cmp "$TMP/mem$budget.out" "$CORPUS/mixed.bin" || fail "-mem$budget round-trip"
done

echo "== -t does not change a -mem archive =="
"$BIN" -m5 -mem64 -t1 "$CORPUS/mixed.bin" "$TMP/t1.osr" || fail "t1 encode"
"$BIN" -m5 -mem64 -t4 "$CORPUS/mixed.bin" "$TMP/t4.osr" || fail "t4 encode"
"$BIN" -m5 -mem64 "$CORPUS/mixed.bin" "$TMP/tauto.osr" || fail "auto encode"
cmp "$TMP/t1.osr" "$TMP/t4.osr" || fail "-t1 vs -t4 differ"
cmp "$TMP/t1.osr" "$TMP/tauto.osr" || fail "-t1 vs auto differ"

echo "== -mem only sizes the LZ methods =="
"$BIN" -m1 -mem16 "$CORPUS/zeros.bin" "$TMP/m1.osr" || fail "-m1 -mem16 encode"
"$BIN" -i "$TMP/m1.osr" | grep -qx 'max_match=8388608' || \
  fail "-m1 -mem16 changed the block size"
"$BIN" -d "$TMP/m1.osr" "$TMP/m1.out" || fail "-m1 -mem16 decode"
cmp "$TMP/m1.out" "$CORPUS/zeros.bin" || fail "-m1 -mem16 round-trip"

echo "== too small a budget is a command line error =="
set +e
"$BIN" -m5 -mem1 "$CORPUS/tiny.bin" "$TMP/small.osr" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "-mem1 rc=$rc (expected 2)"

echo "-mem: block sizing, determinism and round-trip OK"
