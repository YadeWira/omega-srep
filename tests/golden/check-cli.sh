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
# v5 is read-only since 3.0.0: the archive is the fixture the port wrote
# while v5 was still writable (byte-identical to the Rust 2.1.2 oracle).
cp tests/fixtures/v5/text-m3.osr "$W/a5.osr"
"$PORTABS" --format=v6 --seed=7 -m3 "$W/in.bin" "$W/a6.osr" >/dev/null 2>&1 || fail "cannot make v6"
cp "$W/a5.osr" "$W/bad5.osr"
printf '\377' | dd of="$W/bad5.osr" bs=1 seek=$(($(stat -c%s "$W/bad5.osr") / 2)) conv=notrunc status=none
cp "$W/a4.osr" "$W/bad4.osr"
printf '\377' | dd of="$W/bad4.osr" bs=1 seek=$(($(stat -c%s "$W/bad4.osr") / 2)) conv=notrunc status=none
cp "$W/a5.osr" "$W/bad5hdr.osr"
printf '\377' | dd of="$W/bad5hdr.osr" bs=1 seek=16 conv=notrunc status=none
cp "$W/a5.osr" "$W/bad5ftr.osr"
printf '\377' | dd of="$W/bad5ftr.osr" bs=1 seek=$(($(stat -c%s "$W/bad5ftr.osr") - 1)) conv=notrunc status=none
head -c $(($(stat -c%s "$W/a5.osr") - 10)) "$W/a5.osr" > "$W/trunc5.osr"
cp tests/fixtures/v5/text-dup-m3.osr "$W/a5dup.osr"
cp "$W/a5dup.osr" "$W/bad5meta.osr"
python3 - "$W/bad5meta.osr" <<'PY2'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
n = len(d); f = d[n - 32:]
off = struct.unpack_from('<Q', f, 16)[0]; sz = struct.unpack_from('<I', f, 24)[0]
assert sz > 16
d[off + sz // 2] ^= 0xFF
open(p, 'wb').write(d)
PY2

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
        a=${a//@BAD4@/$W/bad4.osr}
        a=${a//@BAD5H@/$W/bad5hdr.osr}
        a=${a//@BAD5F@/$W/bad5ftr.osr}
        a=${a//@TRUNC5@/$W/trunc5.osr}
        a=${a//@BAD5M@/$W/bad5meta.osr}
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
