#!/usr/bin/env bash
# Regression test for the chunk_hash() swap (FNV-1a -> word-at-a-time
# 64-bit hash, Compression/SREP/dedup.cpp).
#
# Why this test exists, specifically: the real `osrep -dup` CLI always
# goes through encode_streaming() (dup_wrapper.cpp), and by DEFAULT
# (no --dup-paranoid) that path trusts chunk_hash() outright on a hit
# -- no byte-compare fallback (dedup.cpp's `if (is_dup && paranoid)`).
# Every other dup test in this suite either uses the byte-compare-
# guarded batch encode() path (tests only, via dedup_test) or passes
# --dup-paranoid explicitly (dup_realworld.sh). This test is the one
# place that exercises the real default, non-paranoid streaming path
# specifically, with content shaped to stress chunk_hash()'s riskiest
# code: the 0-7-byte tail-handling boundary in its word-at-a-time loop.
#
# Forces very small chunks (--chunk-avg=8 --chunk-min=1 --chunk-max=16)
# over a large pseudo-random input so the natural CDC cut-point
# distribution produces many chunks at every length from 1 to 16 bytes
# inclusive -- covering the 1/7/8/9-byte tail cases (and everything
# around them) many times over in one run, without needing to force
# exact chunk boundaries (content-defined chunking can't be dictated
# to an exact length, only encouraged statistically via --chunk-avg).
#
# A bug in the new hash's tail-byte handling (e.g. reading past the
# buffer, or silently truncating short chunks to the same hash) would
# either crash, or -- worse, given no byte-compare fallback here --
# silently misdedupe two different short chunks into one, corrupting
# the round-trip. Byte-identical round-trip is therefore a real
# correctness signal here, not just a sanity check.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$(dirname "$0")/_winpath.sh"

[[ -x bin/osrep ]] || make bin/osrep

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

# 4 MiB of pseudo-random content, forced to tiny CDC chunks. Random
# (not repetitive) content means dedup hits will occur incidentally
# whenever two of the many small chunks happen to be byte-identical
# by chance -- exactly the scenario the non-paranoid path has to get
# right without a byte-compare safety net.
gen_input() {
    local out="$1" size="$2"
    python3 -c "
import struct, sys
def prng_bytes(n, seed):
    out = bytearray(); s = seed
    while len(out) < n:
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        out += struct.pack('<Q', s & 0xFFFFFFFFFFFFFFFF)
    return bytes(out[:n])
sys.stdout.buffer.write(prng_bytes($size, 0x5EED1))
" > "$out"
}

IN="$TMP/tiny_chunks.bin"
gen_input "$IN" $((4 * 1024 * 1024))
IN_SIZE=$(stat -c%s "$IN")

# ---------------------------------------------------------------
# 1. Real CLI, default streaming (NO --dup-paranoid), forced-tiny
#    chunks, across -m3/-m4/-m5. Must round-trip byte-identical.
# ---------------------------------------------------------------
for m in -m3 -m4 -m5; do
    name="${m#-}"
    archive="$TMP/tiny_${name}.osr"
    restored="$TMP/tiny_${name}.dec"
    if ./bin/osrep -dup "$m" --chunk-avg=8 --chunk-min=1 --chunk-max=16 "$IN" "$archive" >/dev/null 2>&1 && \
       ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1 && \
       cmp -s "$IN" "$restored"; then
        arch_sz=$(stat -c%s "$archive")
        echo "OK    osrep -dup $m (no --dup-paranoid) tiny-chunk round-trip   in=$IN_SIZE archive=$arch_sz"
        passed=$((passed + 1))
    else
        echo "FAIL  osrep -dup $m (no --dup-paranoid) tiny-chunk round-trip"
        failed=$((failed + 1))
    fi
done

# ---------------------------------------------------------------
# 2. Same forced-tiny-chunk config, but explicitly with a repeated
#    block spliced in so real dedup hits (not just incidental ones)
#    are guaranteed to occur on short chunks in the non-paranoid path.
# ---------------------------------------------------------------
python3 -c "
import struct, sys
def prng_bytes(n, seed):
    out = bytearray(); s = seed
    while len(out) < n:
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        out += struct.pack('<Q', s & 0xFFFFFFFFFFFFFFFF)
    return bytes(out[:n])
block = prng_bytes(65536, 0xABCDEF)
pad = prng_bytes(12345, 0x111)
sys.stdout.buffer.write(pad + block + pad + block + pad)
" > "$TMP/repeated_tiny.bin"
REP_IN_SIZE=$(stat -c%s "$TMP/repeated_tiny.bin")

archive="$TMP/repeated.osr"
restored="$TMP/repeated.dec"
if ./bin/osrep -dup -m4 --chunk-avg=8 --chunk-min=1 --chunk-max=16 "$TMP/repeated_tiny.bin" "$archive" >/dev/null 2>&1 && \
   ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1 && \
   cmp -s "$TMP/repeated_tiny.bin" "$restored"; then
    arch_sz=$(stat -c%s "$archive")
    echo "OK    osrep -dup -m4 (no --dup-paranoid) tiny-chunk round-trip with real dedup hits   in=$REP_IN_SIZE archive=$arch_sz"
    passed=$((passed + 1))
else
    echo "FAIL  osrep -dup -m4 (no --dup-paranoid) tiny-chunk round-trip with real dedup hits"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------
# 3. Explicit --dup-paranoid control on the same tiny-chunk config --
#    must also round-trip (sanity: paranoid path unaffected by the
#    hash swap either, since it only adds a byte-compare on top).
# ---------------------------------------------------------------
archive="$TMP/paranoid.osr"
restored="$TMP/paranoid.dec"
if ./bin/osrep -dup -m4 --dup-paranoid --chunk-avg=8 --chunk-min=1 --chunk-max=16 "$IN" "$archive" >/dev/null 2>&1 && \
   ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1 && \
   cmp -s "$IN" "$restored"; then
    echo "OK    osrep -dup -m4 --dup-paranoid tiny-chunk round-trip"
    passed=$((passed + 1))
else
    echo "FAIL  osrep -dup -m4 --dup-paranoid tiny-chunk round-trip"
    failed=$((failed + 1))
fi

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
