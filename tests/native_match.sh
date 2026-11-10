#!/usr/bin/env bash
# Differential test for the native match finder: the C parse must produce the
# same .osr as the Pascal reference for -m3, -m4 and -m5.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-match.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CC=${CC:-cc}
CORPUS="$TMP/corpus"
NAT="$TMP/native"
REF="$TMP/reference"
mkdir -p "$CORPUS" "$NAT/u" "$REF/u"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== corpus =="
bash "$ROOT/tests/gen_corpus.sh" "$CORPUS" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "gen_corpus"
}
: > "$TMP/empty.bin"

echo "== native build =="
for f in osrep_cdc osrep_match osrep_crc; do
  $CC -O2 -fPIC -fno-builtin -fno-stack-protector \
    -c "$ROOT/src/c/$f.c" -o "$NAT/$f.o" || fail "cc $f"
done
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$NAT" \
  -FU"$NAT/u" -FE"$NAT" "$ROOT/src/pascal/osrep.lpr" >"$TMP/native.log" 2>&1 || {
  cat "$TMP/native.log"
  fail "native fpc"
}

echo "== Pascal reference build =="
fpc -Mobjfpc -O2 -Sh -dOSREP_NO_NATIVE -Fu"$ROOT/src/pascal" \
  -FU"$REF/u" -FE"$REF" "$ROOT/src/pascal/osrep.lpr" >"$TMP/ref.log" 2>&1 || {
  cat "$TMP/ref.log"
  fail "reference fpc"
}

check_pair() {
  local input=$1 mode=$2 extra=$3 tag=$4
  # shellcheck disable=SC2086
  "$NAT/osrep" "$mode" $extra "$input" "$TMP/$tag.native.osr" || \
    fail "native $mode $extra $input"
  # shellcheck disable=SC2086
  "$REF/osrep" "$mode" $extra "$input" "$TMP/$tag.ref.osr" || \
    fail "reference $mode $extra $input"
  cmp "$TMP/$tag.native.osr" "$TMP/$tag.ref.osr" || \
    fail "$mode $extra $input: native and Pascal differ"
}

for name in zeros tiny mixed text; do
  for mode in -m3 -m4 -m5; do
    check_pair "$CORPUS/$name.bin" "$mode" "" "$name${mode}"
    "$NAT/osrep" -d "$TMP/$name${mode}.native.osr" "$TMP/$name${mode}.out" || \
      fail "decode $mode $name"
    cmp "$TMP/$name${mode}.out" "$CORPUS/$name.bin" || fail "round-trip $mode $name"
  done
done

echo "== options and empty input =="
for mode in -m3 -m5; do
  check_pair "$CORPUS/mixed.bin" "$mode" "-l64 -c64 -a32" "opt${mode}"
done
for mode in -m3 -m4 -m5; do
  check_pair "$TMP/empty.bin" "$mode" "" "empty${mode}"
done

echo "== -t1 / -t4 identity =="
for mode in -m3 -m5; do
  "$NAT/osrep" "$mode" -t1 "$CORPUS/mixed.bin" "$TMP/t1.osr" || fail "$mode -t1"
  "$NAT/osrep" "$mode" -t4 "$CORPUS/mixed.bin" "$TMP/t4.osr" || fail "$mode -t4"
  cmp "$TMP/t1.osr" "$TMP/t4.osr" || fail "$mode -t changes the archive"
done

echo "native match finder: all checks passed"
