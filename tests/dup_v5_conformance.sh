#!/usr/bin/env bash
# Differential gate for the Rust `-dup` wrapper (docs/rust-port.md, phase 5b).
#
# `-dup` is the one path that leaves the C++ as a byte-for-byte oracle for a
# *whole* archive. The dedup body and the `.dupref` meta are each verified
# against the C++ separately (`rust_conformance.sh`), so what the wrapper
# decides is only where the meta goes:
#
#   * v4 (`--format=v4`): the meta is the ODUP trailer, exactly as the C++
#     writes it, so the entire archive must compare byte for byte.
#   * v5: the C++ cannot write v5, so the meta blob is carved out with the
#     footer's own `meta_offset`/`meta_size` and its payload compared against
#     the C++'s trailer payload -- the same `.dupref` bytes, plus v5's CRC.
#
# Skips cleanly (exit 0) when the Rust toolchain is missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping -dup conformance (install rustup; rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ oracle (bin/osrep)"
make bin/osrep >/dev/null 2>&1

say "building the Rust port (osrep-conformance)"
if ! cargo build --release -p osrep-conformance >"$ROOT/target/rust-dup-build.log" 2>&1; then
    cat "$ROOT/target/rust-dup-build.log" >&2
    fail "cargo build failed"
fi
RS="target/release/encode_conformance"
[[ -x "$RS" ]] || fail "missing $RS"

say "rustc: $(rustc --version)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# CDC finds duplicates only where there is real repetition, and tests/corpus
# has none (docs/rust-port.md keeps the measurement). These inputs are a
# repeated block plus a tail that is not a whole chunk, so the meta has both
# TAG_REF runs and a trailing unique.
python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
unit = bytes((i * 31 + 7) & 0xFF for i in range(1 << 19))       # 512 KiB
open(os.path.join(d, "dup2m.bin"), "wb").write(unit * 4)
open(os.path.join(d, "dup5m.bin"), "wb").write(unit * 10 + bytes(range(256)) * 260)
PY

# The v5 arm's check: the C++'s ODUP payload must be exactly the v5 meta blob
# with v5's trailing CRC taken off, and the footer's offsets must land on it.
cat >"$TMP/meta_check.py" <<'PY'
import struct, sys

cpp = open(sys.argv[1], "rb").read()
v5 = open(sys.argv[2], "rb").read()

if cpp[-4:] != b"ODUP":
    sys.exit("the C++ archive has no ODUP trailer")
meta_size = struct.unpack_from("<Q", cpp, len(cpp) - 12)[0]
cpp_meta = cpp[len(cpp) - 12 - meta_size:len(cpp) - 12]

if len(v5) < 32 or v5[-32:-28] != b"OSRF":
    sys.exit("the v5 archive has no footer")
footer = v5[-32:]
meta_off = struct.unpack_from("<Q", footer, 16)[0]
meta_size = struct.unpack_from("<I", footer, 24)[0]
if meta_off + meta_size + 32 != len(v5):
    sys.exit("the v5 footer's meta offsets do not land on the footer")

blob = v5[meta_off:meta_off + meta_size]
if blob[:-4] != cpp_meta:
    sys.exit(
        "the v5 payload is not the C++ `.dupref` blob: "
        f"{len(blob) - 4} vs {len(cpp_meta)} bytes"
    )
PY

pass=0

# dup <input> <cpp-method> <rust-method> <options...>
#   Runs the C++ and both Rust containers over the same input and options.
dup_case() {
    local input="$1" cm="$2" rm="$3"
    shift 3
    if ! ./bin/osrep -dup "$cm" "$@" --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>"$TMP/cpp.err"; then
        fail "cpp -dup $cm $* on $input failed: $(tail -1 "$TMP/cpp.err")"
    fi

    # v4: the ODUP trailer, so the whole archive is the oracle's.
    if ! "$RS" "$rm" --dup "$@" --seed=7 "$input" "$TMP/rs4.osr" >/dev/null 2>"$TMP/rs4.err"; then
        fail "rust --dup $rm $* on $input failed: $(tail -1 "$TMP/rs4.err")"
    fi
    cmp -s "$TMP/cpp.osr" "$TMP/rs4.osr" \
        || fail "-dup $rm $* on $input: the v4 archive differs from the C++'s"

    # v5: the same payload inside the container. The conformance binary already
    # round-tripped it; what is checked here is that the bytes it carries are
    # the C++'s meta and nothing else.
    if ! "$RS" "${rm}v" --dup "$@" --seed=7 "$input" "$TMP/rs5.osr" >/dev/null 2>"$TMP/rs5.err"; then
        fail "rust --dup ${rm}v $* on $input failed: $(tail -1 "$TMP/rs5.err")"
    fi
    if ! out=$(python3 "$TMP/meta_check.py" "$TMP/cpp.osr" "$TMP/rs5.osr" 2>&1); then
        fail "-dup ${rm}v $* on $input: $out"
    fi

    pass=$((pass + 1))
}

say "-dup -m3/-m4/-m5: v4 byte-identical to the C++, v5 carrying the same payload"
for input in "$TMP/dup2m.bin" "$TMP/dup5m.bin"; do
    for m in m3 m4 m5; do
        dup_case "$input" "-$m" "$m"
    done
done

say "-dup: digest shapes (the meta must not depend on the block checksums)"
dup_case "$TMP/dup5m.bin" -m4 m4 -hash=sha1
dup_case "$TMP/dup5m.bin" -m4 m4 -hash-
dup_case "$TMP/dup5m.bin" -m4 m4 -b1mb

say "-dup with the in-memory pass on top (the body is what gets the dictionary)"
dup_case "$TMP/dup5m.bin" -m4 m4 -d16mb

echo "  dup_v5_conformance: passed=$pass"
