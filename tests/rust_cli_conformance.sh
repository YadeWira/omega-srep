#!/usr/bin/env bash
# The Rust CLI against the C++ one (docs/rust-port.md, phase 5c).
#
# Two layers:
#
#   1. **Same argv, same bytes.** For a matrix of inputs and options the C++
#      binary and `oracles/rust/target/release/osrep` are run with identical
#      arguments and the archives must compare byte for byte. The algorithm is
#      already pinned by tests/encode_conformance.sh; what this adds is the
#      *front end* -- the option parsing, the defaults, the container choice --
#      and cross-decoding in both directions.
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
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping Rust CLI conformance (install rustup; oracles/rust/rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ oracle ($CXX_BIN/osrep)"
make_cxx bin/osrep >/dev/null 2>&1 || fail "make -C $CXX_DIR bin/osrep"

say "building the Rust CLI (osrep-cli)"
mkdir -p "$RUST_TARGET"
if ! cargo_rs build --release -p osrep-cli >"$RUST_TARGET/rust-cli-build.log" 2>&1; then
    cat "$RUST_TARGET/rust-cli-build.log" >&2
    fail "cargo build failed"
fi
RS=$RUST_TARGET/release/osrep
# `OSREP_PORT_BIN` runs this whole script -- both layers -- over another build
# of the port's CLI. That is how the Pascal port (docs/pascal-port.md, phase 7)
# is held to exactly the gate the Rust one passes.
if [ -n "${OSREP_PORT_BIN:-}" ]; then
    RS="$OSREP_PORT_BIN"
fi
[[ -x "$RS" ]] || fail "missing $RS"
OSREP_BIN="$RS"

say "rustc: $(cd "$RUST_DIR" && rustc --version)"
say "osrep: $("$RS" --version) / $("$CXX_BIN/osrep" --version)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
# A duplicate-heavy input: tests/corpus is blind to the CDC modes.
unit = bytes((i * 31 + 7) & 0xFF for i in range(1 << 16))
open(os.path.join(d, "dup1m.bin"), "wb").write(unit * 16)
# Ties in the second pass (see the section below and
# tests/cxx_sort_tie_divergence.sh).
import random
r = random.Random(1)
u = bytes(r.randrange(256) for _ in range(512))
open(os.path.join(d, "tie10k.bin"), "wb").write(u * 2 + bytes([r.randrange(256)]) + u * 18)
r = random.Random(20261009)
u = bytes(r.randrange(256) for _ in range(4096))
out = bytearray()
while len(out) < 2 << 20:
    out += u
    if r.random() < 0.05:
        out += bytes(r.randrange(256) for _ in range(r.randint(1, 40)))
open(os.path.join(d, "noisy512k.bin"), "wb").write(out[:512 << 10])
open(os.path.join(d, "noisy2m.bin"), "wb").write(out[:2 << 20])
# Near-duplicates for a small -l (the -m3/-m4/-m5 first pass with -l16..-l128
# or a small -c). Copies of a random unit with the last byte or two of ~30% of
# the 16-byte cells bumped by 1-3, and a short random run after ~20% of the
# copies; one 64 KiB half with a 4 KiB unit, one with a 1 KiB unit. 2.2.x
# wrote other bytes than 1.0.7 on it in every small-l case the gates check:
# chunks that differ in their last byte replaced each other in add_hash (the
# C++ also compares the -m3 digests there), and the ports ran the plain
# compress<0> scan where the C++ runs the bitarr-filtered compress<accel>.
def nearcopies(seed, unit_len):
    r = random.Random(seed)
    unit = bytearray(r.randrange(256) for _ in range(unit_len))
    out = bytearray()
    while len(out) < 65536:
        u = bytearray(unit)
        for c in range(0, unit_len, 16):
            if r.random() < 0.3:
                j = c + 15 - r.randrange(2)
                u[j] = (u[j] + r.randrange(1, 4)) & 0xFF
        out += u
        if r.random() < 0.2:
            out += bytes(r.randrange(256) for _ in range(r.randint(1, 7)))
    return bytes(out[:65536])
open(os.path.join(d, "smalll.bin"), "wb").write(nearcopies(2, 4096) + nearcopies(3, 1024))
# The scan's edge cases, checked below (straight against the C++, except
# a33929/a200k, pinned by md5):
# zruns.bin, random runs between runs of zeros, is where the accelerated
# scan's LOOKAHEAD (it filters through bitarr in batches of up to 256
# positions) matters; nearcopy.bin, 64 KiB at random and three copies with
# 200 bytes changed in each, gives -d's in-memory pass matches close
# together, and the scan only stores candidates between the end of the last
# match and the start of the next one that pass found; a33929.bin and
# a200k.bin, one byte repeated, give -m3 blocks that are not a whole number
# of chunks, where its digest test reads the next block's first chunk.
r = random.Random(20261015)
out = bytearray()
while len(out) < 240000:
    out += bytes(r.randrange(256) for _ in range(r.randint(500, 3000)))
    out += bytes(r.randint(1000, 5000))
open(os.path.join(d, "zruns.bin"), "wb").write(out)
r = random.Random(7)
base = bytes(r.randrange(256) for _ in range(65536))
out = bytearray(base)
for _ in range(3):
    c = bytearray(base)
    for _ in range(200):
        c[r.randrange(len(c))] = r.randrange(256)
    out += c
open(os.path.join(d, "nearcopy.bin"), "wb").write(out)
open(os.path.join(d, "a33929.bin"), "wb").write(b"A" * 33929)
open(os.path.join(d, "a200k.bin"), "wb").write(b"A" * 200000)
PY

pass=0

# diff <input> <options...>
#   Both binaries, same argv, same --seed; archives must be byte-identical, and
#   each must decode the other's.
diff_case() {
    local input="$1"
    shift
    if ! "$CXX_BIN/osrep" "$@" --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>"$TMP/cpp.err"; then
        fail "cpp $* on $(basename "$input") failed: $(tail -1 "$TMP/cpp.err")"
    fi
    if ! "$RS" "$@" --format=v4 --seed=7 "$input" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err"; then
        fail "rust $* on $(basename "$input") failed: $(tail -1 "$TMP/rs.err")"
    fi
    cmp -s "$TMP/cpp.osr" "$TMP/rs.osr" \
        || fail "$* on $(basename "$input"): archives differ ($(stat -c%s "$TMP/cpp.osr") vs $(stat -c%s "$TMP/rs.osr") bytes)"

    # The C++ reading the Rust archive, and the reverse.
    "$CXX_BIN/osrep" -d "$TMP/rs.osr" "$TMP/cpp.dec" >/dev/null 2>&1 \
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

say "a small -l or -c: the bitarr-filtered scan, -aN[/M], and -m3's digest test in add_hash"
# accel = min(max(L/32, 1), 4) picks the C++'s compress<accel> (srep.cpp:631-634)
# and -aN[/M] sizes bitarr and picks the variant; -a0/-a- is compress<0>. 2.2.x
# ignored -a and always ran compress<0>, and its add_hash skipped the -m3
# digest test: every case here differed from 1.0.7 (see smalll.bin above).
for o in "-m3o -l32" "-m3 -l32" "-m4o -l16" "-m4 -c64" "-m5 -c64" "-m4o -l32" "-m4 -l64" \
         "-m3f -l32" "-m3o -l32 -a0" "-m3 -l32 -a-" "-m4o -l16 -a2/2" "-m3o -l32 -a2" \
         "-m4 -l64 -a16" "-m4o -l64 -a4/64" "-m5 -c64 -a8"; do
    # shellcheck disable=SC2086
    diff_case "$TMP/smalll.bin" $o
done
# Where the C++ has no defined behaviour the port keeps the plain scan, which
# is what 2.2.1 wrote for every -a: no compress<3>/<5>/... instance (-a3, -a5,
# and the default accel 3 of -l96..-l127: the C++ exits 3 or writes a block
# that does not decode), -a0/N and -aN/M followed by -a- (a null bitarr: the
# C++ segfaults), and a variant wider than the chunk (-l16 -a1/32: the C++
# aborts). Each must succeed, write exactly the -a0 archive, and round-trip;
# the v4 one must also decode with the C++.
for case in "-m4o -l32 -a3|-m4o -l32 -a0" "-m4 -l32 -a5|-m4 -l32 -a0" \
            "-m3o -l32 -a0/4|-m3o -l32 -a0" "-m4 -l16 -a1/32|-m4 -l16 -a0" \
            "-m4o -l96|-m4o -l96 -a0" "-m3 -l100|-m3 -l100 -a0" \
            "-m4 -l32 -a4/8 -a-|-m4 -l32 -a0" "-m5 -c64 -a2/3|-m5 -c64 -a0"; do
    IFS='|' read -r o plain <<<"$case"
    for fmt in "" --format=v4; do
        rc=0
        # shellcheck disable=SC2086
        "$RS" $fmt --seed=7 $o "$TMP/smalll.bin" "$TMP/fb.osr" >/dev/null 2>"$TMP/fb.err" || rc=$?
        # -l96 and -l100 also earn the power-of-two warning, which is exit 1
        [ "$rc" -le 1 ] || fail "$o $fmt exited $rc: $(tail -1 "$TMP/fb.err")"
        # shellcheck disable=SC2086
        "$RS" $fmt --seed=7 $plain "$TMP/smalll.bin" "$TMP/pl.osr" >/dev/null 2>&1 || true
        cmp -s "$TMP/fb.osr" "$TMP/pl.osr" || fail "$o $fmt: not the plain-scan archive of $plain"
        "$RS" -d "$TMP/fb.osr" "$TMP/fb.dec" >/dev/null 2>&1 || fail "$o $fmt: archive does not decode"
        cmp -s "$TMP/smalll.bin" "$TMP/fb.dec" || fail "$o $fmt: round trip differs"
        if [ -n "$fmt" ]; then
            "$CXX_BIN/osrep" -d "$TMP/fb.osr" "$TMP/fb.cdec" >/dev/null 2>&1 \
                || fail "$o: the C++ could not decode the port's archive"
            cmp -s "$TMP/smalll.bin" "$TMP/fb.cdec" || fail "$o: C++ decode differs"
        fi
        rm -f "$TMP/fb.osr" "$TMP/pl.osr" "$TMP/fb.dec" "$TMP/fb.cdec"
        pass=$((pass + 1))
    done
done

say "the scan's edges and -ia-, straight against the C++"
# The inputs are described where they are generated. These cases give the C++
# the same archive on every run: each was run at least 300 times (half one
# after another, half eight at a time), at -t1 as here, with one result each. -t1 is
# only what they were measured with; the next block's read-ahead (below) is
# unordered at any -t. A later -aN without /M resets the scan variant to its
# default (srep.cpp:345-346). -l130 and -c130 earn the power-of-two warning,
# exit 1, on both sides. -ia- (io_accelerator -1, srep.cpp:349-352) turns off
# the slice filter (hash_table.cpp:33-36) that -m5, and -m4 with a -c well
# below -l, run: text.bin -m5 -l1000 is 4,194,408 bytes with the filter and
# 189 with -ia-; -m3 never reads the filter, so there -ia-/-ia+ must not
# matter (-dl128 keeps BASE_LEN dividing the 128-byte chunk, where the ports
# write the C++'s bytes; see the BASE_LEN section below). The last -ia wins.
# Each case failed on some build the gate above let through: zruns with
# LOOKAHEAD 128, nearcopy with the store window's end included, the -a ones
# with a Pascal CLI that kept the old /M, and the -m4/-m5 -ia- ones on 2.2.1
# and 02d4823, whose ports ignored -ia-.
diff_case_t1() {
    local input="$1" rc
    shift
    rc=0
    "$CXX_BIN/osrep" -t1 "$@" --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>"$TMP/cpp.err" || rc=$?
    [ "$rc" -le 1 ] || fail "cpp -t1 $* on $(basename "$input") exited $rc: $(tail -1 "$TMP/cpp.err")"
    rc=0
    "$RS" "$@" --format=v4 --seed=7 "$input" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err" || rc=$?
    [ "$rc" -le 1 ] || fail "port $* on $(basename "$input") exited $rc: $(tail -1 "$TMP/rs.err")"
    cmp -s "$TMP/cpp.osr" "$TMP/rs.osr" \
        || fail "$* on $(basename "$input"): archives differ from the C++ -t1 ($(stat -c%s "$TMP/cpp.osr") vs $(stat -c%s "$TMP/rs.osr") bytes)"
    "$RS" -d "$TMP/rs.osr" "$TMP/rs.dec" >/dev/null 2>&1 \
        || fail "$* on $(basename "$input"): the port could not decode its archive"
    "$CXX_BIN/osrep" -d "$TMP/rs.osr" "$TMP/cpp.dec" >/dev/null 2>&1 \
        || fail "$* on $(basename "$input"): the C++ could not decode the port's archive"
    cmp -s "$input" "$TMP/rs.dec" || fail "$* on $(basename "$input"): round trip differs"
    cmp -s "$input" "$TMP/cpp.dec" || fail "$* on $(basename "$input"): C++ decode differs"
    rm -f "$TMP/cpp.osr" "$TMP/rs.osr" "$TMP/rs.dec" "$TMP/cpp.dec"
    pass=$((pass + 1))
}
cp tests/corpus/text.bin "$TMP/text.bin"
for case in "zruns.bin|-m3 -l130" "zruns.bin|-m3 -c130" \
            "nearcopy.bin|-m4 -l40 -d1mb" "nearcopy.bin|-m4o -l16 -d1mb" \
            "smalll.bin|-m4 -l16 -a1/2 -a1" "smalll.bin|-m4 -l32 -a2/4 -a2" \
            "text.bin|-m5 -l1000 -ia-" "text.bin|-m5o -l1024 -c128 -ia-" \
            "nearcopy.bin|-m4 -l1024 -c128 -ia-" "nearcopy.bin|-m5 -l1000 -ia+ -ia-" \
            "nearcopy.bin|-m5 -l1000 -ia- -ia+" "nearcopy.bin|-m3 -l1024 -c128 -dl128 -ia-" \
            "nearcopy.bin|-m3 -l1024 -c128 -dl128 -ia+" "text.bin|-m3 -ia-"; do
    IFS='|' read -r f o <<<"$case"
    # shellcheck disable=SC2086
    diff_case_t1 "$TMP/$f" $o
done

say "-m3's read-ahead digest: pinned, because the C++ races there"
# a33929.bin and a200k.bin (one byte repeated) with -b261b/-b392b give -m3
# blocks that are not a whole number of 130-byte chunks. The scan of block k
# overshoots its last chunk by a few bytes, reads those bytes from block k+1,
# and its last add_hash compares the digest of chunk (block end)/L, which only
# block k+1's prepare_buffer writes (HashTable::prepare_ahead). In the C++
# both are written by the reading thread while the compressing thread runs
# block k (io.cpp:250-265), with nothing ordering the two, at every -t (-t1
# included), so 1.0.7's archive here changes between runs. Measured at -t1,
# 762 C++ runs per case (180 one after another, the rest 8 or 48 at a time;
# -m3f 800 more, 64 at a time), the pinned archive came out in:
#   a33929 -m3 -l130 -b261b       757 of 762 (the other 5: one other archive)
#   a33929 -m3 -l130 -b261b -a0   759 of 762 (the other 3: that same one)
#   a200k  -m3 -l130 -b392b       761 of 762
#   a200k  -m3o -l130 -b392b      761 of 762
#   a200k  -m3f -l130 -b392b      1561 of 1562
# The ports always take block k+1 fully read and prepared before block k is
# compressed. The pins are that archive (Rust and Pascal write it; it is the
# C++'s majority output above); a live C++ run here would fail now and then.
# They failed on f7ddd1f, whose ports read a zero digest there.
while read -r want f o; do
    rc=0
    # shellcheck disable=SC2086
    "$RS" $o --format=v4 --seed=7 "$TMP/$f" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err" || rc=$?
    [ "$rc" -le 1 ] || fail "port $o on $f exited $rc: $(tail -1 "$TMP/rs.err")"
    got="$(md5sum < "$TMP/rs.osr" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || fail "$o on $f: md5 $got, pinned $want (the C++'s majority archive)"
    "$RS" -d "$TMP/rs.osr" "$TMP/rs.dec" >/dev/null 2>&1 \
        || fail "$o on $f: the port could not decode its archive"
    "$CXX_BIN/osrep" -d "$TMP/rs.osr" "$TMP/cpp.dec" >/dev/null 2>&1 \
        || fail "$o on $f: the C++ could not decode the port's archive"
    cmp -s "$TMP/$f" "$TMP/rs.dec" || fail "$o on $f: round trip differs"
    cmp -s "$TMP/$f" "$TMP/cpp.dec" || fail "$o on $f: C++ decode differs"
    rm -f "$TMP/rs.osr" "$TMP/rs.dec" "$TMP/cpp.dec"
    pass=$((pass + 1))
done <<'EOF'
3bb728cac4f1991a5262935b783ace1b a33929.bin -m3 -l130 -b261b
3bb728cac4f1991a5262935b783ace1b a33929.bin -m3 -l130 -b261b -a0
790693374c6a276ede29ad58a11dc189 a200k.bin -m3 -l130 -b392b
07e20d42335672be6c2a3b3a32f45986 a200k.bin -m3o -l130 -b392b
5d0d1b127567b39e121e26b56f79dfcc a200k.bin -m3f -l130 -b392b
EOF

say "the second pass orders matches with one shared source the way the C++ does"
# srep.cpp:899 sorts the match list by `src` alone with libstdc++'s std::sort,
# which is not stable; the order of the ties is in the archive. tie10k (the
# smallest input found that shows it with default options) and noisy* (the
# reviewer's: a 4 KiB unit, 1-40 random bytes after ~5% of the copies) gave
# different bytes than 1.0.7 in every one of these with 2.2.1, Rust and Pascal
# alike; 2.3.0 transcribes std::sort. No -m2 here: the C++ -m2 is not
# deterministic on every input.
for input in "$TMP/tie10k.bin" "$TMP/noisy512k.bin" "$TMP/noisy2m.bin"; do
    for m in "" -m3 -m4 -m5 -m3f -m4f -m5f; do
        diff_case "$input" $m
    done
    diff_case "$input" -m4 -b1mb
done
diff_case "$TMP/noisy2m.bin" -m0

say "stdin/stdout: '-' is a pipe, not a file called '-'"
for m in m0 m3 m4 m4f m5o; do
    if ! "$CXX_BIN/osrep" -$m --seed=7 - - <tests/corpus/text.bin >"$TMP/cpp.pipe" 2>"$TMP/cpp.err"; then
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
# The default container through a pipe, with no -s. Until 2.1.2 the v5 header
# took its block count and size from the 25 gb stdin default while the footer
# recorded the real ones, so every such archive compressed with exit 0 and then
# refused to decompress -- silent data loss in the typical backup pipeline
# (`tar c dir | osrep - - > backup.osr`). The layer above pins --format=v4
# and never saw it.
for m in m3 m4 m5f m1; do
    "$RS" -$m --seed=7 - - <tests/corpus/text.bin >"$TMP/v5.pipe" 2>"$TMP/rs.err" \
        || fail "-$m: v5 through a pipe failed to compress: $(tail -1 "$TMP/rs.err")"
    "$RS" --verify "$TMP/v5.pipe" >/dev/null 2>&1 \
        || fail "-$m: a v5 archive written through a pipe does not --verify"
    "$RS" -d - - <"$TMP/v5.pipe" >"$TMP/v5.pipe.out" 2>/dev/null \
        || fail "-$m: a v5 archive written through a pipe does not decompress"
    cmp -s tests/corpus/text.bin "$TMP/v5.pipe.out" || fail "-$m: v5 piped round-trip differs"
    pass=$((pass + 1))
done
# `-sBYTES` smaller than what arrives on stdin. The match finder is sized from
# the declared value, so the longer input overran it: the C++ hangs, and the
# port panicked (exit 101) through 2.1.1. Now it is a command-line error that
# writes nothing; an exact or generous -s still round-trips.
text_size=$(stat -c%s tests/corpus/text.bin)
for fmt in "" "--format=v4"; do
    rc=0
    "$RS" $fmt --seed=7 -s1000 - - <tests/corpus/text.bin >"$TMP/s.pipe" 2>"$TMP/s.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "-s1000 ${fmt:-v5}: exit $rc, expected 2 ($(tail -1 "$TMP/s.err"))"
    [ ! -s "$TMP/s.pipe" ] || fail "-s1000 ${fmt:-v5}: wrote an archive anyway"
    for s in "$text_size" $((text_size * 3)); do
        "$RS" $fmt --seed=7 -s"$s" - - <tests/corpus/text.bin >"$TMP/s.pipe" 2>/dev/null \
            || fail "-s$s ${fmt:-v5}: compression failed"
        "$RS" -d - - <"$TMP/s.pipe" >"$TMP/s.out" 2>/dev/null \
            || fail "-s$s ${fmt:-v5}: does not decompress"
        cmp -s tests/corpus/text.bin "$TMP/s.out" || fail "-s$s ${fmt:-v5}: round-trip differs"
    done
    pass=$((pass + 1))
done
# `-` used to land on disk as a file with that name, which both hid the bug and
# made a naive test pass anyway.
[[ ! -e ./- ]] || fail "a file literally named '-' was created in the working directory"

say "an unknown option is refused, the way the C++ refuses it"
if "$RS" -m4 --seed=7 -bogus tests/corpus/text.bin "$TMP/a.osr" >/dev/null 2>&1; then
    fail "the port accepted -bogus"
fi
if "$CXX_BIN/osrep" -m4 --seed=7 -bogus tests/corpus/text.bin "$TMP/a.osr" >/dev/null 2>&1; then
    fail "the C++ accepted -bogus (the test is wrong, not the port)"
fi
pass=$((pass + 1))

say "a directory as the input is \"Can't open\", not an allocation abort"
# A directory opens on Unix and reports a huge size (i64::MAX on ext4), which
# sized the match finder: 2.2.0 aborted with exit 134 ("memory allocation of
# ... bytes failed"), and -m0 said "Io".
mkdir -p "$TMP/adir"
for m in -m3 -m0 -m1; do
    rc=0; "$RS" --seed=7 $m "$TMP/adir" "$TMP/dir.osr" 2>"$TMP/dir.err" >/dev/null || rc=$?
    [ "$rc" -eq 3 ] || fail "$m on a directory exited $rc, not 3"
    grep -q "Can't open $TMP/adir for read" "$TMP/dir.err" || fail "$m on a directory: $(cat "$TMP/dir.err")"
done
pass=$((pass + 1))

say "a non-ASCII -d part is an invalid option, not a panic"
# -d's parts were split after their first BYTE: "-dñ" cut the two-byte ñ in
# half and panicked (exit 101).
for a in "-dñ" "-d1m:ñ" "-dé5"; do
    rc=0; "$RS" "$a" tests/corpus/tiny.bin "$TMP/n.osr" 2>"$TMP/n.err" >/dev/null || rc=$?
    [ "$rc" -eq 2 ] || fail "$a exited $rc, not 2"
    grep -q "Invalid option: " "$TMP/n.err" || fail "$a: $(cat "$TMP/n.err")"
done
pass=$((pass + 1))

say "-dup: an archive the C++ can read, and the same payload inside v5"
for m in m3 m4 m5; do
    "$CXX_BIN/osrep" -dup -$m --seed=7 "$TMP/dup1m.bin" "$TMP/cpp.osr" >/dev/null 2>&1 \
        || fail "cpp -dup -$m failed"
    "$RS" -dup -$m --format=v4 --seed=7 "$TMP/dup1m.bin" "$TMP/rs.osr" >/dev/null 2>&1 \
        || fail "rust -dup -$m failed"
    cmp -s "$TMP/cpp.osr" "$TMP/rs.osr" || fail "-dup -$m: archives differ"
    # The C++ auto-detects the trailer of the Rust archive, and vice versa.
    "$CXX_BIN/osrep" -d "$TMP/rs.osr" "$TMP/cpp.dec" >/dev/null 2>&1 || fail "-dup -$m: C++ cannot decode the Rust archive"
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
    "$CXX_BIN/osrep" $c --seed=7 "$TMP/dup1m.bin" "$TMP/cpp.osr" >/dev/null 2>&1 \
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

say "-dup: a match that reaches back into an earlier block decodes"
# The future-LZ decoder reads a match of maximum_save bytes or more back from
# the output it has already written. dup::decode created that body file with
# File::create, write-only, so in 2.1.2 those archives failed with
# Decode(Io(Os { code: 9 .. "Bad file descriptor" })). -mem0 -vmblock=4k caps
# maximum_save at 4072 bytes, which text.bin at -b64k is full of; the C++
# (srep_main opens its output "w+b") never had the bug.
for fmt in "" "--format=v4"; do
    # shellcheck disable=SC2086
    "$RS" -v0 --seed=7 -b64k -dup $fmt tests/corpus/text.bin "$TMP/back.osr" >/dev/null 2>&1 \
        || fail "-dup -b64k $fmt: compress failed"
    "$RS" -v0 -d -mem0 -vmblock=4k "$TMP/back.osr" "$TMP/back.out" >/dev/null 2>"$TMP/back.err" \
        || fail "-dup -b64k $fmt: -d -mem0 -vmblock=4k failed: $(cat "$TMP/back.err")"
    cmp -s tests/corpus/text.bin "$TMP/back.out" || fail "-dup -b64k $fmt: round-trip differs"
    pass=$((pass + 1))
done

say "-i and --verify answer an endless input at once"
# Both parse the archive in memory, and 2.1.2 read the whole input before
# looking at its first bytes: /dev/zero (or a pipe that never closes) was read
# until memory ran out. Eight bytes that are neither the v5 magic nor the
# v1-v4 signatures settle it. The address space is capped so that a relapse
# fails here instead of taking the machine down.
if [ -c /dev/zero ]; then
    for m in -i --verify; do
        for src in "/dev/zero" "- </dev/zero"; do
            rc=0
            # shellcheck disable=SC2086
            (ulimit -v 1048576; eval timeout 20 '"$RS"' $m $src) >/dev/null 2>"$TMP/zero.err" || rc=$?
            name=${src%% *}
            [ "$rc" -eq 4 ] && grep -qxF "  ERROR! Not an Omega SREP compressed file (.osr): $name" "$TMP/zero.err" \
                || fail "$m $src: exit $rc, '$(cat "$TMP/zero.err")'"
        done
    done
    pass=$((pass + 1))
fi

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
OSREP_SEED_HEX=$SEED "$CXX_BIN/osrep" -m4 --seed=1 "$TMP/dup1m.bin" "$TMP/hexcpp.osr" >/dev/null 2>&1
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
rc=0; "$CXX_BIN/osrep" -d "$TMP/v5.osr" "$TMP/v5.out" >"$TMP/v5.err" 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "the C++ -d on a v5 archive exited $rc, expected 4 (bad data)"
grep -qi "not an omega srep compressed file" "$TMP/v5.err" \
    || fail "the C++ -d on a v5 archive did not say the file is not an .osr"
[ ! -s "$TMP/v5.out" ] \
    || fail "the C++ -d on a v5 archive produced $(stat -c%s "$TMP/v5.out") bytes of output"
rc=0; "$CXX_BIN/osrep" -i "$TMP/v5.osr" >"$TMP/v5i.err" 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "the C++ -i on a v5 archive exited $rc, expected 4 (bad data)"
grep -qi "not an omega srep compressed file" "$TMP/v5i.err" \
    || fail "the C++ -i on a v5 archive did not say the file is not an .osr"
pass=$((pass + 1))

say "-i agrees with the C++ on mode, hash and size"
for m in m3 m4f m5o; do
    "$CXX_BIN/osrep" -$m --seed=7 tests/corpus/text.bin "$TMP/cpp.osr" >/dev/null 2>&1
    "$RS" -i "$TMP/cpp.osr" >"$TMP/rs.info" 2>&1
    "$CXX_BIN/osrep" -i "$TMP/cpp.osr" >"$TMP/cpp.info" 2>&1
    head -1 "$TMP/rs.info" >"$TMP/rs.head"
    head -1 "$TMP/cpp.info" >"$TMP/cpp.head"
    cmp -s "$TMP/rs.head" "$TMP/cpp.head" \
        || fail "-$m: osrep -i disagrees: '$(cat "$TMP/rs.head")' vs '$(cat "$TMP/cpp.head")'"
    pass=$((pass + 1))
done

say "-i on a -dup archive: v4 (ODUP trailer, every container the C++ writes) and v5"
# 2.3.0 and earlier said "Not an Omega SREP compressed file" on a v4 -dup
# archive: the meta and the ODUP trailer sit after the archive, where Index-LZ
# looks for its footer and Future-LZ/I/O LZ for more blocks. The C++'s own -i
# fails on them too ("Not found ... footer" for Index-LZ, a bogus block size
# for the others), after printing the header line, which is the part both
# have to agree on. The size line is what -d writes, from the meta; the -dup
# line counts the meta's chunks and gives the body the blocks decode to.
# Gear chunking, so that the pass really drops chunks.
python3 - "$TMP/dupg.bin" <<'PY2'
import random, sys
r = random.Random(5)
u = bytes(r.randrange(256) for _ in range(1 << 17))
open(sys.argv[1], "wb").write(u * 12 + b"tail" * 100)
PY2
# The meta's own numbers: chunks, unique, body bytes, restored bytes.
dupmeta() {
    python3 - "$1" <<'PY2'
import struct, sys
b = open(sys.argv[1], "rb").read()
if b[:4] == b"OSR5":
    off, size = struct.unpack("<QI", b[-16:-4])
    m = b[off:off + size - 4]
else:
    size = struct.unpack("<Q", b[-12:-4])[0]
    m = b[len(b) - 12 - size:len(b) - 12]
chunks, unique = struct.unpack("<QQ", m[8:24])
p, lens, body, out = 24, [], 0, 0
for _ in range(chunks):
    tag = m[p]; p += 1
    if tag == 0:
        n = struct.unpack("<I", m[p:p + 4])[0]; p += 4
        lens.append(n); body += n; out += n
    else:
        v = s = 0
        while True:
            c = m[p]; p += 1; v |= (c & 0x7F) << s; s += 7
            if c < 0x80: break
        out += lens[v]
print(chunks, unique, body, out)
PY2
}
show3() { printf '%s' "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'; }
insize=$(stat -c%s "$TMP/dupg.bin")
for spec in "cxx -m3 Index-LZ" "cxx -m3f Future-LZ" "cxx -m4o I/O" "port4 -m3 Index-LZ" "port5 -m3 v5"; do
    set -- $spec
    rm -f "$TMP/di.osr" "$TMP/di.out"
    case "$1" in
        cxx)   "$CXX_BIN/osrep" -dup --chunk-hash=gear --seed=7 "$2" "$TMP/dupg.bin" "$TMP/di.osr" >/dev/null 2>&1 ;;
        port4) "$RS" -dup --chunk-hash=gear --format=v4 --seed=7 "$2" "$TMP/dupg.bin" "$TMP/di.osr" >/dev/null 2>&1 ;;
        port5) "$RS" -dup --chunk-hash=gear --seed=7 "$2" "$TMP/dupg.bin" "$TMP/di.osr" >/dev/null 2>&1 ;;
    esac || fail "-dup $spec: compress failed"
    "$RS" -d "$TMP/di.osr" "$TMP/di.out" >/dev/null 2>&1 && cmp -s "$TMP/dupg.bin" "$TMP/di.out" \
        || fail "-dup $spec: does not round-trip"
    read -r chunks unique body restored <<<"$(dupmeta "$TMP/di.osr")"
    [ "$restored" -eq "$insize" ] && [ "$unique" -lt "$chunks" ] \
        || fail "-dup $spec: the meta does not dedup ($chunks/$unique/$restored)"
    rc=0; "$RS" -i "$TMP/di.osr" >/dev/null 2>"$TMP/di.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "-i on -dup $spec: exit $rc, '$(cat "$TMP/di.err")'"
    arch=$(stat -c%s "$TMP/di.osr")
    grep -qF ".  $(show3 "$insize") -> $(show3 "$arch"): " "$TMP/di.err" \
        || fail "-i on -dup $spec: no size line for $insize -> $arch: '$(cat "$TMP/di.err")'"
    want="-dup: $(show3 "$chunks") chunks, $(show3 "$unique") unique: $(show3 "$insize") -> $(show3 "$body") bytes"
    grep -qxF -- "$want" "$TMP/di.err" || fail "-i on -dup $spec: no '$want' in '$(cat "$TMP/di.err")'"
    case "$3" in
        v5) head -1 "$TMP/di.err" | grep -qxF "v5: -hash=vmac" || fail "-i on -dup $spec: header '$(head -1 "$TMP/di.err")'" ;;
        *)  "$CXX_BIN/osrep" -i "$TMP/di.osr" >/dev/null 2>"$TMP/dic.err" || true
            chead=$(head -1 "$TMP/dic.err")
            case "$chead" in "$3"*) ;; *) fail "-i on -dup $spec: the C++ header is '$chead'" ;; esac
            [ "$(head -c ${#chead} "$TMP/di.err")" = "$chead" ] \
                || fail "-i on -dup $spec: header '$(head -1 "$TMP/di.err")', the C++ says '$chead'" ;;
    esac
    # --verify answers what it answers for any v1-v4 archive.
    if [ "$3" != v5 ]; then
        rc=0; "$RS" --verify "$TMP/di.osr" >/dev/null 2>"$TMP/di.err" || rc=$?
        [ "$rc" -eq 2 ] && grep -qF "is a v1-v4 archive" "$TMP/di.err" \
            || fail "--verify on -dup $spec: exit $rc, '$(cat "$TMP/di.err")'"
    fi
    pass=$((pass + 1))
