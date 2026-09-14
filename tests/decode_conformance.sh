#!/usr/bin/env bash
# End-to-end conformance for the Rust I/O-LZ decoder (format v1/v2).
#
# Fase 4a of the Rust migration (docs/rust-port.md). The Rust decoder reads
# archives written by the real C++ encoder and its output must equal the
# original input byte for byte -- the strongest oracle available, since it
# exercises the container framing, the record decoding, the literal/match
# interleaving and both match sources (read back from the sink, and copied
# within the current block) in one shot.
#
# On top of the round-trip this checks that verification is actually doing
# something, rather than passing because nothing is ever compared:
#
#   * flipping a byte in the last block's literals must make a checksummed
#     archive fail with a digest mismatch;
#   * the same corruption in a `-hash-` archive must decode "successfully" and
#     produce output that DIFFERS from the input -- which is what proves the
#     mismatch above came from the digest and not from a decode that ignored
#     corruption;
#   * a truncated archive must be an error, never a panic.
#
# Skips cleanly (exit 0 with a notice) if the Rust toolchain is missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping decoder conformance (rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ encoder (bin/osrep)"
make bin/osrep >/dev/null 2>&1 || fail "make bin/osrep"

say "building the Rust decoder (decode_conformance)"
if ! cargo build --release -p osrep-conformance >/tmp/decode-conformance-build.log 2>&1; then
    cat /tmp/decode-conformance-build.log >&2
    fail "cargo build failed"
fi
RS=target/release/decode_conformance
[[ -x "$RS" ]] || fail "missing $RS"
OSREP=bin/osrep

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "rustc: $(rustc --version)"

# --- Inputs ---------------------------------------------------------- #

python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
random.seed(20260913)
unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
half = bytes(random.randrange(256) for _ in range(40000))

open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
open(os.path.join(d, "repeat.bin"), "wb").write(unit * 75)          # long runs, overlapping matches
open(os.path.join(d, "random.bin"), "wb").write(
    bytes(random.randrange(256) for _ in range(200000)))            # incompressible: literals only
open(os.path.join(d, "mixed.bin"), "wb").write(unit * 8 + half + unit * 8 + half)
open(os.path.join(d, "dup.bin"), "wb").write(unit * 4 + unit * 4)   # exact repeat: forces cross-block back-references
PY

INPUTS="tiny.bin repeat.bin random.bin mixed.bin dup.bin"
# -b64k keeps every multi-block archive small enough to exercise the
# cross-block read-back path (a match whose source is an earlier block).
BFLAGS="-b64k"

# label|flags
CASES=(
    "v1|-m3o"
    "v2-m1|-m1o"
    "v2-m2|-m2o"
    "v1-siphash|-m3o -hash=siphash"
    "v2-sha512|-m1o -hash=sha512"
    "v1-md5|-m3o -hash=md5"
    "v1-hashoff|-m3o -hash-"
)

total=0
for case in "${CASES[@]}"; do
    IFS='|' read -r label flags <<<"$case"
    for input in $INPUTS; do
        src="$TMP/$input"
        arc="$TMP/$label.$input.osr"
        out="$TMP/$label.$input.out"
        # shellcheck disable=SC2086
        $OSREP $flags $BFLAGS "$src" "$arc" >/dev/null 2>&1 \
            || fail "[$label/$input] encoder rejected the flags"

        if ! res=$("$RS" io-lz "$arc" "$out" 2>&1); then
            fail "[$label/$input] decode: $res"
        fi
        total=$((total + 1))

        [[ "$(stat -c%s "$out")" == "$(stat -c%s "$src")" ]] \
            || fail "[$label/$input] size $(stat -c%s "$out") != $(stat -c%s "$src")"
        cmp -s "$src" "$out" || fail "[$label/$input] decoded bytes differ from the input"

        # The reported stats must describe the archive we just decoded.
        blocks=$(printf '%s' "$res" | sed -n 's/.*blocks=\([0-9]*\).*/\1/p')
        origsize=$(printf '%s' "$res" | sed -n 's/.*origsize=\([0-9]*\).*/\1/p')
        verified=$(printf '%s' "$res" | sed -n 's/.*verified=\([0-9]*\).*/\1/p')
        [[ "$origsize" == "$(stat -c%s "$src")" ]] \
            || fail "[$label/$input] reported origsize=$origsize"
        [[ "$blocks" -ge 1 ]] || fail "[$label/$input] reported blocks=$blocks"
        if [[ "$label" == *hashoff* ]]; then
            [[ "$verified" == "0" ]] || fail "[$label/$input] -hash- must not claim verification"
        else
            [[ "$verified" == "1" ]] || fail "[$label/$input] digest verification was skipped"
        fi
    done
