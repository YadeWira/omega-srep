#!/usr/bin/env bash
# The inputs of the golden suite, in $1. Same bytes on every run: the corpus
# comes from tests/gen_corpus.sh (fixed seeds) and the rest from fixed seeds
# here. The suite must stay runnable without the oracles, so nothing is taken
# from the C++ or the Rust tree.
set -eu

D=$1
[ -n "$D" ] || { echo "usage: inputs.sh <dir>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$D"

CORPUS="$ROOT/tests/corpus"
[ -f "$CORPUS/text.bin" ] || bash "$ROOT/tests/gen_corpus.sh" "$CORPUS" >&2
cp "$CORPUS"/*.bin "$D"/

python3 - "$D" <<'PY'
import os, random, sys
d = sys.argv[1]
# Random runs between runs of zeros: where the accelerated scan's bitarr
# batches and the -m3 digest windows actually matter. Same generator and seed
# as tests/pascal_encode_conformance.sh.
r = random.Random(20261015)
out = bytearray()
while len(out) < 240000:
    out += bytes(r.randrange(256) for _ in range(r.randint(500, 3000)))
    out += bytes(r.randint(1000, 5000))
open(os.path.join(d, "zruns.bin"), "wb").write(out)
open(os.path.join(d, "empty.bin"), "wb").write(b"")
PY
