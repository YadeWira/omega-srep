#!/usr/bin/env bash
# End-to-end conformance for the Rust decoders against archives written by the
# real C++ encoder.
#
#   * io-lz      -- format v1/v2 (Fase 4a)
#   * future-lz  -- format v3/v4 (Fase 4b): the Future-LZ / Index-LZ decoder,
#                   including the MEMORY_MANAGER and its VM spill.
#
# The Rust decoder reads archives written by the real C++ encoder and its output
# must equal the original input byte for byte -- the strongest oracle available,
# since it exercises the container framing, the record decoding, the
# literal/match interleaving and every match source (read back from the sink,
# held in the memory manager, or copied within the current block) in one shot.
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
#   * a truncated archive must be an error, never a panic;
#   * for v3/v4 the VM spill must actually run under a tight memory budget, and
#     the decoded bytes must still be right (spilling is a transparent
#     re-encoding, so it can never change the output).
#
# The v3/v4 archives are produced with `-t1`. The encoder is deterministic for a
# fixed seed regardless of thread count, but `-t1` keeps this oracle obviously
# so; the encoder's own determinism and round-trip are checked separately by
# `tests/futurelz_race_regression.sh`, which is where an encoder bug belongs
# rather than in a decoder test that would only fail intermittently.
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

say "building the Rust decoders (decode_conformance)"
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
# far.bin: 32 distinct 64 KiB blocks, then the same 32 again -- every block
# matches one 2 MiB ahead, so a decoder must hold megabytes of match data and,
# under a tight budget, spill it.
far = [bytes(random.randrange(256) for _ in range(64 * 1024)) for _ in range(32)]
open(os.path.join(d, "far.bin"), "wb").write(b"".join(far) * 2)
PY

INPUTS="tiny.bin repeat.bin random.bin mixed.bin dup.bin"
# -b64k keeps every multi-block archive small enough to exercise the
# cross-block read-back path (a match whose source is an earlier block).
BFLAGS="-b64k"

# --- I/O-LZ (v1/v2) -------------------------------------------------- #

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

say "I/O-LZ round-trip: $total archives decoded byte-for-byte (v1 and v2, 4 hash configs)"

# --- Future-LZ / Index-LZ (v3/v4) ------------------------------------ #

V34_CASES=(
    "v3-m3f|-m3f"
    "v3-m5f|-m5f"
    "v3-m1f|-m1f"
    "v3-m2f|-m2f"
    "v3-m4f|-m4f"
    "v4-m3|-m3"
    "v4-m5|-m5"
    "v4-m1|-m1"
    "v4-m2|-m2"
    "v3-siphash|-m3f -hash=siphash"
    "v3-sha512|-m4f -hash=sha512"
    "v4-md5|-m3 -hash=md5"
    "v3-hashoff|-m3f -hash-"
)

v34=0
for case in "${V34_CASES[@]}"; do
    IFS='|' read -r label flags <<<"$case"
    for input in $INPUTS; do
        src="$TMP/$input"
        arc="$TMP/$label.$input.osr"
        out="$TMP/$label.$input.out"
        # shellcheck disable=SC2086
        $OSREP $flags $BFLAGS -t1 "$src" "$arc" >/dev/null 2>&1 \
            || fail "[$label/$input] encoder rejected the flags"

        if ! res=$("$RS" future-lz "$arc" "$out" 2>&1); then
            fail "[$label/$input] decode: $res"
        fi
        v34=$((v34 + 1))

        [[ "$(stat -c%s "$out")" == "$(stat -c%s "$src")" ]] \
            || fail "[$label/$input] size $(stat -c%s "$out") != $(stat -c%s "$src")"
        cmp -s "$src" "$out" || fail "[$label/$input] decoded bytes differ from the input"

        origsize=$(printf '%s' "$res" | sed -n 's/.*origsize=\([0-9]*\).*/\1/p')
        verified=$(printf '%s' "$res" | sed -n 's/.*verified=\([0-9]*\).*/\1/p')
        [[ "$origsize" == "$(stat -c%s "$src")" ]] \
            || fail "[$label/$input] reported origsize=$origsize"
        if [[ "$label" == *hashoff* ]]; then
            [[ "$verified" == "0" ]] || fail "[$label/$input] -hash- must not claim verification"
        else
            [[ "$verified" == "1" ]] || fail "[$label/$input] digest verification was skipped"
        fi
    done
done

say "Future/Index-LZ round-trip: $v34 archives decoded byte-for-byte (v3 and v4, 4 hash configs)"

# --- The VM spill must actually run, and stay transparent ------------- #
#
# far.bin makes the encoder emit matches whose destination is 2 MiB ahead, so
# the decoder has to hold megabytes of match data. A 1 MiB budget cannot hold
# that, forcing eviction to the spill store; `vmw` counts the bytes that went
# through it, so a zero here would mean this path never ran.

spill_pass=0
for case in "v3|-m5f" "v4|-m5"; do
    IFS='|' read -r label flags <<<"$case"
    src="$TMP/far.bin"
    arc="$TMP/spill.$label.osr"
    out="$TMP/spill.$label.out"
    # shellcheck disable=SC2086
    $OSREP $flags $BFLAGS -t1 "$src" "$arc" >/dev/null 2>&1 \
        || fail "[spill/$label] compress"

    if ! res=$("$RS" future-lz "$arc" "$out" --mem=1048576 --vmblock=131072 2>&1); then
        fail "[spill/$label] decode: $res"
    fi
    vmw=$(printf '%s' "$res" | sed -n 's/.*vmw=\([0-9]*\).*/\1/p')
    vmr=$(printf '%s' "$res" | sed -n 's/.*vmr=\([0-9]*\).*/\1/p')
    [[ -n "$vmw" && "$vmw" -gt 0 ]] \
        || fail "[spill/$label] the spill path was never exercised (vmw=$vmw)"
    [[ "$vmw" == "$vmr" ]] \
        || fail "[spill/$label] wrote $vmw spill bytes but read $vmr back"
    cmp -s "$src" "$out" \
        || fail "[spill/$label] spilled decode differs from the input"
    spill_pass=$((spill_pass + 1))
