#!/usr/bin/env bash
# Phase 1 exact fragmenter: osrep_fragment_buffer (mode zpaq) must reproduce
# every column of the zpaq-std vectors: offset, size, hits, SHA-1 and o1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-frag.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building fragment_dump =="
CC=${CC:-cc}
$CC -O2 -std=c99 -I"$ROOT/src/c" \
  "$ROOT/src/c/osrep_sha1.c" "$ROOT/src/c/osrep_fragment.c" \
  "$ROOT/tools/zpaq-vectors/fragment_dump.c" -o "$TMP/fragment_dump" || \
  fail "cc fragment_dump"
$CC -O2 -std=c99 -I"$ROOT/src/c" \
  "$ROOT/src/c/osrep_sha1.c" "$ROOT/src/c/osrep_fragment.c" \
  "$ROOT/tests/fragment_state_check.c" -o "$TMP/fragment_state_check" || \
  fail "cc fragment_state_check"
"$TMP/fragment_state_check" || fail "incremental state"

echo "== corpus =="
bash "$ROOT/tests/gen_corpus.sh" "$TMP/corpus" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
}

echo "== exact fragments vs zpaq-std (fragment 6) =="
for name in text mixed zeros random tiny; do
  "$TMP/fragment_dump" "$TMP/corpus/$name.bin" 6 >"$TMP/$name.tsv" || \
    fail "fragment_dump $name"
  cmp "$TMP/$name.tsv" "$ROOT/tests/fixtures/zpaq-fragments/$name.tsv" || \
    fail "$name: fragment offset/size/hits/sha1/o1 differ from zpaq-std"
done

echo "== -fragment parameter mapping =="
head -c 65536 "$TMP/corpus/mixed.bin" >"$TMP/small.bin"
"$TMP/fragment_dump" "$TMP/small.bin" 0 >"$TMP/small-n0.tsv" || fail "small n0"
cmp "$TMP/small-n0.tsv" "$ROOT/tests/fixtures/zpaq-fragments/small-n0.tsv" || \
  fail "fragment 0 differs from zpaq-std"
"$TMP/fragment_dump" "$TMP/corpus/zeros.bin" 3 >"$TMP/zeros-n3.tsv" || fail "zeros n3"
cmp "$TMP/zeros-n3.tsv" "$ROOT/tests/fixtures/zpaq-fragments/zeros-n3.tsv" || \
  fail "fragment 3 differs from zpaq-std"
"$TMP/fragment_dump" "$TMP/corpus/zeros.bin" 9 >"$TMP/zeros-n9.tsv" || fail "zeros n9"
cmp "$TMP/zeros-n9.tsv" "$ROOT/tests/fixtures/zpaq-fragments/zeros-n9.tsv" || \
  fail "fragment 9 differs from zpaq-std"
"$TMP/fragment_dump" "$TMP/corpus/random.bin" 9 >"$TMP/random-n9.tsv" || fail "random n9"
cmp "$TMP/random-n9.tsv" "$ROOT/tests/fixtures/zpaq-fragments/random-n9.tsv" || \
  fail "fragment 9 random differs from zpaq-std"

echo "fragmenter exact mode: offsets, sizes, hits, SHA-1 and o1 match zpaq-std"
echo "fragmenter parameters: fragments 0, 3, 6 and 9 match zpaq-std"
