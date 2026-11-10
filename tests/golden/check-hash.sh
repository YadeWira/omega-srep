#!/usr/bin/env bash
# Replays tests/golden/hash_manifest.tsv with the Pascal tool alone: same
# inputs, same digests.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

HT="${OSREP_PASCAL_HASHTOOL:-pascal/bin/hashtool}"
[ -x "$HT" ] || fail "missing $HT (bash pascal/build.sh)"
[ -f tests/golden/hash_manifest.tsv ] || { say "no hash manifest -- skipping"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mk() {
    local spec=$1 kind n seed=0 out rest
    kind=${spec%%:*}; rest=${spec#*:}
    case $kind in
        zeros|seq) n=${rest%%:*} ;;
        rnd) seed=${rest%%:*}; n=${rest#*:} ;;
        *) fail "bad input spec $spec" ;;
    esac
    out="$TMP/$(echo "$spec" | tr ':' '_')"
    python3 - "$kind" "$n" "$seed" "$out" <<'PY'
import random, sys
kind, n, seed, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
if kind == 'zeros':
    data = bytes(n)
elif kind == 'seq':
    data = bytes(i & 0xFF for i in range(n))
else:
    r = random.Random(int(seed))
    data = bytes(r.randrange(256) for _ in range(n))
open(out, 'wb').write(data)
PY
    echo "$out"
}

n=0; bad=0
while IFS=$'\t' read -r algo seed spec want; do
    case "$algo" in ''|\#*) continue;; esac
    f=$(mk "$spec")
    got=$("$HT" "$algo" "$seed" "$f") || { printf 'FAIL: %s %s %s: tool failed\n' "$algo" "$seed" "$spec" >&2; bad=$((bad + 1)); continue; }
    if [ "$got" != "$want" ]; then
        printf 'FAIL: %s %s %s: %s, pinned %s\n' "$algo" "$seed" "$spec" "$got" "$want" >&2
        bad=$((bad + 1)); continue
    fi
    n=$((n + 1))
done < tests/golden/hash_manifest.tsv

[ "$bad" -eq 0 ] || fail "$bad of $((n + bad)) hash vectors failed"
say "hash vectors: passed=$n mismatches=0"
