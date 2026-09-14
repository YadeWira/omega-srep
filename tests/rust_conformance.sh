#!/usr/bin/env bash
# Differential conformance: the Rust port vs the C++ oracle.
#
# Fase 1/2 of the Rust migration (see docs/rust-port.md). Every ported
# module is checked against the SHIPPED C++ binary rather than against a
# second reading of the format spec: the same inputs go through both
# implementations and the produced bytes must match exactly.
#
# Currently covers osrep-core::dedup against tests/dedup_test.cpp
# (bin/dedup_test). As more modules are ported they get added here.
#
# Skips cleanly (exit 0 with a notice) if the Rust toolchain or the C++
# test binary cannot be built, so it can sit in a lane that also runs on
# machines without Rust.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- Toolchains ------------------------------------------------------ #

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping Rust conformance (install rustup; rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ oracle (bin/dedup_test)"
make bin/dedup_test >/dev/null 2>&1

say "building the Rust port (osrep-conformance)"
if ! cargo build --release -p osrep-conformance >/tmp/rust-conformance-build.log 2>&1; then
    cat /tmp/rust-conformance-build.log >&2
    fail "cargo build failed"
fi
RS_DIR=target/release
RS=$RS_DIR/dedup_conformance
[[ -x "$RS" ]] || fail "missing $RS"

say "rustc: $(rustc --version)"

# --- Inputs ---------------------------------------------------------- #

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
random.seed(20260913)

open(os.path.join(d, "empty.bin"), "wb").write(b"")
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")

unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
open(os.path.join(d, "repeat.bin"), "wb").write(unit * 40)          # one long duplicate
open(os.path.join(d, "random.bin"), "wb").write(bytes(random.randrange(256) for _ in range(200000)))
half = bytes(random.randrange(256) for _ in range(65536))
open(os.path.join(d, "doubled.bin"), "wb").write(half + half)      # long-range duplicate
mixed = b"".join(random.choice([unit, half, b"payload " * 200]) for _ in range(60))
open(os.path.join(d, "mixed.bin"), "wb").write(mixed)
PY

INPUTS="empty.bin tiny.bin repeat.bin random.bin doubled.bin mixed.bin"

# Parameter sets: defaults, both CDC hashes, tiny chunks, buffer-bounded.
PARAM_SETS=(
    ""
    "--hash gear"
    "--avg 64 --min 16 --max 256"
    "--avg 64 --min 16 --max 256 --hash gear"
    "--buf 8192"
    "--buf 4096 --avg 256 --min 64 --max 4096"
)

pass=0; fail_count=0
check() {  # check <label> <cmp-a> <cmp-b>
    if cmp -s "$2" "$3"; then pass=$((pass+1));
    else echo "  MISMATCH: $1" >&2; fail_count=$((fail_count+1)); fi
}

say "differential matrix over $INPUTS"
for inp in $INPUTS; do
    for params in "${PARAM_SETS[@]}"; do
        # shellcheck disable=SC2086
        set -- $params
        label="$inp [$params]"

        # 1. encode: blobs must be byte-identical.
        ./bin/dedup_test encode "$TMP/$inp" "$TMP/cpp.enc" $params >/dev/null 2>&1 || fail "cpp encode $label"
        "$RS"           encode "$TMP/$inp" "$TMP/rs.enc"  $params >/dev/null 2>&1 || fail "rust encode $label"
        check "encode $label" "$TMP/cpp.enc" "$TMP/rs.enc"

        # 2. cross-decode: each side must read the other's blob.
        ./bin/dedup_test decode "$TMP/rs.enc"  "$TMP/cpp.dec" >/dev/null 2>&1 || fail "cpp decode(rust) $label"
        "$RS"           decode "$TMP/cpp.enc" "$TMP/rs.dec"  >/dev/null 2>&1 || fail "rust decode(cpp) $label"
        check "decode(cpp of rust) $label" "$TMP/$inp" "$TMP/cpp.dec"
        check "decode(rust of cpp) $label" "$TMP/$inp" "$TMP/rs.dec"

        # 3. split-encode: meta and body both byte-identical.
        ./bin/dedup_test split-encode "$TMP/$inp" "$TMP/cpp.meta" "$TMP/cpp.body" $params >/dev/null 2>&1 || fail "cpp split $label"
        "$RS"           split-encode "$TMP/$inp" "$TMP/rs.meta"  "$TMP/rs.body"  $params >/dev/null 2>&1 || fail "rust split $label"
        check "split meta $label" "$TMP/cpp.meta" "$TMP/rs.meta"
        check "split body $label" "$TMP/cpp.body" "$TMP/rs.body"

        # 4. encode-streaming (the path osrep -dup uses): meta + body
        #    identical, with and without the paranoid byte-compare.
        for extra in "" "--paranoid"; do
            # shellcheck disable=SC2086
            ./bin/dedup_test encode-streaming "$TMP/$inp" "$TMP/cpp.smeta" "$TMP/cpp.sbody" $params $extra >/dev/null 2>&1 \
                || fail "cpp streaming $label $extra"
            "$RS"           encode-streaming "$TMP/$inp" "$TMP/rs.smeta"  "$TMP/rs.sbody"  $params $extra >/dev/null 2>&1 \
                || fail "rust streaming $label $extra"
            check "streaming meta $label $extra" "$TMP/cpp.smeta" "$TMP/rs.smeta"
            check "streaming body $label $extra" "$TMP/cpp.sbody" "$TMP/rs.sbody"
        done
    done
done

# --- selftest text --------------------------------------------------- #

say "selftest output"
./bin/dedup_test selftest > "$TMP/cpp.selftest" 2>&1 || fail "cpp selftest"
"$RS"           selftest > "$TMP/rs.selftest"  2>&1 || fail "rust selftest"
check "selftest stdout" "$TMP/cpp.selftest" "$TMP/rs.selftest"

# --- corrupt meta (the forward-ref case) ----------------------------- #

say "corrupt meta: both must reject with the same code"
python3 - "$TMP/bad.meta" <<'PY'
import struct, sys
hdr = struct.pack('<II', 0x52505544, 1) + struct.pack('<QQ', 1, 1)
open(sys.argv[1], 'wb').write(hdr + bytes([1, 0]))   # tag=REF, index 0
PY
printf 'body' > "$TMP/bad.body"
set +e
./bin/dedup_test decode-streaming "$TMP/bad.meta" "$TMP/bad.body" "$TMP/cpp.bad.out" >/dev/null 2>"$TMP/cpp.bad.err"
cpp_rc=$?
"$RS"           decode-streaming "$TMP/bad.meta" "$TMP/bad.body" "$TMP/rs.bad.out"  >/dev/null 2>"$TMP/rs.bad.err"
rs_rc=$?
set -e
[ "$cpp_rc" -ne 0 ] || fail "cpp accepted a ref-before-unique meta"
[ "$rs_rc"  -ne 0 ] || fail "rust accepted a ref-before-unique meta"
[ "$cpp_rc" -lt 128 ] || fail "cpp crashed ($cpp_rc)"
[ "$rs_rc"  -lt 128 ] || fail "rust crashed ($rs_rc)"
grep -q 'rc=5' "$TMP/cpp.bad.err" || fail "cpp did not report DEDUP_ERR_BAD_REF: $(cat "$TMP/cpp.bad.err")"
grep -q 'rc=5' "$TMP/rs.bad.err"  || fail "rust did not report DEDUP_ERR_BAD_REF: $(cat "$TMP/rs.bad.err")"
pass=$((pass+1))

# --- digests (hashes.cpp) -------------------------------------------- #

say "building the C++ digest oracle (bin/hash_test)"
make bin/hash_test >/dev/null 2>&1

# Padding boundaries for MD5/SHA-1 (64-byte blocks) and SHA-512
# (128-byte blocks): the lengths where the "1" bit and the length field
# straddle a block edge. This is where hand-written digest ports break.
python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
for n in (0, 1, 55, 56, 63, 64, 65, 111, 112, 119, 120, 127, 128, 129, 255, 256, 1000, 4096, 100000):
    open(os.path.join(d, f"pad-{n}.bin"), "wb").write(
        bytes((i * 7 + 3) & 0xFF for i in range(n)))
PY

hash_pass=0; hash_skip=0
for algo in md5 sha1 sha512 vmac siphash; do
    case "$algo" in
        md5|sha1|sha512) seed=none ;;
        vmac)    seed="$(printf 'ab%.0s' $(seq 1 32))" ;;
        siphash) seed="$(printf 'cd%.0s' $(seq 1 16))" ;;
    esac
    for n in 0 1 55 56 63 64 65 111 112 119 120 127 128 129 255 256 1000 4096 100000; do
        ./bin/hash_test "$algo" "$seed" "$TMP/pad-$n.bin" > "$TMP/cpp.hash" 2>&1 \
            || fail "cpp hash_test $algo $n"
        set +e
        "$RS_DIR/hash_conformance" "$algo" "$seed" "$TMP/pad-$n.bin" > "$TMP/rs.hash" 2>&1
        rc=$?
        set -e
        if [ "$rc" -eq 3 ]; then hash_skip=$((hash_skip+1)); continue; fi
        [ "$rc" -eq 0 ] || fail "rust hash_conformance $algo $n (rc=$rc)"
        check "hash $algo len=$n" "$TMP/cpp.hash" "$TMP/rs.hash"
        hash_pass=$((hash_pass+1))
    done