done

say "spill: $spill_pass archives forced through the VM store and decoded correctly"

# --- Corruption must be caught by the digest ------------------------- #
#
# The corrupted byte must land in a block's LITERALS, not just somewhere in the
# file: for a compressible input the trailing blocks have literal_bytes == 0
# (everything is a match), so the last byte of the file is part of the last
# block's match list and corrupting it breaks the framing instead of the data.
# container_conformance blocks gives the exact region, and the first block with
# literals at all is used.

corrupt_pass=0
# mode|flags -- v1/v2 via the I/O-LZ decoder, v3/v4 via the Future-LZ one.
for case in "io-lz|-m3o" "io-lz|-m1o" "future-lz|-m3f" "future-lz|-m3"; do
    IFS='|' read -r decoder flags <<<"$case"
    for input in repeat.bin mixed.bin; do
        src="$TMP/$input"
        tag="$decoder$flags"

        # A checksummed archive must be rejected with a digest mismatch.
        arc="$TMP/corrupt.$tag.$input.osr"
        # shellcheck disable=SC2086
        $OSREP $flags $BFLAGS -t1 "$src" "$arc" >/dev/null 2>&1 \
            || fail "[corrupt/$tag/$input] compress"
        layout=$("$ROOT/target/release/container_conformance" blocks "$arc" 2>&1) \
            || fail "[corrupt/$tag/$input] blocks: $layout"
        lit_start=$(printf '%s\n' "$layout" | sed -n 's/.*literal_start=\([0-9]*\) literal_len=\([0-9]*\).*/\1/p' | head -1)
        lit_len=$(printf '%s\n' "$layout" | sed -n 's/.*literal_start=\([0-9]*\) literal_len=\([0-9]*\).*/\2/p' | head -1)
        [[ -n "$lit_start" && "$lit_len" -gt 0 ]] \
            || fail "[corrupt/$tag/$input] no block with literals to corrupt"
        python3 - "$arc" "$((lit_start + lit_len / 2))" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read())
b[off] ^= 0xFF
open(p, "wb").write(b)
PY
        if out=$("$RS" "$decoder" "$arc" "$TMP/corrupt.$tag.$input.out" 2>&1); then
            fail "[corrupt/$tag/$input] corrupted literals decoded without a checksum error: $out"
        fi
        case "$out" in
            *checksum*block*) ;;
            *) fail "[corrupt/$tag/$input] expected a digest mismatch, got: $out" ;;
        esac

        # The same corruption with checksums disabled must decode (nothing to
        # compare) and produce DIFFERENT bytes -- otherwise the test above would
        # pass even if the decoder ignored corruption entirely.
        arc2="$TMP/nohash.$tag.$input.osr"
        # shellcheck disable=SC2086
        $OSREP $flags -hash- $BFLAGS -t1 "$src" "$arc2" >/dev/null 2>&1 \
            || fail "[corrupt/$tag/$input] compress -hash-"
        python3 - "$arc2" "$((lit_start + lit_len / 2))" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read())
b[off] ^= 0xFF
open(p, "wb").write(b)
PY
        "$RS" "$decoder" "$arc2" "$TMP/nohash.$tag.$input.out" >/dev/null 2>&1 \
            || fail "[corrupt/$tag/$input] -hash- archive unexpectedly failed to decode"
        if cmp -s "$src" "$TMP/nohash.$tag.$input.out"; then
            fail "[corrupt/$tag/$input] corruption had no effect, so the digest test proves nothing"
        fi
        corrupt_pass=$((corrupt_pass + 1))
    done
done

say "corruption: $corrupt_pass archives caught by the digest (and shown to be real corruption)"

# --- Truncation must be an error, not a panic ------------------------ #

trunc_pass=0
for case in "io-lz|-m3o" "future-lz|-m3f" "future-lz|-m3"; do
    IFS='|' read -r decoder flags <<<"$case"
    for input in repeat.bin mixed.bin; do
        src="$TMP/$input"
        tag="$decoder$flags"
        arc="$TMP/trunc.$tag.$input.osr"
        # shellcheck disable=SC2086
        $OSREP $flags $BFLAGS -t1 "$src" "$arc" >/dev/null 2>&1 \
            || fail "[trunc/$tag/$input] compress"
        head -c $(( $(stat -c%s "$arc") - 3 )) "$arc" >"$TMP/trunc.$tag.$input.cut"
        if out=$("$RS" "$decoder" "$TMP/trunc.$tag.$input.cut" "$TMP/trunc.$tag.$input.out" 2>&1); then
            fail "[trunc/$tag/$input] a truncated archive decoded successfully: $out"
        fi
        # A panic would surface as a rust panic message, not a clean error.
        case "$out" in
            *panic*) fail "[trunc/$tag/$input] panicked instead of erroring: $out" ;;
        esac
        trunc_pass=$((trunc_pass + 1))
    done
done

say "truncation: $trunc_pass archives rejected cleanly"

echo "decode_conformance: passed=$((total + v34 + spill_pass + corrupt_pass + trunc_pass)) mismatches=0"
