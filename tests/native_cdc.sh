#!/usr/bin/env bash
# Differential test for the native CDC: the C chunk boundaries/hashes must be
# byte-identical to the Pascal reference. Builds two CLIs, one with C and one
# with -dOSREP_NO_NATIVE, and compares every dedup mode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-native.XXXXXX")"
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
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_cdc.c" -o "$NAT/osrep_cdc.o" || fail "cc cdc"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_match.c" -o "$NAT/osrep_match.o" || fail "cc match"
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

for name in zeros tiny mixed; do
  for mode in -m1 -m2 -dup; do
    tag="${name}${mode}"
    "$NAT/osrep" "$mode" "$CORPUS/$name.bin" "$TMP/$tag.native.osr" || \
      fail "native $mode $name"
    "$REF/osrep" "$mode" "$CORPUS/$name.bin" "$TMP/$tag.ref.osr" || \
      fail "reference $mode $name"
    cmp "$TMP/$tag.native.osr" "$TMP/$tag.ref.osr" || \
      fail "$mode $name: native and Pascal differ"
    "$NAT/osrep" -d "$TMP/$tag.native.osr" "$TMP/$tag.out" || \
      fail "decode $mode $name"
    cmp "$TMP/$tag.out" "$CORPUS/$name.bin" || fail "round-trip $mode $name"
  done
done

echo "== empty input =="
for mode in -m1 -m2 -dup; do
  "$NAT/osrep" "$mode" "$TMP/empty.bin" "$TMP/e.native.osr" || fail "native $mode empty"
  "$REF/osrep" "$mode" "$TMP/empty.bin" "$TMP/e.ref.osr" || fail "reference $mode empty"
  cmp "$TMP/e.native.osr" "$TMP/e.ref.osr" || fail "$mode empty: native and Pascal differ"
done

echo "== -t1 / -t4 identity =="
for mode in -m1 -m2; do
  "$NAT/osrep" "$mode" -t1 "$CORPUS/mixed.bin" "$TMP/t1.osr" || fail "$mode -t1"
  "$NAT/osrep" "$mode" -t4 "$CORPUS/mixed.bin" "$TMP/t4.osr" || fail "$mode -t4"
  cmp "$TMP/t1.osr" "$TMP/t4.osr" || fail "$mode -t changes the archive"
done

echo "native CDC: all checks passed"