done
# A trailer -d refuses is one -i refuses: a meta_size past the file, a meta
# that is not DUPR, a reference to a chunk not yet seen.
"$CXX_BIN/osrep" -dup --chunk-hash=gear --seed=7 -m3 "$TMP/dupg.bin" "$TMP/di.osr" >/dev/null 2>&1
python3 - "$TMP/di.osr" "$TMP" <<'PY2'
import struct, sys
b = open(sys.argv[1], "rb").read(); d = sys.argv[2]
size = struct.unpack("<Q", b[-12:-4])[0]; at = len(b) - 12 - size
open(d + "/bad1.osr", "wb").write(b[:-12] + struct.pack("<Q", len(b)) + b"ODUP")
m = bytearray(b); m[at] ^= 1; open(d + "/bad2.osr", "wb").write(bytes(m))
m = bytearray(b); p = at + 24
while m[p] == 0: p += 5
m[p + 1] = 0x7F; open(d + "/bad3.osr", "wb").write(bytes(m))
PY2
for f in bad1 bad2 bad3; do
    rc=0; "$RS" -d "$TMP/$f.osr" "$TMP/di.out" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "-d accepted the broken -dup trailer $f"
    rc=0; "$RS" -i "$TMP/$f.osr" >/dev/null 2>"$TMP/di.err" || rc=$?
    [ "$rc" -eq 4 ] && grep -qxF "  ERROR! Not an Omega SREP compressed file (.osr): $TMP/$f.osr" "$TMP/di.err" \
        || fail "-i on the broken -dup trailer $f: exit $rc, '$(cat "$TMP/di.err")'"
