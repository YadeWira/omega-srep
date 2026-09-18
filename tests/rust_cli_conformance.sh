#!/usr/bin/env bash
# The Rust CLI against the C++ one (docs/rust-port.md, phase 5c).
#
# Two layers:
#
#   1. **Same argv, same bytes.** For a matrix of inputs and options the C++
#      binary and `target/release/osrep` are run with identical arguments and
#      the archives must compare byte for byte. The algorithm is already pinned
#      by tests/encode_conformance.sh; what this adds is the *front end* -- the
#      option parsing, the defaults, the container choice -- and cross-decoding
#      in both directions.
#
#      Since phase 5c-2 the port's default container is v5, which the C++ cannot
#      write, so this layer pins `--format=v4` on the Rust side: what it is
#      asking is "can the port still reproduce the oracle exactly when asked
#      for the oracle's format", and that question outlives the default flip.
#      The v5 default is covered by tests/format_v5_conformance.sh and by
#      layer 2, which runs the whole CLI suite over it.
#
#   2. **The CLI test suite, run against the Rust binary.** tests/_osrep_bin.sh
#      lets `OSREP_BIN` point every CLI-level script at a different build, so the
#      ten scripts below are the same ones that gate the C++ -- duplicate
#      handling, corrupt archives, spilling, concurrency, seed determinism and
#      all -- run over the port.
#
# Skips cleanly (exit 0) when the Rust toolchain is missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping Rust CLI conformance (install rustup; rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ oracle (bin/osrep)"
make bin/osrep >/dev/null 2>&1 || fail "make bin/osrep"

say "building the Rust CLI (osrep-cli)"
if ! cargo build --release -p osrep-cli >target/rust-cli-build.log 2>&1; then
    cat target/rust-cli-build.log >&2
    fail "cargo build failed"
fi
RS=target/release/osrep
[[ -x "$RS" ]] || fail "missing $RS"
OSREP_BIN="$RS"

say "rustc: $(rustc --version)"
say "osrep: $("$RS" --version) / $(./bin/osrep --version)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
# A duplicate-heavy input: tests/corpus is blind to the CDC modes.
unit = bytes((i * 31 + 7) & 0xFF for i in range(1 << 16))
open(os.path.join(d, "dup1m.bin"), "wb").write(unit * 16)
PY

pass=0

# diff <input> <options...>
#   Both binaries, same argv, same --seed; archives must be byte-identical, and
#   each must decode the other's.
diff_case() {
    local input="$1"
    shift
    if ! ./bin/osrep "$@" --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>"$TMP/cpp.err"; then
        fail "cpp $* on $(basename "$input") failed: $(tail -1 "$TMP/cpp.err")"
    fi
    if ! "$RS" "$@" --format=v4 --seed=7 "$input" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err"; then
        fail "rust $* on $(basename "$input") failed: $(tail -1 "$TMP/rs.err")"
    fi
    cmp -s "$TMP/cpp.osr" "$TMP/rs.osr" \
        || fail "$* on $(basename "$input"): archives differ ($(stat -c%s "$TMP/cpp.osr") vs $(stat -c%s "$TMP/rs.osr") bytes)"

    # The C++ reading the Rust archive, and the reverse.
    ./bin/osrep -d "$TMP/rs.osr" "$TMP/cpp.dec" >/dev/null 2>&1 \
        || fail "$* on $(basename "$input"): the C++ could not decode the Rust archive"
    "$RS" -d "$TMP/cpp.osr" "$TMP/rs.dec" >/dev/null 2>&1 \
        || fail "$* on $(basename "$input"): the Rust binary could not decode the C++ archive"
    cmp -s "$input" "$TMP/cpp.dec" || fail "$* on $(basename "$input"): cross-decode differs"
    cmp -s "$input" "$TMP/rs.dec" || fail "$* on $(basename "$input"): cross-decode differs"

    pass=$((pass + 1))
}

