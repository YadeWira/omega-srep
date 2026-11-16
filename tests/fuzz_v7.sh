#!/usr/bin/env bash
# Fuzz the v7 decoder (format-v7.md) with structure-aware mutations, on a
# build with range, stack and object checks (-Cr -Ct -CR; no -Co: the
# hashes wrap on purpose).
#   FUZZ_CASES (default 3000), FUZZ_SEED (default 1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-fuzz7.XXXXXX")"
KEEP=${FUZZ_KEEP:-}
trap '[ -n "$KEEP" ] || rm -rf "$TMP"' EXIT

CC=${CC:-cc}
CASES=${FUZZ_CASES:-3000}
SEED=${FUZZ_SEED:-1}
B="$TMP/build"
S="$TMP/seeds"
W="$TMP/work"
mkdir -p "$B/u" "$S" "$W"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== checked build =="
for f in osrep_cdc osrep_match osrep_lr osrep_vhash_nh osrep_crc_native; do
  $CC -O1 -g -fPIC -fno-builtin -fno-stack-protector \
    -c "$ROOT/src/c/$f.c" -o "$B/$f.o" || fail "cc $f"
done
fpc -Mobjfpc -O1 -Sh -Cr -Ct -CR -gl -Fu"$ROOT/src/pascal" -Fo"$B" \
  -FU"$B/u" -FE"$B" "$ROOT/src/pascal/osrep.lpr" >"$TMP/fpc.log" 2>&1 || {
  cat "$TMP/fpc.log"
  fail "fpc"
}

echo "== seeds =="
bash "$ROOT/tests/gen_corpus.sh" "$TMP/corpus" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "gen_corpus"
}
python3 - "$TMP/corpus/versions.bin" <<'PY'
# three versions of 40 KB of pseudo-random words with edits: many matches
# with literals between them, inside and across blocks
import random, sys
r = random.Random(7)
words = [''.join(r.choice('abcdefghij') for _ in range(r.randint(2, 9)))
         for _ in range(4000)]
t = bytearray(' '.join(r.choice(words) for _ in range(7000)).encode()[:40000])
out = bytearray()
for v in range(3):
    for k in range(40):
        p = r.randrange(len(t) - 8)
        t[p:p + r.randint(0, 6)] = b'v%03d' % (v * 100 + k)
    out += t
open(sys.argv[1], 'wb').write(bytes(out))
PY
head -c 70000 "$TMP/corpus/mixed.bin" >"$TMP/corpus/mixed-s.bin"
: >"$TMP/corpus/empty.bin"
for name in versions mixed-s tiny zeros empty; do
  i=0
  for opt in "-l64 -b64kb" "-l32 -hash- -b32kb" "-l64 --align=1 -b64kb" ""; do
    i=$((i + 1))
    cp "$TMP/corpus/$name.bin" "$S/$name-$i"
    # shellcheck disable=SC2086
    "$B/osrep" -m6 $opt "$S/$name-$i" "$S/$name-$i.osr" >/dev/null || fail "seed $name $opt"
  done
done

echo "== fuzz: $CASES cases, seed $SEED =="
ulimit -v 4000000
python3 "$ROOT/tests/fuzz_v7.py" "$B/osrep" "$S" "$W" "$CASES" "$SEED" || {
  KEEP=1
  echo "failing cases kept in $W" >&2
  fail "fuzz"
}
echo "v7 fuzz: all checks passed"