done
pass=$((pass + 1))

say "-i on the plain archive of a file that ends in \"ODUP\", and on a -dup archive of one"
# A Future-LZ or I/O LZ archive ends in its last literals, so the archive of a
# v4 -dup archive ends in that archive's own trailer, meta and all. -i reads
# behind a trailer only when the archive there holds up; otherwise it reads
# the whole file as a plain archive, as the C++'s -i does. The -dup archive of
# a -dup archive has a real trailer, and is described through it.
"$RS" -dup --format=v4 --seed=7 tests/corpus/text.bin "$TMP/in4.osr" >/dev/null 2>&1 \
    || fail "ODUP input: compress failed"
[ "$(tail -c 4 "$TMP/in4.osr")" = ODUP ] || fail "ODUP input: the -dup archive does not end in ODUP"
"$RS" --format=v4 --seed=7 -m3f "$TMP/in4.osr" "$TMP/od.osr" >/dev/null 2>&1 || fail "ODUP input -m3f: compress failed"
[ "$(tail -c 4 "$TMP/od.osr")" = ODUP ] || fail "ODUP input -m3f: the archive does not end in ODUP"
"$RS" -dup --format=v4 --seed=7 "$TMP/in4.osr" "$TMP/nest.osr" >/dev/null 2>&1 || fail "nested -dup: compress failed"
for spec in "od Future-LZ" "nest Index-LZ"; do
    set -- $spec
    rc=0; "$RS" -i "$TMP/$1.osr" >/dev/null 2>"$TMP/od.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "-i on $1.osr: exit $rc, '$(cat "$TMP/od.err")'"
    "$CXX_BIN/osrep" -i "$TMP/$1.osr" >/dev/null 2>"$TMP/odc.err" || true
    chead=$(head -1 "$TMP/odc.err")
    case "$chead" in "$2"*) ;; *) fail "-i on $1.osr: the C++ header is '$chead'" ;; esac
    [ "$(head -c ${#chead} "$TMP/od.err")" = "$chead" ] \
        || fail "-i on $1.osr: header '$(head -1 "$TMP/od.err")', the C++ says '$chead'"
    case "$1" in
        od) grep -q '^-dup: ' "$TMP/od.err" && fail "-i on od.osr: a -dup line for a plain archive" ;;
        nest) grep -q '^-dup: ' "$TMP/od.err" || fail "-i on nest.osr: no -dup line" ;;
    esac
    grep -qF ".  $(show3 "$(stat -c%s "$TMP/in4.osr")") -> " "$TMP/od.err" \
        || fail "-i on $1.osr: the size line is not the inner archive's size: '$(cat "$TMP/od.err")'"
    rc=0; "$RS" --verify "$TMP/$1.osr" >/dev/null 2>"$TMP/od.err" || rc=$?
    [ "$rc" -eq 2 ] && grep -qF "is a v1-v4 archive" "$TMP/od.err" \
        || fail "--verify on $1.osr: exit $rc, '$(cat "$TMP/od.err")'"
    pass=$((pass + 1))
