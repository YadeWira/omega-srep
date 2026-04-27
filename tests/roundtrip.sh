#!/usr/bin/env bash
# Round-trip correctness gate for Omega SREP.
# For every corpus input × every -mN method, verifies that
# decompress(compress(x)) == x. Fails CI on any mismatch.
set -euo pipefail

BIN="${OSREP_BIN:-bin/osrep}"
CORPUS="${OSREP_CORPUS:-tests/corpus}"
WORK="$(mktemp -d -t osrep-roundtrip-XXXX)"

# Compression methods to exercise. Methods 0–5 are documented in srep.cpp.
METHODS=("-m0" "-m1" "-m2" "-m3" "-m4" "-m5")

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Run 'make' first." >&2
  exit 1
fi

if ! ls "$CORPUS"/*.bin >/dev/null 2>&1; then
  echo "Corpus missing — generating..."
  bash tests/gen_corpus.sh "$CORPUS"
fi

passed=0
failed=0
fail_log=()

for input in "$CORPUS"/*.bin; do
  name="$(basename "$input")"
  for m in "${METHODS[@]}"; do
    out="$WORK/$name.$m.osr"
    back="$WORK/$name.$m.out"

    if ! "$BIN" "$m" "$input" "$out" >/dev/null 2>&1; then
      printf 'FAIL  %-12s %-4s  (compress)\n' "$name" "$m"
      fail_log+=("compress: $name $m")
      failed=$((failed+1))
      continue
    fi

    if ! "$BIN" -d "$out" "$back" >/dev/null 2>&1; then
      printf 'FAIL  %-12s %-4s  (decompress)\n' "$name" "$m"
      fail_log+=("decompress: $name $m")
      failed=$((failed+1))
      continue
    fi

    if ! cmp -s "$input" "$back"; then
      printf 'FAIL  %-12s %-4s  (mismatch)\n' "$name" "$m"
      fail_log+=("mismatch: $name $m")
      failed=$((failed+1))
      continue
    fi

    printf 'OK    %-12s %-4s\n' "$name" "$m"
    passed=$((passed+1))
    rm -f "$out" "$back"
  done
done

echo
echo "passed=$passed failed=$failed"

if (( failed > 0 )); then
  echo "failures:"
  printf '  %s\n' "${fail_log[@]}"
  exit 1
fi
