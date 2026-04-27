#!/usr/bin/env bash
# Format-corruption fuzz for `-dup` archives.
#
# Takes a known-good `-dup` archive and deliberately corrupts each
# region (ODUP magic, meta_size, DUPR magic, chunk-table bytes, body
# bytes, truncation). For every corruption variant, asserts that
# `osrep -d`:
#   - exits non-zero (refuses the archive), OR
#   - exits 0 only if output cmp's clean against original (corruption
#     happened to land in unread region — rare, accepted), AND
#   - never crashes (no SIGSEGV / SIGABRT / SIGBUS), AND
#   - never silently produces wrong output that compares OK.
#
# This is the "user transferred archive over flaky network" scenario:
# the failure mode we want is a clean error, not data loss.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$(dirname "$0")/_winpath.sh"

[[ -x bin/osrep ]] || make bin/osrep

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a baseline -dup archive that we can corrupt.
python3 -c "
import sys
unit = b'corruption fuzz payload, repeating block. ' * 200
body = (b'A' * 4096 + b'B' * 4096) * 32
sys.stdout.buffer.write(unit + body + body + unit + body)
" > "$TMP/in.bin"

./bin/osrep -dup -m4 "$TMP/in.bin" "$TMP/good.osr" >/dev/null 2>&1
GOOD_SIZE=$(stat -c%s "$TMP/good.osr")
echo "baseline archive: $GOOD_SIZE bytes"

mutate_byte() {
    local off="$1"
    local newval="$2"
    cp "$TMP/good.osr" "$TMP/corrupt.osr"
    python3 -c "
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(int(sys.argv[2]))
    f.write(bytes([int(sys.argv[3], 0)]))
" "$(winpath "$TMP/corrupt.osr")" "$off" "$newval"
}

mutate_u64() {
    local off="$1"
    local val="$2"
    cp "$TMP/good.osr" "$TMP/corrupt.osr"
    python3 -c "
import sys, struct
with open(sys.argv[1], 'r+b') as f:
    f.seek(int(sys.argv[2]))
    f.write(struct.pack('<Q', int(sys.argv[3], 0)))
" "$(winpath "$TMP/corrupt.osr")" "$off" "$val"
}

# Run osrep -d on $TMP/corrupt.osr; classify outcome.
classify_outcome() {
    local label="$1"
    local out="$TMP/dec.bin"
    rm -f "$out"
    set +e
    timeout --foreground 10 ./bin/osrep -d "$TMP/corrupt.osr" "$out" >/dev/null 2>&1
    local rc=$?
    set -e
    case "$rc" in
        0)
            if [[ -f "$out" ]] && cmp -s "$TMP/in.bin" "$out"; then
                echo "OK    $label (rc=0, bytes match — corruption in unread region)"
                return 0
            else
                echo "FAIL  $label (rc=0 with WRONG output — silent data corruption!)"
                return 1
            fi
            ;;
        124)
            echo "FAIL  $label (timeout — possible infinite loop)"
            return 1
            ;;
        139|134|136)
            echo "FAIL  $label (rc=$rc — process crashed on corrupted input!)"
            return 1
            ;;
        *)
            echo "OK    $label (rc=$rc, clean error reject)"
            return 0
            ;;
    esac
}

passed=0
failed=0

# 1. Corrupt ODUP magic (last 4 bytes).
for newval in 0x00 0x4F 0xFF 0xAA 0x42; do
    off=$((GOOD_SIZE - 1))
    mutate_byte "$off" "$newval"
    if classify_outcome "ODUP-magic-byte[-1]=$newval"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

# 2. Corrupt meta_size (8 bytes before ODUP magic).
for badval in 0 1 99 0xFFFFFFFFFFFFFFFF $((GOOD_SIZE * 1000)); do
    off=$((GOOD_SIZE - 12))
    mutate_u64 "$off" "$badval"
    if classify_outcome "meta_size=$badval"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

# 3. Corrupt DUPR magic at start of meta blob.
META_SIZE=$(python3 -c "
import sys, struct
data = open(sys.argv[1],'rb').read()
print(struct.unpack('<Q', data[-12:-4])[0])
" "$(winpath "$TMP/good.osr")")
META_OFFSET=$((GOOD_SIZE - 12 - META_SIZE))
for newval in 0x00 0x44 0xFF 0xCC 0x52; do
    mutate_byte "$META_OFFSET" "$newval"
    if classify_outcome "DUPR-magic-byte[0]=$newval"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

# 4. Corrupt mid-meta (chunk-table region).
for offset_into_meta in 24 50 100 $((META_SIZE / 2)) $((META_SIZE - 5)); do
    [[ "$offset_into_meta" -ge "$META_SIZE" ]] && continue
    off=$((META_OFFSET + offset_into_meta))
    mutate_byte "$off" 0xFF
    if classify_outcome "meta-byte[+$offset_into_meta]=0xFF"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

# 5. Corrupt body (SREP-compressed payload).
for offset in 100 1000 $((GOOD_SIZE / 4)) $((GOOD_SIZE / 2)); do
    [[ "$offset" -ge "$META_OFFSET" ]] && continue
    mutate_byte "$offset" 0xFF
    if classify_outcome "body-byte[$offset]=0xFF"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

# 6. Truncated archive (chop off last N bytes).
for chop in 4 12 50 1000; do
    [[ "$chop" -ge "$GOOD_SIZE" ]] && continue
    keep=$((GOOD_SIZE - chop))
    head -c "$keep" "$TMP/good.osr" > "$TMP/corrupt.osr"
    if classify_outcome "truncated-by-$chop-bytes"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

echo
echo "passed=$passed failed=$failed"
exit $(( failed == 0 ? 0 : 1 ))
