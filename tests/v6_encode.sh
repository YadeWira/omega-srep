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

echo "== building with fpc + native CDC =="
CC=${CC:-cc}
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_cdc.c" -o "$BUILD/osrep_cdc.o" || fail "cc osrep_cdc.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_match.c" -o "$BUILD/osrep_match.o" || fail "cc osrep_match.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_crc_native.c" -o "$BUILD/osrep_crc_native.o" || fail "cc osrep_crc_native.c"
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$BUILD" -FU"$UNITS" -FE"$BUILD" \
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

echo "== -m1/-m2: dedup-only modes =="
for m in -m1 -m2; do
  "$BIN" "$m" "$CORPUS/zeros.bin" "$TMP/${m#-}-zeros.osr" || fail "encode $m"
  "$BIN" --verify "$TMP/${m#-}-zeros.osr" || fail "--verify $m"
  "$BIN" -d "$TMP/${m#-}-zeros.osr" "$TMP/${m#-}-zeros.out" || fail "decode $m"
  cmp "$TMP/${m#-}-zeros.out" "$CORPUS/zeros.bin" || fail "round-trip $m"
  INFO="$("$BIN" -i "$TMP/${m#-}-zeros.osr")"
  printf '%s\n' "$INFO" | grep -qx 'restored_size=262144' || \
    fail "$m restored_size: $INFO"
  "$BIN" "$m" -t1 "$CORPUS/mixed.bin" "$TMP/${m#-}-t1.osr" || fail "$m -t1"
  "$BIN" "$m" -t4 "$CORPUS/mixed.bin" "$TMP/${m#-}-t4.osr" || fail "$m -t4"
  cmp "$TMP/${m#-}-t1.osr" "$TMP/${m#-}-t4.osr" || fail "$m -t changes the archive"
done

echo "== -m4/-m5: lazy and deeper, round-trip =="
for m in -m4 -m5; do
  "$BIN" "$m" -t4 "$CORPUS/mixed.bin" "$TMP/${m#-}.osr" || fail "encode $m"
  "$BIN" --verify "$TMP/${m#-}.osr" || fail "--verify $m"
  "$BIN" -d "$TMP/${m#-}.osr" "$TMP/${m#-}.out" || fail "decode $m"
  cmp "$TMP/${m#-}.out" "$CORPUS/mixed.bin" || fail "round-trip $m"
done
"$BIN" -m4 --seed=7 "$CORPUS/text.bin" "$TMP/m4a.osr" || fail "m4 seed a"
"$BIN" -m4 --seed=7 "$CORPUS/text.bin" "$TMP/m4b.osr" || fail "m4 seed b"
cmp "$TMP/m4a.osr" "$TMP/m4b.osr" || fail "m4 determinism"

echo "== -t threads: same archive, round-trip =="
"$BIN" -m3 -t1 "$CORPUS/mixed.bin" "$TMP/t1.osr" || fail "encode -t1"
"$BIN" -m3 -t4 "$CORPUS/mixed.bin" "$TMP/t4.osr" || fail "encode -t4"
cmp "$TMP/t1.osr" "$TMP/t4.osr" || fail "-t changes the archive"
"$BIN" -d "$TMP/t4.osr" "$TMP/t4.out" || fail "decode -t4"
cmp "$TMP/t4.out" "$CORPUS/mixed.bin" || fail "round-trip -t4"
if "$BIN" -m3 -tx "$CORPUS/tiny.bin" "$TMP/tx.osr" >/dev/null 2>&1; then
  fail "-tx was accepted"
fi

echo "== -m0: stored stream =="
"$BIN" -m0 "$CORPUS/text.bin" "$TMP/m0.osr" || fail "-m0 encode"
"$BIN" --verify "$TMP/m0.osr" || fail "--verify -m0"
"$BIN" -d "$TMP/m0.osr" "$TMP/m0.out" || fail "-d -m0"
cmp "$TMP/m0.out" "$CORPUS/text.bin" || fail "-m0 round-trip"
M0INFO="$("$BIN" -i "$TMP/m0.osr")"
printf '%s\n' "$M0INFO" | grep -qx 'stat_size=0' || fail "-m0 stat_size"
"$BIN" -m0 -dup "$CORPUS/zeros.bin" "$TMP/m0-dup.osr" || fail "-m0 -dup"
"$BIN" -d "$TMP/m0-dup.osr" "$TMP/m0-dup.out" || fail "-d -m0 -dup"
cmp "$TMP/m0-dup.out" "$CORPUS/zeros.bin" || fail "-m0 -dup round-trip"

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

echo "== -dup write: dedup, restore, determinism =="
"$BIN" -dup -m3 "$CORPUS/zeros.bin" "$TMP/dup-zeros.osr" || fail "encode -dup zeros"
"$BIN" --verify "$TMP/dup-zeros.osr" || fail "--verify -dup zeros"
"$BIN" -d "$TMP/dup-zeros.osr" "$TMP/dup-zeros.out" || fail "decode -dup zeros"
cmp "$TMP/dup-zeros.out" "$CORPUS/zeros.bin" || fail "restore -dup zeros"
DUPINFO="$("$BIN" -i "$TMP/dup-zeros.osr")"
printf '%s\n' "$DUPINFO" | grep -qx 'original_size=55429' || \
  fail "-dup body size changed: $DUPINFO"
printf '%s\n' "$DUPINFO" | grep -qx 'restored_size=262144' || \
  fail "-dup restored size: $DUPINFO"

"$BIN" -dup -m3 -t1 "$CORPUS/zeros.bin" "$TMP/dup-t1.osr" || fail "-dup -t1"
"$BIN" -dup -m3 -t4 "$CORPUS/zeros.bin" "$TMP/dup-t4.osr" || fail "-dup -t4"
cmp "$TMP/dup-t1.osr" "$TMP/dup-t4.osr" || fail "-dup -t changes the archive"

"$BIN" -dup -m3 -hash- "$CORPUS/zeros.bin" "$TMP/dup-hashnone.osr" || \
  fail "-dup -hash-"
"$BIN" -d "$TMP/dup-hashnone.osr" "$TMP/dup-hashnone.out" || fail "-d -dup -hash-"
cmp "$TMP/dup-hashnone.out" "$CORPUS/zeros.bin" || fail "-dup -hash- restore"

"$BIN" -dup -m5 "$CORPUS/mixed.bin" "$TMP/dup-m5.osr" || fail "-dup -m5"
"$BIN" -d "$TMP/dup-m5.osr" "$TMP/dup-m5.out" || fail "-d -dup -m5"
cmp "$TMP/dup-m5.out" "$CORPUS/mixed.bin" || fail "-dup -m5 round-trip"

: > "$TMP/dup-empty.bin"
"$BIN" -dup -m3 "$TMP/dup-empty.bin" "$TMP/dup-empty.osr" || fail "-dup empty"
"$BIN" -d "$TMP/dup-empty.osr" "$TMP/dup-empty.out" || fail "-d -dup empty"
[ ! -s "$TMP/dup-empty.out" ] || fail "-dup empty content"

echo "== stdin / stdout =="
"$BIN" -m3 "$CORPUS/text.bin" "$TMP/file.osr" || fail "file encode"
cat "$CORPUS/text.bin" | "$BIN" -m3 - - > "$TMP/pipe.osr" || fail "stdin encode"
cmp "$TMP/file.osr" "$TMP/pipe.osr" || fail "stdin encode differs"
cat "$TMP/pipe.osr" | "$BIN" -d - - > "$TMP/pipe.out" || fail "stdin decode"
cmp "$TMP/pipe.out" "$CORPUS/text.bin" || fail "stdin decode differs"
cat "$TMP/pipe.osr" | "$BIN" --verify - || fail "stdin verify"
cat "$TMP/pipe.osr" | "$BIN" -i - | grep -qx 'original_size=4194304' || \
  fail "stdin info"
cat "$CORPUS/text.bin" | "$BIN" -m3 - > "$TMP/pipe-default.osr" || \
  fail "stdin default stdout"
cmp "$TMP/file.osr" "$TMP/pipe-default.osr" || fail "default stdout differs"
cat "$CORPUS/zeros.bin" | "$BIN" -m1 - - > "$TMP/pipe-m1.osr" || fail "stdin -m1"
"$BIN" -d "$TMP/pipe-m1.osr" "$TMP/pipe-m1.out" || fail "decode stdin -m1"
cmp "$TMP/pipe-m1.out" "$CORPUS/zeros.bin" || fail "stdin -m1 content"
cat "$CORPUS/zeros.bin" | "$BIN" -dup -m3 - - > "$TMP/pipe-dup.osr" || \
  fail "stdin -dup"
"$BIN" -d "$TMP/pipe-dup.osr" "$TMP/pipe-dup.out" || fail "decode stdin -dup"
cmp "$TMP/pipe-dup.out" "$CORPUS/zeros.bin" || fail "stdin -dup content"

echo "== pinned v6-new fixtures =="
[ -f "$ROOT/tests/fixtures/v6-new/manifest.tsv" ] || fail "missing v6-new manifest"
while IFS=$'\t' read -r sha id input args; do
  [ -n "$id" ] || continue
  case "$id" in \#*) continue ;; esac
  archive="$ROOT/tests/fixtures/v6-new/$id.osr"
  [ -f "$archive" ] || fail "missing fixture $id"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  fi
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
