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
sys.stdout.buffer.write(struct.pack('<Q', $meta_size))
sys.stdout.buffer.write(b'ODUP')
" >> "$TMP/xa.archive"

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
data = open('$TMP/xb.archive','rb').read()
print(struct.unpack('<Q', data[-12:-4])[0])
")
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

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
