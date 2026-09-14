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
[[ -x bin/dedup_test ]] || make bin/dedup_test >/dev/null

say "building the Rust port (osrep-conformance)"
if ! cargo build --release -p osrep-conformance >/tmp/rust-conformance-build.log 2>&1; then
    cat /tmp/rust-conformance-build.log >&2
    fail "cargo build failed"
fi
RS=target/release/dedup_conformance
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

# --- Summary --------------------------------------------------------- #

echo "rust_conformance: passed=$pass mismatches=$fail_count"
[ "$fail_count" -eq 0 ]
