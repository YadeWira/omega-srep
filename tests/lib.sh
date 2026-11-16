#!/usr/bin/env bash
# libosrep L0 acceptance: build libosrep.so, build test_lib.c against
# include/osrep.h, run the self-tests and the corpus, then prove that the
# library's .osr is byte-for-byte the CLI's (default options and --seed=7)
# and that both read each other's archives and the pinned v6 fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrep-lib.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LIB="$TMP/lib"
CORPUS="$TMP/corpus"
INPUTS="$TMP/inputs"
BUILD="$TMP/build"
UNITS="$TMP/units"
mkdir -p "$LIB" "$CORPUS" "$INPUTS" "$BUILD" "$UNITS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "== building libosrep =="
bash "$ROOT/src/lib/build.sh" "$LIB" || fail "src/lib/build.sh"
SO="$LIB/libosrep.so"
[ -f "$SO" ] || fail "libosrep.so was not produced"
for sym in osrep_version osrep_options_default osrep_last_error \
           osrep_compress osrep_decompress osrep_free \
           osrep_compress_file osrep_decompress_file; do
  nm -D --defined-only "$SO" | awk '{print $3}' | grep -qx "$sym" || \
    fail "missing exported symbol: $sym"
done

echo "== building test_lib =="
cc -O2 -Wall -Wextra -pthread -I"$ROOT/include" "$ROOT/src/lib/test_lib.c" \
  -L"$LIB" -losrep -Wl,-rpath,"$LIB" -o "$TMP/test_lib" || fail "cc test_lib.c"

echo "== library self-tests =="
"$TMP/test_lib" | tee "$TMP/selftest.log"
grep -q ', 0 failures$' "$TMP/selftest.log" || fail "library self-tests"

echo "== corpus =="
bash "$ROOT/tests/gen_corpus.sh" "$CORPUS" >"$TMP/corpus.log" 2>&1 || {
  cat "$TMP/corpus.log"
  fail "tests/gen_corpus.sh"
}
"$TMP/test_lib" "$CORPUS"/text.bin "$CORPUS"/mixed.bin "$CORPUS"/zeros.bin \
  "$CORPUS"/random.bin "$CORPUS"/tiny.bin | tee "$TMP/corpus-test.log"
grep -q ', 0 failures$' "$TMP/corpus-test.log" || fail "library corpus round-trip"

echo "== building the CLI =="
CC=${CC:-cc}
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_cdc.c" -o "$BUILD/osrep_cdc.o" || fail "cc osrep_cdc.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_match.c" -o "$BUILD/osrep_match.o" || fail "cc osrep_match.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_lr.c" -o "$BUILD/osrep_lr.o" || fail "cc osrep_lr.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_vhash_nh.c" -o "$BUILD/osrep_vhash_nh.o" || fail "cc osrep_vhash_nh.c"
$CC -O2 -fPIC -fno-builtin -fno-stack-protector \
  -c "$ROOT/src/c/osrep_crc_native.c" -o "$BUILD/osrep_crc_native.o" || fail "cc osrep_crc_native.c"
fpc -Mobjfpc -O2 -Sh -Fu"$ROOT/src/pascal" -Fo"$BUILD" -FU"$UNITS" -FE"$BUILD" \
  "$ROOT/src/pascal/osrep.lpr" >"$TMP/fpc.log" 2>&1 || {
  cat "$TMP/fpc.log"
  fail "fpc build"
}
CLI="$BUILD/osrep"
[ -x "$CLI" ] || fail "CLI binary was not produced"