say "same argv, same bytes: method x suffix x hash"
for input in tests/corpus/tiny.bin tests/corpus/text.bin tests/corpus/zeros.bin \
             tests/corpus/random.bin "$TMP/dup1m.bin"; do
    [ -f "$input" ] || continue
    for m in m0 m1 m2 m3 m4 m5; do
        for suffix in "" f o; do
            diff_case "$input" "-$m$suffix"
        done
    done
    for h in vmac md5 sha1 sha512 siphash -; do
        if [ "$h" = "-" ]; then hopts="-hash-"; else hopts="-hash=$h"; fi
        diff_case "$input" -m4 $hopts
        diff_case "$input" -m5o $hopts
    done
done

say "options that reach the encoder: -b, -l, -c, -d, -m"
diff_case tests/corpus/text.bin -m3 -b64k
diff_case tests/corpus/text.bin -m3 -b1mb -l1024
diff_case tests/corpus/text.bin -m4 -l256 -c128
diff_case tests/corpus/text.bin -m5 -d16mb
diff_case tests/corpus/text.bin -m0 -d16mb
diff_case tests/corpus/text.bin -m3 -dl256
diff_case tests/corpus/text.bin -m4 -m64kb          # -mBYTES, the maximum-save form
diff_case tests/corpus/text.bin -m4 -t8 -v0         # accepted and ignored

say "stdin/stdout: '-' is a pipe, not a file called '-'"
for m in m0 m3 m4 m4f m5o; do
    if ! ./bin/osrep -$m --seed=7 - - <tests/corpus/text.bin >"$TMP/cpp.pipe" 2>"$TMP/cpp.err"; then
        fail "cpp -$m through a pipe failed: $(tail -1 "$TMP/cpp.err")"
    fi
    if ! "$RS" -$m --format=v4 --seed=7 - - <tests/corpus/text.bin >"$TMP/rs.pipe" 2>"$TMP/rs.err"; then
        fail "rust -$m through a pipe failed: $(tail -1 "$TMP/rs.err")"
    fi
    cmp -s "$TMP/cpp.pipe" "$TMP/rs.pipe" || fail "-$m: the two piped archives differ"
    "$RS" -d - - <"$TMP/cpp.pipe" >"$TMP/rs.pipe.out" 2>/dev/null \
        || fail "-$m: the port could not decode a piped archive"
    cmp -s tests/corpus/text.bin "$TMP/rs.pipe.out" || fail "-$m: piped round-trip differs"
    pass=$((pass + 1))
done
# `-` used to land on disk as a file with that name, which both hid the bug and
# made a naive test pass anyway.
[[ ! -e ./- ]] || fail "a file literally named '-' was created in the working directory"

say "an unknown option is refused, the way the C++ refuses it"
if "$RS" -m4 --seed=7 -bogus tests/corpus/text.bin "$TMP/a.osr" >/dev/null 2>&1; then
    fail "the port accepted -bogus"
fi
if ./bin/osrep -m4 --seed=7 -bogus tests/corpus/text.bin "$TMP/a.osr" >/dev/null 2>&1; then
    fail "the C++ accepted -bogus (the test is wrong, not the port)"
fi
pass=$((pass + 1))

say "-dup: an archive the C++ can read, and the same payload inside v5"
for m in m3 m4 m5; do
    ./bin/osrep -dup -$m --seed=7 "$TMP/dup1m.bin" "$TMP/cpp.osr" >/dev/null 2>&1 \
        || fail "cpp -dup -$m failed"
    "$RS" -dup -$m --format=v4 --seed=7 "$TMP/dup1m.bin" "$TMP/rs.osr" >/dev/null 2>&1 \
        || fail "rust -dup -$m failed"
    cmp -s "$TMP/cpp.osr" "$TMP/rs.osr" || fail "-dup -$m: archives differ"
    # The C++ auto-detects the trailer of the Rust archive, and vice versa.
    ./bin/osrep -d "$TMP/rs.osr" "$TMP/cpp.dec" >/dev/null 2>&1 || fail "-dup -$m: C++ cannot decode the Rust archive"
    cmp -s "$TMP/dup1m.bin" "$TMP/cpp.dec" || fail "-dup -$m: cross-decode differs"
    # And the default container, v5 since phase 5c-2: the C++ cannot read it,
    # so only the port's own round-trip is checked here
    # (tests/dup_v5_conformance.sh does the payload comparison).
    "$RS" -dup -$m --seed=7 "$TMP/dup1m.bin" "$TMP/rs5.osr" >/dev/null 2>&1 \
        || fail "rust --format=v5 -dup -$m failed"
    "$RS" -d "$TMP/rs5.osr" "$TMP/rs5.dec" >/dev/null 2>&1 || fail "-dup -$m v5: will not decode"
    cmp -s "$TMP/dup1m.bin" "$TMP/rs5.dec" || fail "-dup -$m v5: round-trip differs"
    pass=$((pass + 1))