done
say "digests: $hash_pass matched, $hash_skip skipped (not ported yet)"

# --- VMAC-128 (the default hash) ------------------------------------- #

say "vmac-128 vs the vendored vmac.c"
python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
# Lengths around the 4096-byte NH block and the 16-byte sub-chunk boundary:
# where the first-block absorb switches to poly_step, and where the padded
# tail kicks in.
for n in (0, 1, 15, 16, 17, 31, 32, 63, 64, 4095, 4096, 4097, 8191, 8192,
          8193, 12288, 12345, 40000):
    open(os.path.join(d, f"vmac-{n}.bin"), "wb").write(
        bytes((i * 7 + 3) & 0xFF for i in range(n)))
PY

VMAC_KEYS=(
    "0000000000000000000000000000000000000000000000000000000000000000"
    "abababababababababababababababababababababababababababababababab"
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
)
VMAC_LENS="0 1 15 16 17 31 32 63 64 4095 4096 4097 8191 8192 8193 12288 12345 40000"
vmac_pass=0
for key in "${VMAC_KEYS[@]}"; do
    for n in $VMAC_LENS; do
        ./bin/hash_test vmac "$key" "$TMP/vmac-$n.bin" > "$TMP/cpp.vmac" 2>&1 \
            || fail "cpp hash_test vmac len=$n"
        "$RS_DIR/hash_conformance" vmac "$key" "$TMP/vmac-$n.bin" > "$TMP/rs.vmac" 2>&1 \
            || fail "rust hash_conformance vmac len=$n"
        check "vmac len=$n key=${key:0:8}" "$TMP/cpp.vmac" "$TMP/rs.vmac"
        vmac_pass=$((vmac_pass+1))
    done
