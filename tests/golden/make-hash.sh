#!/usr/bin/env bash
# Records tests/golden/hash_manifest.tsv: fixed vectors for every hash and for
# the AES block primitive, so the C++ hash_test is not needed after the oracles
# go. Each vector is checked against the C++ oracle before it is recorded.
#
# Input specs: zeros:N, seq:N, rnd:SEED:N. The checker rebuilds the same files.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

HT="${OSREP_PASCAL_HASHTOOL:-pascal/bin/hashtool}"
[ -x "$HT" ] || fail "missing $HT (bash pascal/build.sh)"
[ -x "$CXX_BIN/hash_test" ] || make_cxx bin/hash_test >/dev/null 2>&1
[ -x "$CXX_BIN/hash_test" ] || fail "missing C++ hash_test oracle"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/in"; mkdir -p "$D"

mk() {  # mk SPEC -> file path in $TMP
    local spec=$1 kind n seed=0 out rest
    kind=${spec%%:*}; rest=${spec#*:}
    case $kind in
        zeros) n=${rest%%:*}; out="$TMP/$(echo "$spec" | tr ':' '_')" ;;
        seq)   n=${rest%%:*}; out="$TMP/$(echo "$spec" | tr ':' '_')" ;;
        rnd)   seed=${rest%%:*}; n=${rest#*:}; out="$TMP/$(echo "$spec" | tr ':' '_')" ;;
        *) fail "bad input spec $spec" ;;
    esac
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

SEED16=$(printf 'ab%.0s' $(seq 16))
SEED32=$(printf 'ab%.0s' $(seq 32))
OUT="$TMP/manifest.tsv"; : > "$OUT"; n=0

record() {  # record ALGO SEED SPEC
    local algo=$1 seed=$2 spec=$3 f c p
    f=$(mk "$spec")
    c=$("$CXX_BIN/hash_test" "$algo" "$seed" "$f") || fail "C++ $algo $spec"
    p=$("$HT" "$algo" "$seed" "$f") || fail "Pascal $algo $spec"
    [ "$c" = "$p" ] || fail "$algo $spec: C++ $c, Pascal $p"
    printf '%s\t%s\t%s\t%s\n' "$algo" "$seed" "$spec" "$p" >> "$OUT"
    n=$((n + 1))
}

for spec in zeros:0 seq:1 seq:15 seq:16 seq:64 seq:1000 rnd:7:65536; do
    for algo in md5 sha1 sha512; do record "$algo" none "$spec"; done
    record siphash "$SEED16" "$spec"
    record vmac "$SEED32" "$spec"
done
for spec in zeros:16 zeros:32 zeros:64; do
    record aes "$SEED32" "$spec"
done

mv "$OUT" tests/golden/hash_manifest.tsv
say "tests/golden/hash_manifest.tsv: $n vectors, C++ == Pascal"
