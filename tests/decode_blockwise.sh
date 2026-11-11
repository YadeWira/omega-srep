#!/usr/bin/env bash
# Block-wise decoder: multi-block archives, a legacy archive with cross-block
# matches (global fallback), the DUPR restore path and corruption handling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-decode.XXXXXX")"
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

echo "== block-wise: many small blocks =="
"$BIN" -m5 -b256kb "$CORPUS/mixed.bin" "$TMP/many.osr" || fail "encode many blocks"
"$BIN" --verify "$TMP/many.osr" || fail "verify many blocks"
"$BIN" -i "$TMP/many.osr" | grep -qx 'blocks=25' || fail "expected 25 blocks"
"$BIN" -d "$TMP/many.osr" "$TMP/many.out" || fail "decode many blocks"
cmp "$TMP/many.out" "$CORPUS/mixed.bin" || fail "many blocks round-trip"
"$BIN" -d "$TMP/many.osr" - | cmp - "$CORPUS/mixed.bin" || fail "many blocks to stdout"

echo "== global fallback: legacy archive with cross-block matches =="
"$BIN" -d "$ROOT/tests/fixtures/v6/text-b1mb-m3.osr" "$TMP/legacy.out" || \
  fail "decode cross-block fixture"
cmp "$TMP/legacy.out" "$CORPUS/text.bin" || fail "cross-block round-trip"

echo "== streaming: synthetic cross-block chain =="
python3 "$ROOT/tests/gen_crossblock.py" "$TMP/cross.osr" "$TMP/cross.expected" 16
"$BIN" --verify "$TMP/cross.osr" || fail "verify cross-block chain"
"$BIN" -d "$TMP/cross.osr" "$TMP/cross.out" || fail "decode cross-block chain"
cmp "$TMP/cross.out" "$TMP/cross.expected" || fail "cross-block chain round-trip"
"$BIN" -d "$TMP/cross.osr" - | cmp - "$TMP/cross.expected" || \
  fail "cross-block chain to stdout"

echo "== DUPR restore: unique chunks and references =="
"$BIN" -m1 "$CORPUS/zeros.bin" "$TMP/dup-zeros.osr" || fail "-m1 zeros"
"$BIN" -d "$TMP/dup-zeros.osr" "$TMP/dup-zeros.out" || fail "-m1 zeros decode"
cmp "$TMP/dup-zeros.out" "$CORPUS/zeros.bin" || fail "-m1 zeros round-trip"
"$BIN" -dup -m5 "$CORPUS/mixed.bin" "$TMP/dup-mixed.osr" || fail "-dup -m5 mixed"
"$BIN" -d "$TMP/dup-mixed.osr" "$TMP/dup-mixed.out" || fail "-dup mixed decode"
cmp "$TMP/dup-mixed.out" "$CORPUS/mixed.bin" || fail "-dup mixed round-trip"
MIXED_SIZE="$(wc -c < "$CORPUS/mixed.bin" | tr -d ' ')"
"$BIN" -i "$TMP/dup-mixed.osr" | grep -qx "restored_size=$MIXED_SIZE" || \
  fail "-dup restored_size"

echo "== corruption still fails in the block-wise path =="
python3 - "$TMP/many.osr" "$TMP/bad.osr" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())
data[120] ^= 0x01
open(dst, 'wb').write(data)
PY
set +e
"$BIN" -d "$TMP/bad.osr" "$TMP/bad.out" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "corrupt block-wise -d rc=$rc (expected 4)"
set +e
"$BIN" --verify "$TMP/bad.osr" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "corrupt block-wise --verify rc=$rc (expected 4)"

echo "decode: block-wise, cross-block fallback, DUPR and corruption OK"