done
say "vmac: $vmac_pass matched"

# --- AES-256 ECB (the primitive vmac is built on) -------------------- #

say "aes-256 ecb vs the vendored aes.c"
python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
for n in (0, 16, 32, 48, 64, 256, 4096, 65536):
    open(os.path.join(d, f"aes-{n}.bin"), "wb").write(
        bytes((i * 13 + 5) & 0xFF for i in range(n)))
PY

# Three 32-byte keys: all-zero, the FIPS-197 example, and a repeated byte.
KEYS=(
    "0000000000000000000000000000000000000000000000000000000000000000"
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    "abababababababababababababababababababababababababababababababab"
)
AES_LENS="0 16 32 48 64 256 4096 65536"
aes_pass=0
for key in "${KEYS[@]}"; do
    for n in $AES_LENS; do
        ./bin/hash_test aes "$key" "$TMP/aes-$n.bin" > "$TMP/cpp.aes" 2>&1 \
            || fail "cpp hash_test aes len=$n"
        "$RS_DIR/hash_conformance" aes "$key" "$TMP/aes-$n.bin" > "$TMP/rs.aes" 2>&1 \
            || fail "rust hash_conformance aes len=$n"
        check "aes len=$n key=${key:0:8}" "$TMP/cpp.aes" "$TMP/rs.aes"
        aes_pass=$((aes_pass+1))
    done
done
say "aes: $aes_pass matched"

# --- Summary --------------------------------------------------------- #

echo "rust_conformance: passed=$pass mismatches=$fail_count"
[ "$fail_count" -eq 0 ]
