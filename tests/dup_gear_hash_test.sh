#!/usr/bin/env bash
# F5.6 regression test: --chunk-hash=gear finds non-buffer-aligned
# duplicates that --chunk-hash=fnv (the default) misses.
#
# Background: the CDC boundary hash used by the dedup pre-pass
# (Compression/SREP/dedup.cpp) is selectable via --chunk-hash=fnv|gear
# (see dup_wrapper.cpp's --chunk-hash flag). FNV's rolling hash has no
# fixed window -- its cut-point sequence depends on distance-since-
# last-buffer-reset, not on local content alone -- so it only finds a
# duplicate if both copies happen to sit at the same offset modulo
# --chunk-buf (default 8 MiB). Gear-hash's h = (h<<1) + GEAR[byte] has
# an implicit ~64-byte content window (older bytes shift off the top
# of the 64-bit register), so it resyncs on repeated content
# regardless of absolute offset. Full research writeup: F5.6 in
# docs/research-notes.md (Python-prototype finding); this test
# replicates the finding for the real C++ port with real numbers.
#
# IMPORTANT measurement note: this test asserts the improvement at the
# dedup *body* level (bytes fed to SREP after the pre-pass), not at
# the final `osrep -dup` archive-size level. Measured empirically: at
# -m3/-m4/-m5, SREP's own long-range match finder independently
# recovers most of a same-sized duplicate on its own (its hash-based
# matching has nothing to do with the CDC pre-pass), so the final
# archive size for --chunk-hash=fnv and --chunk-hash=gear ends up
# nearly identical even when the dedup pre-pass itself completely
# misses the duplicate. Asserting on final archive size would make
# this test pass even if the gear port were silently broken (or
# removed) -- the dedup-body-level metric (measured here via
# `dedup_test split-encode --hash`) is what actually isolates the
# pre-pass's own behavior and is the only sound regression signal for
# this specific finding. Section 3 below still round-trips the real
# `osrep -dup --chunk-hash=` CLI flag end-to-end for correctness (not
# ratio), so the user-facing flag path stays covered too.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$(dirname "$0")/_winpath.sh"

[[ -x bin/osrep      ]] || make bin/osrep
[[ -x bin/dedup_test ]] || make bin/dedup_test

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

BUF=8388608  # osrep -dup native default --chunk-buf

# Deterministic misaligned-duplicate input: an 8 MiB pseudo-random
# block appears twice, at two offsets that are NOT congruent modulo
# --chunk-buf (777 vs. 3,142,369 mod 8 MiB) -- i.e. the duplicate is
# not buffer-grid-aligned, the exact scenario F5.6 identified as the
# FNV chunker's blind spot. Padding is itself pseudo-random (not
# zeros/constant bytes) so CDC has real content to cut on and neither
# hash degenerates to constant-mask behavior.
gen_misaligned_input() {
    local out="$1"
    python3 -c "
import struct

def prng_bytes(n, seed):
    out = bytearray()
    s = seed
    while len(out) < n:
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        out += struct.pack('<Q', s & 0xFFFFFFFFFFFFFFFF)
    return bytes(out[:n])

BUF = 8 * 1024 * 1024
dup_block = prng_bytes(BUF, 0xC0FFEE)
pad0 = prng_bytes(777, 0xA1)               # copy #1 starts at offset 777 (mod BUF = 777)
pad1 = prng_bytes(3_141_592, 0xB2)         # copy #2 starts at offset 777+BUF+3141592 (mod BUF = 3,142,369)
pad2 = prng_bytes(555_555, 0xD3)
import sys
sys.stdout.buffer.write(pad0 + dup_block + pad1 + dup_block + pad2)
" > "$out"
}

IN="$TMP/misaligned_dup.bin"
gen_misaligned_input "$IN"
IN_SIZE=$(stat -c%s "$IN")
DUP_LEN=8388608

# ---------------------------------------------------------------
# 1. Dedup-body-level measurement (the real F5.6 signal): fnv should
#    find ~nothing, gear should find nearly the whole 8 MiB duplicate.
# ---------------------------------------------------------------
meta_fnv="$TMP/meta.fnv"; body_fnv="$TMP/body.fnv"
meta_gear="$TMP/meta.gear"; body_gear="$TMP/body.gear"

