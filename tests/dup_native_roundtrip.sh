#!/usr/bin/env bash
# F5.3b: native -dup flag round-trip test.
#
# Verifies osrep itself (no external shell wrapper) round-trips
# correctly through the dedup pre-pass + ODUP trailer pipeline.
# Exercises:
#   - osrep -dup -mN in out.osr        (compress with native flag)
#   - osrep -d out.osr restored        (decompress, auto-detects ODUP)
#   - bytes(in) == bytes(restored)
# Also verifies:
#   - osrep -dup -m0 ... rejects (m0 incompatible with -dup)
#   - archives produced by F5.3a wrapper round-trip via the native
#     flag and vice-versa (interoperability)
#
# Methods covered: -m1, -m2, -m3, -m4, -m5. -m0 is the negative case.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Path-portability shim: on Git-Bash/MSYS, translate POSIX paths to
# Windows mixed-form so inline Python can open them.
source "$(dirname "$0")/_winpath.sh"

[[ -x bin/osrep      ]] || make bin/osrep
[[ -x bin/dedup_test ]] || make bin/dedup_test

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Deterministic synthetic with structural redundancy (long-range
# duplicates) so the dedup pre-pass actually has work to do.
gen_input() {
    local out="$1"
    python3 -c "
import sys
unit = b'Omega SREP -dup native pipeline payload, repeating block. ' * 200
body = (b'A' * 4096 + b'B' * 4096) * 32
sys.stdout.buffer.write(unit + body + body + unit + body)
" > "$out"
}

passed=0
failed=0

# 1. Round-trip across recommended methods.
for method in -m1 -m2 -m3 -m4 -m5; do
    name="${method#-}"
    in="$TMP/in_${name}.bin"
    archive="$TMP/out_${name}.osr"
    restored="$TMP/restored_${name}.bin"

    gen_input "$in"
    in_size=$(stat -c%s "$in")

    if ! ./bin/osrep -dup "$method" "$in" "$archive" >/dev/null 2>&1; then
        echo "FAIL  $method  compress (native -dup) failed"
        failed=$((failed + 1)); continue
    fi
    if ! ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1; then
        echo "FAIL  $method  decompress (auto-detect ODUP) failed"
        failed=$((failed + 1)); continue
    fi
    if cmp -s "$in" "$restored"; then
        arch_size=$(stat -c%s "$archive")
        ratio=$(python3 -c "print(f'{$arch_size/$in_size:.3f}')")
        printf "OK    %s  in=%d  archive=%d  ratio=%s\n" \
            "$method" "$in_size" "$arch_size" "$ratio"
        passed=$((passed + 1))
    else
        echo "FAIL  $method  bytes differ"
        failed=$((failed + 1))
    fi
done

# 2. -dup -m0 should be rejected.
gen_input "$TMP/m0_in.bin"
if ./bin/osrep -dup -m0 "$TMP/m0_in.bin" "$TMP/m0.osr" >/dev/null 2>&1; then
    echo "FAIL  -dup -m0 should be rejected"
    failed=$((failed + 1))
else
    echo "OK    -dup -m0 correctly rejected"
    passed=$((passed + 1))
fi

# 3. Interoperability: F5.3a shell wrapper produces an archive that
#    osrep -d (with native ODUP detection) can decompress.
xa_in="$TMP/xa_in.bin"
gen_input "$xa_in"
./bin/dedup_test split-encode "$xa_in" "$TMP/xa.meta" "$TMP/xa.body" --buf 8388608 >/dev/null
./bin/osrep -m4 "$TMP/xa.body" "$TMP/xa.body.osr" >/dev/null 2>&1
cat "$TMP/xa.body.osr" "$TMP/xa.meta" > "$TMP/xa.archive"
meta_size=$(stat -c%s "$TMP/xa.meta")
python3 -c "
import sys, struct
ms = int(sys.argv[1])
sys.stdout.buffer.write(struct.pack('<Q', ms))
sys.stdout.buffer.write(b'ODUP')
" "$meta_size" >> "$TMP/xa.archive"

if ./bin/osrep -d "$TMP/xa.archive" "$TMP/xa.restored" >/dev/null 2>&1 && \
   cmp -s "$xa_in" "$TMP/xa.restored"; then
    echo "OK    F5.3a-wrapped archive decompresses via native osrep -d"
    passed=$((passed + 1))
else
    echo "FAIL  F5.3a/native interop"
    failed=$((failed + 1))
fi

# 4. Inverse: native -dup compress -> dedup_test post-process can read it
#    (the F5.3a tooling consumes ODUP archives produced by either path).
xb_in="$TMP/xb_in.bin"
gen_input "$xb_in"
./bin/osrep -dup -m4 "$xb_in" "$TMP/xb.archive" >/dev/null 2>&1

total=$(stat -c%s "$TMP/xb.archive")
trailer_magic=$(tail -c 4 "$TMP/xb.archive")
xb_meta_size=$(python3 -c "
import sys, struct
data = open(sys.argv[1],'rb').read()
print(struct.unpack('<Q', data[-12:-4])[0])
" "$(winpath "$TMP/xb.archive")")
xb_body_size=$(( total - 12 - xb_meta_size ))
dd if="$TMP/xb.archive" of="$TMP/xb.body.osr" bs=1 count="$xb_body_size" status=none
dd if="$TMP/xb.archive" of="$TMP/xb.meta"     bs=1 skip="$xb_body_size" count="$xb_meta_size" status=none
./bin/osrep -d "$TMP/xb.body.osr" "$TMP/xb.body.dec" >/dev/null 2>&1
./bin/dedup_test split-decode "$TMP/xb.meta" "$TMP/xb.body.dec" "$TMP/xb.restored" >/dev/null
if [[ "$trailer_magic" == "ODUP" ]] && cmp -s "$xb_in" "$TMP/xb.restored"; then
    echo "OK    native archive consumable by F5.3a tooling (ODUP trailer)"
    passed=$((passed + 1))
else
    echo "FAIL  native/F5.3a interop"
    failed=$((failed + 1))
fi

# 4a-bis. --seed=N reproducibility. Same seed + same input must produce
# byte-identical archive bytes; no seed must produce differing bytes;
# different seeds must differ. Verifies F6.3.
xs_in="$TMP/seed_in.bin"
gen_input "$xs_in"
./bin/osrep --seed=12345 -m4 "$xs_in" "$TMP/seed_a.osr" >/dev/null 2>&1
./bin/osrep --seed=12345 -m4 "$xs_in" "$TMP/seed_b.osr" >/dev/null 2>&1
./bin/osrep --seed=99999 -m4 "$xs_in" "$TMP/seed_c.osr" >/dev/null 2>&1
./bin/osrep             -m4 "$xs_in" "$TMP/seed_d.osr" >/dev/null 2>&1
./bin/osrep             -m4 "$xs_in" "$TMP/seed_e.osr" >/dev/null 2>&1
seed_ok=1
cmp -s "$TMP/seed_a.osr" "$TMP/seed_b.osr" || seed_ok=0   # same seed must match
! cmp -s "$TMP/seed_a.osr" "$TMP/seed_c.osr" || seed_ok=0 # different seeds must differ
! cmp -s "$TMP/seed_d.osr" "$TMP/seed_e.osr" || seed_ok=0 # no seed must differ
./bin/osrep -d "$TMP/seed_a.osr" "$TMP/seed_dec.bin" >/dev/null 2>&1
cmp -s "$xs_in" "$TMP/seed_dec.bin" || seed_ok=0          # round-trip
if (( seed_ok )); then
    echo "OK    --seed=N: same seed -> byte-identical, no seed -> differs"
    passed=$((passed + 1))
else
    echo "FAIL  --seed=N reproducibility violated"
    failed=$((failed + 1))
fi

# 4b. --dup-paranoid round-trip (byte-compare on every hash hit).
xp_in="$TMP/xp_in.bin"
gen_input "$xp_in"
xp_archive="$TMP/xp.osr"
xp_restored="$TMP/xp.bin"
if ./bin/osrep -dup --dup-paranoid -m4 "$xp_in" "$xp_archive" >/dev/null 2>&1 && \
   ./bin/osrep -d "$xp_archive" "$xp_restored" >/dev/null 2>&1 && \
   cmp -s "$xp_in" "$xp_restored"; then
    arch=$(stat -c%s "$xp_archive")
    echo "OK    --dup-paranoid round-trip          archive=$arch"
    passed=$((passed + 1))
else
    echo "FAIL  --dup-paranoid round-trip"
    failed=$((failed + 1))
fi

# 4c. Paranoid and default should produce equivalent decoded output.
# Archive bytes differ run-to-run because SREP uses a per-run hash
# seed (non-deterministic body.osr); the chunk-table portion of the
# trailer is deterministic, but the SREP-compressed body is not. We
# compare round-trip output instead of raw archive bytes.
xq_in="$TMP/xq_in.bin"
gen_input "$xq_in"
xq_normal="$TMP/xq_normal.osr"
xq_paranoid="$TMP/xq_paranoid.osr"
xq_normal_dec="$TMP/xq_normal.bin"
xq_paranoid_dec="$TMP/xq_paranoid.bin"
./bin/osrep -dup -m4                "$xq_in" "$xq_normal"   >/dev/null 2>&1
./bin/osrep -dup --dup-paranoid -m4 "$xq_in" "$xq_paranoid" >/dev/null 2>&1
./bin/osrep -d "$xq_normal"   "$xq_normal_dec"   >/dev/null 2>&1
./bin/osrep -d "$xq_paranoid" "$xq_paranoid_dec" >/dev/null 2>&1
# Both must decode to the original input.
if cmp -s "$xq_in" "$xq_normal_dec" && cmp -s "$xq_in" "$xq_paranoid_dec"; then
    nrm_sz=$(stat -c%s "$xq_normal")
    par_sz=$(stat -c%s "$xq_paranoid")
    echo "OK    paranoid and default both round-trip (archives ${nrm_sz} vs ${par_sz} B)"
    passed=$((passed + 1))
else
    echo "FAIL  paranoid/default round-trip mismatch"
    failed=$((failed + 1))
fi

# 5. Edge cases — adversarial input shapes that have a way of finding
# off-by-ones in CDC / chunk-table / trailer code.
edge_case() {
    local label="$1"
    local input_path="$2"
    local archive="$TMP/edge_${label}.osr"
    local restored="$TMP/edge_${label}.bin"
    if ! ./bin/osrep -dup -m4 "$input_path" "$archive" >/dev/null 2>&1; then
        echo "FAIL  edge:$label  compress failed"
        return 1
    fi
    if ! ./bin/osrep -d "$archive" "$restored" >/dev/null 2>&1; then
        echo "FAIL  edge:$label  decompress failed"
        return 1
    fi
    if ! cmp -s "$input_path" "$restored"; then
        echo "FAIL  edge:$label  bytes differ"
        return 1
    fi
    in_sz=$(stat -c%s "$input_path")
    arch_sz=$(stat -c%s "$archive")
    printf "OK    edge:%-22s  in=%d  archive=%d\n" "$label" "$in_sz" "$arch_sz"
    return 0
}

# 5a. 1-byte input (smaller than min_chunk).
printf 'X' > "$TMP/edge_1byte.bin"
if edge_case "1byte" "$TMP/edge_1byte.bin"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi

# 5b. Input smaller than min_chunk (512 bytes < default min 1024).
python3 -c "import sys; sys.stdout.buffer.write(b'A' * 512)" > "$TMP/edge_small.bin"
if edge_case "smaller-than-min-chunk" "$TMP/edge_small.bin"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi

# 5c. Single chunk-buf-sized block, no internal redundancy.
python3 -c "
import sys, struct
s = 0xC0FFEE12345678
for _ in range(8 * 1024 * 1024 // 8):
    s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
    s ^= s >> 7
    s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
    sys.stdout.buffer.write(struct.pack('<Q', s))
" > "$TMP/edge_norep.bin"
if edge_case "no-redundancy-8mb" "$TMP/edge_norep.bin"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi

# 5d. Exactly two buffers worth of identical content (16 MiB / 8 MiB buf).
python3 -c "
import sys
block = (b'edge-bench-block-' * 524288)[:8 * 1024 * 1024]
sys.stdout.buffer.write(block)
sys.stdout.buffer.write(block)
" > "$TMP/edge_2bufs.bin"
if edge_case "two-identical-buffers" "$TMP/edge_2bufs.bin"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi

# 5e. Input that crosses a buffer boundary mid-chunk (8 MiB + 1 byte).
python3 -c "
import sys
sys.stdout.buffer.write((b'omega-' * 1500000)[:8 * 1024 * 1024 + 1])
" > "$TMP/edge_crossbuf.bin"
if edge_case "crosses-buffer-boundary" "$TMP/edge_crossbuf.bin"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi

# 5f. Empty file. srep_main itself rejects empty input (upstream
# behavior, not -dup-specific), so the expectation is that
# osrep -dup fails the same way osrep -m4 would. Assert
# consistency, not unconditional success.
: > "$TMP/edge_empty.bin"
plain_rc=0
./bin/osrep -m4 "$TMP/edge_empty.bin" "$TMP/edge_empty_plain.osr" >/dev/null 2>&1 || plain_rc=$?
dup_rc=0
./bin/osrep -dup -m4 "$TMP/edge_empty.bin" "$TMP/edge_empty_dup.osr" >/dev/null 2>&1 || dup_rc=$?
if [[ "$plain_rc" -eq "$dup_rc" ]]; then
    echo "OK    edge:empty-input          plain rc=$plain_rc, -dup rc=$dup_rc (consistent)"
    passed=$((passed + 1))
else
    echo "FAIL  edge:empty-input          plain rc=$plain_rc, -dup rc=$dup_rc"
    failed=$((failed + 1))
fi

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