done

say "-dup: the flags around it"
for c in "-dup --dup-paranoid -m4" "-dup -m4 --chunk-avg=8192" "-dup -m4 --chunk-hash=gear" \
         "-dup -m4 --chunk-min=2048 --chunk-max=32768 --chunk-buf=65536"; do
    # shellcheck disable=SC2086
    ./bin/osrep $c --seed=7 "$TMP/dup1m.bin" "$TMP/cpp.osr" >/dev/null 2>&1 \
        || fail "cpp $c failed"
    # shellcheck disable=SC2086
    "$RS" $c --format=v4 --seed=7 "$TMP/dup1m.bin" "$TMP/rs.osr" >/dev/null 2>&1 \
        || fail "rust $c failed"
    cmp -s "$TMP/cpp.osr" "$TMP/rs.osr" || fail "$c: archives differ"
    pass=$((pass + 1))
done
if "$RS" -dup -m0 --seed=7 "$TMP/dup1m.bin" "$TMP/x.osr" >/dev/null 2>&1; then
    fail "-dup -m0 was accepted"
fi
if "$RS" -dup -m4 --chunk-hash=bogus --seed=7 "$TMP/dup1m.bin" "$TMP/x.osr" >/dev/null 2>&1; then
    fail "--chunk-hash=bogus was accepted"
fi
pass=$((pass + 1))

say "--seed=N and OSREP_SEED_HEX"
"$RS" --seed=12345 -m4 "$TMP/dup1m.bin" "$TMP/s1.osr" >/dev/null 2>&1
"$RS" --seed=12345 -m4 "$TMP/dup1m.bin" "$TMP/s2.osr" >/dev/null 2>&1
"$RS" --seed=99999 -m4 "$TMP/dup1m.bin" "$TMP/s3.osr" >/dev/null 2>&1
cmp -s "$TMP/s1.osr" "$TMP/s2.osr" || fail "the same seed produced different archives"
cmp -s "$TMP/s1.osr" "$TMP/s3.osr" && fail "different seeds produced the same archive"
# No seed at all: the key is drawn per run, so two runs must differ.
"$RS" -m4 "$TMP/dup1m.bin" "$TMP/n1.osr" >/dev/null 2>&1
"$RS" -m4 "$TMP/dup1m.bin" "$TMP/n2.osr" >/dev/null 2>&1
cmp -s "$TMP/n1.osr" "$TMP/n2.osr" && fail "two unseeded runs produced the same archive"
# OSREP_SEED_HEX pins the key, and must beat --seed. The key lands at a
# different offset in each container -- v4's header is 16 bytes, v5's is 28 --
# so both are checked rather than just the default: this is the one assertion
# the 5c-2 default flip was predicted to move, and pinning both offsets is what
# keeps it from silently drifting again.
SEED=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
for fmt_off in "v4 16 48" "v5 28 60"; do
    set -- $fmt_off
    OSREP_SEED_HEX=$SEED "$RS" -m4 --format="$1" --seed=1 "$TMP/dup1m.bin" "$TMP/hex.$1.osr" >/dev/null 2>&1
    stored=$(python3 -c "print(open('$TMP/hex.$1.osr','rb').read()[$2:$3].hex())")
    [[ "$stored" == "$SEED" ]] \
        || fail "OSREP_SEED_HEX did not take effect in $1 at [$2:$3] (stored $stored)"