./bin/dedup_test split-encode "$IN" "$meta_fnv"  "$body_fnv"  --buf "$BUF" --hash fnv  >/dev/null
./bin/dedup_test split-encode "$IN" "$meta_gear" "$body_gear" --buf "$BUF" --hash gear >/dev/null

body_sz_fnv=$(stat -c%s "$body_fnv")
body_sz_gear=$(stat -c%s "$body_gear")

# All floating-point math and formatting happens inside python3 (not
# bash's printf %f, which is locale-sensitive -- e.g. under a
# comma-decimal locale like es_PE.UTF-8, `printf '%.4f' 1.0` fails
# with "invalid number"). Results come back as plain "%s"-safe strings.
read -r fnv_ratio gear_ratio <<EOF
$(python3 -c "
in_sz=$IN_SIZE; f=$body_sz_fnv; g=$body_sz_gear
print(f/in_sz, g/in_sz)
")
EOF

echo "misaligned-dup input:  size=$IN_SIZE  dup_block=$DUP_LEN (not buf-aligned; offsets mod $BUF differ)"
python3 -c "
in_sz=$IN_SIZE; f=$body_sz_fnv; g=$body_sz_gear; dup=$DUP_LEN
print(f'  fnv  body={f}  ratio={f/in_sz:.4f}')
print(f'  gear body={g}  ratio={g/in_sz:.4f}  (recovered {100*(in_sz-g)/dup:.1f}% of the {dup}-byte duplicate)')
"

# fnv must find (essentially) nothing on this misaligned case: body
# size should equal the full input, i.e. ratio >= 0.99.
if python3 -c "exit(0 if $fnv_ratio >= 0.99 else 1)"; then
    echo "OK    fnv  finds ~nothing on misaligned dup (ratio=$fnv_ratio, expected >= 0.99)"
    passed=$((passed + 1))
else
    echo "FAIL  fnv  unexpectedly deduped the misaligned duplicate (ratio=$fnv_ratio) -- test fixture invalid or fnv behavior changed"
    failed=$((failed + 1))
fi

# gear must recover the large majority of the duplicate: ratio should
# be well below fnv's, with a comfortable margin below the real
# measured value (~0.606) to absorb minor chunk-boundary-placement
# noise without being a tautology.
if python3 -c "exit(0 if $gear_ratio <= 0.75 else 1)"; then
    echo "OK    gear finds the misaligned dup (ratio=$gear_ratio, expected <= 0.75)"
    passed=$((passed + 1))
else
    echo "FAIL  gear failed to find the misaligned duplicate (ratio=$gear_ratio, expected <= 0.75)"
    failed=$((failed + 1))
fi

# The headline comparison: gear must be dramatically better than fnv
# on this exact case (real measured gap is ~0.39; require >= 0.20).
if python3 -c "exit(0 if ($fnv_ratio - $gear_ratio) >= 0.20 else 1)"; then
    echo "OK    gear beats fnv by >= 0.20 dedup-body-ratio on misaligned dup (actual gap: $(python3 -c "print(f'{$fnv_ratio-$gear_ratio:.4f}')"))"
    passed=$((passed + 1))
else
    echo "FAIL  gear did not meaningfully beat fnv (fnv=$fnv_ratio gear=$gear_ratio)"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------
# 2. split-decode round-trip: the gear-produced meta/body pair must
#    decode back to the exact original via the ordinary decode_split
#    path -- confirms the format-compat claim (decode is unaware of
#    which hash chose the chunk boundaries) for a real gear-chunked
#    artifact, not just the default fnv path.
# ---------------------------------------------------------------
restored_gear="$TMP/restored.gear.bin"
./bin/dedup_test split-decode "$meta_gear" "$body_gear" "$restored_gear" >/dev/null
if cmp -s "$IN" "$restored_gear"; then
    echo "OK    gear split-encode/split-decode round-trips byte-identical"
    passed=$((passed + 1))
else
    echo "FAIL  gear split-encode/split-decode round-trip mismatch"
    failed=$((failed + 1))
fi

# Sanity: default (no --hash) split-encode must equal explicit --hash
# fnv, byte-for-byte -- confirms the flag's default didn't drift.
meta_def="$TMP/meta.default"; body_def="$TMP/body.default"
./bin/dedup_test split-encode "$IN" "$meta_def" "$body_def" --buf "$BUF" >/dev/null
if cmp -s "$body_def" "$body_fnv" && cmp -s "$meta_def" "$meta_fnv"; then
    echo "OK    default (no --hash) split-encode == --hash fnv, byte-for-byte"
    passed=$((passed + 1))
else
    echo "FAIL  default split-encode diverged from --hash fnv"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------
# 3. Real CLI end-to-end: `osrep -dup -mN --chunk-hash=gear` round-
#    trips correctly (compress -> decompress -> byte-identical). This
#    is a correctness check on the user-facing flag, not a ratio
#    check -- see the header comment for why archive size doesn't
#    discriminate fnv vs. gear once SREP's own long-range compression
#    is in the loop.
# ---------------------------------------------------------------
for m in -m3 -m4 -m5; do
    name="${m#-}"
    archive="$TMP/cli_${name}.osr"
    restored="$TMP/cli_${name}.dec"
    if ./bin/osrep -dup "$m" --chunk-hash=gear "$IN" "$archive" >/dev/null 2>&1 && \
       ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1 && \
       cmp -s "$IN" "$restored"; then
        arch_sz=$(stat -c%s "$archive")
        echo "OK    osrep -dup $m --chunk-hash=gear round-trip   archive=$arch_sz"
        passed=$((passed + 1))
    else
        echo "FAIL  osrep -dup $m --chunk-hash=gear round-trip"
        failed=$((failed + 1))
    fi
done

# ---------------------------------------------------------------
# 4. Edge cases under --chunk-hash=gear (mirrors tests/dup_native_roundtrip.sh's
#    edge-case coverage, but exercising the gear path specifically).
# ---------------------------------------------------------------
gear_edge_case() {
    local label="$1" input_path="$2"
    local archive="$TMP/edge_${label}.osr"
    local restored="$TMP/edge_${label}.dec"
    if ! ./bin/osrep -dup -m4 --chunk-hash=gear "$input_path" "$archive" >/dev/null 2>&1; then
        echo "FAIL  edge:$label  compress failed"; return 1
    fi
    if ! ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1; then
        echo "FAIL  edge:$label  decompress failed"; return 1
    fi
    if ! cmp -s "$input_path" "$restored"; then
        echo "FAIL  edge:$label  bytes differ"; return 1
    fi
    echo "OK    edge:$label  round-trip OK (archive=$(stat -c%s "$archive"))"
    return 0
}

printf 'X' > "$TMP/edge_1byte.bin"
if gear_edge_case "1byte" "$TMP/edge_1byte.bin"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi

: > "$TMP/edge_empty.bin"
plain_rc=0
./bin/osrep -m4 "$TMP/edge_empty.bin" "$TMP/edge_empty_plain.osr" >/dev/null 2>&1 || plain_rc=$?
gear_rc=0
./bin/osrep -dup -m4 --chunk-hash=gear "$TMP/edge_empty.bin" "$TMP/edge_empty_gear.osr" >/dev/null 2>&1 || gear_rc=$?
if [[ "$plain_rc" -eq "$gear_rc" ]]; then
    echo "OK    edge:empty-input (gear)   plain rc=$plain_rc, -dup --chunk-hash=gear rc=$gear_rc (consistent)"
    passed=$((passed + 1))
else
    echo "FAIL  edge:empty-input (gear)   plain rc=$plain_rc, gear rc=$gear_rc"
    failed=$((failed + 1))
fi

# ---------------------------------------------------------------
# 5. Invalid --chunk-hash value is rejected with ERR_CMDLINE (rc=2),
#    not silently accepted or misinterpreted as fnv.
# ---------------------------------------------------------------
bogus_rc=0
./bin/osrep -dup -m4 --chunk-hash=bogus "$IN" "$TMP/bogus.osr" >/dev/null 2>&1 || bogus_rc=$?
if [[ "$bogus_rc" -eq 2 ]]; then
    echo "OK    --chunk-hash=bogus correctly rejected (rc=2)"
    passed=$((passed + 1))
else
    echo "FAIL  --chunk-hash=bogus should be rejected with rc=2, got rc=$bogus_rc"
    failed=$((failed + 1))
fi

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