done

say "-i on Future-LZ and I/O LZ: the size line, and the C++'s summary line"
# The C++ prints its decoder's progress line there (timings included), then
# the same "Decompression memory ..." summary as for Index-LZ; 2.3.0 printed
# the header line alone. The summary is compared as written: the RAM figure is
# a placeholder in the port, and these inputs need none.
for m in m3f m3o m5f m1o m0f; do
    "$CXX_BIN/osrep" -$m --seed=7 tests/corpus/text.bin "$TMP/cpp.osr" >/dev/null 2>&1
    "$RS" -i "$TMP/cpp.osr" >/dev/null 2>"$TMP/rs.info" || fail "-$m: -i failed: $(cat "$TMP/rs.info")"
    "$CXX_BIN/osrep" -i "$TMP/cpp.osr" >/dev/null 2>"$TMP/cpp.info"
    arch=$(stat -c%s "$TMP/cpp.osr"); insize=$(stat -c%s tests/corpus/text.bin)
    [ "$(sed -n 2p "$TMP/rs.info")" = ".  $(show3 "$insize") -> $(show3 "$arch"): $(python3 -c "print('%.2f' % ($arch * 100 / $insize))")%" ] \
        || fail "-$m: -i size line '$(sed -n 2p "$TMP/rs.info")'"
    [ "$(sed -n 3p "$TMP/rs.info")" = "$(grep -a '^Decompression memory' "$TMP/cpp.info")" ] \
        || fail "-$m: -i summary '$(sed -n 3p "$TMP/rs.info")' vs the C++'s '$(grep -a '^Decompression memory' "$TMP/cpp.info")'"
    pass=$((pass + 1))
done

say "-i -index=: the lists come from the index, as in the C++"
# The C++ reads each block's list from the index named on the command line;
# 2.3.0 ignored -index= and called the archive "Not an Omega SREP". Without
# the index such an archive does not parse (its block headers announce lists
# that are not there), and a short index is the C++'s "unexpected end".
for m in m3f m5o; do
    rm -f "$TMP/ix.osr" "$TMP/ix.ix"
    "$CXX_BIN/osrep" -$m --seed=7 -b1mb -index="$TMP/ix.ix" tests/corpus/mixed.bin "$TMP/ix.osr" >/dev/null 2>&1
    "$RS" -i -index="$TMP/ix.ix" "$TMP/ix.osr" >/dev/null 2>"$TMP/rs.info" || fail "-$m -index=: -i failed: $(cat "$TMP/rs.info")"
    "$CXX_BIN/osrep" -i -index="$TMP/ix.ix" "$TMP/ix.osr" >/dev/null 2>"$TMP/cpp.info"
    [ "$(head -1 "$TMP/rs.info")" = "$(head -1 "$TMP/cpp.info")" ] || fail "-$m -index=: -i header differs"
    grep -qF ".  $(show3 "$(stat -c%s tests/corpus/mixed.bin)") -> " "$TMP/rs.info" \
        || fail "-$m -index=: -i size line '$(sed -n 2p "$TMP/rs.info")'"
    # The match count and the stat bytes; the C++ measures the RAM, the port does not.
    [ "$(sed -n 3p "$TMP/rs.info" | sed 's/is [0-9]* mb/is N mb/')" = \
      "$(grep -a '^Decompression memory' "$TMP/cpp.info" | sed 's/is [0-9]* mb/is N mb/')" ] \
        || fail "-$m -index=: -i summary '$(sed -n 3p "$TMP/rs.info")' vs '$(grep -a '^Decompression memory' "$TMP/cpp.info")'"
    rc=0; "$RS" -i "$TMP/ix.osr" >/dev/null 2>"$TMP/rs.info" || rc=$?
    [ "$rc" -eq 4 ] || fail "-$m: -i without its index exited $rc"
    head -c 10 "$TMP/ix.ix" > "$TMP/short.ix"
    rc=0; "$RS" -i -index="$TMP/short.ix" "$TMP/ix.osr" >/dev/null 2>"$TMP/rs.info" || rc=$?
    [ "$rc" -eq 4 ] && grep -qxF "  ERROR! Decompression problem: unexpected end of file $TMP/short.ix or I/O error" "$TMP/rs.info" \
        || fail "-$m: -i with a short index: exit $rc, '$(cat "$TMP/rs.info")'"
    rc=0; "$RS" -i -index="$TMP/none.ix" "$TMP/ix.osr" >/dev/null 2>"$TMP/rs.info" || rc=$?
    [ "$rc" -eq 3 ] && grep -qxF "  ERROR! Can't open index file $TMP/none.ix for read" "$TMP/rs.info" \
        || fail "-$m: -i with a missing index: exit $rc, '$(cat "$TMP/rs.info")'"
    pass=$((pass + 1))
