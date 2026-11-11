#!/usr/bin/env bash
# Compare a baseline zpaq-std with one whose add() loop uses the OSREP
# fragmenter API. Both must produce byte-identical archives.
#
#   tools/zpaq-vectors/integration-test.sh BASELINE_ZPAQ INTEGRATED_ZPAQ DATA
#
# The archives are frozen with -touch and -timestamp so the comparison does
# not depend on the clock.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 BASELINE_ZPAQ INTEGRATED_ZPAQ DATA" >&2
  exit 2
fi

BASE=$1
INTEGRATED=$2
DATA=$3
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-zpaq-int.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for method in -m0 -m1 -m5; do
  "$BASE" a "$TMP/base.zpaq" "$DATA" "$method" \
    -touch 20240101000000 -timestamp 2024-01-01_00:00:00 >/dev/null 2>&1 || \
    fail "baseline $method"
  "$INTEGRATED" a "$TMP/patched.zpaq" "$DATA" "$method" \
    -touch 20240101000000 -timestamp 2024-01-01_00:00:00 >/dev/null 2>&1 || \
    fail "integrated $method"
  cmp "$TMP/base.zpaq" "$TMP/patched.zpaq" || \
    fail "$method: archives differ"
  echo "$method: byte-identical ($(stat -c%s "$TMP/base.zpaq") bytes)"
  rm -f "$TMP/base.zpaq" "$TMP/patched.zpaq"
done

echo "zpaq-std integration: archives are byte-identical"
