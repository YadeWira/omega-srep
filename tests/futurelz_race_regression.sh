#!/usr/bin/env bash
# Regression: the Future-LZ / Index-LZ encoder must be *deterministic* for a
# fixed seed, and every archive it writes must round-trip.
#
# The bug (present through 1.0.6)
# ------------------------------
# The main thread filled header[0..2], copied header[] (including header[3..],
# the per-block digest the *background* thread writes with hash_func) into the
# COMPRESSED_BLOCK, and only then called bg_thread.write(). But write() is what
# signals WriteReady, and the BG thread's next-next iteration reuses that same
# header buffer for the block after next -- so the copy raced the digest write.
# VHash::compute stores the 16-byte digest as two 8-byte memcpys
# (hashes.cpp:377-379), so a block could be stored, and later written to the
# file, with another block's digest or with half of it stale.
#
# The captured failure showed it exactly: the archive's 4th block carried a
# digest whose first half was the VMAC of the *empty string* -- i.e. of the EOF
# block the BG thread was hashing at that moment -- and whose second half was
# untouched zeros.
#
# Symptom: the encoder printed success, but decompression failed with
# "checksum of decompressed data is not the same as checksum of original data",
# intermittently: 3/200 single-threaded, 17/200 at the default thread count.
# -m3f/-m4f and the v4 modes are exposed to the same race, just less often.
# Reported upstream as "m3f-m5f are halfly broken: compression ok, decompress
# fails; the first N blocks come out and then a CRC error".
#
# Why this test can pin it
# ------------------------
# The failure is deterministic per (input, options, seed) at ~4% per run. The
# archive stores its hash seed, and OSREP_SEED_HEX replays exactly those bytes,
# so one captured failure is enough to reproduce forever. Both properties are
# asserted below: the output must not vary run to run, and it must always
# round-trip -- the second catches a wrong digest even if determinism somehow
# held.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The seed of the archive that first exposed this, read straight out of it.
SEED=e765312fbb692a185e92603b4a1cbd9de481629f894d2212c69a6c1e254df35f
RUNS=${FUTURELZ_RACE_RUNS:-150}

source "$(dirname "$0")/_osrep_bin.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
# A repeating 4 KiB unit across 5 blocks: enough cross-block matches to keep the
# pipeline (and so the race window) busy, and small enough to run 150x.
unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
open(os.path.join(d, "src.bin"), "wb").write(unit * 75)
PY
SRC="$TMP/src.bin"

# -t16 gives PrepThreadsCount its maximum, which is where the race fires most.
CASES=(
    "v3-m5f|-m5f"
    "v3-m3f|-m3f"
    "v4-m5|-m5"
)

for case in "${CASES[@]}"; do
    IFS='|' read -r label flags <<<"$case"
    first_hash=""
    for i in $(seq 1 "$RUNS"); do
        arc="$TMP/$label.$i.osr"
        # shellcheck disable=SC2086
        OSREP_SEED_HEX="$SEED" $OSREP $flags -b64k -t16 "$SRC" "$arc" >/dev/null 2>&1 \
            || fail "[$label] compress failed on run $i"

        # The hook must have applied: the stored seed is the pinned one. Its
        # offset depends on the container -- v4's header is 16 bytes, v5's is
        # 28 -- so it is derived from the magic rather than hardcoded, which
        # lets this regression keep running against whatever the binary writes
        # by default (v5 since phase 5c-2) instead of being pinned to v4.
        if [[ -z "$first_hash" ]]; then
            stored=$(python3 -c "
import sys
d = open(sys.argv[1],'rb').read()
off = 28 if d[:4] == b'OSR5' else 16
print(d[off:off+32].hex())
" "$arc")
            [[ "$stored" == "$SEED" ]] \
                || fail "[$label] OSREP_SEED_HEX did not take effect (stored $stored)"
        fi

        # Round-trip: a torn digest shows up here even if the bytes were stable.
        $OSREP -d "$arc" "$TMP/$label.$i.out" >/dev/null 2>&1 \
            || fail "[$label] run $i produced an archive that does not decompress"
        cmp -s "$SRC" "$TMP/$label.$i.out" \
            || fail "[$label] run $i decoded to the wrong bytes"

        # Determinism: for a fixed seed the encoder must be byte-identical.
        h=$(md5sum "$arc" | cut -d' ' -f1)
        if [[ -z "$first_hash" ]]; then
            first_hash="$h"
        elif [[ "$h" != "$first_hash" ]]; then
            fail "[$label] run $i differs from run 1 with the same seed ($h != $first_hash)"
        fi
    done
    say "$label: $RUNS runs byte-identical and all round-tripped"
done

echo "futurelz_race_regression: passed=$(( ${#CASES[@]} * RUNS )) mismatches=0"
