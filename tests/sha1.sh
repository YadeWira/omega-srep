#!/usr/bin/env bash
# SHA-1: FIPS vectors plus a differential check against the system sha1sum on
# the generated corpus (covers lengths around the 55/56 and 63/64 boundaries).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-sha1.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CC=${CC:-cc}
$CC -O2 -std=c99 -I"$ROOT/src/c" "$ROOT/src/c/osrep_sha1.c" \
  "$ROOT/tests/sha1_vectors.c" -o "$TMP/sha1_vectors" || fail "cc sha1_vectors"
"$TMP/sha1_vectors" || fail "FIPS vectors"

$CC -O2 -std=c99 -I"$ROOT/src/c" "$ROOT/src/c/osrep_sha1.c" \
  "$ROOT/tools/zpaq-vectors/sha1_file.c" -o "$TMP/sha1_file" || fail "cc sha1_file"

bash "$ROOT/tests/gen_corpus.sh" "$TMP/corpus" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
}
if command -v sha1sum >/dev/null 2>&1; then
  HASH="sha1sum"
else
  HASH="shasum -a 1"
fi
for f in "$TMP"/corpus/*.bin; do
  want="$($HASH "$f" | cut -d' ' -f1)"
  got="$("$TMP/sha1_file" "$f")"
  [ "$want" = "$got" ] || fail "$(basename "$f"): got $got want $want"
done

echo "sha1: FIPS vectors and system hash agree on the corpus"
