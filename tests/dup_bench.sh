#!/usr/bin/env bash
# F5.4 -dup vs baseline benchmark.
#
# Replicates Bulat's FA 0.11 measurement on a smaller corpus that fits
# this 7 GiB box. Corpus is deliberately constructed with long-range
# duplicates (a 32 MiB block repeated 4x = 128 MiB total): the
# textbook case where -dup should win. Without -dup, SREP's Future-LZ
# has to track all 3 future copies of the first block in RAM; with
# -dup, the dedup pre-pass strips 96 MiB up front and SREP only ever
# sees the 32 MiB unique-chunk stream.
#
# We measure peak RSS only on the `osrep` invocations (not on the
# dedup_test split-encode/split-decode steps). The dedup wrapper's
# full-buffer read is an artifact of the F5.3a shell pipeline; the
# production -dup integration (F5.3b) will stream. This bench is
# about whether the F5 design saves SREP RAM, not pipeline overhead.
#
# Tunables via env:
#   OSREP_BENCH_DIR       cache dir for the corpus (default ~/.osrep-bench)
#   OSREP_BENCH_BLOCK_MB  block size MiB           (default 32)
#   OSREP_BENCH_REPEATS   block repetitions        (default 4)
#   OSREP_BENCH_METHOD    osrep method             (default -m4)
#   OSREP_BENCH_OUT       results doc path         (default docs/dup-bench.md)

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BENCH_DIR="${OSREP_BENCH_DIR:-$HOME/.osrep-bench}"
BLOCK_MB="${OSREP_BENCH_BLOCK_MB:-32}"
REPEATS="${OSREP_BENCH_REPEATS:-4}"
METHOD="${OSREP_BENCH_METHOD:--m4}"
# CDC buffer size: matches FA's `-b` default of 8 MiB. Buffer-bounded
# CDC is what makes long-range duplicate blocks dedupe cleanly. A
# divisor of BLOCK_MB so identical block-repetitions split into
# identical buffers.
BUF_BYTES="${OSREP_BENCH_BUF:-$((8 * 1024 * 1024))}"
OUT_DOC="${OSREP_BENCH_OUT:-docs/dup-bench.md}"

mkdir -p "$BENCH_DIR"
[[ -x bin/osrep      ]] || make bin/osrep
[[ -x bin/dedup_test ]] || make bin/dedup_test

INPUT="$BENCH_DIR/dup_bench_in_${BLOCK_MB}x${REPEATS}.bin"

if [[ ! -f "$INPUT" ]]; then
    echo "generating $INPUT (block=${BLOCK_MB}M x ${REPEATS}) ..."
    python3 - <<PY > "$INPUT"
import os, sys, struct
BLOCK = ${BLOCK_MB} * 1024 * 1024
REPS = ${REPEATS}

def xs(s):
    while True:
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        yield s

text = (b"Omega SREP -dup benchmark; long-range duplicate fodder. " * 1024)[:1024 * 1024]
gen = xs(0xDEADBEEF)
binbuf = bytearray(BLOCK - len(text))
for i in range(0, len(binbuf), 8):
    v = next(gen)
    binbuf[i:i+8] = struct.pack("<Q", v)
block = text + bytes(binbuf)
assert len(block) == BLOCK
out = sys.stdout.buffer
for _ in range(REPS):
    out.write(block)
PY
fi
INPUT_SIZE=$(stat -c%s "$INPUT")
echo "input: $INPUT ($INPUT_SIZE bytes = $((INPUT_SIZE / 1024 / 1024)) MiB)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# measure.py runs the command, prints "max_rss_kib elapsed_secs".
# Each invocation is a fresh python3 process, so getrusage(RUSAGE_CHILDREN)
# is isolated per measurement (no leakage between A_compress, B_compress, etc).
measure() {
    local label="$1"
    shift
    python3 tests/measure.py "$@"
}

# ----- Config A: osrep -mN baseline (no -dup) -----
A_OSR="$WORK/A.osr"
A_DEC="$WORK/A.bin"

read RSS_A_C TIME_A_C <<< "$(measure A_compress ./bin/osrep "$METHOD" "$INPUT" "$A_OSR")"
A_OSR_SIZE=$(stat -c%s "$A_OSR")
read RSS_A_D TIME_A_D <<< "$(measure A_decompress ./bin/osrep -d "$A_OSR" "$A_DEC")"
cmp -s "$INPUT" "$A_DEC" || { echo "A round-trip mismatch"; exit 1; }

# ----- Config B: -dup pipeline (F5.3a) -----
B_META="$WORK/B.meta"
B_BODY="$WORK/B.body"
B_BODY_OSR="$WORK/B.body.osr"
B_ARCHIVE="$WORK/B.osrd"
B_BODY_DEC="$WORK/B.body.dec"
B_DEC="$WORK/B.bin"

./bin/dedup_test split-encode "$INPUT" "$B_META" "$B_BODY" --buf "$BUF_BYTES" >/dev/null
META_SIZE=$(stat -c%s "$B_META")
BODY_SIZE=$(stat -c%s "$B_BODY")

