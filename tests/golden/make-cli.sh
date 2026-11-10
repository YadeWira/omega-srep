#!/usr/bin/env bash
# Records tests/golden/cli/: stdout, stderr and exit code for the CLI cases in
# cli_cases.txt. These are the texts the Rust oracle used to pin; after it is
# retired they are the contract. Paths under the work dir are normalized to
# <W> so a recording does not depend on mktemp's name.
#
# Usage: tests/golden/make-cli.sh
#        OSREP_PORT_BIN=... tests/golden/make-cli.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
case "$PORT" in /*) PORTABS=$PORT ;; *) PORTABS=$PWD/$PORT ;; esac

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
D="$W/in"
bash tests/golden/inputs.sh "$D" >/dev/null
cp "$D/text.bin" "$W/in.bin"
"$PORTABS" --format=v4 --seed=7 -m3 "$W/in.bin" "$W/a4.osr" >/dev/null 2>&1 || fail "cannot make v4"
"$PORTABS" --format=v5 --seed=7 -m3 "$W/in.bin" "$W/a5.osr" >/dev/null 2>&1 || fail "cannot make v5"
"$PORTABS" --format=v6 --seed=7 -m3 "$W/in.bin" "$W/a6.osr" >/dev/null 2>&1 || fail "cannot make v6"
cp "$W/a5.osr" "$W/bad5.osr"
printf '\377' | dd of="$W/bad5.osr" bs=1 seek=$(($(stat -c%s "$W/bad5.osr") / 2)) conv=notrunc status=none

norm() { sed -e "s#$W#<W>#g" -e "s#$PORTABS#<BIN>#g" "$1"; }

OUTDIR="$W/cli"
mkdir -p "$OUTDIR"
: > "$OUTDIR/manifest.tsv"
n=0

while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    id=${line%%|*}
    args=${line#*|}
    rm -f "$W/out.bin" "$W/ix.ix"
    set -- $args
    argv=()
    for a in "$@"; do
        a=${a//@W@/$W}
        a=${a//@IN@/$W/in.bin}
        a=${a//@A4@/$W/a4.osr}
        a=${a//@A5@/$W/a5.osr}
        a=${a//@A6@/$W/a6.osr}
        a=${a//@BAD5@/$W/bad5.osr}
        a=${a//@OUT@/$W/out.bin}
        argv+=("$a")
    done
    rc=0
    "$PORTABS" "${argv[@]}" >"$W/stdout" 2>"$W/stderr" || rc=$?
    norm "$W/stdout" > "$OUTDIR/$id.out"
    norm "$W/stderr" > "$OUTDIR/$id.err"
    printf '%s\t%d\n' "$id" "$rc" >> "$OUTDIR/manifest.tsv"
    n=$((n + 1))
done < tests/golden/cli_cases.txt

rm -rf tests/golden/cli
mv "$OUTDIR" tests/golden/cli
say "tests/golden/cli: $n cases recorded (stdout, stderr, exit)"
