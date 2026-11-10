#!/usr/bin/env bash
# v5 is read-only since 3.0.0: --format=v5 is rejected, but every v1-v5
# archive must still decode. This replays the stored v5 archives in
# tests/fixtures/v5/ (recorded while the port still wrote v5 byte-identically
# to the Rust 2.1.2 oracle) against the port:
#   * the fixture still has the recorded sha256;
#   * --verify accepts it;
#   * -d decodes it back to the input byte for byte.
#
# Usage: tests/v5_readonly.sh
#        OSREP_PORT_BIN=... tests/v5_readonly.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
[ -f tests/fixtures/v5/manifest.tsv ] || fail "missing tests/fixtures/v5/manifest.tsv"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/in"
bash tests/golden/inputs.sh "$D" >/dev/null

total=0
while IFS=$'\t' read -r want id input args; do
    case "$want" in ''|\#*) continue;; esac
    total=$((total + 1))
    [ -f "tests/fixtures/v5/$id.osr" ] || fail "missing tests/fixtures/v5/$id.osr for '$input $args'"
    [ -f "$D/$input" ] || fail "missing input $input"

    got=$(sha256sum < "tests/fixtures/v5/$id.osr" | cut -d' ' -f1)
    [ "$got" = "$want" ] || fail "$id.osr: sha256 $got, pinned $want"

    rc=0
    "$PORT" --verify "tests/fixtures/v5/$id.osr" >/dev/null 2>"$TMP/err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$id.osr: --verify exited $rc: $(tail -1 "$TMP/err")"

    rc=0
    "$PORT" -d "tests/fixtures/v5/$id.osr" "$TMP/out" >/dev/null 2>"$TMP/err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$id.osr: -d exited $rc: $(tail -1 "$TMP/err")"
    cmp -s "$D/$input" "$TMP/out" || fail "$id.osr ($input): decode differs"
done < tests/fixtures/v5/manifest.tsv

[ "$total" -gt 0 ] || fail "no v5 fixtures"
echo "  v5_readonly: passed=$total mismatches=0"
