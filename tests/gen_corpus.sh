#!/usr/bin/env bash
# Generates a deterministic round-trip test corpus for Omega SREP.
# Same inputs on every run (fixed seeds, fixed text). Safe to re-run.
set -eu
# Note: no `pipefail` — `yes | head` is expected to SIGPIPE `yes`,
# which would otherwise abort the script under pipefail.

OUT="${1:-tests/corpus}"
mkdir -p "$OUT"

# 1. Highly compressible repeating text (4 MiB) — exercises REP's strong path.
yes "Omega SREP round-trip corpus payload, repeated for compressibility. " \
  | head -c $((4 * 1024 * 1024)) > "$OUT/text.bin"

# 2. Zeros (256 KiB) — degenerate input, exercises run handling.
head -c $((256 * 1024)) /dev/zero > "$OUT/zeros.bin"

# 3. Pseudo-random (2 MiB) with fixed seed — worst case for compression,
#    catches bugs in the no-match path. random.randbytes is Python 3.9+.
python3 -c "import random, sys; random.seed(42); sys.stdout.buffer.write(random.randbytes(2*1024*1024))" \
  > "$OUT/random.bin"

# 4. Mixed (text + zeros + random concatenated) — tests block boundaries.
cat "$OUT/text.bin" "$OUT/zeros.bin" "$OUT/random.bin" > "$OUT/mixed.bin"

# 5. Tiny (1 KiB) — boundary case, smaller than the default block size.
yes "tiny payload " | head -c 1024 > "$OUT/tiny.bin"

ls -la "$OUT"