done

say "the CLI suite, with OSREP_BIN pointed at the Rust binary"
# `futurelz_race_regression.sh` repeats 150x per case in the C++ gate; here the
# point is that the CLI plumbing is right, not the race (which is a C++ bug the
# Rust port cannot have).
say "-index=: the match lists in a second file, byte for byte against the C++"
# `-index=` moves the per-block match lists out of the archive (`fstat`,
# srep.cpp:606). Both files have to match the oracle, not just the archive:
# an index that differs is an archive that cannot be decoded by the other
# implementation, which is exactly what the cross-checks below catch.
for m in m1f m3f m5f m1o m3o m5o; do
    rm -f "$TMP/ix_c.osr" "$TMP/ix_c.ix" "$TMP/ix_r.osr" "$TMP/ix_r.ix"
    "$CXX_BIN/osrep" --seed=7 "-$m" -index="$TMP/ix_c.ix" tests/corpus/text.bin "$TMP/ix_c.osr" >/dev/null 2>&1 \
        || fail "the C++ could not write an index for -$m"
    "$RS" --format=v4 --seed=7 "-$m" -index="$TMP/ix_r.ix" tests/corpus/text.bin "$TMP/ix_r.osr" >/dev/null 2>&1 \
        || fail "the port could not write an index for -$m"
    cmp -s "$TMP/ix_c.osr" "$TMP/ix_r.osr" || fail "-$m -index=: archives differ"
    cmp -s "$TMP/ix_c.ix"  "$TMP/ix_r.ix"  || fail "-$m -index=: index files differ"

    # Each implementation must read the other's pair, or the split format is
    # only self-consistent.
    "$RS" -d -index="$TMP/ix_c.ix" "$TMP/ix_c.osr" "$TMP/ix_a.out" >/dev/null 2>&1 \
        || fail "-$m -index=: the port could not decode the C++'s archive"
    cmp -s tests/corpus/text.bin "$TMP/ix_a.out" || fail "-$m -index=: port decoded the C++ archive wrongly"
    "$CXX_BIN/osrep" -d -index="$TMP/ix_r.ix" "$TMP/ix_r.osr" "$TMP/ix_b.out" >/dev/null 2>&1 \
        || fail "-$m -index=: the C++ could not decode the port's archive"
    cmp -s tests/corpus/text.bin "$TMP/ix_b.out" || fail "-$m -index=: C++ decoded the port archive wrongly"
    pass=$((pass + 1))
done

say "-index= is refused for the container that cannot read it back"
# The default (Index-LZ) decoder finds its match lists by seeking in the
# archive and never consults the index, so an archive written this way used to
# compress with exit 0 and then fail to decompress -- silent data loss. Both
# binaries now refuse it up front.
for bin in "$CXX_BIN/osrep" "$RS"; do
    rc=0; "$bin" -m3 -index="$TMP/ix_no.ix" tests/corpus/text.bin "$TMP/ix_no.osr" >"$TMP/ix_no.err" 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "$bin -m3 -index= exited $rc, expected 2 (cmdline)"
    grep -qi "index" "$TMP/ix_no.err" || fail "$bin -m3 -index= did not explain itself"
    [ ! -s "$TMP/ix_no.osr" ] || fail "$bin -m3 -index= left an archive behind"
done
pass=$((pass + 1))

say "a chunk length below the slice width is a command-line error, not SIGFPE"
# `SliceHash` computes `slice_size = L/8` and then divides by it
# (hash_table.cpp:32-34), so -c1..-c7 used to be a division by zero: SIGFPE
# (exit 136) in the C++ and a panic (exit 101) in the port, both with no
# message. -c0 means "not given" and must still take the default.
for n in 1 4 7; do
    for bin in "$CXX_BIN/osrep" "$RS"; do
        rc=0; "$bin" "-c$n" -m3 tests/corpus/text.bin "$TMP/c.osr" >"$TMP/c.err" 2>&1 || rc=$?
        [ "$rc" -eq 2 ] || fail "$bin -c$n exited $rc, expected 2 (cmdline)"
    done
    pass=$((pass + 1))
done
for n in 0 8; do
    for bin in "$CXX_BIN/osrep" "$RS"; do
        rc=0; "$bin" "-c$n" -m3 tests/corpus/text.bin "$TMP/c.osr" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 0 ] || fail "$bin -c$n exited $rc, expected 0"
    done
    pass=$((pass + 1))
done

say "an -l that leaves the match finder an empty slice is a command-line error, not a panic"
# Without -c, -l also sets the chunk L (srep.cpp:466-470): L = -l for -m1..-m4,
# and for -m5 the power of two below -l+1, halved -- so -l8..-l14 give -m5 an
# L of 4. Any L below 8 is the same division by zero as -c1..-c7 above: the
# C++ dies with SIGFPE (exit 136) and the port panicked (exit 101, 2.1.2) or,
# in Pascal, printed "Division by zero" (exit 4). Only the port is checked:
# the oracle still crashes here.
small_l_case() {
    local m="$1" n="$2" least="$3"
    rc=0; "$RS" --seed=7 "$m" "-l$n" tests/corpus/text.bin "$TMP/sl.osr" >"$TMP/sl.out" 2>"$TMP/sl.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "$m -l$n exited $rc, expected 2 (cmdline)"
    local want="  ERROR! Invalid option: -l$n -- with ${m:0:3} the match length must be 0 (default) or at least $least bytes"
    grep -qxF -- "$want" "$TMP/sl.err" || fail "$m -l$n: stderr is not '$want': $(cat "$TMP/sl.err")"
    [ ! -s "$TMP/sl.osr" ] || fail "$m -l$n left an archive behind"
    pass=$((pass + 1))
}
rm -f "$TMP/sl.osr"
for n in 1 4 7; do
    for m in -m1 -m2 -m3 -m4 -m3o -m4f; do small_l_case "$m" "$n" 8; done
done
for n in 1 4 8 12 14; do
    for m in -m5 -m5o -m5f; do small_l_case "$m" "$n" 15; done
done
# The smallest -l each method takes, -m0 (no match finder) with any -l, and an
# explicit -c (which sets L itself) must all still work and round-trip.
for args in "-m4 -l8" "-m2 -l8" "-m5 -l15" "-m5o -l15" "-m0 -d4mb -l4" "-m5 -c8 -l4" "-m4 -c16 -l4"; do
    rc=0; "$RS" --seed=7 $args tests/corpus/text.bin "$TMP/sl.osr" >/dev/null 2>"$TMP/sl.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$args exited $rc, expected 0: $(tail -1 "$TMP/sl.err")"
    "$RS" -d "$TMP/sl.osr" "$TMP/sl.dec" >/dev/null 2>&1 || fail "$args: archive does not decode"
    cmp -s tests/corpus/text.bin "$TMP/sl.dec" || fail "$args: round trip differs"
    rm -f "$TMP/sl.osr" "$TMP/sl.dec"
    pass=$((pass + 1))
done

say "unusual -l/-c values keep the match finder inside its buffers"
# Three reads that left their arrays in 2.1.2 (exit 101; the C++ reads or
# writes outside its allocations instead, and the Pascal did the same without
# noticing):
#   * -m5 with an -l just under a power of two (-l1000 -> L 256): the slice
#     check walks 22 slices, not the 8 one entry holds, so near the ends of the
#     ring it hashed bytes outside it. Such a slice now counts as a mismatch.
#   * -l/-c not a power of two (-l17 -m4, -c17 -m5): the last chunk number
#     reached the end of hasharr, and the 4-byte batch read up to 3 bytes past
#     a full block in the ring's last slot. Both arrays now have room.
# The archives are pinned, and all nine are also what 1.0.7 writes on the
# x86-64 reference machine. The -l17/-c17 pins moved in 2.3.0: L 17 gives
# accel 1, and the C++ runs compress<1> (the bitarr-filtered scan) there, not
# the compress<0> that 2.2.x ran; before, they differed from 1.0.7.
python3 - "$TMP" <<'PY'
import os, random, sys
# A 4 KiB unit repeated, with a short random run after ~5% of the copies:
# periodic enough that the slice check passes slice after slice, broken
# enough that candidates are probed up to the end of every block.
r = random.Random(20261009)
unit = bytes(r.randrange(256) for _ in range(4096))
out = bytearray()
while len(out) < 2 << 20:
    out += unit
    if r.random() < 0.05:
        out += bytes(r.randrange(256) for _ in range(r.randint(1, 40)))
open(os.path.join(sys.argv[1], "noisy2m.bin"), "wb").write(out[:2 << 20])
PY
while read -r want input args; do
    rc=0; "$RS" --format=v4 --seed=7 $args "$input" "$TMP/ob.osr" >/dev/null 2>"$TMP/ob.err" || rc=$?
    # -l17 with -m4 also earns the power-of-two warning, which is exit 1.
    [ "$rc" -le 1 ] || fail "$args on $input exited $rc: $(grep -a -m1 -E 'panicked|ERROR' "$TMP/ob.err")"
    got="$(md5sum < "$TMP/ob.osr" | cut -c1-32)"
    [ "$got" = "$want" ] || fail "$args on $input: archive md5 $got, expected $want"
    "$RS" -d "$TMP/ob.osr" "$TMP/ob.dec" >/dev/null 2>&1 || fail "$args on $input: archive does not decode"
    cmp -s "$input" "$TMP/ob.dec" || fail "$args on $input: round trip differs"
    rm -f "$TMP/ob.osr" "$TMP/ob.dec"
    pass=$((pass + 1))
