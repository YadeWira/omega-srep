#!/usr/bin/env bash
# OSREP mode: the fragmenter API must reproduce the -m1/-m2 CDC boundaries
# (osrep_cdc_find chunker 1) with the same min/max/average.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-cdcmode.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CC=${CC:-cc}
$CC -O2 -std=c99 -I"$ROOT/src/c" \
  "$ROOT/src/c/osrep_sha1.c" "$ROOT/src/c/osrep_fragment.c" \
  "$ROOT/src/c/osrep_cdc.c" "$ROOT/tests/osrep_cdc_mode.c" \
  -o "$TMP/osrep_cdc_mode" || fail "cc osrep_cdc_mode"

bash "$ROOT/tests/gen_corpus.sh" "$TMP/corpus" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
}
for f in "$TMP"/corpus/*.bin; do
  "$TMP/osrep_cdc_mode" "$f" || fail "$(basename "$f")"
done

echo "OSREP mode: CDC boundaries match osrep_cdc_find (48-byte FNV, 8 KiB)"
