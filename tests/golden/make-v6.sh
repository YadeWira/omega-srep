#!/usr/bin/env bash
# Records tests/golden/manifest-v6.tsv: the v6 cases, from the port alone.
#
# v6 has no oracle (neither the C++ nor the Rust writes it), so unlike
# make.sh this cannot compare against a reference. What it does check, for
# every case, before recording:
#   * the port writes the archive and exits 0 (or 1 with the warning a
#     non-power-of-two -l prints; that is the warning the v4 references share);
#   * --verify accepts it (which covers the per-block CRC and blocks_crc);
#   * it decodes back to the input byte for byte;
#   * the archive starts with "OSR6".
# A changed manifest is a changed archive: review its diff.
#
# Usage: tests/golden/make-v6.sh
#        OSREP_PORT_BIN=... tests/golden/make-v6.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

# 0, or the non-power-of-two -l warning (exit 1, archive still written and
# pinned); it reads the stderr of the run being checked.
ok_rc() {
    [ "$1" -eq 0 ] && return 0
    [ "$1" -eq 1 ] && grep -q 'Warning: -l parameter should be power of 2' "$TMP/stderr"
}

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
say "osrep: $("$PORT" --version)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/in"
bash tests/golden/inputs.sh "$D" >/dev/null

OUT="$TMP/manifest-v6.tsv"
: > "$OUT"
n=0

while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    input=${line%% *}
    args=${line#* }
    [ -f "$D/$input" ] || fail "no input $D/$input for '$line'"
    case " $args " in
        *" --format=v6 "*) ;;
        *) fail "case without --format=v6: '$line'" ;;
    esac

    rm -f "$TMP/a.osr" "$TMP/dec"
    # shellcheck disable=SC2086
    rc=0; "$PORT" $args --seed=7 "$D/$input" "$TMP/a.osr" >/dev/null 2>"$TMP/stderr" || rc=$?
    crc=$rc
    ok_rc "$rc" || fail "port: '$line' exited $rc: $(tail -1 "$TMP/stderr")"
    [ "$(head -c 4 "$TMP/a.osr")" = "OSR6" ] || fail "port: '$line' did not write OSR6"
    rc=0; "$PORT" --verify "$TMP/a.osr" >/dev/null 2>"$TMP/stderr" || rc=$?
    [ "$rc" -eq 0 ] || fail "port: --verify rejected '$line': $(tail -1 "$TMP/stderr")"
    rc=0; "$PORT" -d "$TMP/a.osr" "$TMP/dec" >/dev/null 2>"$TMP/stderr" || rc=$?
    [ "$rc" -eq 0 ] || fail "port: '$line' does not decode: $(tail -1 "$TMP/stderr")"
    cmp -s "$D/$input" "$TMP/dec" || fail "port: '$line' does not round-trip"

    sum=$(sha256sum < "$TMP/a.osr" | cut -d' ' -f1)
    printf '%s\t%d\t%s\t%s\n' "$sum" "$crc" "$input" \
        "$(printf '%s' "$args" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')" >> "$OUT"
    n=$((n + 1))
done < tests/golden/cases-v6.txt

[ "$n" -gt 0 ] || fail "no v6 cases"
mv "$OUT" tests/golden/manifest-v6.tsv
say "tests/golden/manifest-v6.tsv: $n cases, round-trip and --verify checked"
