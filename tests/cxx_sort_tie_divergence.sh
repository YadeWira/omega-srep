#!/usr/bin/env bash
# Gate: the order of equal-`src` matches in the second pass is the C++'s.
#
# The C++ 1.0.x encoder sorts the second-pass match list with libstdc++'s
# std::sort and a comparator that looks at `src` only (srep.cpp:899). On inputs
# where many matches share one `src` (a block repeated after an insertion that
# breaks the -l chunk alignment), std::sort leaves those ties in an order of its
# own. Up to 2.2.1 the Rust (stable sort) and the Pascal (merge sort) kept
# collection order instead: same size, same decoded bytes, different archive
# bytes, on about one real file in ten. Since 2.3.0 both transcribe libstdc++'s
# std::sort (second_pass.rs `libstdcxx_sort`, secondpass.pas `SortBySrc`).
#
# Every case below that is not a control DIFFERED with 2.2.1 (Rust and Pascal
# alike; measured). Only second-pass modes are affected; -mNo writes the lists
# inline and never sorts, and libstdc++ sorts 16 elements or fewer with a plain
# (stable) insertion sort, so small inputs cannot show it.
#
# Exit status: 0 = every implementation matches the C++ byte for byte and the
#                  archives cross-decode,
#              1 = an archive differs from the C++'s (the tie order regressed),
#              2 = setup problem, or an archive that does not cross-decode.
#
#   OSREP_CPP_BIN   C++ 1.0.7 oracle   (default: $CXX_BIN/osrep, built if missing)
#   OSREP_RUST_BIN  Rust osrep         (default: $RUST_TARGET/release/osrep, built if missing)
#   OSREP_PORT_BIN  the Pascal osrep   (default: pascal/bin/osrep-linux-x86_64;
#                   point it at a wine wrapper to check a Windows build)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

CPP="${OSREP_CPP_BIN:-$CXX_BIN/osrep}"
RS="${OSREP_RUST_BIN:-$RUST_TARGET/release/osrep}"
PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
warn_shared_wine "$PORT"

if [ -z "${OSREP_CPP_BIN:-}" ] && [ ! -x "$CPP" ]; then
    make_cxx bin/osrep >/dev/null 2>&1 || { echo "cannot build $CPP" >&2; exit 2; }
fi
if [ -z "${OSREP_RUST_BIN:-}" ] && [ ! -x "$RS" ]; then
    cargo_rs build --release -p osrep-cli >/dev/null 2>&1 || { echo "cannot build $RS" >&2; exit 2; }
fi
for b in "$CPP" "$RS" "$PORT"; do
    [ -x "$b" ] || { echo "missing executable: $b (the Pascal: bash pascal/build.sh)" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# <unit> bytes of random data written <pre> times, one random byte, then <post>
# more copies. The one-byte insertion breaks the -l chunk alignment, so the
# match finder resolves every later copy to the same pre-insertion copy: <post>
# - 1 matches with one shared src. noisy*: the reviewer's shape, a 4 KiB unit
# with 1-40 random bytes after ~5% of the copies.
python3 - "$TMP" <<'PY' || { echo "cannot generate the inputs" >&2; exit 2; }
import hashlib, os, random, sys
d = sys.argv[1]
def gen(name, unit_len, pre, ins, post, md5):
    r = random.Random(1)
    unit = bytes(r.randrange(256) for _ in range(unit_len))
    b = bytearray(unit * pre)
    b += bytes(r.randrange(256) for _ in range(ins))
    b += unit * post
    assert hashlib.md5(b).hexdigest() == md5, name
    open(os.path.join(d, name), "wb").write(bytes(b))
gen("tie9k.bin", 512, 2, 1, 16, "5f68346dc0c7bbbb8bb33755b3036918")    # 17 matches with -m5, 15 with -m3
gen("tie10k.bin", 512, 2, 1, 18, "68d27d59d779fa29b871acd256ffee30")   # the smallest that differs by default
gen("tie139k.bin", 4096, 2, 1, 32, "01a4a29379b8570fd9c997403f6571a2") # every second-pass mode
r = random.Random(20261009)
unit = bytes(r.randrange(256) for _ in range(4096))
out = bytearray()
while len(out) < 2 << 20:
    out += unit
    if r.random() < 0.05:
        out += bytes(r.randrange(256) for _ in range(r.randint(1, 40)))
assert hashlib.md5(out[:2 << 20]).hexdigest() == "1f692d4629cdcb788025c18817c71d6d"
open(os.path.join(d, "noisy512k.bin"), "wb").write(out[:512 << 10])
open(os.path.join(d, "noisy2m.bin"), "wb").write(out[:2 << 20])
PY

diverged=0
checked=0
check() {  # check <input> <tie|same> <options...>
    local input="$1" expect="$2"; shift 2
    local label
    label="$(basename "$input") [${*:-default}]"
    "$CPP" --seed=7 "$@" "$input" "$TMP/cpp.osr" >/dev/null 2>&1 || { echo "  C++ failed on $label" >&2; exit 2; }
    for impl in "$RS" "$PORT"; do
        "$impl" --format=v4 --seed=7 "$@" "$input" "$TMP/impl.osr" >/dev/null 2>&1 \
            || { echo "  $impl failed on $label" >&2; exit 2; }
        # Both directions: the decoders must not care about the tie order.
        rm -f "$TMP/a.dec" "$TMP/b.dec"
        "$CPP" -d "$TMP/impl.osr" "$TMP/a.dec" >/dev/null 2>&1 && cmp -s "$TMP/a.dec" "$input" \
            || { echo "  DECODE PROBLEM: the C++ cannot decode $impl's archive of $label" >&2; exit 2; }
        "$impl" -d "$TMP/cpp.osr" "$TMP/b.dec" >/dev/null 2>&1 && cmp -s "$TMP/b.dec" "$input" \
            || { echo "  DECODE PROBLEM: $impl cannot decode the C++ archive of $label" >&2; exit 2; }
        if cmp -s "$TMP/cpp.osr" "$TMP/impl.osr"; then
            echo "  same    $label  $impl"
        else
            echo "  DIFFERS $label  $impl  (differed in 2.2.1: $expect)"
            diverged=1
        fi
        checked=$((checked + 1))
    done
}

echo "second-pass modes (the tie order is in the archive):"
for m in "" -m3 -m4 -m5 -m3f -m4f -m5f; do
    # shellcheck disable=SC2086
    check "$TMP/tie10k.bin" yes $m
    # shellcheck disable=SC2086
    check "$TMP/tie139k.bin" yes $m
    # shellcheck disable=SC2086
    check "$TMP/noisy512k.bin" yes $m
done
check "$TMP/tie9k.bin" yes -m5
check "$TMP/tie9k.bin" yes -m5f
check "$TMP/tie10k.bin" yes -m4 -b1mb
check "$TMP/noisy2m.bin" yes -m0
check "$TMP/noisy2m.bin" yes
echo "controls (no second pass, or too few ties to reorder):"
check "$TMP/tie9k.bin" no -m3
check "$TMP/tie9k.bin" no -m4f
check "$TMP/tie139k.bin" no -m3o
check "$TMP/tie139k.bin" no -m4o
check "$TMP/tie139k.bin" no -m1
check "$TMP/noisy512k.bin" no -m0

if [ "$diverged" -ne 0 ]; then
    echo "FAIL: an archive differs from the C++'s: the second-pass tie order regressed"
    exit 1
fi
echo "cxx_sort_tie_divergence: $checked archives match the C++ byte for byte and cross-decode"
