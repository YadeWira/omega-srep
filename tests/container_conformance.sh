#!/usr/bin/env bash
# Container-framing conformance: osrep-core::container vs archives written by
# the real C++ encoder.
#
# Fase 3a of the Rust migration (docs/rust-port.md). The container codec has no
# standalone C++ counterpart to diff field-by-field, so each archive is instead
# pinned four ways:
#
#   1. every field the Rust codec derives must equal what the encoder was asked
#      for: version, hash tag, seed/digest sizes, and match-length base;
#   2. the codec must recover the exact uncompressed size from the framing
#      alone -- the input file's size is known, so that is an exact oracle;
#   3. re-encoding the header and the v4 footer must reproduce the bytes in the
#      file exactly, which exercises the write direction too;
#   4. the C++ decoder's own reading of the same framing is cross-checked
#      through `osrep -i`: its mode word and hash name must agree, and for
#      INDEX_LZ its reported original size must match (which is how we know the
#      footer arithmetic is right -- the C++ derives it from the same table).
#
# Skips cleanly (exit 0 with a notice) if the Rust toolchain is missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping container conformance (rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ encoder (bin/osrep)"
make bin/osrep >/dev/null 2>&1 || fail "make bin/osrep"

say "building the Rust codec (container_conformance)"
if ! cargo build --release -p osrep-conformance >/tmp/container-conformance-build.log 2>&1; then
    cat /tmp/container-conformance-build.log >&2
    fail "cargo build failed"
fi
RS=target/release/container_conformance
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

open(os.path.join(d, "empty.bin"), "wb").write(b"")
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
open(os.path.join(d, "repeat.bin"), "wb").write(unit * 75)               # 300 KiB, many matches
open(os.path.join(d, "random.bin"), "wb").write(
    bytes(random.randrange(256) for _ in range(200000)))                 # incompressible
half = bytes(random.randrange(256) for _ in range(40000))
open(os.path.join(d, "mixed.bin"), "wb").write(unit * 8 + half + unit * 8 + half)
PY

INPUTS="empty.bin tiny.bin repeat.bin random.bin mixed.bin"
# -b64k makes every non-trivial input span several blocks, so the multi-block
# framing (block-size table, v4 block count) is covered, not just one block.
BFLAGS="-b64k"

# --- Case table ------------------------------------------------------ #
# label|osrep flags|version|mode word|hash_num|hash name|seed|digest|base_len
CASES=(
    "v4-m3|-m3|4|Index-LZ|4|vmac|32|16|0"
    "v4-m0|-m0|4|Index-LZ|4|vmac|32|16|0"
    "v4-m1|-m1|4|Index-LZ|4|vmac|32|16|0"
    "v4-m2|-m2|4|Index-LZ|4|vmac|32|16|0"
    "v4-m4|-m4|4|Index-LZ|4|vmac|32|16|0"
    "v4-m5|-m5|4|Index-LZ|4|vmac|32|16|0"
    "v3-future|-m3f|3|Future-LZ|4|vmac|32|16|0"
    "v2-io-m1|-m1o|2|I/O LZ|4|vmac|32|16|32"
    "v2-io-m2|-m2o|2|I/O LZ|4|vmac|32|16|32"
    "v1-round|-m3o|1|I/O LZ|4|vmac|32|16|512"
    "v4-md5|-m3 -hash=md5|4|Index-LZ|0|md5|0|16|0"
    "v4-sha1|-m3 -hash=sha1|4|Index-LZ|2|sha1|0|20|0"
    "v4-sha512|-m3 -hash=sha512|4|Index-LZ|3|sha512|0|64|0"
    "v4-siphash|-m3 -hash=siphash|4|Index-LZ|5|siphash|16|8|0"
    "v4-hashoff|-m3 -hash-|4|Index-LZ|1||0|16|0"
    "v3-siphash|-m3f -hash=siphash|3|Future-LZ|5|siphash|16|8|0"
)

# --- Helpers --------------------------------------------------------- #

