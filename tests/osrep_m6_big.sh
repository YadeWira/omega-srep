#!/usr/bin/env bash
# The embeddable -m6 API on an input over 4 GiB (default 6.5 GiB, from
# tests/orep_bigsrc.c: repeats up to 1.9 GB back, and repeats whose
# destination or source straddles 2^31, 2^32 and 3*2^31).  The API encodes
# and decodes through mapped files (tests/osrep_m6_big.lpr); the CLI must
# give the same stream and decode it too.  Needs about 3x SIZE of disk in
# WORK; run it separately (it takes minutes):
#   tests/osrep_m6_big.sh <work dir> [size, default 6656m]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=${1:?usage: osrep_m6_big.sh <work dir> [size]}
SIZE=${2:-6656m}
mkdir -p "$WORK/b/u"
WORK=$(cd "$WORK" && pwd)
B=$WORK/b
CC=${CC:-cc}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in osrep_cdc osrep_match osrep_lr osrep_vhash_nh osrep_crc_native; do
  $CC -O2 -fPIC -fno-builtin -fno-stack-protector \
    -c "$ROOT/src/c/$f.c" -o "$B/$f.o" || fail "cc $f"
done
for p in "$ROOT/src/pascal/osrep.lpr" "$ROOT/tests/osrep_m6_big.lpr"; do
  fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$B" -FU"$B/u" -FE"$B" "$p" \
    >"$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; fail "fpc $p"; }
done
$CC -O2 -o "$B/orep_bigsrc" "$ROOT/tests/orep_bigsrc.c" || fail "cc bigsrc"

echo "== input: $SIZE =="
"$B/orep_bigsrc" "$SIZE" 1 > "$WORK/in.bin"
sha=$(sha256sum < "$WORK/in.bin" | cut -c1-64)
ls -l "$WORK/in.bin"

echo "== API encode, API decode =="
"$B/osrep_m6_big" enc "$WORK/in.bin" "$WORK/api.osr"
"$B/osrep_m6_big" dec "$WORK/api.osr" "$WORK/out.bin"
[ "$(sha256sum < "$WORK/out.bin" | cut -c1-64)" = "$sha" ] || fail "api round trip"
rm -f "$WORK/out.bin"

echo "== the CLI writes the same stream and decodes the API's =="
"$B/osrep" -m6 -hash- "$WORK/in.bin" "$WORK/cli.osr" >/dev/null
cmp "$WORK/api.osr" "$WORK/cli.osr" || fail "api != cli"
rm -f "$WORK/cli.osr"
"$B/osrep" -d "$WORK/api.osr" - | sha256sum | cut -c1-64 > "$WORK/cli.sha"
[ "$(cat "$WORK/cli.sha")" = "$sha" ] || fail "cli decode of the api stream"
ls -l "$WORK/api.osr"
rm -f "$WORK/in.bin" "$WORK/api.osr" "$WORK/cli.sha"
echo "osrep_m6 big: all checks passed"