done

say "round-trip: $total archives decoded byte-for-byte (v1 and v2, 4 hash configs)"

# --- Corruption must be caught by the digest ------------------------- #
#
# The corrupted byte must land in a block's LITERALS, not just somewhere in the
# file: for a compressible input the trailing blocks have literal_bytes == 0
# (everything is a match), so the last byte of the file is part of the last
# block's match list and corrupting it breaks the framing instead of the data.
# container_conformance blocks gives the exact region, and the first block with
# literals at all is used.

corrupt_pass=0
for input in repeat.bin mixed.bin; do
    src="$TMP/$input"

    # A checksummed archive must be rejected with a digest mismatch.
    arc="$TMP/corrupt.$input.osr"
    $OSREP -m3o $BFLAGS "$src" "$arc" >/dev/null 2>&1 || fail "[corrupt/$input] compress"
    layout=$("$ROOT/target/release/container_conformance" blocks "$arc" 2>&1) \
        || fail "[corrupt/$input] blocks: $layout"
    lit_start=$(printf '%s\n' "$layout" | sed -n 's/.*literal_start=\([0-9]*\) literal_len=\([0-9]*\).*/\1/p' | head -1)
    lit_len=$(printf '%s\n' "$layout" | sed -n 's/.*literal_start=\([0-9]*\) literal_len=\([0-9]*\).*/\2/p' | head -1)
    [[ -n "$lit_start" && "$lit_len" -gt 0 ]] \
        || fail "[corrupt/$input] no block with literals to corrupt"
    python3 - "$arc" "$((lit_start + lit_len / 2))" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read())
b[off] ^= 0xFF
open(p, "wb").write(b)
PY
    if out=$("$RS" io-lz "$arc" "$TMP/corrupt.$input.out" 2>&1); then
        fail "[corrupt/$input] corrupted literals decoded without a checksum error: $out"
    fi
    case "$out" in
        *checksum*block*) ;;
        *) fail "[corrupt/$input] expected a digest mismatch, got: $out" ;;
    esac

    # The same corruption with checksums disabled must decode (nothing to
    # compare) and produce DIFFERENT bytes -- otherwise the test above would
    # pass even if the decoder ignored corruption entirely.
    arc2="$TMP/nohash.$input.osr"
    $OSREP -m3o -hash- $BFLAGS "$src" "$arc2" >/dev/null 2>&1 || fail "[corrupt/$input] compress -hash-"
    python3 - "$arc2" "$((lit_start + lit_len / 2))" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read())
b[off] ^= 0xFF
open(p, "wb").write(b)
PY
    "$RS" io-lz "$arc2" "$TMP/nohash.$input.out" >/dev/null 2>&1 \
        || fail "[corrupt/$input] -hash- archive unexpectedly failed to decode"
    if cmp -s "$src" "$TMP/nohash.$input.out"; then
        fail "[corrupt/$input] corruption had no effect, so the digest test proves nothing"
    fi
    corrupt_pass=$((corrupt_pass + 1))
done

say "corruption: $corrupt_pass archives caught by the digest (and shown to be real corruption)"

# --- Truncation must be an error, not a panic ------------------------ #

trunc_pass=0
for input in repeat.bin mixed.bin; do
    src="$TMP/$input"
    arc="$TMP/trunc.$input.osr"
    $OSREP -m3o $BFLAGS "$src" "$arc" >/dev/null 2>&1 || fail "[trunc/$input] compress"
    head -c $(( $(stat -c%s "$arc") - 3 )) "$arc" >"$TMP/trunc.$input.cut"
    if out=$("$RS" io-lz "$TMP/trunc.$input.cut" "$TMP/trunc.$input.out" 2>&1); then
        fail "[trunc/$input] a truncated archive decoded successfully: $out"
    fi
    # A panic would surface as a rust panic message, not a clean error.
    case "$out" in
        *panic*) fail "[trunc/$input] panicked instead of erroring: $out" ;;
    esac
    trunc_pass=$((trunc_pass + 1))
done

say "truncation: $trunc_pass archives rejected cleanly"

echo "decode_conformance: passed=$((total + corrupt_pass + trunc_pass)) mismatches=0"
