#!/usr/bin/env bash
# stdin larger than 32 MiB goes to a temporary file (--temp=DIR), not to
# RAM: the same archive as from a file, round trips through pipes, a low
# RSS, and the temporary file never left behind (also after an error).
#   OSREP=<binary> to test a given build (default: build one)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-stdin.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CC=${CC:-cc}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [ -z "${OSREP:-}" ]; then
  mkdir -p "$TMP/b/u"
  for f in osrep_cdc osrep_match osrep_lr osrep_vhash_nh osrep_crc_native; do
    $CC -O2 -fPIC -fno-builtin -fno-stack-protector \
      -c "$ROOT/src/c/$f.c" -o "$TMP/b/$f.o" || fail "cc $f"
  done
  fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$TMP/b" -FU"$TMP/b/u" \
    -FE"$TMP/b" "$ROOT/src/pascal/osrep.lpr" >"$TMP/fpc.log" 2>&1 || {
    cat "$TMP/fpc.log"
    fail "fpc"
  }
  OSREP=$TMP/b/osrep
fi

T=$TMP/t
mkdir -p "$T"
empty_t() { [ -z "$(ls -A "$T")" ] || fail "temporary file left in $T: $(ls -A "$T")"; }

# 96 MiB: random 1 MiB pieces, half of them repeated far apart, so the
# archive is also over 32 MiB (its decode goes through the temp file too)
python3 - "$TMP/in.bin" <<'EOF'
import random, sys
r = random.Random(5)
pieces = [bytes(r.getrandbits(8) for _ in range(1 << 16)) * 16 for _ in range(8)]
out = open(sys.argv[1], 'wb')
for k in range(96):
    if k % 2:
        out.write(pieces[r.randrange(len(pieces))])
    else:
        out.write(r.randbytes(1 << 20))
EOF
head -c 100000 "$TMP/in.bin" > "$TMP/small.bin"

rss() { # rss <cmd...>: runs it, prints the peak RSS in MB on fd 3
  /usr/bin/time -f '%M' -o "$TMP/rss" "$@"
  echo $(( $(cat "$TMP/rss") / 1024 )) >&3
}

echo "== small stdin: in memory, same archive as from a file =="
"$OSREP" -m6 "$TMP/small.bin" "$TMP/small.file.osr" >/dev/null
"$OSREP" -m6 --temp="$T" - - < "$TMP/small.bin" > "$TMP/small.pipe.osr"
cmp -s "$TMP/small.file.osr" "$TMP/small.pipe.osr" || fail "small: stdin != file"
"$OSREP" -d --temp="$T" - - < "$TMP/small.pipe.osr" | cmp -s - "$TMP/small.bin" ||
  fail "small round trip"
empty_t

echo "== 96 MiB through pipes =="
"$OSREP" -m6 "$TMP/in.bin" "$TMP/file.osr" >/dev/null
exec 3>"$TMP/rss.log"
cat "$TMP/in.bin" | rss "$OSREP" -m6 --temp="$T" - - > "$TMP/pipe.osr"
cmp -s "$TMP/file.osr" "$TMP/pipe.osr" || fail "stdin != file"
[ "$(stat -c%s "$TMP/pipe.osr")" -gt $((32 << 20)) ] || fail "archive too small for the test"
cat "$TMP/pipe.osr" | rss "$OSREP" -d --temp="$T" - - > "$TMP/out.bin"
cmp -s "$TMP/in.bin" "$TMP/out.bin" || fail "round trip"
cat "$TMP/pipe.osr" | rss "$OSREP" --verify --temp="$T" - >/dev/null
exec 3>&-
{ read -r enc_mb; read -r dec_mb; read -r ver_mb; } < "$TMP/rss.log"
echo "  peak RSS: encode $enc_mb MB, decode $dec_mb MB, verify $ver_mb MB (input 96 MiB)"
[ "$enc_mb" -lt 80 ] && [ "$dec_mb" -lt 80 ] && [ "$ver_mb" -lt 80 ] ||
  fail "stdin seems to be held in RAM"
empty_t

echo "== -dup from stdin (keeps its input in memory by design) =="
"$OSREP" -dup --temp="$T" - - < "$TMP/in.bin" > "$TMP/dup.osr"
"$OSREP" -d - - < "$TMP/dup.osr" | cmp -s - "$TMP/in.bin" || fail "dup round trip"
empty_t

echo "== a damaged archive: exit 4, no temporary file left =="
cp "$TMP/pipe.osr" "$TMP/bad.osr"
printf '\xff\xff\xff\xff' | dd of="$TMP/bad.osr" bs=1 seek=$((40 << 20)) conv=notrunc 2>/dev/null
set +e
"$OSREP" -d --temp="$T" - - < "$TMP/bad.osr" > /dev/null 2>"$TMP/err"
rc=$?
set -e
[ "$rc" = 4 ] || fail "damaged archive: exit $rc ($(cat "$TMP/err"))"
empty_t

echo "== --temp errors =="
set +e
"$OSREP" -d --temp="$TMP/nonexistent" - - < "$TMP/small.pipe.osr" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 2 ] || fail "--temp=<missing dir>: exit $rc"

echo "stdin temp: all checks passed"
