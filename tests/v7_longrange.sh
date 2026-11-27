#!/usr/bin/env bash
# -m6 / format v7: the native long-range finder against its Pascal
# reference (same archive), round trips, --verify, -i, and corruption of the
# match table and of a block.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-v7.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

CC=${CC:-cc}
CORPUS="$TMP/corpus"
NAT="$TMP/native"
REF="$TMP/reference"
mkdir -p "$CORPUS" "$NAT/u" "$REF/u"

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
# versions: the same text three times with a few edits, so there are long
# repeats far apart and across blocks of 64 KiB
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
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$NAT" \
  -FU"$NAT/u" -FE"$NAT" "$ROOT/src/pascal/osrep.lpr" >"$TMP/native.log" 2>&1 || {
  cat "$TMP/native.log"
  fail "native fpc"
}
fpc -Mobjfpc -O2 -Sh -dOSREP_NO_NATIVE -Fu"$ROOT/src/pascal" \
  -FU"$REF/u" -FE"$REF" "$ROOT/src/pascal/osrep.lpr" >"$TMP/ref.log" 2>&1 || {
  cat "$TMP/ref.log"
  fail "reference fpc"
}

echo "== native = reference, round trip, verify =="
for name in empty tiny zeros mixed text random versions; do
  for opt in "" "-l64" "-l128 -b64kb" "-l32 -hash-" "-l64 --align=1"; do
    tag="$name${opt// /}"
    # shellcheck disable=SC2086
    "$NAT/osrep" -m6 $opt "$CORPUS/$name.bin" "$TMP/$tag.n.osr" || fail "native $tag"
    # shellcheck disable=SC2086
    "$REF/osrep" -m6 $opt "$CORPUS/$name.bin" "$TMP/$tag.r.osr" || fail "reference $tag"
    cmp -s "$TMP/$tag.n.osr" "$TMP/$tag.r.osr" || fail "$tag: native and Pascal differ"
    [ "$(head -c 4 "$TMP/$tag.n.osr")" = "OSR7" ] || fail "$tag: not a v7 archive"
    "$NAT/osrep" --verify "$TMP/$tag.n.osr" >/dev/null || fail "verify $tag"
    "$NAT/osrep" -i "$TMP/$tag.n.osr" >/dev/null || fail "info $tag"
    "$NAT/osrep" -d "$TMP/$tag.n.osr" "$TMP/$tag.out" || fail "decode $tag"
    cmp -s "$TMP/$tag.out" "$CORPUS/$name.bin" || fail "round trip $tag"
    rm -f "$TMP/$tag.r.osr" "$TMP/$tag.out"
  done
done

echo "== streaming finder: tiny buffers and stdin give the same archive =="
for name in text versions mixed; do
  for opt in "-l64" "-l128 --align=1"; do
    tag="$name${opt// /}"
    # shellcheck disable=SC2086
    "$NAT/osrep" -m6 $opt "$CORPUS/$name.bin" "$TMP/$tag.a.osr" || fail "native $tag"
    for cap in 1 300 4096 65536; do
      # shellcheck disable=SC2086
      OSREP_LR_BUF=$cap "$NAT/osrep" -m6 $opt "$CORPUS/$name.bin" "$TMP/$tag.b.osr" ||
        fail "buffer $cap $tag"
      cmp -s "$TMP/$tag.a.osr" "$TMP/$tag.b.osr" || fail "$tag: buffer $cap differs"
    done
    # shellcheck disable=SC2086
    "$NAT/osrep" -m6 $opt - "$TMP/$tag.c.osr" <"$CORPUS/$name.bin" || fail "stdin $tag"
    cmp -s "$TMP/$tag.a.osr" "$TMP/$tag.c.osr" || fail "$tag: stdin differs"
    rm -f "$TMP/$tag.a.osr" "$TMP/$tag.b.osr" "$TMP/$tag.c.osr"
  done
done

echo "== the finder's pieces and threads do not change the archive =="
# OSREP_LR_PIECE forces small pieces (rounded down to a multiple of the
# step, at least one step): many piece boundaries, and the buffers of
# positions grow from their smallest size
for name in zeros text versions mixed random; do
  for opt in "-l32" "-l64" "-l128 --align=1"; do
    tag="$name${opt// /}"
    # shellcheck disable=SC2086
    "$REF/osrep" -m6 $opt "$CORPUS/$name.bin" "$TMP/$tag.r.osr" || fail "reference $tag"
    for pt in "1 1" "1 3" "97 2" "4096 7" "100000 4" "- 64"; do
      set -- $pt
      if [ "$1" = - ]; then
        # shellcheck disable=SC2086
        "$NAT/osrep" -m6 $opt -t"$2" "$CORPUS/$name.bin" "$TMP/$tag.p.osr" ||
          fail "threads $2 $tag"
      else
        # shellcheck disable=SC2086
        OSREP_LR_PIECE=$1 OSREP_LR_BUF=4096 "$NAT/osrep" -m6 $opt -t"$2" \
          "$CORPUS/$name.bin" "$TMP/$tag.p.osr" || fail "piece $1 threads $2 $tag"
      fi
      cmp -s "$TMP/$tag.r.osr" "$TMP/$tag.p.osr" ||
        fail "$tag: piece $1, $2 threads differs from the reference"
    done
    rm -f "$TMP/$tag.r.osr" "$TMP/$tag.p.osr"
  done
