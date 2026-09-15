#!/usr/bin/env bash
# Regression: decompression must not leak its VM scratch file.
#
# VIRTUAL_MEMORY_MANAGER's path is created eagerly with mkstemp() (srep.cpp,
# decompression path) but the FILE* is only fopen()ed on the first spill, inside
# save_to_disk(). The destructor used to remove the file only inside
# `if (vmfile)` -- so every Future-LZ/Index-LZ decompression that did not spill,
# which is almost all of them, leaked an empty
# $TMPDIR/osrep-virtual-memory-XXXXXX. A normal session accumulates thousands.
#
# The test decompresses with TMPDIR pointed at a directory that should stay
# completely empty, and asserts it does -- for both the common no-spill path and
# a decode whose memory settings make the VM file actually be opened. The
# spilling case is `-mem=1mb -vmblock=128k`, which is the budget
# tests/decode_conformance.sh proves spills (`vmw=2359296` for `far.bin`); the
# 8mb/256k pair this used to spell out never evicted anything, so the assertion
# it carried was vacuous. The pre-fix binary leaves *no* leftover in the
# spilling case (it opened the file, and so removed it) while it leaves exactly
# one for a plain decode, which is what the first half covers.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

source "$(dirname "$0")/_osrep_bin.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WORK="$TMP/work";  VMTMP="$TMP/vmtmp"
mkdir -p "$WORK" "$VMTMP"

python3 - "$WORK" <<'PY'
import os, random, sys
d = sys.argv[1]
random.seed(4242)
unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
open(os.path.join(d, "repeat.bin"), "wb").write(unit * 75)
# far.bin: 32 distinct 64 KiB blocks, then the same 32 again -- matches whose
# destination is 2 MiB ahead, i.e. data the decoder must hold and spill.
far = [bytes(random.randrange(256) for _ in range(64 * 1024)) for _ in range(32)]
open(os.path.join(d, "far.bin"), "wb").write(b"".join(far) * 2)
PY

# A v4 archive (the default format) and a v3 one.
$OSREP -m3  -b64k -t1 "$WORK/repeat.bin" "$WORK/v4.osr" >/dev/null 2>&1 || fail "compress v4"
$OSREP -m5f -b64k -t1 "$WORK/repeat.bin" "$WORK/v3.osr" >/dev/null 2>&1 || fail "compress v3"
$OSREP -m5f -b64k -t1 "$WORK/far.bin"    "$WORK/far.osr" >/dev/null 2>&1 || fail "compress far"

leftovers() { ls -A "$VMTMP" | wc -l; }

# --- no-spill path (what almost every real decode does) ----------------- #
for i in $(seq 1 12); do
    TMPDIR="$VMTMP" $OSREP -d "$WORK/v4.osr" "$WORK/out-v4.$i" >/dev/null 2>&1 \
        || fail "v4 decode $i failed"
    TMPDIR="$VMTMP" $OSREP -d "$WORK/v3.osr" "$WORK/out-v3.$i" >/dev/null 2>&1 \
        || fail "v3 decode $i failed"
done
cmp -s "$WORK/repeat.bin" "$WORK/out-v4.12" || fail "v4 decoded to the wrong bytes"
cmp -s "$WORK/repeat.bin" "$WORK/out-v3.12" || fail "v3 decoded to the wrong bytes"
n=$(leftovers)
[[ "$n" -eq 0 ]] || fail "24 plain decodes left $n temp file(s) in TMPDIR"
say "no-spill: 24 decodes (v3 + v4) left the TMPDIR empty"

# --- spilling path (the VM file really is opened) ----------------------- #
TMPDIR="$VMTMP" $OSREP -d -mem=1mb -vmblock=128k "$WORK/far.osr" "$WORK/out-far" >/dev/null 2>&1 \
    || fail "spilling decode failed"
cmp -s "$WORK/far.bin" "$WORK/out-far" || fail "spilling decode produced the wrong bytes"
n=$(leftovers)
[[ "$n" -eq 0 ]] || fail "the spilling decode left $n temp file(s) in TMPDIR"
say "spill: forced VM use still cleaned up after itself"

echo "vm_tempfile_leak_regression: passed=25 mismatches=0"