read RSS_B_C TIME_B_C <<< "$(measure B_compress ./bin/osrep "$METHOD" "$B_BODY" "$B_BODY_OSR")"

cat "$B_BODY_OSR" "$B_META" > "$B_ARCHIVE"
python3 -c "
import sys, struct
sys.stdout.buffer.write(struct.pack('<Q', $META_SIZE))
sys.stdout.buffer.write(b'ODUP')
" >> "$B_ARCHIVE"
B_ARCH_SIZE=$(stat -c%s "$B_ARCHIVE")
B_BODY_OSR_SIZE=$(stat -c%s "$B_BODY_OSR")

dd if="$B_ARCHIVE" of="$WORK/B_body_osr_dec" bs=1M count="$B_BODY_OSR_SIZE" iflag=count_bytes status=none
dd if="$B_ARCHIVE" of="$WORK/B_meta_dec"     bs=1  skip="$B_BODY_OSR_SIZE" count="$META_SIZE" status=none

read RSS_B_D TIME_B_D <<< "$(measure B_decompress ./bin/osrep -d "$WORK/B_body_osr_dec" "$B_BODY_DEC")"
./bin/dedup_test split-decode "$WORK/B_meta_dec" "$B_BODY_DEC" "$B_DEC" >/dev/null
cmp -s "$INPUT" "$B_DEC" || { echo "B round-trip mismatch"; exit 1; }

RATIO_ARCH=$(python3 -c "print(f'{$B_ARCH_SIZE/$A_OSR_SIZE*100:.1f}')")
DELTA_RSS_C=$(python3 -c "print(f'{(1 - $RSS_B_C/$RSS_A_C)*100:.1f}')")
DELTA_RSS_D=$(python3 -c "print(f'{(1 - $RSS_B_D/$RSS_A_D)*100:.1f}')")

mkdir -p "$(dirname "$OUT_DOC")"
{
    echo "# Omega SREP \`-dup\` benchmark (F5.4)"
    echo
    echo "Generated by \`tests/dup_bench.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo
    echo "## Setup"
    echo
    echo "- Host: \`$(uname -srm)\`, $(nproc) cores, $(awk '/MemTotal/ {printf "%.1f GiB\n", $2/1024/1024}' /proc/meminfo) RAM"
    echo "- Method: \`$METHOD\`"
    echo "- CDC buffer size: $((BUF_BYTES / 1024 / 1024)) MiB (\`--buf=$BUF_BYTES\`)"
    echo "- Input: ${BLOCK_MB} MiB block × ${REPEATS} = $((INPUT_SIZE / 1024 / 1024)) MiB total"
    echo "- Block content: 1 MiB text + $((BLOCK_MB - 1)) MiB xorshift64 binary, repeated identically"
    echo
    echo "RSS measurements use \`tests/measure.py\` (a Python wrapper"
    echo "around \`getrusage(RUSAGE_CHILDREN)\`, since GNU \`time\` isn't"
    echo "installed on this host) and cover only the \`osrep\` invocation."
    echo "The F5.3a wrapper's split-encode and split-decode steps are"
    echo "excluded — they read the full input into a contiguous buffer"
    echo "and would dominate the comparison; F5.3b's native integration"
    echo "will stream and remove that overhead."
    echo
    echo "## Results"
    echo
    echo "| metric                       | A (\`$METHOD\`) | B (\`$METHOD -dup\`) | delta |"
    echo "|------------------------------|---------------:|--------------------:|------:|"
    echo "| archive size (bytes)         | $A_OSR_SIZE | $B_ARCH_SIZE | ${RATIO_ARCH}% of A |"
    echo "| compress peak RSS (KiB)      | $RSS_A_C | $RSS_B_C | -${DELTA_RSS_C}% |"
    echo "| decompress peak RSS (KiB)    | $RSS_A_D | $RSS_B_D | -${DELTA_RSS_D}% |"
    echo "| compress wall-clock (s)      | $TIME_A_C | $TIME_B_C | |"
    echo "| decompress wall-clock (s)    | $TIME_A_D | $TIME_B_D | |"
    echo
    echo "## Pipeline structure (B)"
    echo
    echo "- meta blob (chunk table): $META_SIZE bytes"
    echo "- body (unique chunks): $BODY_SIZE bytes (= $((BODY_SIZE * 100 / INPUT_SIZE))% of input)"
    echo "- body.osr (post-SREP): $B_BODY_OSR_SIZE bytes"
    echo "- final archive: $B_ARCH_SIZE bytes (body.osr + meta + 12-byte ODUP trailer)"
    echo
    echo "## Success criterion"
    echo
    echo "Design target: B's peak decompress RSS < A's by >=50% with archive bloat <=10%."
    echo
    echo "- decompress peak RSS reduction: -${DELTA_RSS_D}% (target >=50%)"
    echo "- archive size: ${RATIO_ARCH}% of A (target <=110%)"
} > "$OUT_DOC"

cat "$OUT_DOC"
echo
echo "wrote $OUT_DOC"
