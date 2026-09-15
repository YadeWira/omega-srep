#!/usr/bin/env bash
# Differential gate for the Rust ENCODER (docs/rust-port.md, phase 4c).
#
# The C++ `osrep` binary is the oracle: the same input and the same options go
# through both implementations and the resulting archive must be byte-for-byte
# identical. That is only decidable with --seed=N -- otherwise each side draws
# the per-archive hash key from Fortuna and no two runs agree, let alone two
# implementations.
#
# Covers the ported subset of phase 4c; modes that are not ported yet are
# reported as "not ported" rather than as failures. Skips cleanly (exit 0)
# when the Rust toolchain is missing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v cargo >/dev/null 2>&1; then
    say "cargo not found -- skipping encoder conformance (install rustup; rust-toolchain.toml pins 1.77.2)"
    exit 0
fi

say "building the C++ oracle (bin/osrep)"
make bin/osrep >/dev/null 2>&1

say "building the Rust port (osrep-conformance)"
if ! cargo build --release -p osrep-conformance >/tmp/rust-encoder-build.log 2>&1; then
    cat /tmp/rust-encoder-build.log >&2
    fail "cargo build failed"
fi
RS_DIR=target/release
RS="$RS_DIR/encode_conformance"
[[ -x "$RS" ]] || fail "missing $RS"

say "rustc: $(rustc --version)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Inputs ---------------------------------------------------------- #

# tests/corpus is only mildly redundant for -m0, so the harness adds its own
# duplicate-heavy input (see docs/rust-port.md). The large one also drives the
# dictionary ring past its wrap point, which is where the modular arithmetic
# in compress_inmem has to hold up.
python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
unit = bytes((i * 17 + 5) & 0xFF for i in range(1 << 19))   # 512 KiB
open(os.path.join(d, "dup4m.bin"), "wb").write(unit * 8)
open(os.path.join(d, "dup20m.bin"), "wb").write(unit * 40)  # 20 MiB: wraps a -d2mb/-b1mb ring
open(os.path.join(d, "empty.bin"), "wb").write(b"")
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
PY

pass=0

# enc <input> <cpp-mode> <rust-mode> <options...>
#   Runs both encoders with --seed=7 and diffs the archives.
enc() {
    local input="$1" cm="$2" rm="$3"
    shift 3
    if ! ./bin/osrep "$cm" "$@" --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>"$TMP/cpp.err"; then
        fail "cpp $cm $* on $input failed: $(tail -1 "$TMP/cpp.err")"
    fi
    if ! "$RS" "$rm" "$@" --seed=7 "$input" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err"; then
        fail "rust $rm $* on $input failed: $(tail -1 "$TMP/rs.err")"
    fi
    if cmp -s "$TMP/cpp.osr" "$TMP/rs.osr"; then
        pass=$((pass+1))
    else
        fail "$cm $* on $input: archives differ ($(stat -c%s "$TMP/cpp.osr") vs $(stat -c%s "$TMP/rs.osr") bytes)"
    fi
}

# --- mode x options matrix ------------------------------------------- #

say "-m0o (in-memory REP, format v2) vs the C++ encoder"
for input in tests/corpus/mixed.bin tests/corpus/text.bin tests/corpus/zeros.bin \
             tests/corpus/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" -m0o m0o -d16mb
    enc "$input" -m0o m0o -d2mb -b1mb      # ring wraps repeatedly on dup20m
    enc "$input" -m0o m0o -d16mb -l1024
    enc "$input" -m0o m0o -d16mb -dl256    # changes BASE_LEN, i.e. the record shape
    enc "$input" -m0o m0o -d16mb -hash-    # checksums disabled: digest bytes stay zero
    enc "$input" -m0o m0o -d16mb -hash=md5
    enc "$input" -m0o m0o -d16mb -hash=siphash
done

say "-m4o/-m5o (hash-table match finder, format v2) vs the C++ encoder"
# The big inputs cross block boundaries (and so exercise the read-ahead slot
# the scanner reads a few bytes past the block end through), and the -d cases
# run the in-memory pass on top of the match finder, the way `-m0 -m4` combines.
for input in tests/corpus/mixed.bin tests/corpus/text.bin tests/corpus/random.bin \
             "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" -m4o m4o
    enc "$input" -m4o m4o -b1mb
    enc "$input" -m4o m4o -d16mb           # in-memory pass + match finder
    enc "$input" -m4o m4o -d16mb -b1mb
    enc "$input" -m4o m4o -l1024
    enc "$input" -m5o m5o
    enc "$input" -m5o m5o -b1mb
    enc "$input" -m5o m5o -d16mb
    enc "$input" -m5o m5o -l1024
    enc "$input" -m5o m5o -l256
done

say "-m3o (digest-verified chunks, format v1) vs the C++ encoder"
# -m3 with no dictionary writes v1 (3-word round matches); adding -d drops
# ROUND_MATCHES and so falls back to v2 -- both shapes are covered here.
for input in tests/corpus/mixed.bin tests/corpus/text.bin tests/corpus/random.bin \
             "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" -m3o m3o
    enc "$input" -m3o m3o -b1mb
    enc "$input" -m3o m3o -d16mb
    enc "$input" -m3o m3o -l1024
done

# Degenerate inputs and the C++'s own 512 MiB dictionary default.
enc "$TMP/empty.bin" -m0o m0o -d16mb
enc "$TMP/tiny.bin"  -m0o m0o -d16mb
enc tests/corpus/tiny.bin -m0o m0o

say "encode_conformance: passed=$pass"

# --- not ported yet -------------------------------------------------- #

set +e
"$RS" m4 -d16mb --seed=7 "$TMP/dup4m.bin" "$TMP/rs.osr" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
    fail "expected 'm4: not ported' (rc=3), got rc=$rc"
fi
say "unported modes report rc=3 as expected"
