#!/usr/bin/env bash
# Cross-implementation test: C++ dedup module vs Python prototype.
# Builds bin/dedup_test, runs its selftest, then verifies that on
# identical input the C++ and Python encoders produce byte-identical
# .dupref blobs and each can decode the other's output.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -x bin/dedup_test ]]; then
    make bin/dedup_test
fi

echo "[1/3] C++ selftest"
./bin/dedup_test selftest

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[2/3] cross-encoder byte-identity"
# Same xorshift64-doubled input the C++ selftest uses.
python3 -c "
import sys
def xs(s):
    while True:
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        yield s
g = xs(7)
half = bytes(next(g) & 0xFF for _ in range(131072))
sys.stdout.buffer.write(half + half)
" > "$TMP/in.bin"

./bin/dedup_test encode             "$TMP/in.bin" "$TMP/cpp.dupref" >/dev/null
python3 tests/dup_prototype.py encode "$TMP/in.bin" "$TMP/py.dupref"  >/dev/null
cmp "$TMP/cpp.dupref" "$TMP/py.dupref"
echo "    encoders produce byte-identical blobs"

echo "[3/4] cross-decoder round-trip"
python3 tests/dup_prototype.py decode "$TMP/cpp.dupref" "$TMP/cpp_via_py.bin" >/dev/null
./bin/dedup_test decode               "$TMP/py.dupref"  "$TMP/py_via_cpp.bin" >/dev/null
cmp "$TMP/in.bin" "$TMP/cpp_via_py.bin"
cmp "$TMP/in.bin" "$TMP/py_via_cpp.bin"
echo "    Python decoded C++ blob OK; C++ decoded Python blob OK"

# Buffered CDC mode: verify the same byte-identity property holds
# with buf_size > 0 (the FA-style configuration F5.4 uses).
echo "[4/4] cross-encoder byte-identity (buf=64K)"
./bin/dedup_test encode               "$TMP/in.bin" "$TMP/cpp_buf.dupref" --buf 65536 >/dev/null
python3 tests/dup_prototype.py encode "$TMP/in.bin" "$TMP/py_buf.dupref"  --buf 65536 >/dev/null
cmp "$TMP/cpp_buf.dupref" "$TMP/py_buf.dupref"
python3 tests/dup_prototype.py decode "$TMP/cpp_buf.dupref" "$TMP/cpp_buf_via_py.bin" >/dev/null
./bin/dedup_test decode               "$TMP/py_buf.dupref"  "$TMP/py_buf_via_cpp.bin" >/dev/null
cmp "$TMP/in.bin" "$TMP/cpp_buf_via_py.bin"
cmp "$TMP/in.bin" "$TMP/py_buf_via_cpp.bin"
echo "    buffered encoders byte-identical, both decoders round-trip"

echo "dedup_xtest: PASS"
