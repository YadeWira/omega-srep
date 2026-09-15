#!/usr/bin/env bash
# Regression for the decode_streaming forward-ref out-of-bounds.
#
# A .dupref meta blob is [24-byte header][chunk_count records]. The header
# carries unique_count, but decode_streaming() builds its unique_slots
# vector incrementally as it walks the records: a record that is a ref
# *before* any unique has been seen must be rejected, not indexed. Meta
# blobs come straight out of the ODUP trailer, so a corrupt/crafted
# archive could reach this from the CLI.
#
# Before the fix this indexed unique_slots[0] while its size() was still
# 0: UB that reads uninitialized storage (reserve() only guarantees
# capacity), so it could silently yield a garbage Slot -- spurious
# failures or wrong output -- instead of rejecting the archive. It must
# now fail cleanly with DEDUP_ERR_BAD_REF.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$(dirname "$0")/_osrep_bin.sh"
[[ -x bin/dedup_test ]] || make bin/dedup_test

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A meta whose single record is a ref to unique #0, i.e. a reference to a
# chunk that does not exist. unique_count=1 passes the header-level
# unique_count<=chunk_count check, which is exactly the hole.
python3 - "$TMP/meta.bin" <<'PY'
import struct, sys
magic   = struct.pack('<I', 0x52505544)   # "DUPR"
version = struct.pack('<I', 1)
header  = magic + version + struct.pack('<QQ', 1, 1)   # chunk_count=1, unique_count=1
record  = bytes([1, 0])                                 # tag=REF, varint index 0
open(sys.argv[1], 'wb').write(header + record)
PY

# Body can be anything non-empty; the decoder must bail before using it.
printf 'not-a-real-body' > "$TMP/body.bin"

echo "[1/2] decode_streaming rejects a leading ref (dedup_test)"
set +e
./bin/dedup_test decode-streaming "$TMP/meta.bin" "$TMP/body.bin" "$TMP/out.bin" \
    >"$TMP/unit.out" 2>"$TMP/unit.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: decode_streaming accepted a ref-before-unique meta" >&2
    exit 1
fi
if [ "$rc" -ge 128 ]; then
    echo "FAIL: decode_streaming crashed (signal $((rc - 128)))" >&2
    exit 1
fi
if ! grep -q 'rc=5$' "$TMP/unit.err"; then
    echo "FAIL: expected DEDUP_ERR_BAD_REF (rc=5), got: $(cat "$TMP/unit.err")" >&2
    exit 1
fi
echo "      clean reject rc=$rc (DEDUP_ERR_BAD_REF)"

echo "[2/2] the same meta through the CLI (osrep -d) must not crash or corrupt"
# Build a good -dup archive, then splice in the malformed meta as its
# ODUP trailer -- the exact shape a corrupted archive would have.
python3 - > "$TMP/orig.bin" <<'PY'
import sys
unit = b'trailer splice payload. ' * 100
body = (b'X' * 4096 + b'Y' * 4096) * 16
sys.stdout.buffer.write(unit + body + body + unit)
PY
"$OSREP" -dup -m4 "$TMP/orig.bin" "$TMP/good.osr" >/dev/null 2>&1

python3 - "$TMP/good.osr" "$TMP/meta.bin" "$TMP/bad.osr" <<'PY'
import struct, sys
good, metab, out = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(good, 'rb').read()
assert data[-4:] == b'ODUP', "baseline archive has no ODUP trailer"
meta_size = struct.unpack('<Q', data[-12:-4])[0]
body_osr = data[:len(data) - 12 - meta_size]
meta = open(metab, 'rb').read()
open(out, 'wb').write(body_osr + meta + struct.pack('<Q', len(meta)) + b'ODUP')
PY

set +e
"$OSREP" -d "$TMP/bad.osr" "$TMP/bad.out" >"$TMP/e2e.out" 2>"$TMP/e2e.err"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "FAIL: osrep -d accepted an archive with a ref-before-unique meta" >&2
    exit 1
fi
if [ "$rc" -ge 128 ]; then
    echo "FAIL: osrep -d crashed (signal $((rc - 128)))" >&2
    cat "$TMP/e2e.err" >&2
    exit 1
fi
echo "      clean reject rc=$rc"

echo "dup_ref_oob_regression: PASS"