done

echo "== default method is -m6; -dup alone keeps -m3 =="
"$NAT/osrep" -m6 "$CORPUS/versions.bin" "$TMP/def6.osr" || fail "-m6 versions"
"$NAT/osrep" "$CORPUS/versions.bin" "$TMP/def.osr" || fail "default versions"
cmp -s "$TMP/def6.osr" "$TMP/def.osr" || fail "default is not -m6"
"$NAT/osrep" -l64 - "$TMP/defl.osr" <"$CORPUS/versions.bin" || fail "default -l64 stdin"
[ "$(head -c 4 "$TMP/defl.osr")" = "OSR7" ] || fail "default with options is not v7"
"$NAT/osrep" -dup "$CORPUS/versions.bin" "$TMP/dup.osr" || fail "-dup alone"
"$NAT/osrep" -m3 -dup "$CORPUS/versions.bin" "$TMP/dup3.osr" || fail "-m3 -dup"
cmp -s "$TMP/dup.osr" "$TMP/dup3.osr" || fail "-dup alone is not -m3 -dup"
if "$NAT/osrep" -m6 -dup "$CORPUS/versions.bin" "$TMP/bad6.osr" 2>/dev/null; then
  fail "-m6 -dup accepted"
fi
rm -f "$TMP/def6.osr" "$TMP/def.osr" "$TMP/defl.osr" "$TMP/dup.osr" "$TMP/dup3.osr" "$TMP/bad6.osr"

echo "== matches cross blocks =="
"$NAT/osrep" -m6 -l64 -b64kb "$CORPUS/versions.bin" "$TMP/v.osr"
count=$(python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read()
print(struct.unpack_from('<Q', d, 28 + 32)[0])" "$TMP/v.osr")
[ "$count" -gt 0 ] || fail "versions.bin: no long-range matches"

echo "== corruption is rejected =="
python3 - "$TMP/v.osr" "$TMP" <<'EOF'
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
stat = struct.unpack_from('<Q', d, len(d) - 36 + 8)[0]   # table size
t0 = 60                                                    # header + seed
cases = {
    'table-gap': t0 + 8,                     # the first gap varint
    'table-dist': t0 + stat - 4 - 2,         # inside the distance column
    'table-crc': t0 + stat - 4,              # the table CRC itself
    'block': t0 + stat + 16 + 20,            # first block's literals
}
for name, off in cases.items():
    c = bytearray(d)
    c[off] ^= 0x55
    open(f'{sys.argv[2]}/bad-{name}.osr', 'wb').write(c)
EOF
for name in table-gap table-dist table-crc block; do
  if "$NAT/osrep" -d "$TMP/bad-$name.osr" "$TMP/bad.out" 2>"$TMP/err.txt"; then
    fail "corrupt $name decoded"
  fi
  rc=0
  "$NAT/osrep" --verify "$TMP/bad-$name.osr" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ] || fail "corrupt $name: --verify rc=$rc"
done

echo "== pinned v7 fixtures (frozen format) =="
FX="$ROOT/tests/fixtures/v7"
[ -f "$FX/manifest.tsv" ] || fail "missing v7 manifest"
python3 - "$CORPUS/random.bin" "$CORPUS/rversions.bin" <<'EOF'
import sys
r = open(sys.argv[1], 'rb').read()[:65536]
out = bytearray()
for v in range(3):
    b = bytearray(r)
    for k in range(12):
        p = (k * 7919 + v * 104729) % (len(b) - 8)
        b[p:p + 4] = b'v%03d' % v
    out += b
open(sys.argv[2], 'wb').write(bytes(out))
EOF
nfx=0
while IFS=$'\t' read -r sha id input args; do
  [ -n "$id" ] || continue
  case "$id" in \#*) continue ;; esac
  archive="$FX/$id.osr"
  [ -f "$archive" ] || fail "missing fixture $id"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  fi
  [ "$actual" = "$sha" ] || fail "sha256 mismatch for $id"
  for b in "$NAT/osrep" "$REF/osrep"; do
    "$b" --verify "$archive" >/dev/null || fail "--verify $id"
    "$b" -d "$archive" "$TMP/fx.out" || fail "-d $id"
    cmp "$TMP/fx.out" "$CORPUS/$input" || fail "v7 fixture $id content"
    "$b" -d "$archive" - < /dev/null | cmp - "$CORPUS/$input" || \
      fail "v7 fixture $id to stdout"
  done
  nfx=$((nfx + 1))
done < "$FX/manifest.tsv"
[ "$nfx" -eq 6 ] || fail "expected 6 v7 fixtures, read $nfx"

echo "v7 long-range: all checks passed"
