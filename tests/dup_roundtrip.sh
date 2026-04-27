#!/usr/bin/env bash
# F5.3 -dup pipeline round-trip.
#
# Exercises the dedup pre-pass + SREP encoder + ODUP trailer assembly
# end-to-end without modifying srep.cpp's mainline. F5.3b will fold
# this pipeline behind a `-dup` flag on osrep itself; F5.4 will
# benchmark it on a multi-GB corpus.
#
# Pipeline (compress):
#   input -> dedup split-encode -> meta blob + body bytes
#   body  -> osrep -mN          -> body.osr
#   archive = body.osr + meta + uint64_le(meta_size) + "ODUP"
#
# Pipeline (decompress):
#   archive: last 4 bytes must be "ODUP", uint64 before that = meta_size
#   slice off trailer (12 + meta_size bytes) -> body.osr + meta
#   body.osr -> osrep -d -> body
#   meta + body -> dedup split-decode -> output
#
# Exit code 0 iff every method round-trips.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# -m0 (REP-only) is incompatible with -dup per the design and is
# excluded; -m1/-m2 work but emit a CDC-on-CDC warning in the real
# integration (F5.3b); -m3/-m4/-m5 are the recommended pairings.
METHODS=(${OSREP_DUP_METHODS:-"-m1 -m2 -m3 -m4 -m5"})

[[ -x bin/osrep      ]] || make bin/osrep
[[ -x bin/dedup_test ]] || make bin/dedup_test

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Deterministic synthetic with structural redundancy so the dedup
# pre-pass actually has something to remove.
gen_input() {
    local out="$1"
    python3 -c "
import sys
unit = b'Omega SREP -dup pipeline payload, repeating block. ' * 200
body = (b'A' * 4096 + b'B' * 4096) * 32
sys.stdout.buffer.write(unit + body + body + unit + body)
" > "$out"
}

pack_archive() {
    local body_osr="$1" meta="$2" out="$3"
    local meta_size
    meta_size=$(stat -c%s "$meta")
    cat "$body_osr" "$meta" > "$out"
    python3 -c "
import sys, struct
sys.stdout.buffer.write(struct.pack('<Q', $meta_size))
sys.stdout.buffer.write(b'ODUP')
" >> "$out"
}

unpack_archive() {
    local archive="$1" body_osr_out="$2" meta_out="$3"
    local total trailer_magic meta_size body_size
    total=$(stat -c%s "$archive")
    if (( total < 12 )); then echo "archive too small" >&2; return 1; fi
    trailer_magic=$(tail -c 4 "$archive")
    if [[ "$trailer_magic" != "ODUP" ]]; then
        echo "missing ODUP trailer" >&2; return 1
    fi
    meta_size=$(python3 -c "
import struct
data = open('$archive','rb').read()
print(struct.unpack('<Q', data[-12:-4])[0])
")
    body_size=$(( total - 12 - meta_size ))
    if (( body_size <= 0 )); then echo "invalid trailer sizes" >&2; return 1; fi
    dd if="$archive" of="$body_osr_out" bs=1 count="$body_size" status=none
    dd if="$archive" of="$meta_out"     bs=1 skip="$body_size" count="$meta_size" status=none
}

passed=0
failed=0

for method in $METHODS; do
    name="${method#-}"
    in="$TMP/in.bin"
    body="$TMP/body.bin"
    meta="$TMP/meta.bin"
    body_osr="$TMP/body.osr"
    archive="$TMP/out_${name}.osrd"
    body_dec="$TMP/body_dec.bin"
    meta_dec="$TMP/meta_dec.bin"
    body_osr_dec="$TMP/body_osr_dec.osr"
    out="$TMP/out_${name}.bin"

    rm -f "$in" "$body" "$meta" "$body_osr" "$archive" \
          "$body_dec" "$meta_dec" "$body_osr_dec" "$out"

    gen_input "$in"
    in_size=$(stat -c%s "$in")

    ./bin/dedup_test split-encode "$in" "$meta" "$body" >/dev/null
    ./bin/osrep "$method" "$body" "$body_osr" >/dev/null

    pack_archive "$body_osr" "$meta" "$archive"
    arch_size=$(stat -c%s "$archive")

    unpack_archive "$archive" "$body_osr_dec" "$meta_dec"
    ./bin/osrep -d "$body_osr_dec" "$body_dec" >/dev/null
    ./bin/dedup_test split-decode "$meta_dec" "$body_dec" "$out" >/dev/null

    if cmp -s "$in" "$out"; then
        ratio=$(python3 -c "print(f'{$arch_size/$in_size:.3f}')")
        printf "OK    %s  in=%d  archive=%d  ratio=%s\n" \
            "$method" "$in_size" "$arch_size" "$ratio"
        passed=$((passed + 1))
    else
        echo "FAIL  $method  round-trip mismatch"
        failed=$((failed + 1))
    fi
done

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
