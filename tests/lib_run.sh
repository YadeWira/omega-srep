#!/usr/bin/env bash
# osrep_run(): the command line as a library function (include/osrep.h).
#
#   tests/lib_run.sh [rounds]     (default 12)
#
# 1. The library's osrep_run writes the CLI's archive for every method, and
#    the loop in src/lib/test_run_loop.c calls it <rounds> times in one
#    process: files, pipes, -1 handles, damaged archives, bad command lines,
#    two calls at once; descriptors, threads and the resident set must stay
#    where they were after the first round.
# 2. The same loop under AddressSanitizer against a library built with
#    cmem (its Pascal heap is the C one): no leak at exit, no bad access.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUNDS=${1:-12}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-librun.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building libosrep, the CLI and the loop =="
bash "$ROOT/src/lib/build.sh" "$TMP/lib" >/dev/null || fail "src/lib/build.sh"
SO="$TMP/lib/libosrep.so"
nm -D --defined-only "$SO" | awk '{print $3}' | grep -qx osrep_run || \
  fail "osrep_run is not exported"
mkdir -p "$TMP/cli/o" "$TMP/cli/u"
for f in osrep_cdc osrep_match osrep_lr osrep_vhash_nh osrep_crc_native; do
  cc -O2 -fno-builtin -fno-stack-protector -c "$ROOT/src/c/$f.c" -o "$TMP/cli/o/$f.o"
done
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$TMP/cli/o" -FU"$TMP/cli/u" \
  -FE"$TMP/cli" "$ROOT/src/pascal/osrep.lpr" >"$TMP/cli/fpc.log" 2>&1 || {
  cat "$TMP/cli/fpc.log"
  fail "fpc CLI"
}
CLI="$TMP/cli/osrep"
cc -O2 -Wall -Wextra -pthread "$ROOT/src/lib/test_run_loop.c" -ldl \
  -o "$TMP/loop" || fail "cc test_run_loop.c"

# 2.6 MB: text, the same text later (a long-range repeat), random bytes
python3 - "$TMP/in.bin" <<'PY'
import random, sys
r = random.Random(11)
words = [''.join(r.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(r.randint(2, 9)))
         for _ in range(3000)]
text = ' '.join(r.choice(words) for _ in range(150000)).encode()
noise = bytes(r.getrandbits(8) for _ in range(400000))
open(sys.argv[1], 'wb').write(text + noise + text[100000:600000] + noise[:200000])
PY

echo "== the CLI's archives =="
mkdir -p "$TMP/exp" "$TMP/work"
# the methods of test_run_loop.c, in its order
i=0
for m in "-m6" "-m6 -t4" "-m6 -l64 --align=1 -t2" "-m6 -hash- -t1" "-m3" \
         "-m5 -b1mb" "-m1" "-dup" "-m0 --seed=7"; do
  # shellcheck disable=SC2086
  "$CLI" $m "$TMP/in.bin" "$TMP/exp/$i.osr" || fail "CLI $m"
  i=$((i + 1))
done

echo "== $ROUNDS rounds =="
"$TMP/loop" "$SO" "$TMP/in.bin" "$TMP/work" "$ROUNDS" "$TMP/exp" | tee "$TMP/loop.log"
grep -q ', 0 failures$' "$TMP/loop.log" || fail "osrep_run loop"
[ -z "$(ls -A "$TMP/work")" ] || { ls -la "$TMP/work"; fail "files left in the work directory"; }

echo "== AddressSanitizer, Pascal heap on malloc (cmem) =="
FPC="fpc -Facmem" bash "$ROOT/src/lib/build.sh" "$TMP/libc" >/dev/null || \
  fail "src/lib/build.sh with cmem"
cc -O1 -g -fsanitize=address -fno-omit-frame-pointer -pthread \
  "$ROOT/src/lib/test_run_loop.c" -ldl -o "$TMP/loop-asan" || fail "cc -fsanitize=address"
mkdir -p "$TMP/work2"
ASAN_OPTIONS=detect_leaks=1:abort_on_error=0 \
  "$TMP/loop-asan" "$TMP/libc/libosrep.so" "$TMP/in.bin" "$TMP/work2" 3 \
  >"$TMP/asan.log" 2>&1 || { tail -40 "$TMP/asan.log"; fail "under AddressSanitizer"; }
grep -q ', 0 failures$' "$TMP/asan.log" || { tail -20 "$TMP/asan.log"; fail "asan loop"; }
if grep -q 'ERROR: \(Leak\|Address\)Sanitizer' "$TMP/asan.log"; then
  grep -A12 'ERROR:' "$TMP/asan.log" | head -40
  fail "AddressSanitizer report"
fi
tail -1 "$TMP/asan.log"
echo "lib_run: all checks passed"