done <<EOF
2f2b286c8c0f85a7d06869935a93a6b3 tests/corpus/tiny.bin -m5 -l1000
a1cf9353f86601ddb899f36aaf2353da tests/corpus/tiny.bin -m5o -l1000
720fe49b06f40483a1389c5fb660318b tests/corpus/tiny.bin -m5f -l1000
b4ed8daf9deaefbec2cbd9f18122e52d $TMP/noisy2m.bin -m5 -l1000 -b1mb
e3a9a4e95ed57711cc8013d74db62746 $TMP/noisy2m.bin -m5o -l1000 -b1mb
46b4ce95087359a552ee65b038e2ad85 $TMP/noisy2m.bin -m5f -l2000 -b1mb
983d886bc4287933468ca4738095feae tests/corpus/text.bin -m4 -l17 -b1mb
983d886bc4287933468ca4738095feae tests/corpus/text.bin -m5 -c17 -b1mb
f6c1579ce5fac9a5c6fd42b29ddb9d6e tests/corpus/random.bin -m4 -l9
EOF

say "-m3's digest check stays inside the ring with an -l/-c that is not a power of two"
# The 4-byte batch overshoots its chunk by up to three positions when 4 does
# not divide L, and -m3 hashes the L bytes at each candidate: with a full block
# in the ring's last slot (-b4kb, no -d: a two-block ring) that window ends up
# to three bytes past the ring. 2.1.2 panicked there (exit 101, "range end
# index ... out of range"); those bytes now read as zero, as the Pascal port's
# zeroed ring tail always had them. The archives are pinned (Rust and Pascal
# agree); they keep the power-of-two warning, exit 1. Through 2.2.0 they did
# not decode (-b4kb is not a multiple of 17, so the blocks after the first
# start off the chunk grid, as in 1.0.7); now they do -- see
# tests/m3_grid_regress.sh below. The pins moved in 2.3.0: L 17 runs the C++'s
# compress<1> (the bitarr-filtered scan) instead of compress<0>, and add_hash
# compares the -m3 digests; the archives still decode, with the C++ too.
while read -r want args; do
    rc=0; "$RS" --format=v4 --seed=7 $args tests/corpus/text.bin "$TMP/dg.osr" >/dev/null 2>"$TMP/dg.err" || rc=$?
    [ "$rc" -eq 1 ] || fail "$args exited $rc, expected 1 (warning): $(grep -a -m1 -E 'panicked|ERROR' "$TMP/dg.err")"
    got="$(md5sum < "$TMP/dg.osr" | cut -c1-32)"
    [ "$got" = "$want" ] || fail "$args: archive md5 $got, expected $want"
    "$RS" -d "$TMP/dg.osr" "$TMP/dg.dec" >/dev/null 2>&1 || fail "$args: archive does not decode"
    cmp -s tests/corpus/text.bin "$TMP/dg.dec" || fail "$args: round trip differs"
    rm -f "$TMP/dg.osr" "$TMP/dg.dec"
    pass=$((pass + 1))
done <<EOF
3da714f1149c046323c45229ef6f6fcf -m3 -l17 -b4kb
3da714f1149c046323c45229ef6f6fcf -m3 -c17 -b4kb
bcb8084698e36d5b0fe28dddd07a1aa8 -m3o -l17 -b4kb
61c98db3cd9ffaff74847c941690e85c -m3f -l17 -b4kb
EOF

say "-l, -c, -dl and -dc above 4294967295 are refused, not wrapped or overflowed"
# The C++ keeps all four in an unsigned (srep.cpp:292): -l4294967296 is -l0
# there. 2.1.2 took them whole -- -l2^63 and up panicked in the match finder
# (2 * L), -m5 -l2^64-1 overflowed -l + 1 to an L of 0 and divided by zero --
# and the i686 build truncated them to 32 bits, so the two builds wrote
# different archives. The largest value still works.
big_case() {
    local want="$1"; shift
    rc=0; "$RS" --seed=7 "$@" tests/corpus/tiny.bin "$TMP/bg.osr" >/dev/null 2>"$TMP/bg.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "$* exited $rc, expected 2 (cmdline)"
    grep -qxF -- "  ERROR! $want" "$TMP/bg.err" || fail "$*: stderr is not '$want': $(cat "$TMP/bg.err")"
    [ ! -s "$TMP/bg.osr" ] || fail "$* left an archive behind"
    rm -f "$TMP/bg.osr"
    pass=$((pass + 1))
}
big_case "Invalid option: -l9223372036854775808 -- the match length must be at most 4294967295 bytes" -m3 -l9223372036854775808
big_case "Invalid option: -l18446744073709551615 -- the match length must be at most 4294967295 bytes" -m5 -l18446744073709551615
big_case "Invalid option: -l4294967296 -- the match length must be at most 4294967295 bytes" -m4 -l4294967296
big_case "Invalid option: -c4294967296 -- the chunk length must be at most 4294967295 bytes" -m4 -c4294967296
big_case "Invalid option: -dl4294967296 -- the dictionary match length must be at most 4294967295 bytes" -m0 -d1mb:l4294967296
big_case "Invalid option: -dc99999999999 -- the dictionary chunk length must be at most 4294967295 bytes" -m0 -dc99999999999
for args in "-m5 -l4294967295" "-m4 -l4294967295" "-m4 -c4294967295" "-m0 -d1mb:l4294967295" "-m0 -d1mb:c4294967295"; do
    rc=0; "$RS" --seed=7 $args tests/corpus/tiny.bin "$TMP/bg.osr" >/dev/null 2>"$TMP/bg.err" || rc=$?
    [ "$rc" -le 1 ] || fail "$args exited $rc: $(tail -1 "$TMP/bg.err")"
    "$RS" -d "$TMP/bg.osr" "$TMP/bg.dec" >/dev/null 2>&1 || fail "$args: archive does not decode"
    cmp -s tests/corpus/tiny.bin "$TMP/bg.dec" || fail "$args: round trip differs"
    rm -f "$TMP/bg.osr" "$TMP/bg.dec"
    pass=$((pass + 1))
done

say "an in-memory dictionary chunk of zero is a command-line error, not a division by zero"
# The dictionary hashes -dc chunks, -dl/8 without -dc, and sizes its table by
# dictsize/chunk: -dl1..-dl7 without -dc divided by zero whenever the
# dictionary is on (-m0, or -d with -m3..-m5). The C++ dies with SIGFPE, 2.1.2
# panicked, the Pascal printed "Division by zero" (exit 4).
for args in "-m0 -dl4" "-m3 -d1mb:l7" "-m5 -d1mb:c0:l1" "-m4f -d4mb:l4"; do
    rc=0; "$RS" --seed=7 $args tests/corpus/tiny.bin "$TMP/dw.osr" >/dev/null 2>"$TMP/dw.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "$args exited $rc, expected 2 (cmdline)"
    n="$(printf '%s' "$args" | grep -o 'l[0-9]*$')"
    want="  ERROR! Invalid option: -d$n -- without -dc the dictionary match length must be 0 (default) or at least 8 bytes"
    grep -qxF -- "$want" "$TMP/dw.err" || fail "$args: stderr is not '$want': $(cat "$TMP/dw.err")"
    rm -f "$TMP/dw.osr"
    pass=$((pass + 1))
done
# With -dc, or without a dictionary (-dl then only sets the record base), any
# -dl still works.
for args in "-m0 -d1mb:c1:l4" "-m0 -dc8 -dl4" "-m4 -dl4" "-m0 -dl8"; do
    rc=0; "$RS" --seed=7 $args tests/corpus/text.bin "$TMP/dw.osr" >/dev/null 2>"$TMP/dw.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$args exited $rc, expected 0: $(tail -1 "$TMP/dw.err")"
    "$RS" -d "$TMP/dw.osr" "$TMP/dw.dec" >/dev/null 2>&1 || fail "$args: archive does not decode"
    cmp -s tests/corpus/text.bin "$TMP/dw.dec" || fail "$args: round trip differs"
    rm -f "$TMP/dw.osr" "$TMP/dw.dec"
    pass=$((pass + 1))
done

say "an in-memory dictionary hash table under 8 bytes gets one slot, not a crash"
# -dh is in bytes, rounded up to a power of two, and the table holds
# hashsize/8 eight-byte slots: -dh1b..-dh4b gave a table of zero slots whose
# mask wrapped to all ones. The C++ dies with SIGSEGV, 2.2.0's Rust panicked
# (exit 101) and its Pascal printed "Access violation" (exit 4). They now get
# the single slot -dh5b..-dh8b get, so they write -dh8b's archive.
for args in "-m0 -dh1b" "-m0 -dh4b" "-m3 -d64kb -dh2b" "-m5 -d1mb -dh3b" "-dup -m4 -d1mb -dh1b"; do
    ref="${args% -dh*} -dh8b"
    "$RS" --seed=7 $ref tests/corpus/text.bin "$TMP/dh8.osr" >/dev/null 2>&1 || fail "$ref failed"
    rc=0; "$RS" --seed=7 $args tests/corpus/text.bin "$TMP/dh.osr" >/dev/null 2>"$TMP/dh.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$args exited $rc, expected 0: $(tail -1 "$TMP/dh.err")"
    cmp -s "$TMP/dh8.osr" "$TMP/dh.osr" || fail "$args: archive differs from $ref"
    rm -f "$TMP/dh.dec"
    "$RS" -d "$TMP/dh.osr" "$TMP/dh.dec" >/dev/null 2>&1 || fail "$args: archive does not decode"
    cmp -s tests/corpus/text.bin "$TMP/dh.dec" || fail "$args: round trip differs"
    rm -f "$TMP/dh.osr" "$TMP/dh8.osr" "$TMP/dh.dec"
    pass=$((pass + 1))
done

say "-dup with --chunk-* the chunker cannot use is a command-line error"
# avg 0, min 0 or max below min used to start the run and fail inside the
# encoder with "dedup failed, rc=8" (exit 4).
dup_bad() {
    local want="$1"; shift
    rc=0; "$RS" --seed=7 "$@" tests/corpus/text.bin "$TMP/cb.osr" >/dev/null 2>"$TMP/cb.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "$* exited $rc, expected 2 (cmdline): $(tail -1 "$TMP/cb.err")"
    grep -qxF -- "  ERROR! $want" "$TMP/cb.err" || fail "$*: stderr is not '$want': $(cat "$TMP/cb.err")"
    [ ! -s "$TMP/cb.osr" ] || fail "$* left an archive behind"
    rm -f "$TMP/cb.osr"
    pass=$((pass + 1))
}
dup_bad "Invalid option: --chunk-avg=0 -- the average chunk size must be at least 1 byte" -dup --chunk-avg=0
dup_bad "Invalid option: --chunk-min=0 -- the minimum chunk size must be at least 1 byte" -dup -m3 --chunk-min=0
dup_bad "Invalid option: --chunk-max=10 -- the maximum chunk size must be at least --chunk-min (20 bytes)" \
    -dup --chunk-min=20 --chunk-max=10
