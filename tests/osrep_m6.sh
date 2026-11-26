#!/usr/bin/env bash
# The embeddable -m6 API (src/pascal/osrep_m6.pas): its built-in checks
# (tests/osrep_m6_test.lpr) with the native and the reference build, and
# the same streams as the CLI both ways: the API writes byte for byte what
# `osrep -m6` writes, decodes the CLI's streams, and the CLI decodes its.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-m6api.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CC=${CC:-cc}
CORPUS="$TMP/corpus"
NAT="$TMP/native"
REF="$TMP/reference"
mkdir -p "$CORPUS" "$NAT/u" "$REF/u" "$TMP/w"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== corpus =="
bash "$ROOT/tests/gen_corpus.sh" "$CORPUS" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "gen_corpus"
}
: > "$CORPUS/empty.bin"
python3 - "$CORPUS/text.bin" "$CORPUS/versions.bin" <<'EOF'
import sys
t = open(sys.argv[1], 'rb').read()[:300000]
out = bytearray()
for v in range(3):
    b = bytearray(t)
    for k in range(20):
        p = (k * 7919 + v * 104729) % (len(b) - 8)
        b[p:p + 4] = b'v%03d' % v
    out += b
open(sys.argv[2], 'wb').write(bytes(out))
EOF

echo "== builds =="
for f in osrep_cdc osrep_match osrep_lr osrep_vhash_nh osrep_crc_native; do
  $CC -O2 -fPIC -fno-builtin -fno-stack-protector \
    -c "$ROOT/src/c/$f.c" -o "$NAT/$f.o" || fail "cc $f"
done
for p in "$ROOT/src/pascal/osrep.lpr" "$ROOT/tests/osrep_m6_test.lpr"; do
  fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$NAT" \
    -FU"$NAT/u" -FE"$NAT" "$p" >"$TMP/native.log" 2>&1 || {
    cat "$TMP/native.log"
    fail "native fpc $p"
  }
  fpc -Mobjfpc -O2 -Sh -dOSREP_NO_NATIVE -Fu"$ROOT/src/pascal" \
    -FU"$REF/u" -FE"$REF" "$p" >"$TMP/ref.log" 2>&1 || {
    cat "$TMP/ref.log"
    fail "reference fpc $p"
  }
done

echo "== built-in checks =="
"$NAT/osrep_m6_test" self || fail "native self"
"$REF/osrep_m6_test" self || fail "reference self"

echo "== the API and the CLI write the same streams =="
n=0
for f in "$CORPUS"/*; do
  name=$(basename "$f")
  # minlen align block digest
  for opts in "512 16 8388608 0" "64 1 65536 0" "32 1 65536 1" "128 32 1048576 0"; do
    set -- $opts
    cli=(-m6 "-l$1" "--align=$2" "-b$3")
    [ "$4" = 0 ] && cli+=(-hash-)
    w="$TMP/w/$name.$1.$2.$3.$4"
    "$NAT/osrep" "${cli[@]}" "$f" "$w.cli" >/dev/null 2>&1 || fail "cli $name $opts"
    "$NAT/osrep_m6_test" enc "$f" "$w.api" "$@" || fail "api $name $opts"
    cmp -s "$w.cli" "$w.api" || fail "api != cli: $name $opts"
    "$REF/osrep_m6_test" enc "$f" "$w.ref" "$@" || fail "ref api $name $opts"
    cmp -s "$w.cli" "$w.ref" || fail "reference api != cli: $name $opts"
    "$NAT/osrep_m6_test" dec "$w.cli" "$w.out" || fail "api decodes cli: $name $opts"
    cmp -s "$f" "$w.out" || fail "api decode of cli: $name $opts"
    "$REF/osrep_m6_test" dec "$w.cli" "$w.out" || fail "ref decodes cli: $name $opts"
    cmp -s "$f" "$w.out" || fail "reference decode of cli: $name $opts"
    "$NAT/osrep" -d "$w.api" "$w.out2" >/dev/null 2>&1 || fail "cli decodes api: $name $opts"
    cmp -s "$f" "$w.out2" || fail "cli decode of api: $name $opts"
    rm -f "$w".*
    n=$((n + 1))
  done
done
echo "  $n cases"

echo "== a v6 stream is refused =="
"$NAT/osrep" -m3 "$CORPUS/text.bin" "$TMP/w/v6.osr" >/dev/null 2>&1 || fail "v6 encode"
"$NAT/osrep_m6_test" reject "$TMP/w/v6.osr" || fail "v6 accepted"

echo "osrep_m6: all checks passed"