done
# The oracle only writes v4, so that is the archive it is compared against.
OSREP_SEED_HEX=$SEED ./bin/osrep -m4 --seed=1 "$TMP/dup1m.bin" "$TMP/hexcpp.osr" >/dev/null 2>&1
cmp -s "$TMP/hex.v4.osr" "$TMP/hexcpp.osr" || fail "OSREP_SEED_HEX archive differs from the C++"
pass=$((pass + 1))

say "the C++ refuses a v5 archive cleanly, and says why"
# Since phase 5c-2 the port writes v5 by default, so this is what a user still
# on a 1.0.x binary hits. It must be a clean refusal -- the archive is not
# corrupt, it is newer -- and never a crash or a partial file, which is the
# failure mode that would silently hand someone wrong bytes.
"$RS" -m4 --seed=7 tests/corpus/text.bin "$TMP/v5.osr" >/dev/null 2>&1 \
    || fail "the port could not write its own default container"
[ "$(head -c 4 "$TMP/v5.osr")" = "OSR5" ] || fail "the default container is not v5"
rm -f "$TMP/v5.out"
# `set -e` is on and these are expected to fail, so the status is captured.
rc=0; ./bin/osrep -d "$TMP/v5.osr" "$TMP/v5.out" >"$TMP/v5.err" 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "the C++ -d on a v5 archive exited $rc, expected 4 (bad data)"
grep -qi "not an omega srep compressed file" "$TMP/v5.err" \
    || fail "the C++ -d on a v5 archive did not say the file is not an .osr"
[ ! -s "$TMP/v5.out" ] \
    || fail "the C++ -d on a v5 archive produced $(stat -c%s "$TMP/v5.out") bytes of output"
rc=0; ./bin/osrep -i "$TMP/v5.osr" >"$TMP/v5i.err" 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "the C++ -i on a v5 archive exited $rc, expected 4 (bad data)"
grep -qi "not an omega srep compressed file" "$TMP/v5i.err" \
    || fail "the C++ -i on a v5 archive did not say the file is not an .osr"
pass=$((pass + 1))

say "-i agrees with the C++ on mode, hash and size"
for m in m3 m4f m5o; do
    ./bin/osrep -$m --seed=7 tests/corpus/text.bin "$TMP/cpp.osr" >/dev/null 2>&1
    "$RS" -i "$TMP/cpp.osr" >"$TMP/rs.info" 2>&1
    ./bin/osrep -i "$TMP/cpp.osr" >"$TMP/cpp.info" 2>&1
    head -1 "$TMP/rs.info" >"$TMP/rs.head"
    head -1 "$TMP/cpp.info" >"$TMP/cpp.head"
    cmp -s "$TMP/rs.head" "$TMP/cpp.head" \
        || fail "-$m: osrep -i disagrees: '$(cat "$TMP/rs.head")' vs '$(cat "$TMP/cpp.head")'"
    pass=$((pass + 1))
done

say "the CLI suite, with OSREP_BIN pointed at the Rust binary"
# `futurelz_race_regression.sh` repeats 150x per case in the C++ gate; here the
# point is that the CLI plumbing is right, not the race (which is a C++ bug the
# Rust port cannot have).
for s in roundtrip mode_suffix_hash_matrix dup_roundtrip dup_native_roundtrip \
         dup_corruption_fuzz dup_concurrency dup_ref_oob_regression \
         vm_options_regression vm_tempfile_leak_regression futurelz_race_regression; do
    if ! out=$(OSREP_BIN="$RS" FUTURELZ_RACE_RUNS="${FUTURELZ_RACE_RUNS:-20}" bash "tests/$s.sh" 2>&1); then
        printf '%s\n' "$out" >&2
        fail "tests/$s.sh failed with OSREP_BIN=$RS"
    fi
    say "$s: $(printf '%s' "$out" | tail -1)"
    pass=$((pass + 1))
done

echo "  rust_cli_conformance: passed=$pass mismatches=0"
