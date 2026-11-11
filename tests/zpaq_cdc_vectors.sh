#!/usr/bin/env bash
# Phase 0 zpaq vectors: OSREP's order-1 CDC must produce exactly the same
# fragment boundaries as zpaq-std's fragment_buffer at -fragment 6.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-zpaq.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building cdc_dump =="
CC=${CC:-cc}
$CC -O2 -std=c99 -c "$ROOT/src/c/osrep_cdc.c" -o "$TMP/osrep_cdc.o" || \
  fail "cc osrep_cdc.c"
$CC -O2 -std=c99 "$ROOT/tools/zpaq-vectors/cdc_dump.c" "$TMP/osrep_cdc.o" \
  -o "$TMP/cdc_dump" || fail "cc cdc_dump.c"

echo "== corpus =="
bash "$ROOT/tests/gen_corpus.sh" "$TMP/corpus" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
}

echo "== fragment boundaries vs zpaq-std =="
for name in text mixed zeros random tiny; do
  "$TMP/cdc_dump" "$TMP/corpus/$name.bin" >"$TMP/$name.tsv" || \
    fail "cdc_dump $name"
  cut -f1,2 "$ROOT/tests/fixtures/zpaq-fragments/$name.tsv" >"$TMP/$name.expected"
  cmp "$TMP/$name.tsv" "$TMP/$name.expected" || \
    fail "$name: OSREP CDC boundaries differ from zpaq-std"
done

echo "zpaq CDC vectors: fragment boundaries match on all five files"
