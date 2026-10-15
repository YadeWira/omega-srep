#!/usr/bin/env bash
# tests/pgo_train.sh -- training-workload driver for the PGO release build
# (`make -C oracles/cxx bin/osrep-pgo`, see oracles/cxx/Makefile). Exercises the instrumented binary
# across every -mN mode (not just the ones this task cared about) and at
# both -t1 and a multi-thread value, so GCC's profile-guided branch-layout
# and inlining decisions don't overfit to whichever mode/thread-count
# happened to get trained -- -m3/-m4/-m5 have measurably different hot-loop
# profiles (see docs/research-notes.md's F3.3e section), and -m1/-m2's CDC
# thread pool is a genuinely different code path from -m3/-m5's
# prepare_buffer stripe pool.
#
# Usage: bash tests/pgo_train.sh <instrumented-binary> <profile-dir>
#   Called by `make -C oracles/cxx pgo-train`; not normally run by hand.
#
# Training corpus: tests/corpus/*.bin (small, deterministic, always present,
# no external dependency -- see docs, "required minimum" tier). If larger
# real-world corpora used by tests/multi_corpus_bench.sh are present on the
# maintainer's release-build machine (enwik8, data.tar), training against
# those too is recommended but optional -- add them to CORPUS_FILES below
# via an env override before running `make -C oracles/cxx bin/osrep-pgo` on that machine.
set -eu

BIN="${1:?usage: pgo_train.sh <instrumented-binary> <profile-dir>}"
PROFILE_DIR="${2:?usage: pgo_train.sh <instrumented-binary> <profile-dir>}"

# `make -C oracles/cxx pgo-train` runs this from the repository root and
# passes BIN and PROFILE_DIR as absolute paths. The corpus is reached
# through ROOT, so the script also works from any other directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ROOT/tests/corpus"

if [[ ! -d "$CORPUS" ]] || [[ -z "$(ls -A "$CORPUS" 2>/dev/null)" ]]; then
  echo "Generating corpus..."
  bash "$ROOT/tests/gen_corpus.sh" "$CORPUS"
fi

# Extra real-world corpus files, space-separated, override via env for a
# maintainer's release-build machine. Not required -- see header comment.
CORPUS_FILES="$CORPUS/tiny.bin $CORPUS/zeros.bin $CORPUS/random.bin $CORPUS/mixed.bin $CORPUS/text.bin ${PGO_EXTRA_CORPUS:-}"

WORK="$(mktemp -d -t osrep-pgo-train-XXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "PGO training: profile data -> $PROFILE_DIR"
for input in $CORPUS_FILES; do
  [[ -f "$input" ]] || { echo "  (skip, not found: $input)"; continue; }
  for m in 0 1 2 3 4 5; do
    for t in 1 8; do
      out="$WORK/train.osr"
      dec="$WORK/train.dec"
      "$BIN" -m"$m" -t"$t" "$input" "$out"   >/dev/null 2>&1 || true
      "$BIN" -d       -t"$t" "$out"   "$dec" >/dev/null 2>&1 || true
      rm -f "$out" "$dec"
    done
  done
  echo "  trained on $input (all -mN, -t1 and -t8)"
done

echo "PGO training done. Profile data in $PROFILE_DIR/*.gcda."