echo "== library .osr == CLI .osr =="
for name in text mixed zeros random tiny; do
  f="$CORPUS/$name.bin"
  "$CLI" -m3 "$f" "$TMP/cli.osr" || fail "CLI encode $name"
  "$TMP/test_lib" --emit 0 "$f" "$TMP/lib.osr" || fail "library encode $name"
  cmp "$TMP/cli.osr" "$TMP/lib.osr" || fail "default .osr differs: $name"

  "$CLI" -m3 --seed=7 "$f" "$TMP/cli7.osr" || fail "CLI encode seed 7 $name"
  "$TMP/test_lib" --emit 7 "$f" "$TMP/lib7.osr" || fail "library encode seed 7 $name"
  cmp "$TMP/cli7.osr" "$TMP/lib7.osr" || fail "seed 7 .osr differs: $name"

  "$CLI" -d "$TMP/lib.osr" "$TMP/cli-back.bin" || fail "CLI decode library $name"
  cmp "$TMP/cli-back.bin" "$f" || fail "CLI decode of library archive: $name"
  "$TMP/test_lib" --decode "$TMP/cli.osr" "$TMP/lib-back.bin" || \
    fail "library decode CLI $name"
  cmp "$TMP/lib-back.bin" "$f" || fail "library decode of CLI archive: $name"
done

echo "== encoder options match the CLI =="
f="$CORPUS/mixed.bin"
"$CLI" -m3 -b1mb -l64 -c16 -a32 --seed=7 "$f" "$TMP/cli-opts.osr" || \
  fail "CLI encode with options"
"$TMP/test_lib" --emit-opt 7 1048576 64 32 16 "$f" "$TMP/lib-opts.osr" || \
  fail "library encode with options"
cmp "$TMP/cli-opts.osr" "$TMP/lib-opts.osr" || fail "option .osr differs"

echo "== the library reads v7 (-m6, the CLI default) =="
for name in text mixed zeros tiny; do
  f="$CORPUS/$name.bin"
  for opt in "" "-l64 --align=1 -b64kb" "-l32 -hash- -b64kb"; do
    # shellcheck disable=SC2086
    "$CLI" -m6 $opt "$f" "$TMP/cli7.osr" || fail "CLI -m6 $opt $name"
    [ "$(head -c 4 "$TMP/cli7.osr")" = "OSR7" ] || fail "not v7: $name $opt"
    "$TMP/test_lib" --decode "$TMP/cli7.osr" "$TMP/lib7-back.bin" || \
      fail "library decode v7 $name $opt"
    cmp "$TMP/lib7-back.bin" "$f" || fail "library decode of v7: $name $opt"
  done
done
"$CLI" "$CORPUS/text.bin" "$TMP/def7.osr" || fail "CLI default encode"
"$TMP/test_lib" --decode-limit "$TMP/def7.osr" 1048576 || \
  fail "max_output on a v7 archive"
python3 - "$ROOT/tests" "$TMP/def7.osr" "$TMP/bad7.osr" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fuzz_v7 import Archive
d = open(sys.argv[2], 'rb').read()
a = Archive(d)
a.dist[0] += 1  # a valid table CRC, but the block digest no longer matches
open(sys.argv[3], 'wb').write(a.build())
PY
if "$TMP/test_lib" --decode "$TMP/bad7.osr" "$TMP/bad7.out" 2>/dev/null; then
  fail "library accepted a v7 archive with a wrong match"
fi

echo "== pinned v6 fixtures through the library =="
bash "$ROOT/tests/golden/inputs.sh" "$INPUTS" >"$TMP/inputs.log" 2>&1 || {
  cat "$TMP/inputs.log"
  fail "tests/golden/inputs.sh"
}
"$TMP/test_lib" --decode "$ROOT/tests/fixtures/v6/text-m3.osr" "$TMP/text.out" || \
  fail "library decode text-m3.osr"
cmp "$TMP/text.out" "$INPUTS/text.bin" || fail "text-m3.osr content"
"$TMP/test_lib" --decode "$ROOT/tests/fixtures/v6/text-dup-m3.osr" "$TMP/dup.out" || \
  fail "library decode text-dup-m3.osr"
cmp "$TMP/dup.out" "$INPUTS/text.bin" || fail "text-dup-m3.osr content"
"$TMP/test_lib" --decode-limit "$ROOT/tests/fixtures/v6/text-dup-m3.osr" 1048576 || \
  fail "max_output on the -dup final output"
"$TMP/test_lib" --decode "$ROOT/tests/fixtures/v6/empty-m3.osr" "$TMP/empty.out" || \
  fail "library decode empty-m3.osr"
[ ! -s "$TMP/empty.out" ] || fail "empty-m3.osr content"

echo "libosrep: all checks passed"
