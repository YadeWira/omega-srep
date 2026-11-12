#!/usr/bin/env bash
# Format-aware cuts of -osrep (OSREP_FRAG_F_*): every way of driving the
# state gives the same fragments, and in a tar or zip an unchanged member
# keeps its fragments when its neighbour changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-fmt.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CC=${CC:-cc}
$CC -O2 -std=c99 -Wall -Wextra -pedantic -I"$ROOT/src/c" \
  "$ROOT/src/c/osrep_sha1.c" "$ROOT/src/c/osrep_fragment.c" \
  "$ROOT/tests/fragment_format_check.c" -o "$TMP/check" || fail "cc"

# three members: text, random, text; v2 changes the middle one
mkdir -p "$TMP/v1/d" "$TMP/v2/d"
python3 - "$TMP" <<'EOF'
import random, sys
t = sys.argv[1]
r = random.Random(7)
a = b"".join(b"line %d of the first member, %d\n" % (i, r.randrange(10**9)) for i in range(9000))
c = bytes(r.randrange(256) for _ in range(300000))
d = b"".join(b"third member %d %d\n" % (i, r.randrange(10**9)) for i in range(7000))
b1 = bytes(r.randrange(256) for _ in range(70000))
b2 = bytes(r.randrange(256) for _ in range(91000))
for v, b in (("v1", b1), ("v2", b2)):
    for name, data in (("a.txt", a), ("b.bin", b), ("c.bin", c), ("d.txt", d)):
        if name == "b.bin" or v == "v1":
            open("%s/%s/d/%s" % (t, v, name), "wb").write(data)
EOF
cp "$TMP/v1/d/a.txt" "$TMP/v1/d/c.bin" "$TMP/v1/d/d.txt" "$TMP/v2/d/"
touch -d 2026-01-01 "$TMP"/v1/d/* "$TMP"/v2/d/a.txt "$TMP"/v2/d/c.bin "$TMP"/v2/d/d.txt
touch -d 2026-02-01 "$TMP"/v2/d/b.bin
for v in v1 v2; do
  (cd "$TMP/$v" && tar --sort=name --format=ustar --owner=0 --group=0 \
    -cf "$TMP/$v.tar" d && tar --sort=name --format=gnu --owner=0 \
    --group=0 -cf "$TMP/$v.gnu.tar" d)
  if command -v zip >/dev/null; then
    (cd "$TMP/$v" && zip -q -X -r "$TMP/$v.zip" d/a.txt d/b.bin d/c.bin d/d.txt)
  fi
done

for f in "$TMP"/v1.tar "$TMP"/v2.gnu.tar "$TMP"/v1/d/a.txt "$TMP"/v1/d/c.bin; do
  for n in 0 3 6; do
    for flags in osrep 0 2 32 40 42; do
      "$TMP/check" same "$f" "$n" "$flags" >/dev/null ||
        fail "same $f N=$n flags=$flags"
    done
  done
done
[ -f "$TMP/v1.zip" ] && for flags in osrep 0 32 40 42; do
  "$TMP/check" same "$TMP/v2.zip" 3 "$flags" >/dev/null ||
    fail "same zip flags=$flags"
done

# what v2 adds: about the changed member (91000 bytes) and its headers
for t in tar gnu.tar; do
  plain=$("$TMP/check" newbytes "$TMP/v1.$t" "$TMP/v2.$t" 3 0)
  aware=$("$TMP/check" newbytes "$TMP/v1.$t" "$TMP/v2.$t" 3 osrep)
  echo "$t: v2 adds $plain bytes (plain CDC), $aware (TAR)"
  # the member and both headers it touches, plus the tail of the fragment
  # before its header (no rule cuts before a header: that would move a cut
  # back), at most one average fragment
  [ "$aware" -le $((91136 + 1024 + 8192)) ] || fail "$t: TAR cuts add $aware"
  [ "$aware" -lt "$plain" ] || fail "$t: TAR cuts add more than the plain CDC"
done
if [ -f "$TMP/v1.zip" ]; then
  plain=$("$TMP/check" newbytes "$TMP/v1.zip" "$TMP/v2.zip" 3 0)
  sig=$("$TMP/check" newbytes "$TMP/v1.zip" "$TMP/v2.zip" 3 osrep)
  echo "zip: v2 adds $plain bytes (plain CDC), $sig (-osrep: ZIP_SIG|ZIP_AFTER)"
  # the member, its local header and the whole central directory
  [ "$sig" -le $((91000 + 200 + 400)) ] || fail "zip: ZIP_SIG cuts add $sig"
else
  echo "zip: skipped (no zip)"
fi
echo "format-aware cuts: same fragments by every path; unchanged members keep theirs"