dup_bad "Invalid option: --chunk-max=16384 -- the maximum chunk size must be at least --chunk-min (20000 bytes)" \
    -dup --dup-paranoid --chunk-min=20000
# Without -dup the --chunk-* options are not used, and are still accepted.
rc=0; "$RS" --seed=7 -m3 --chunk-avg=0 --chunk-min=0 tests/corpus/text.bin "$TMP/cb.osr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "--chunk-avg=0 without -dup exited $rc, expected 0"
rm -f "$TMP/cb.osr"
pass=$((pass + 1))

say "-m5 with an -c that is not a power of two warns and exits 1, like the C++"
# srep.cpp:476 tests the final L: always a power of two for -m5 without -c,
# but -c sets it directly. 2.1.2 skipped the test for -m5 altogether and
# exited 0 in silence.
# Against the C++ where it survives the run (it dies with SIGBUS on other odd
# -c values with this input), and on the expected exit and warning otherwise.
for args in "-m5 -c17" "-m5 -c16" "-m5 -l17" "-m5 -c16 -l17"; do
    rc_c=0; "$CXX_BIN/osrep" $args tests/corpus/tiny.bin "$TMP/w5c.osr" >/dev/null 2>"$TMP/w5c.err" || rc_c=$?
    rc=0; "$RS" --seed=7 $args tests/corpus/tiny.bin "$TMP/w5.osr" >/dev/null 2>"$TMP/w5.err" || rc=$?
    [ "$rc" -eq "$rc_c" ] || fail "$args exited $rc, the C++ $rc_c"
    w_c="$(grep -ac 'power of 2' "$TMP/w5c.err" || true)"
    w="$(grep -ac 'power of 2' "$TMP/w5.err" || true)"
    [ "$w" = "$w_c" ] || fail "$args: $w power-of-two warnings, the C++ printed $w_c"
    rm -f "$TMP/w5c.osr" "$TMP/w5.osr"
    pass=$((pass + 1))
done
for args in "-m5 -c100" "-m5f -c24" "-m5o -c4100"; do
    rc=0; "$RS" --seed=7 $args tests/corpus/text.bin "$TMP/w5.osr" >/dev/null 2>"$TMP/w5.err" || rc=$?
    [ "$rc" -eq 1 ] || fail "$args exited $rc, expected 1 (warning)"
    grep -qxF "Warning: -l parameter should be power of 2, otherwise compressed file may be corrupt" "$TMP/w5.err" \
        || fail "$args: no power-of-two warning"
    rm -f "$TMP/w5.osr"
    pass=$((pass + 1))
done

say "-m3 with a BASE_LEN that does not divide the chunk writes archives that decode"
# Without -d, -m3 stores offsets and lengths in units of BASE_LEN (min(-l,
# -dl)), not of the chunk L (ENCODE_LZ_MATCH's L1, srep.cpp:117). With -c
# below BASE_LEN (-c8 -l16), or a BASE_LEN that does not divide L (-c8 -l17,
# -dl17), 1.0.7 and 2.1.2 wrote archives that exit 0 and do not decode, or
# stopped with "match len too small" (exit 4) -- every -l from 17 to 498 with
# -m3 -c8 did one or the other on the inputs tried. A match is now moved to
# the BASE_LEN grid and cut to whole units; matches that already were exact
# (BASE_LEN dividing L, the default) are untouched, so -c512 -l1024 keeps the
# archive it always had. The two txtmut200k pins moved in 2.3.0 (-l17 was
# 359c59db0e1ac1cd62233c72ee3c6510, -l100 was 2a7800ab8a72d5a064168742eb402a10):
# their second pass has matches with equal sources, now ordered as libstdc++'s
# std::sort orders them. Same sizes; Rust and Pascal agree.
python3 - "$TMP" <<'PY'
import os, random, sys
text = open("tests/corpus/text.bin", "rb").read()
r = random.Random(20261010)
b = bytearray(text[:200 << 10])
for _ in range(len(b) // 300):
    b[r.randrange(len(b))] = r.randrange(256)
open(os.path.join(sys.argv[1], "txtmut200k"), "wb").write(b)
PY
while read -r want input args; do
    rc=0; "$RS" --format=v4 --seed=7 $args "$input" "$TMP/bl.osr" >/dev/null 2>"$TMP/bl.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$args on $input exited $rc, expected 0: $(grep -a -m1 -E 'panicked|ERROR' "$TMP/bl.err")"
    "$RS" -d "$TMP/bl.osr" "$TMP/bl.dec" >/dev/null 2>&1 || fail "$args on $input: archive does not decode"
    cmp -s "$input" "$TMP/bl.dec" || fail "$args on $input: round trip differs"
    got="$(md5sum < "$TMP/bl.osr" | cut -c1-32)"
    [ "$got" = "$want" ] || fail "$args on $input: archive md5 $got, expected $want"
    rm -f "$TMP/bl.osr" "$TMP/bl.dec"
    pass=$((pass + 1))
done <<EOF
5b700950d763e29419d7d867b5a32944 tests/corpus/text.bin -m3 -c8 -l16
4f8be3b7a76a7cab06e78af7e60571a7 tests/corpus/text.bin -m3 -c8 -l17
4422307111a512d5deef0976c5f29834 tests/corpus/text.bin -m3 -dl17
48287a053ebc239bd64dd9ddd3b2f6a1 tests/corpus/text.bin -m3 -c256 -l1024
48287a053ebc239bd64dd9ddd3b2f6a1 tests/corpus/text.bin -m3 -c512 -l1024
2761d42870348cf2c44f69dfd005ef40 tests/corpus/text.bin -m3f -c8 -l24
5c972e778a39918e764050fe440c5bd1 tests/corpus/mixed.bin -m3o -c8 -l16
c805e2c10d95ab8585977dfb3e50cf46 $TMP/txtmut200k -m3 -c8 -b4kb -l17
124da8db254b1cc36b5a7d7f2d1993eb $TMP/txtmut200k -m3 -c8 -b4kb -l100
EOF
# The v5 default container takes the same matches.
for l in 16 17 24 100 498; do
    rc=0; "$RS" --seed=7 -m3 -c8 -b4kb "-l$l" "$TMP/txtmut200k" "$TMP/bl.osr" >/dev/null 2>"$TMP/bl.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "-m3 -c8 -b4kb -l$l (v5) exited $rc: $(grep -a -m1 -E 'panicked|ERROR' "$TMP/bl.err")"
    "$RS" -d "$TMP/bl.osr" "$TMP/bl.dec" >/dev/null 2>&1 || fail "-m3 -c8 -b4kb -l$l (v5): archive does not decode"
    cmp -s "$TMP/txtmut200k" "$TMP/bl.dec" || fail "-m3 -c8 -b4kb -l$l (v5): round trip differs"
    rm -f "$TMP/bl.osr" "$TMP/bl.dec"
    pass=$((pass + 1))
done

say "CDC (-m1/-m2) match lengths use the header's BASE_LEN, so the archives decode"
# The decoder adds BASE_LEN = min(-l, -dl) (the v4 FUTURELZ_BASE_LEN) back to
# every match length, but CDC encoded them against its own min match, raised
# to 16 (compress_cdc.cpp:208). Whenever the two differ -- -c with an -l above
# 512 (the dictionary's -dl then stays 512), a -dl below CDC's min match, an
# -l below 16 -- 1.0.7, 2.1.2 and 2.2.0 wrote archives that exit 0 and stop
# at -d with "literal run does not fill the block". The lengths now count
# from BASE_LEN; where it already was the min match nothing changes, so the
# controls at the end keep the bytes 2.2.0 wrote. The fixed archives are
# pinned (Rust and Pascal agree); the C++ still writes the broken ones.
python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
r = random.Random(20261012)
for unit, k in ((300, 4), (2000, 3), (20000, 3)):
    u = bytes(r.randrange(256) for _ in range(unit))
    open(os.path.join(d, "cdc_u%dx%d" % (unit, k)), "wb").write(u * k)
open(os.path.join(d, "cdc_t300k"), "wb").write(open("tests/corpus/text.bin", "rb").read()[:300000])
open(os.path.join(d, "cdc_z1m"), "wb").write(bytes(1 << 20))
PY
while read -r want input args; do
    rc=0; "$RS" --seed=7 $args "$TMP/$input" "$TMP/cb.osr" >/dev/null 2>"$TMP/cb.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$args on $input exited $rc, expected 0: $(grep -a -m1 -E 'panicked|ERROR' "$TMP/cb.err")"
    rc=0; "$RS" -d "$TMP/cb.osr" "$TMP/cb.dec" >/dev/null 2>"$TMP/cb.err" || rc=$?
    [ "$rc" -eq 0 ] || fail "$args on $input: archive does not decode (exit $rc): $(tail -1 "$TMP/cb.err")"
    cmp -s "$TMP/$input" "$TMP/cb.dec" || fail "$args on $input: round trip differs"
    case " $args " in *" --format=v4 "*) ;; *)
        "$RS" --verify "$TMP/cb.osr" >/dev/null 2>&1 || fail "$args on $input: --verify rejects the archive" ;;
    esac
    got="$(md5sum < "$TMP/cb.osr" | cut -c1-32)"
    [ "$got" = "$want" ] || fail "$args on $input: archive md5 $got, expected $want"
    rm -f "$TMP/cb.osr" "$TMP/cb.dec"
    pass=$((pass + 1))
