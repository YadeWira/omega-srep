#!/usr/bin/env bash
# Phase 1b acceptance: -m3 encoder round-trips, determinism, -hash-, the
# pinned v6-new archives, -dup read, and structural corruption rejection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-v6-encode.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CORPUS="$TMP/corpus"
BUILD="$TMP/build"
UNITS="$TMP/units"
mkdir -p "$CORPUS" "$BUILD" "$UNITS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building with fpc =="
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -FU"$UNITS" -FE"$BUILD" \
  "$ROOT/src/pascal/osrep.lpr" >"$TMP/fpc.log" 2>&1 || {
  cat "$TMP/fpc.log"
  fail "fpc build"
}
BIN="$BUILD/osrep"
[ -x "$BIN" ] || fail "binary was not produced"

echo "== corpus =="
if ! bash "$ROOT/tests/gen_corpus.sh" "$CORPUS" >"$TMP/corpus.log" 2>&1; then
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
fi

echo "== -m3 round-trip =="
for name in text.bin mixed.bin zeros.bin random.bin tiny.bin; do
  "$BIN" -m3 "$CORPUS/$name" "$TMP/$name.osr" || fail "encode $name"
  "$BIN" --verify "$TMP/$name.osr" || fail "--verify $name"
  "$BIN" -d "$TMP/$name.osr" "$TMP/$name.out" || fail "decode $name"
  cmp "$TMP/$name.out" "$CORPUS/$name" || fail "round-trip $name"
done

echo "== -b/-l/-c/-a options =="
"$BIN" -m3 -b1mb -l64 -c16 -a32 "$CORPUS/mixed.bin" \
  "$TMP/mixed-opts.osr" || fail "encode mixed with options"
"$BIN" --verify "$TMP/mixed-opts.osr" || fail "--verify mixed-opts"
"$BIN" -d "$TMP/mixed-opts.osr" "$TMP/mixed-opts.out" || fail "decode mixed-opts"
cmp "$TMP/mixed-opts.out" "$CORPUS/mixed.bin" || fail "round-trip mixed-opts"

echo "== -t threads: same archive, round-trip =="
"$BIN" -m3 -t1 "$CORPUS/mixed.bin" "$TMP/t1.osr" || fail "encode -t1"
"$BIN" -m3 -t4 "$CORPUS/mixed.bin" "$TMP/t4.osr" || fail "encode -t4"
cmp "$TMP/t1.osr" "$TMP/t4.osr" || fail "-t changes the archive"
"$BIN" -d "$TMP/t4.osr" "$TMP/t4.out" || fail "decode -t4"
cmp "$TMP/t4.out" "$CORPUS/mixed.bin" || fail "round-trip -t4"
if "$BIN" -m3 -tx "$CORPUS/tiny.bin" "$TMP/tx.osr" >/dev/null 2>&1; then
  fail "-tx was accepted"
fi

echo "== unimplemented methods are rejected =="
for m in -m0 -m1 -m2 -m4 -m5; do
  if "$BIN" "$m" "$CORPUS/text.bin" "$TMP/unimplemented.osr" \
       >"$TMP/unimplemented.log" 2>&1; then
    fail "$m was accepted"
  fi
  grep -q 'not implemented yet' "$TMP/unimplemented.log" || fail "$m message"
done

echo "== determinism: --seed=7 twice =="
"$BIN" -m3 --seed=7 "$CORPUS/text.bin" "$TMP/det-1.osr" || fail "encode det-1"
"$BIN" -m3 --seed=7 "$CORPUS/text.bin" "$TMP/det-2.osr" || fail "encode det-2"
cmp "$TMP/det-1.osr" "$TMP/det-2.osr" || fail "determinism"

echo "== -hash- =="
"$BIN" -m3 -hash- --seed=7 "$CORPUS/zeros.bin" "$TMP/hashnone.osr" || \
  fail "encode -hash-"
"$BIN" --verify "$TMP/hashnone.osr" || fail "--verify -hash-"
"$BIN" -d "$TMP/hashnone.osr" "$TMP/hashnone.out" || fail "decode -hash-"
cmp "$TMP/hashnone.out" "$CORPUS/zeros.bin" || fail "round-trip -hash-"
INFO="$("$BIN" -i "$TMP/hashnone.osr")"
printf '%s\n' "$INFO" | grep -qx 'hash_id=1' || fail "-hash- hash_id"
printf '%s\n' "$INFO" | grep -qx 'hash_size=0' || fail "-hash- hash_size"

echo "== pinned v6-new fixtures =="
[ -f "$ROOT/tests/fixtures/v6-new/manifest.tsv" ] || fail "missing v6-new manifest"
while IFS=$'\t' read -r sha id input args; do
  [ -n "$id" ] || continue
  case "$id" in \#*) continue ;; esac
  archive="$ROOT/tests/fixtures/v6-new/$id.osr"
  [ -f "$archive" ] || fail "missing fixture $id"
  actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  [ "$actual" = "$sha" ] || fail "sha256 mismatch for $id"
  "$BIN" --verify "$archive" || fail "--verify $id"
  "$BIN" -d "$archive" "$TMP/new-$id.out" || fail "-d $id"
  cmp "$TMP/new-$id.out" "$CORPUS/$input" || fail "v6-new round-trip $id"
done < "$ROOT/tests/fixtures/v6-new/manifest.tsv"

echo "== -dup read: text-dup-m3 =="
"$BIN" -d "$ROOT/tests/fixtures/v6/text-dup-m3.osr" "$TMP/dup.out" || \
  fail "-d text-dup-m3"
cmp "$TMP/dup.out" "$CORPUS/text.bin" || fail "text-dup restore != text.bin"

echo "== encoder corruption must be rejected =="
"$BIN" -m3 --seed=7 "$CORPUS/tiny.bin" "$TMP/corrupt-src.osr" || \
  fail "encode corrupt-src"
cp "$TMP/corrupt-src.osr" "$TMP/corrupt.osr"
python3 - "$TMP/corrupt.osr" <<'PY'
import struct
import sys

p = sys.argv[1]
d = bytearray(open(p, 'rb').read())

def crc32c(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x82F63B78 if crc & 1 else crc >> 1
    return crc

boff = 60  # header (28) + seed (32)
lit, orig, stat, _ = struct.unpack('<IIII', d[boff:boff + 16])
assert lit > 0 and stat > 0
# Move one byte from literals to records: payload is unchanged, so block_crc
# and blocks_crc stay valid.  Only the footer stat_size changes.
d[boff:boff + 4] = struct.pack('<I', lit - 1)
d[boff + 8:boff + 12] = struct.pack('<I', stat + 1)
footer = len(d) - 36
st = struct.unpack('<Q', d[footer + 8:footer + 16])[0]
d[footer + 8:footer + 16] = struct.pack('<Q', st + 1)
d[footer + 32:footer + 36] = struct.pack('<I', crc32c(d[footer:footer + 32]))
open(p, 'wb').write(d)
PY
"$BIN" --verify "$TMP/corrupt.osr" || fail "--verify rejected the mutated archive"
set +e
"$BIN" -d "$TMP/corrupt.osr" "$TMP/corrupt.out" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "mutated encoder archive -d rc=$rc (expected 4)"

echo "== old v6 fixtures still read =="
bash "$ROOT/tests/v6_read.sh"

echo "v6_encode: PASS"
