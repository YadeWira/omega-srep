#!/usr/bin/env bash
# Wall-clock vs CPU-time profile for Omega SREP across all -mN methods.
# Runs each method on a representative input and parses osrep's own
# banner ("Cpu X mb/s (Y sec), real Z mb/s (W sec) = N%") to expose
# how single-thread-bound each method is.
#
# Usage: bash tests/profile.sh [INPUT]
#   INPUT defaults to tests/corpus/text.bin (~4 MiB, highly compressible).
#
# Output: a small table — method, real_seconds, cpu_seconds,
# real_throughput_mbps, cpu_throughput_mbps, parallelism_pct.
# Higher parallelism_pct means more wall-time is overlapped across
# threads (currently only the BG I/O+hash thread, plus -m1/-m2's -tN).
set -eu

BIN="${OSREP_BIN:-bin/osrep}"
INPUT="${1:-tests/corpus/text.bin}"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found. Run 'make' first." >&2; exit 1
fi
if [[ ! -f "$INPUT" ]]; then
  echo "Generating corpus..."
  bash tests/gen_corpus.sh tests/corpus
fi

WORK="$(mktemp -d -t osrep-profile-XXXX)"
SIZE_BYTES=$(stat -c %s "$INPUT")
SIZE_MB=$(LC_ALL=C python3 -c "print(f'{${SIZE_BYTES} / (1024*1024):.2f}')")

printf 'input: %s (%s MiB)\n\n' "$INPUT" "$SIZE_MB"
printf '%-6s %10s %10s %10s %10s %12s\n' \
  method real_s cpu_s real_mbps cpu_mbps parallel_pct

for m in -m0 -m1 -m2 -m3 -m4 -m5; do
  out="$WORK/$m.osr"
  banner=$("$BIN" "$m" "$INPUT" "$out" 2>&1 | tr -d '\r' | grep -oE 'Cpu (inf|[0-9.]+) mb/s \([0-9.]+ sec\), real (inf|[0-9.]+) mb/s \([0-9.]+ sec\) = [0-9]+%' | tail -1)
  if [[ -z "$banner" ]]; then
    printf '%-6s %s\n' "$m" '<no timing in banner>'
    continue
  fi
  cpu_mbps=$(echo  "$banner" | sed -E 's/^Cpu ([0-9.]+) mb\/s.*/\1/')
  cpu_s=$(echo    "$banner" | sed -E 's/^Cpu [0-9.]+ mb\/s \(([0-9.]+) sec\).*/\1/')
  real_mbps=$(echo "$banner" | sed -E 's/.*real ([0-9.]+) mb\/s.*/\1/')
  real_s=$(echo   "$banner" | sed -E 's/.*real [0-9.]+ mb\/s \(([0-9.]+) sec\).*/\1/')
  pct=$(echo      "$banner" | sed -E 's/.* = ([0-9]+)%/\1/')
  printf '%-6s %10s %10s %10s %10s %12s\n' \
    "$m" "$real_s" "$cpu_s" "$real_mbps" "$cpu_mbps" "${pct}%"
done

cat <<'EOF'

Reading the table:
  parallel_pct = real / cpu — how well the wall-clock is being overlapped.
    100%  = no overlap; entire CPU time is spent on the critical path.
    < 50% = the BG thread (I/O + hash prep) is hiding ~half the work.
  Lower parallel_pct on a method => more headroom for threading.
EOF