done <<EOF
a5de3ae088ccfbf4d052cdd9f3bdf79e cdc_u300x4 -m1 -c64 -l8
b524c3d98fc45504728bbd23bda93638 cdc_u300x4 -m2 -c64 -l8 --format=v4
a5de3ae088ccfbf4d052cdd9f3bdf79e cdc_u300x4 -m1o -c64 -l8
70e21360fcdf42120f0fe484bd637bab cdc_u20000x3 -m1 -dl16
b30a63bad32c44c1ec181852a4682071 cdc_u20000x3 -m1 -dl16 --format=v4
6ded0c041446fbae96ac113219b079d3 cdc_u20000x3 -m2f -dl24
bfe9358c21e0d646ae17646b3ed7509a cdc_u300x4 -m1 -c64 -l100 -dl64
fa338c1cf020f2e8a4d7d0b1837aed0f cdc_t300k -m1 -c256 -l768
8102defdf2cdabc0ca6262b4649ba7e7 cdc_u2000x3 -m2 -c64 -l600 --format=v4
8388359a339f58a4bd81616b5960cd6f cdc_u2000x3 -m1 -c64 -l600
1f96c037f642a3757af061ff79cc76c9 cdc_z1m -m2 -c512 -l1536
d1fe91c313ddb8f7773a584ba0175fbc cdc_t300k -m1 -dl32
fa338c1cf020f2e8a4d7d0b1837aed0f cdc_t300k -m1 -c64 -l768 -dl768
d1fe91c313ddb8f7773a584ba0175fbc cdc_t300k -m1
d1fe91c313ddb8f7773a584ba0175fbc cdc_t300k -m2
70e21360fcdf42120f0fe484bd637bab cdc_u20000x3 -m1
83ddf5a7fbf852bbdf1c913c36a4e9c9 cdc_u2000x3 -m2 -c64 -l512
EOF
say "-m3 with blocks off the chunk grid writes archives that decode"
# Any -b that is not a multiple of the chunk L (-b65537b, -l8192 -b100kb,
# -l17 ...) left every block after the first off the grid -m3 assumed for a
# match's source: exit 0 and an archive -d refused, or decoded to other bytes
# with -hash-. Through 2.2.0, and in 1.0.7. The cases, and the archives that
# must not move, are in their own script.
if ! out=$(OSREP_BIN="$RS" bash tests/m3_grid_regress.sh 2>&1); then
    printf '%s\n' "$out" >&2
    fail "tests/m3_grid_regress.sh failed with OSREP_BIN=$RS"
fi
say "$(printf '%s' "$out" | tail -1 | sed 's/^ *//')"
pass=$((pass + 1))

say "the options the port accepts and does not act on really are inert"
# --help says that -tN, -mmap/-nommap, -slp and -pc have no effect here.
# That claim has to be checked, not asserted: each one must be accepted AND
# leave the archive byte-identical to the same run without it. If one ever
# starts mattering, this fails and the prose has to be corrected with the
# code. -aN and -ia-/-ia+ are not in that list since 2.3.0: -aN sizes bitarr
# and picks the scan, -ia- turns off the slice filter, both like the C++ (see
# the small -l section and the -ia- cases above), and --help says they change
# the archive. -a4/4 and -ia+ stay here because they are what -m3's defaults
# resolve to, so spelling them out must not move the archive; -ia- does not
# move a -m3 one either (-m3 never reads the slice filter).
"$RS" --seed=7 -m3 tests/corpus/text.bin "$TMP/inert_base.osr" >/dev/null 2>&1 \
    || fail "could not write the baseline archive"
for opt in -t1 -t8 -a4/4 -mmap -nommap -ia+ -ia- -slp -slp- -slp+ -pc -pc16; do
    rc=0
    "$RS" --seed=7 -m3 "$opt" tests/corpus/text.bin "$TMP/inert.osr" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "$opt was rejected (exit $rc); the docs say it is accepted"
    cmp -s "$TMP/inert_base.osr" "$TMP/inert.osr" \
        || fail "$opt changed the archive. The docs say it has no effect -- fix whichever is wrong."
    pass=$((pass + 1))
done
# -ia- does act on the default container too: the v5 -m5 -l1000 archive of
# text.bin must move with it (and not with -ia+).
"$RS" --seed=7 -m5 -l1000 tests/corpus/text.bin "$TMP/ia_base.osr" >/dev/null 2>&1 \
    || fail "could not write the -m5 -l1000 archive"
"$RS" --seed=7 -m5 -l1000 -ia+ tests/corpus/text.bin "$TMP/ia_plus.osr" >/dev/null 2>&1 \
    || fail "-ia+ was rejected"
"$RS" --seed=7 -m5 -l1000 -ia- tests/corpus/text.bin "$TMP/ia_minus.osr" >/dev/null 2>&1 \
    || fail "-ia- was rejected"
cmp -s "$TMP/ia_base.osr" "$TMP/ia_plus.osr" || fail "-ia+ (the default) changed the v5 archive"
cmp -s "$TMP/ia_base.osr" "$TMP/ia_minus.osr" && fail "-ia- left the v5 -m5 -l1000 archive unchanged"
"$RS" -d "$TMP/ia_minus.osr" "$TMP/ia_minus.dec" >/dev/null 2>&1 \
    && cmp -s tests/corpus/text.bin "$TMP/ia_minus.dec" || fail "the v5 -ia- archive does not round-trip"
rm -f "$TMP/ia_base.osr" "$TMP/ia_plus.osr" "$TMP/ia_minus.osr" "$TMP/ia_minus.dec"
pass=$((pass + 1))
# -rem is a comment in both implementations, and takes a value.
"$RS" --seed=7 -m3 -rem=anything tests/corpus/text.bin "$TMP/inert.osr" >/dev/null 2>&1 \
    || fail "-rem was rejected"
cmp -s "$TMP/inert_base.osr" "$TMP/inert.osr" || fail "-rem changed the archive"
pass=$((pass + 1))

say "--verify: what it accepts, what it catches, and what it admits it misses"
# The one thing v5 can do that v4 cannot: answer "is this archive sound?"
# without reconstructing it. v4 carries no checksum anywhere, so the only
# answer there is a full decompress.
"$RS" --seed=7 -m3 tests/corpus/text.bin "$TMP/vf.osr" >/dev/null 2>&1 \
    || fail "could not write a v5 archive to verify"
"$RS" --verify "$TMP/vf.osr" >/dev/null 2>&1 || fail "--verify rejected a healthy v5 archive"
# Every mode, and -dup, which adds the meta blob and its CRC.
for m in m1 m3 m5; do
    for extra in "" "-dup"; do
        "$RS" --seed=7 $extra "-$m" tests/corpus/text.bin "$TMP/vh.osr" >/dev/null 2>&1 || continue
        "$RS" --verify "$TMP/vh.osr" >/dev/null 2>&1 \
            || fail "--verify rejected a healthy -$m $extra archive"
    done
done
pass=$((pass + 1))

# Truncation at any point, trailing junk, and an empty file must all be caught.
SZ=$(stat -c%s "$TMP/vf.osr")
for frac in 10 50 90 99; do
    head -c $((SZ * frac / 100)) "$TMP/vf.osr" > "$TMP/vt.osr"
    rc=0; "$RS" --verify "$TMP/vt.osr" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "--verify passed an archive truncated to ${frac}%"
done
cat "$TMP/vf.osr" > "$TMP/vj.osr"; printf 'XXXXXXXX' >> "$TMP/vj.osr"
rc=0; "$RS" --verify "$TMP/vj.osr" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "--verify passed an archive with trailing junk"
: > "$TMP/ve.osr"
rc=0; "$RS" --verify "$TMP/ve.osr" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "--verify passed an empty file"
pass=$((pass + 1))

# Corruption in the framing -- the header, the footer, the block headers -- is
# what the CRCs and the structural walk exist for.
for off in 4 8 12 20 24; do
    python3 - "$TMP/vf.osr" "$TMP/vc.osr" "$off" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[int(sys.argv[3])] ^= 0xFF
open(sys.argv[2], 'wb').write(d)
PY
    rc=0; "$RS" --verify "$TMP/vc.osr" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "--verify passed a header corrupted at byte $off"
done
pass=$((pass + 1))

say "--verify says no to the containers it cannot answer for"
# v4 has no checksum anywhere, so claiming to verify it would be a lie. It is
# refused with a cmdline status and an explanation, not a false "intact".
"$RS" --format=v4 --seed=7 -m3 tests/corpus/text.bin "$TMP/v4.osr" >/dev/null 2>&1
rc=0; "$RS" --verify "$TMP/v4.osr" >"$TMP/v4.err" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "--verify on a v4 archive exited $rc, expected 2 (cmdline)"
grep -qi "v1-v4" "$TMP/v4.err" || fail "--verify on v4 did not explain why"
# And something that is not an archive at all is bad data, not a usage error.
rc=0; "$RS" --verify tests/corpus/text.bin >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "--verify on a non-archive exited $rc, expected 4 (bad data)"
pass=$((pass + 1))

say "--verify does not claim to cover the stored block bytes"
# Pinning the documented limitation: nothing in v5 checksums a literal run, so
# a flip there survives --verify and is only caught by decoding. If this ever
# starts failing, the coverage changed and the docs and help text must follow.
LITOFF=$((SZ - 64))
python3 - "$TMP/vf.osr" "$TMP/vl.osr" "$LITOFF" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[int(sys.argv[3])] ^= 0xFF
open(sys.argv[2], 'wb').write(d)
PY
if "$RS" --verify "$TMP/vl.osr" >/dev/null 2>&1; then
    # Expected today: --verify passes, and the decoder is what catches it.
    rc=0; "$RS" -d "$TMP/vl.osr" "$TMP/vl.out" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] \
        || fail "a flipped literal byte passed BOTH --verify and -d: nothing caught it"
else
    fail "--verify caught a flipped literal byte. That is an improvement, not a
      failure -- but the help text and docs say it cannot, so update them and
      this test together."
fi
pass=$((pass + 1))

say "what each binary reports on stderr"
# Its own script because it compares the two binaries' *text*, which nothing
# else here does -- the rest diff archives and exit codes. That gap is how a
# line the C++ prints and the port does not went unnoticed until a downstream
# consumer turned out to be parsing it.
if ! out=$(OSREP_BIN="$RS" bash tests/stderr_conformance.sh 2>&1); then
    printf '%s\n' "$out" >&2
    fail "tests/stderr_conformance.sh failed"
fi
say "stderr_conformance: $(printf '%s' "$out" | tail -1)"
pass=$((pass + 1))

for s in roundtrip mode_suffix_hash_matrix dup_roundtrip dup_native_roundtrip \
         dup_corruption_fuzz dup_concurrency dup_ref_oob_regression dup_length_regression \
         vm_options_regression vm_tempfile_leak_regression futurelz_race_regression; do
    if ! out=$(OSREP_BIN="$RS" FUTURELZ_RACE_RUNS="${FUTURELZ_RACE_RUNS:-20}" bash "tests/$s.sh" 2>&1); then
        printf '%s\n' "$out" >&2
        fail "tests/$s.sh failed with OSREP_BIN=$RS"
    fi
    say "$s: $(printf '%s' "$out" | tail -1)"
    pass=$((pass + 1))
done

echo "  rust_cli_conformance: passed=$pass mismatches=0"
