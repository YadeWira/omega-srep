#!/usr/bin/env bash
# v5 conformance: the container has no C++ oracle (the C++ cannot emit v5), so
# each case checks itself. `docs/format-spec-v5.md` section 6.
#
#   * layer 2 -- the archive must carry exactly the same matches as the same
#     encoding written as Future-LZ (v4), which *is* byte-verified. The
#     conformance binary does that comparison and exits non-zero on a mismatch.
#   * layer 3 -- the container's rejection rules, each with a negative case.
#
# Usage: tests/format_v5_conformance.sh [rust-binary]

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

RS=${1:-$ROOT/target/release/encode_conformance}
if [ ! -x "$RS" ]; then
    cargo build --release -p osrep-conformance >/dev/null 2>&1 || {
        echo "cannot build $RS" >&2
        exit 1
    }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

say() { printf '  %s\n' "$*"; }

# The CDC modes need a duplicate-heavy input; tests/corpus is blind to them.
python3 - "$TMP" <<'PY'
import os, sys
tmp = sys.argv[1]
block = os.urandom(1 << 19)
# 5 MiB of a repeated 512 KiB chunk, plus something incompressible.
open(f"{tmp}/dup5m.bin", "wb").write(block * 10 + os.urandom(64 * 1024))
open(f"{tmp}/mixed.bin", "wb").write(block + b"hello world" * 40000)
PY

# A v5 case: the binary encodes, then verifies the stream itself.
v5enc() {
    local input="$1" mode="$2"
    shift 2
    if ! out=$("$RS" "$mode" --seed=7 "$@" "$input" "$TMP/out.osr" 2>&1); then
        fail "$mode on $(basename "$input") rc=$? ${out:-}"
    fi
    [ -s "$TMP/out.osr" ] || fail "$mode on $(basename "$input") wrote nothing"
    pass=$((pass + 1))
}

say "v5 container, every method, checked against the Future-LZ stream"
for input in "$TMP/mixed.bin" "$TMP/dup5m.bin" "$ROOT/tests/corpus/mixed.bin"; do
    [ -f "$input" ] || continue
    for m in m0 m1 m2 m3 m4 m5; do
        v5enc "$input" "${m}v"
    done
    # Options that change the record values themselves.
    v5enc "$input" m3v -l256
    v5enc "$input" m3v -b1mb
    v5enc "$input" m4v -c1024
    v5enc "$input" m1v -l2048
    v5enc "$input" m0v -d16mb
    # Digest shapes: v5 states `hash_size` explicitly, so the disabled case
    # (`0`, the field is absent) and SipHash's 8 bytes -- the size the v4
    # `-16` bias used to wrap to 248 -- both have to round-trip.
    v5enc "$input" m4v -hash-
    v5enc "$input" m4v -hash=siphash
done

say "degenerate inputs"
: >"$TMP/empty.bin"
printf 'x' >"$TMP/tiny.bin"
v5enc "$TMP/empty.bin" m3v
v5enc "$TMP/tiny.bin" m3v
v5enc "$ROOT/tests/corpus/tiny.bin" m5v

# `-dup`: the dedup pre-pass runs, its `.dupref` payload rides inside the
# container, and the archive comes back through the post-pass. The conformance
# binary does the round-trip (including reading the payload out by the footer's
# offsets) and exits non-zero on any mismatch.
say "-dup: the dedup payload rides in the container and comes back"
for m in m3 m4 m5; do
    for input in "$TMP/dup5m.bin" "$TMP/mixed.bin"; do
        v5enc "$input" "${m}v" --dup
    done
done
v5enc "$TMP/dup5m.bin" m4v --dup -hash=sha1
v5enc "$TMP/dup5m.bin" m4v --dup -hash-

say "rejection rules live in the unit tests"
# Header/footer/meta CRC mismatches, bad magic, bad version, undefined flags,
# a mismatched hash_id/hash_size pair, an unterminated varint and a block count
# that disagrees with the footer are covered by `cargo test -p osrep-core`
# (v5::tests), which the core suite runs.

echo "  format_v5_conformance: passed=$pass"