field() {  # field <dump> <key>
    printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

total=0
for case in "${CASES[@]}"; do
    IFS='|' read -r label flags version mode hnum hname seed digest base <<<"$case"
    for input in $INPUTS; do
        src="$TMP/$input"
        arc="$TMP/$label.$input.osr"
        # shellcheck disable=SC2086
        if ! $OSREP $flags $BFLAGS "$src" "$arc" >/dev/null 2>&1; then
            fail "[$label/$input] encoder rejected the flags"
        fi
        total=$((total + 1))

        if ! dump=$("$RS" dump "$arc" 2>&1); then
            fail "[$label/$input] dump: $dump"
        fi

        got_version=$(field "$dump" version)
        [[ "$got_version" == "$version" ]] \
            || fail "[$label/$input] version=$got_version want=$version"
        got_mode=$(field "$dump" mode);  got_mode=${got_mode/index/Index-LZ}
        got_mode=${got_mode/future/Future-LZ}; got_mode=${got_mode/io/I/O LZ}
        [[ "$got_mode" == "$mode" ]] \
            || fail "[$label/$input] mode=$got_mode want=$mode"
        [[ "$(field "$dump" hash_num)" == "$hnum" ]] \
            || fail "[$label/$input] hash_num=$(field "$dump" hash_num) want=$hnum"
        [[ "$(field "$dump" hash)" == "$hname" ]] \
            || fail "[$label/$input] hash=$(field "$dump" hash) want=$hname"
        [[ "$(field "$dump" seed)" == "$seed" ]] \
            || fail "[$label/$input] seed=$(field "$dump" seed) want=$seed"
        [[ "$(field "$dump" digest)" == "$digest" ]] \
            || fail "[$label/$input] digest=$(field "$dump" digest) want=$digest"
        [[ "$(field "$dump" base_len)" == "$base" ]] \
            || fail "[$label/$input] base_len=$(field "$dump" base_len) want=$base"

        # (2) the framing alone must account for the whole input.
        want_size=$(stat -c%s "$src")
        got_size=$(field "$dump" origsize)
        [[ "$got_size" == "$want_size" ]] \
            || fail "[$label/$input] origsize=$got_size want=$want_size"
        # Nothing may be left over after the last block.
        [[ "$(field "$dump" trailing)" == "0" ]] \
            || fail "[$label/$input] trailing=$(field "$dump" trailing)"
        # Every input beyond the trivial ones must actually span blocks.
        if [[ "$want_size" -gt 65536 ]]; then
            [[ "$(field "$dump" blocks)" -ge 2 ]] \
                || fail "[$label/$input] expected a multi-block archive"
        fi

        # (3) the write direction: header and footer must re-encode exactly.
        if ! "$RS" check "$arc" >/dev/null 2>&1; then
            fail "[$label/$input] $( "$RS" check "$arc" 2>&1 )"
        fi

        # (4) the C++ decoder's own reading of the framing.
        info=$("$OSREP" -i "$arc" 2>&1 || true)
        case "$info" in
            *"$mode"*"-hash=$hname"*) ;;
            *) fail "[$label/$input] osrep -i disagrees on mode/hash: $(printf '%s' "$info" | head -1)" ;;
        esac
        # INDEX_LZ reports the size straight from the footer arithmetic; parse
        # it when show3 emitted plain grouped digits (small inputs).
        reported=$(printf '%s' "$info" | head -1 | sed -n 's/.*  \([0-9,]*\) -> .*/\1/p' | tr -d ',')
        if [[ -n "$reported" ]]; then
            [[ "$reported" == "$want_size" ]] \
                || fail "[$label/$input] osrep -i size=$reported want=$want_size"
        fi
    done
done

say "framing: $total archives matched (version, mode, hash, seed, digest, base, origsize, re-encode, -i)"

# --- ODUP trailer (the -dup body boundary) --------------------------- #
#
# The archive body holds the concatenation of the UNIQUE chunks, so its
# uncompressed size is at most the input size, and exactly equal only when the
# input has no repeated chunk. `random.bin` is incompressible, so every CDC
# chunk is unique and the body must reproduce it byte for byte -- that is the
# exact oracle. The other two only have to stay within bounds.

dup_pass=0
for spec in "tiny.bin|0" "random.bin|1" "repeat.bin|0"; do
    IFS='|' read -r input expect_exact <<<"$spec"
    src="$TMP/$input"
    arc="$TMP/dup.$input.osr"
    back="$TMP/dup.$input.back"
    $OSREP -dup -m4 "$src" "$arc" >/dev/null 2>&1 || fail "[-dup/$input] compress"
    tr=$("$RS" trailer "$arc" 2>&1) || fail "[-dup/$input] $tr"
    [[ "$tr" == odup\ body=*\ meta=* ]] || fail "[-dup/$input] trailer reported: $tr"
    body_len=$(printf '%s' "$tr" | sed -n 's/odup body=\([0-9]*\) meta=.*/\1/p')
    file_len=$(stat -c%s "$arc")
    [[ "$body_len" -lt "$file_len" ]] || fail "[-dup/$input] body=$body_len file=$file_len"

    # dump/check must transparently parse the body, and the framing must still
    # close exactly (so the body boundary is right, not merely plausible).
    dump=$("$RS" dump "$arc" 2>&1) || fail "[-dup/$input] dump: $dump"
    [[ "$(field "$dump" odup)" == "1" ]] || fail "[-dup/$input] odup not detected"
    src_size=$(stat -c%s "$src")
    body_size=$(field "$dump" origsize)
    [[ "$body_size" -le "$src_size" ]] \
        || fail "[-dup/$input] body origsize=$body_size exceeds input=$src_size"
    if [[ "$expect_exact" == "1" ]]; then
        [[ "$body_size" == "$src_size" ]] \
            || fail "[-dup/$input] unique body should equal the input: $body_size != $src_size"
    fi
    "$RS" check "$arc" >/dev/null 2>&1 || fail "[-dup/$input] check failed on the body"

    # And the C++ decoder must still round-trip the archive.
    $OSREP -d "$arc" "$back" >/dev/null 2>&1 || fail "[-dup/$input] decompress"
    cmp -s "$src" "$back" || fail "[-dup/$input] round-trip mismatch"
    dup_pass=$((dup_pass + 1))
done

say "odup trailer: $dup_pass archives split and round-tripped"

echo "container_conformance: passed=$((total + dup_pass)) mismatches=0"
