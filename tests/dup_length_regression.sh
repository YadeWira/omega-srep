#!/usr/bin/env bash
# Regression for the -dup dedup key that ignored the chunk length.
#
# The streaming encoder keys each chunk on two 64-bit hashes that read the
# chunk 8 bytes at a time and fold the 0-7 byte tail in as a zero-padded
# word, without the length. A chunk X and X followed by 1-7 zero bytes (same
# number of whole words) therefore got the same key, and without
# --dup-paranoid the first hit became a reference: the archive was written
# with exit 0, `-d` and `--verify` exited 0 too, and the output had the wrong
# size. The smallest case with default options is 2049 zero bytes: FNV cuts
# the zero run into 1025-byte chunks and the final 1024-byte chunk took the
# key of the first one. 2.2.0, 2.1.x and the C++ 1.0.7 all have the bug, so
# this script fails against bin/osrep: run it with OSREP_BIN pointing at a
# port (tests/rust_cli_conformance.sh does).
#
# A hit of a different length is now a new unique chunk, with or without
# --dup-paranoid, which is what --dup-paranoid always did: on these inputs the
# two archives must be byte-identical.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$(dirname "$0")/_osrep_bin.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
rng = random.Random(7)
for n in (2049, 3074, 4099, 262144):
    open(os.path.join(d, f"z{n}"), "wb").write(bytes(n))
open(os.path.join(d, "z3"), "wb").write(bytes(3))
# 1000 random bytes, then a zero run whose last chunk is a whole-word prefix
# of an earlier one.
open(os.path.join(d, "pad18434"), "wb").write(rng.randbytes(1000) + bytes(17434))
# Random bytes then 1025 zeros, cut into fixed 13-byte chunks: the last
# chunk is a short run of zeros.
open(os.path.join(d, "pad1025"), "wb").write(rng.randbytes(1000) + bytes(1025))
# Periodic text with a zero tail, under small non-power-of-two chunks.
t = b"".join(b"line %06d of some periodic text\n" % (i % 500) for i in range(6000))
open(os.path.join(d, "pertext"), "wb").write(t + bytes(2051))
PY

pass=0
failed=0
# Every case is reported, so a run against an unfixed build lists them all.
check() {
    local input="$1"; shift
    local base; base="$(basename "$input")"
    for par in "" "--dup-paranoid"; do
        local tag="plain"; [ -z "$par" ] || tag="paranoid"
        "$OSREP" --seed=7 "$@" $par "$input" "$TMP/a.osr" >/dev/null 2>"$TMP/a.err" \
            || { echo "FAIL: $base $* $par: compress exited non-zero: $(tail -1 "$TMP/a.err")" >&2; failed=$((failed + 1)); return; }
        rm -f "$TMP/a.dec"
        "$OSREP" -d "$TMP/a.osr" "$TMP/a.dec" >/dev/null 2>&1 \
            || { echo "FAIL: $base $* $par: -d failed" >&2; failed=$((failed + 1)); return; }
        if ! cmp -s "$input" "$TMP/a.dec"; then
            echo "FAIL: $base $* $par: round trip differs ($(stat -c%s "$input") bytes in, $(stat -c%s "$TMP/a.dec") out)" >&2
            failed=$((failed + 1)); return
        fi
        mv "$TMP/a.osr" "$TMP/$tag.osr"
    done
    cmp -s "$TMP/plain.osr" "$TMP/paranoid.osr" \
        || { echo "FAIL: $base $*: -dup and -dup --dup-paranoid wrote different archives" >&2; failed=$((failed + 1)); return; }
    pass=$((pass + 1))
}

check "$TMP/z2049" -dup
check "$TMP/z3074" -dup
check "$TMP/z4099" -dup
check "$TMP/z262144" -dup -m4 --chunk-min=64 --chunk-avg=256
check "$TMP/z3" -dup -m3 --chunk-min=1
check "$TMP/pad18434" -dup -m3
check "$TMP/pad1025" -dup -m5 --chunk-min=13 --chunk-max=13 --chunk-avg=13
check "$TMP/pertext" -dup -m4 --chunk-avg=100 --chunk-min=9
check "$TMP/z2049" -dup $OSREP_V4

[ "$failed" -eq 0 ] || { echo "  dup_length_regression: passed=$pass FAILED=$failed" >&2; exit 1; }
echo "  dup_length_regression: passed=$pass"
