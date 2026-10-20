#!/usr/bin/env bash
# Regression for the accelerated scan's bitarr size (-aN) on real data.
#
# The repo's synthetic inputs do not distinguish -a8 from -a16: text, mixed,
# zeros, random, zruns, text200k and a dozen generated 8-32 MiB shapes write
# the same archive with both. A port that clamped N to 8 would pass every
# other suite. Real data does distinguish them: 32 MiB of a tarball of mixed
# files, -m4 -l16/-l32, write different archives with -a8 and -a16 -- and the
# ports match the C++ on all four.
#
# This is a differential gate: it needs the C++ oracle. It also asserts that
# the C++ still tells -a8 from -a16; if it stops, the sample no longer covers
# the bitarr and this gate would be lying (silently passing everything).
#
# The sample is not in the repo, so the script skips cleanly (exit 0) when it
# is missing: default is the benchmark tarball of the releases, and
# OSREP_REAL_TAR (or $1) points it elsewhere.
#
# Usage: tests/real_world_scan_regression.sh [/path/to/mixed-files.tar]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SRC="${1:-${OSREP_REAL_TAR:-/mnt/IA_LAB/agentes/osrep/fase8/real.tar}}"
if [ ! -f "$SRC" ]; then
    say "no real sample at $SRC -- skipping (set OSREP_REAL_TAR to a tarball of mixed files)"
    exit 0
fi

PORT="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$PORT" ] || fail "missing port binary $PORT (bash pascal/build.sh)"
[ -x "$CXX_BIN/osrep" ] || make_cxx bin/osrep >/dev/null 2>&1
[ -x "$CXX_BIN/osrep" ] || fail "missing C++ oracle $CXX_BIN/osrep"
warn_shared_wine "$PORT"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
head -c $((32 * 1024 * 1024)) "$SRC" > "$TMP/in.bin"
[ "$(stat -c%s "$TMP/in.bin")" -eq $((32 * 1024 * 1024)) ] \
    || fail "the sample is smaller than 32 MiB"
say "input: 32 MiB of $(basename "$SRC")"

pass=0
CHECK_SUM=""

check() {  # check OPTS -> md5 of the C++ archive in $CHECK_SUM
    local opts=$1
    # shellcheck disable=SC2086
    "$CXX_BIN/osrep" -t1 $opts --seed=7 "$TMP/in.bin" "$TMP/cpp.osr" >/dev/null 2>&1 \
        || fail "C++ failed on $opts"
    # shellcheck disable=SC2086
    "$PORT" --format=v4 $opts --seed=7 "$TMP/in.bin" "$TMP/port.osr" >/dev/null 2>&1 \
        || fail "port failed on $opts"
    cmp -s "$TMP/cpp.osr" "$TMP/port.osr" \
        || fail "$opts: the port differs from the C++"
    "$PORT" -d "$TMP/port.osr" "$TMP/dec" >/dev/null 2>&1 \
        && cmp -s "$TMP/in.bin" "$TMP/dec" \
        || fail "$opts: the port's archive does not decode back to the input"
    pass=$((pass + 1))
    CHECK_SUM=$(md5sum < "$TMP/cpp.osr" | cut -c1-32)
}

for l in 16 32; do
    check "-m4 -l$l -a8";  a8=$CHECK_SUM
    check "-m4 -l$l -a16"; a16=$CHECK_SUM
    [ "$a8" != "$a16" ] \
        || fail "-m4 -l$l: -a8 and -a16 write the same archive on this sample, so it no longer covers the bitarr size (R11); use a more varied tarball"
    say "-m4 -l$l: -a8 $a8, -a16 $a16, the port matches both"
    pass=$((pass + 1))
done

echo "  real_world_scan_regression: passed=$pass mismatches=0"
