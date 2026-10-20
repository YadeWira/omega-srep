#!/usr/bin/env bash
# The golden suite without the oracles: replays tests/golden/manifest.tsv with
# the Pascal alone. Every archive must have the recorded sha256, the recorded
# exit code, and decode back to the input.
#
# This is what a future release runs when the C++ and the Rust are gone; the
# differential suites remain as the optional oracle gate. Run
# tests/golden/make.sh to re-record, and review the diff of the manifest: a
# changed line is a changed archive.
#
# Usage: tests/golden/check.sh
#        OSREP_PORT_BIN=... tests/golden/check.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
[ -f tests/golden/manifest.tsv ] || fail "missing tests/golden/manifest.tsv (run tests/golden/make.sh)"
say "osrep: $("$PORT" --version)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/in"
bash tests/golden/inputs.sh "$D" >/dev/null

n=0; bad=0
while IFS=$'\t' read -r want wrc input args; do
    case "$want" in ''|\#*) continue;; esac
    [ -f "$D/$input" ] || fail "manifest names a missing input: $input"

    rc=0
    # shellcheck disable=SC2086
    "$PORT" $args --seed=7 "$D/$input" "$TMP/port.osr" >/dev/null 2>"$TMP/stderr" || rc=$?
    got=$( [ -f "$TMP/port.osr" ] && sha256sum < "$TMP/port.osr" | cut -d' ' -f1 || echo -)

    if [ "$rc" -ne "$wrc" ] || [ "$got" != "$want" ]; then
        printf 'FAIL: %s %s: exit %s (pinned %s), sha256 %s (pinned %s)\n' \
            "$input" "$args" "$rc" "$wrc" "${got:0:16}" "${want:0:16}" >&2
        bad=$((bad + 1))
        continue
    fi

    rc=0
    "$PORT" -d "$TMP/port.osr" "$TMP/dec" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || ! cmp -s "$D/$input" "$TMP/dec"; then
        printf 'FAIL: %s %s: the archive does not decode back to the input\n' "$input" "$args" >&2
        bad=$((bad + 1))
        continue
    fi
    rm -f "$TMP/port.osr" "$TMP/dec"
    n=$((n + 1))
done < tests/golden/manifest.tsv

[ "$bad" -eq 0 ] || fail "$bad of $((n + bad)) golden cases failed"
say "golden: passed=$n mismatches=0"
