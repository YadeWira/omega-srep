#!/usr/bin/env bash
# v6 reader acceptance: build with FPC, decode the seven non-dup fixtures,
# verify all eight, and exercise the negative CLI/data paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-v6-read.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

IN="$TMP/inputs"
OUT="$TMP/out"
BUILD="$TMP/build"
UNITS="$TMP/units"
mkdir -p "$IN" "$OUT" "$BUILD" "$UNITS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building with fpc =="
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -FU"$UNITS" -FE"$BUILD" \
  "$ROOT/src/pascal/osrep.lpr" >"$TMP/fpc.log" 2>&1 || {
  cat "$TMP/fpc.log"
  fail "fpc build"
}
BIN="$BUILD/osrep"
[ -x "$BIN" ] || fail "binary was not produced"

echo "== version =="
[ "$("$BIN" --version)" = "OSREP 0.0.2 (2026-11-10)" ] || fail "--version text"

echo "== fixtures: -d round-trip =="
if ! bash "$ROOT/tests/golden/inputs.sh" "$IN" >"$TMP/inputs.log" 2>&1; then
  cat "$TMP/inputs.log"
  fail "tests/golden/inputs.sh"
fi
while read -r id input; do
  "$BIN" -d "$ROOT/tests/fixtures/v6/$id.osr" "$OUT/$id.out" || fail "-d $id"
  cmp "$OUT/$id.out" "$IN/$input" || fail "round-trip $id != $input"
done <<'EOF'
empty-m3 empty.bin
text-m3 text.bin
text-m4 text.bin
text-m5 text.bin
tiny-m1 tiny.bin
zeros-m0 zeros.bin
zruns-m3 zruns.bin
EOF

echo "== fixtures: --verify (including the dup meta CRC) =="
for f in "$ROOT"/tests/fixtures/v6/*.osr; do
  "$BIN" --verify "$f" || fail "--verify $(basename "$f")"
done

echo "== negative: corrupt block must be rejected with exit 4 =="
cp "$ROOT/tests/fixtures/v6/text-m3.osr" "$TMP/corrupt-block.osr"
python3 - "$TMP/corrupt-block.osr" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
d[200] ^= 0x01
open(p, 'wb').write(d)
PY
set +e
"$BIN" --verify "$TMP/corrupt-block.osr" >/dev/null 2>&1
rc=$?
"$BIN" -d "$TMP/corrupt-block.osr" "$OUT/corrupt.out" >/dev/null 2>&1
rc_d=$?
set -e
[ "$rc" -eq 4 ] || fail "corrupt block --verify rc=$rc (expected 4)"
[ "$rc_d" -eq 4 ] || fail "corrupt block -d rc=$rc_d (expected 4)"

echo "== negative: corrupt dup meta must be rejected with exit 4 =="
cp "$ROOT/tests/fixtures/v6/text-dup-m3.osr" "$TMP/corrupt-meta.osr"
python3 - "$TMP/corrupt-meta.osr" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
# text-dup-m3: meta_offset = 1149
d[1149 + 10] ^= 0x01
open(p, 'wb').write(d)
PY
set +e
"$BIN" --verify "$TMP/corrupt-meta.osr" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "corrupt meta rc=$rc (expected 4)"

echo "== info output is stable =="
INFO="$("$BIN" -i "$ROOT/tests/fixtures/v6/text-m3.osr")"
EXPECTED="OSREP v6
blocks=1
original_size=4194304
stat_size=7
meta_size=0
hash_id=4
hash_size=16"
[ "$INFO" = "$EXPECTED" ] || fail "-i output changed:
$INFO"

echo "== stdout output =="
"$BIN" -d "$ROOT/tests/fixtures/v6/tiny-m1.osr" - | cmp - "$IN/tiny.bin" || \
  fail "-d to stdout"

echo "== exit codes: 2 for command line, 3 for I/O =="
set +e
"$BIN" --not-an-option >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown option rc=$rc (expected 2)"
set +e
"$BIN" --verify "$TMP/does-not-exist.osr" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "missing input rc=$rc (expected 3)"
set +e
"$BIN" -d >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing -d argument rc=$rc (expected 2)"

echo "v6_read: PASS"
