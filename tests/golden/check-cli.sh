#!/usr/bin/env bash
# Replays the CLI transcripts recorded by make-cli.sh: same arguments, same
# stdout, same stderr (normalized), same exit code. The setup mirrors
# make-cli.sh on purpose: the archives the cases use are built here.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
[ -d tests/golden/cli ] || { say "no cli transcripts -- skipping"; exit 0; }
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

n=0; bad=0
while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    id=${line%%|*}
    args=${line#*|}
    want_rc=$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' tests/golden/cli/manifest.tsv)
    [ -n "$want_rc" ] || fail "no recorded exit for '$id'"
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
    norm "$W/stdout" > "$W/stdout.n"
    norm "$W/stderr" > "$W/stderr.n"
    if [ "$rc" -ne "$want_rc" ]; then
        printf 'FAIL: cli %s: exit %s, recorded %s\n' "$id" "$rc" "$want_rc" >&2
        bad=$((bad + 1)); continue
    fi
    if ! cmp -s "$W/stdout.n" "tests/golden/cli/$id.out"; then
        printf 'FAIL: cli %s: stdout differs\n' "$id" >&2
        diff -u "tests/golden/cli/$id.out" "$W/stdout.n" | head -20 >&2 || true
        bad=$((bad + 1)); continue
    fi
    if ! cmp -s "$W/stderr.n" "tests/golden/cli/$id.err"; then
        printf 'FAIL: cli %s: stderr differs\n' "$id" >&2
        diff -u "tests/golden/cli/$id.err" "$W/stderr.n" | head -20 >&2 || true
        bad=$((bad + 1)); continue
    fi
    n=$((n + 1))
done < tests/golden/cli_cases.txt

[ "$bad" -eq 0 ] || fail "$bad of $((n + bad)) cli transcripts failed"
say "cli transcripts: passed=$n mismatches=0"
