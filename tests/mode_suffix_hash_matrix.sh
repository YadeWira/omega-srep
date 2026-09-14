#!/usr/bin/env bash
# Round-trip matrix: method x LZ suffix x block-hash variant.
#
# tests/roundtrip.sh covers bare -m0..-m5 on the corpus; this adds the
# axes the release gate previously left to hand-testing:
#   - suffixes: "" (Index-LZ, v4), f (Future-LZ, v3), o (I/O-LZ, v1/v2)
#   - every -hash= choice, including the disabled "-hash-"
# Each cell is compress -> decompress -> cmp, with the per-block
# checksum verifying on the way back.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -x bin/osrep ]] || make bin/osrep

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP/in.bin" <<'PY'
import sys
unit = bytes((i * 31 + 7) & 0xFF for i in range(32768))
open(sys.argv[1], 'wb').write((unit + b'repeated block payload ' * 700) * 4)
PY

METHODS="m0 m1 m2 m3 m4 m5"
HASHES="vmac md5 sha1 sha512 siphash -"

pass=0; fail=0
for suffix in "" f o; do
    for h in $HASHES; do
        if [ "$h" = "-" ]; then hopts="-hash-"; else hopts="-hash=$h"; fi
        for m in $METHODS; do
            tag="$m${suffix:+$suffix}"
            if ! ./bin/osrep -$m$suffix $hopts "$TMP/in.bin" "$TMP/c.osr" >/dev/null 2>&1; then
                echo "FAIL compress $tag $hopts"; fail=$((fail+1)); continue
            fi
            if ./bin/osrep -d "$TMP/c.osr" "$TMP/c.out" >/dev/null 2>&1 && cmp -s "$TMP/in.bin" "$TMP/c.out"; then
                pass=$((pass+1))
            else
                echo "FAIL round-trip $tag $hopts"; fail=$((fail+1))
            fi
        done
    done
done

echo "mode_suffix_hash_matrix: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
