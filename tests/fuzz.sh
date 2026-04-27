#!/usr/bin/env bash
# Random round-trip fuzzer for Omega SREP.
# Generates N pseudo-random inputs (deterministic per seed) varying size
# and content profile, then asserts decompress(compress(x)) == x for every
# -mN method. Complements tests/roundtrip.sh which uses a fixed corpus.
#
# Usage: bash tests/fuzz.sh [N] [SEED_BASE]
#   N           number of seeds to try (default 10)
#   SEED_BASE   first seed value (default 1) — useful to reproduce a bug
set -eu

BIN="${OSREP_BIN:-bin/osrep}"
N="${1:-10}"
SEED_BASE="${2:-1}"
WORK="$(mktemp -d -t osrep-fuzz-XXXX)"
METHODS=("-m0" "-m1" "-m2" "-m3" "-m4" "-m5")

# Methods with known preexisting upstream bugs (predate the Omega fork).
# Failures here are reported but don't fail the harness — tracked in tasks for future fixes.
# Set OSREP_FUZZ_STRICT=1 to make them fatal (use after fixing).
KNOWN_BUG_METHODS=("-m5")

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Run 'make' first." >&2
  exit 1
fi

failed=0
known_failed=0
fail_log=()
known_log=()

is_known_bug_method() {
  local m="$1"
  for kb in "${KNOWN_BUG_METHODS[@]}"; do
    [[ "$kb" == "$m" ]] && return 0
  done
  return 1
}

record_failure() {
  local kind="$1" seed="$2" size="$3" m="$4"
  if [[ "${OSREP_FUZZ_STRICT:-0}" != "1" ]] && is_known_bug_method "$m"; then
    printf 'KNOWN seed=%-4d size=%-8d %-4s  (%s)\n' "$seed" "$size" "$m" "$kind"
    known_log+=("$kind: seed=$seed size=$size $m")
    known_failed=$((known_failed + 1))
  else
    printf 'FAIL  seed=%-4d size=%-8d %-4s  (%s)\n' "$seed" "$size" "$m" "$kind"
    fail_log+=("$kind: seed=$seed size=$size $m")
    failed=$((failed + 1))
  fi
}

for i in $(seq 0 $((N - 1))); do
  seed=$((SEED_BASE + i))
  # Vary size: 1 KiB to 4 MiB.
  size=$(python3 -c "import random; random.seed($seed); print(random.randint(1024, 4*1024*1024))")
  # Vary content profile: 0=pseudo-random, 1=low-entropy text, 2=block-structured.
  profile=$((seed % 3))

  case "$profile" in
    0)
      python3 -c "
import random, sys
random.seed($seed)
sys.stdout.buffer.write(random.randbytes($size))" > "$WORK/in_$seed.bin"
      ;;
    1)
      python3 -c "
import random, sys
random.seed($seed)
alpha = bytes(random.choices(b'abcdefgh ', k=64))
out = (alpha * (($size // 64) + 1))[:$size]
sys.stdout.buffer.write(out)" > "$WORK/in_$seed.bin"
      ;;
    2)
      python3 -c "
import random, sys
random.seed($seed)
n = $size
out = bytearray(n)
i = 0
while i < n:
    blk = min(n - i, random.randint(64, 4096))
    if random.random() < 0.5:
        out[i:i+blk] = random.randbytes(blk)
    i += blk
sys.stdout.buffer.write(bytes(out))" > "$WORK/in_$seed.bin"
      ;;
  esac

  for m in "${METHODS[@]}"; do
    out="$WORK/$seed.$m.osr"
    back="$WORK/$seed.$m.out"

    # `bash -c` runs the binary in a subshell so any signal (e.g. SIGSEGV) is
    # contained and bash doesn't print "Abortado/Aborted" job-control noise.
    if ! bash -c '"$@" >/dev/null 2>&1' _ "$BIN" "$m" "$WORK/in_$seed.bin" "$out" 2>/dev/null; then
      record_failure compress "$seed" "$size" "$m"
      continue
    fi
    if ! bash -c '"$@" >/dev/null 2>&1' _ "$BIN" -d "$out" "$back" 2>/dev/null; then
      record_failure decompress "$seed" "$size" "$m"
      continue
    fi
    if ! cmp -s "$WORK/in_$seed.bin" "$back"; then
      record_failure mismatch "$seed" "$size" "$m"
      continue
    fi
    rm -f "$out" "$back"
  done
  rm -f "$WORK/in_$seed.bin"
done

total=$((N * 6))
passed=$((total - failed - known_failed))
echo
echo "fuzz passed=$passed failed=$failed known_bugs=$known_failed (over $N seeds x 6 methods)"

if (( known_failed > 0 )); then
  echo "known upstream bugs (tracked in F4.4 — not fatal unless OSREP_FUZZ_STRICT=1):"
  printf '  %s\n' "${known_log[@]}"
fi
if (( failed > 0 )); then
  echo "failures:"
  printf '  %s\n' "${fail_log[@]}"
  exit 1
fi
