#!/usr/bin/env bash
# libosrep in 7-Zip and 7-Zip-zstd: build the library (which is also the
# codec plugin), make a private copy of each 7-Zip with it in Codecs/, and
# prove the method OSREP:
#   -m0=OSREP            the .osr stream alone
#   -m0=OSREP -m1=LZMA2  the preprocessor followed by LZMA2
#   -m0=OSREP -m1=zstd   the same with 7-Zip-zstd, when it is installed
# Every file must come back byte for byte; a damaged archive must fail.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-7z.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SEVEN=${SEVEN:-/usr/lib/7zip}
SEVEN_ZSTD=${SEVEN_ZSTD:-/mnt/IA_LAB/agentes/ZPAQ-STD/peazip/7zzs/lin}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building libosrep and its 7-Zip plugin =="
bash "$ROOT/src/lib/build.sh" "$TMP/lib" || fail "src/lib/build.sh"
LIB="$TMP/lib/libosrep.so"
[ -f "$LIB" ] || fail "libosrep.so was not produced"

echo "== input =="
IN="$TMP/in"
mkdir -p "$IN/sub"
bash "$ROOT/tests/gen_corpus.sh" "$IN" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
}
cp "$IN/text.bin" "$IN/sub/text-copy.bin"
: > "$IN/empty.bin"
printf 'OSREP in 7-Zip\n' > "$IN/hello.txt"

# test_one <7-Zip dir> <label> <extra coder or empty>
test_one() {
  local dir=$1 label=$2 extra=$3
  local Z="$TMP/$label-7z"
  local SZ OUT OUTFILE CHAIN BASE
  if [ ! -f "$dir/7z" ] || [ ! -f "$dir/7z.so" ]; then
    echo "== $label: not found in $dir, skipped =="
    return 0
  fi
  echo "== $label =="
  mkdir -p "$Z/Codecs"
  cp "$dir/7z" "$dir/7z.so" "$Z/"
  cp "$LIB" "$Z/Codecs/osrep.so"
  SZ="$Z/7z"
  "$SZ" i | grep -q '37F03 OSREP' || fail "$label does not list OSREP"
  echo "listed: $("$SZ" i | grep '37F03 OSREP')"

  OUT="$TMP/$label-out-osrep"
  rm -rf "$OUT"; mkdir -p "$OUT"
  (cd "$IN" && "$SZ" a -bso0 -bsp0 -m0=OSREP "$TMP/$label-osrep.7z" .) || \
    fail "$label a -m0=OSREP"
  "$SZ" x -bso0 -bsp0 -o"$OUT" "$TMP/$label-osrep.7z" || fail "$label x -m0=OSREP"
  diff -r "$IN" "$OUT" || fail "$label OSREP-only round-trip"
  echo "OSREP-only: $(wc -c < "$TMP/$label-osrep.7z" | tr -d ' ') bytes, every file back"

  OUT="$TMP/$label-out-lzma2"
  rm -rf "$OUT"; mkdir -p "$OUT"
  (cd "$IN" && "$SZ" a -bso0 -bsp0 -mmt=4 -m0=OSREP -m1=LZMA2 "$TMP/$label-chain.7z" .) || \
    fail "$label a -m0=OSREP -m1=LZMA2"
  "$SZ" l -slt "$TMP/$label-chain.7z" | grep -q 'OSREP LZMA2' || \
    fail "$label does not record the OSREP LZMA2 chain"
  "$SZ" x -bso0 -bsp0 -o"$OUT" "$TMP/$label-chain.7z" || fail "$label x chain"
  diff -r "$IN" "$OUT" || fail "$label OSREP+LZMA2 round-trip"
  "$SZ" t -bso0 -bsp0 "$TMP/$label-chain.7z" || fail "$label t chain"
  echo "OSREP+LZMA2: $(wc -c < "$TMP/$label-chain.7z" | tr -d ' ') bytes, every file back"

  OUT="$TMP/$label-out-blocks"
  rm -rf "$OUT"; mkdir -p "$OUT"
  (cd "$IN" && "$SZ" a -bso0 -bsp0 -ms=1m -m0=OSREP -m1=LZMA2 "$TMP/$label-blocks.7z" .) || \
    fail "$label a -ms=1m -m0=OSREP -m1=LZMA2"
  "$SZ" t -bso0 -bsp0 "$TMP/$label-blocks.7z" || fail "$label t blocks"
  "$SZ" x -bso0 -bsp0 -o"$OUT" "$TMP/$label-blocks.7z" || fail "$label x blocks"
  diff -r "$IN" "$OUT" || fail "$label OSREP+LZMA2 1 MiB blocks round-trip"
  echo "OSREP+LZMA2, 1 MiB blocks: $(wc -c < "$TMP/$label-blocks.7z" | tr -d ' ') bytes, every file back"

  (cd "$IN" && "$SZ" a -bso0 -bsp0 -m0=LZMA2 "$TMP/$label-lzma2.7z" .) || \
    fail "$label a -m0=LZMA2"
  echo "LZMA2 alone: $(wc -c < "$TMP/$label-lzma2.7z" | tr -d ' ') bytes"
  local d=$(( $(wc -c < "$TMP/$label-chain.7z") - $(wc -c < "$TMP/$label-lzma2.7z") ))
  if [ "$d" -lt 0 ]; then
    echo "OSREP+LZMA2 saves $((-d)) bytes vs LZMA2 alone"
  else
    echo "OSREP+LZMA2 costs $d bytes vs LZMA2 alone"
  fi

  if [ -n "$extra" ]; then
    OUT="$TMP/$label-out-$extra"
    rm -rf "$OUT"; mkdir -p "$OUT"
    (cd "$IN" && "$SZ" a -bso0 -bsp0 -m0=OSREP -m1="$extra" "$TMP/$label-$extra.7z" .) || \
      fail "$label a -m0=OSREP -m1=$extra"
    "$SZ" l -slt "$TMP/$label-$extra.7z" | grep -qi "OSREP $extra" || \
      fail "$label does not record the OSREP $extra chain"
    "$SZ" x -bso0 -bsp0 -o"$OUT" "$TMP/$label-$extra.7z" || fail "$label x $extra"
    diff -r "$IN" "$OUT" || fail "$label OSREP+$extra round-trip"
    echo "OSREP+$extra: $(wc -c < "$TMP/$label-$extra.7z" | tr -d ' ') bytes, every file back"
  fi

  echo "== $label: a damaged archive must fail =="
  cp "$TMP/$label-chain.7z" "$TMP/$label-bad.7z"
  python3 - "$TMP/$label-bad.7z" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
d[len(d) // 2] ^= 0x5A
open(p, "wb").write(d)
PY
  if "$SZ" x -bso0 -bsp0 -o"$TMP/$label-out-bad" "$TMP/$label-bad.7z" \
       >"$TMP/$label-bad.log" 2>&1; then
    fail "$label: a damaged archive extracted without an error"
  fi
  echo "damaged archive rejected: $(tail -1 "$TMP/$label-bad.log")"
}

test_one "$SEVEN" 7zip ""
test_one "$SEVEN_ZSTD" 7zip-zstd zstd

echo "libosrep + 7-Zip: all checks passed"
