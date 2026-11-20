#!/bin/bash
# OREP on streams longer than 4 GiB (output positions past 2^32; past 2^33
# with SIZE > 8g). Everything is streamed from tests/orep_bigsrc.c; only step
# (c) writes the encoded stream to a file, and deletes it.
#
#   tests/orep_big.sh <orep> [<orep-i386>]
#
# Environment:
#   SIZE=5g      input size (k/m/g suffix), > 4g to pass 2^32
#   SEED=1       generator seed
#   WORK=dir     scratch (default /mnt/IA_LAB/agentes/osrep/score/big4g/work)
#   OREP_REF=x   also encode with this (all-Pascal) build and compare bytes
#   CAGE=0       do not wrap each step in a 6G systemd scope (default 1)
#
# Steps (sequential; each in its own cage):
#  a  gen | orep -w1024m -t4 | orep -d   -> sha of the round trip, plus the
#     sha and size of the encoded stream (tee'd through fifos, no file)
#  b  the same with -t1; the encoded sha must equal (a)'s
#  c  -w2040m -l512 -t4 to a file, decode the file, compare, delete it
#  d  (OREP_REF) the reference build with -w1024m -t4: encoded sha = (a)'s
#  e  (i386) -w1024m -t4: encoded sha = (a)'s and the round trip is right,
#     or a clean failure (exit 1..127 with a message, no output accepted)
#  f  (i386) -w2040m -l512: works (sha = (c)'s) or fails cleanly
# Reports wall time and peak RSS of every encoder and decoder.
set -u
OREP=${1:?usage: orep_big.sh <orep> [<orep-i386>]}
OREP32=${2:-}
SIZE=${SIZE:-5g}
SEED=${SEED:-1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/mnt/IA_LAB/agentes/osrep/score/big4g/work}
export TMPDIR=${TMPDIR:-/mnt/IA_LAB/agentes/osrep/score/tmp}
CAGE=${CAGE:-1}
mkdir -p "$WORK" "$TMPDIR"
WORK=$(cd "$WORK" && pwd)
OREP=$(cd "$(dirname "$OREP")" && pwd)/$(basename "$OREP")
[ -n "$OREP32" ] && OREP32=$(cd "$(dirname "$OREP32")" && pwd)/$(basename "$OREP32")
GEN=$WORK/orep_bigsrc
gcc -O2 -o "$GEN" "$ROOT/tests/orep_bigsrc.c" || exit 1

fail=0
say() { echo "$@"; }
bad() { echo "FAIL: $*"; fail=1; }

cage() {
  if [ "$CAGE" = 1 ]; then
    systemd-run --user --scope --quiet --slice=osrep-review.slice \
      -p MemoryMax=6G -p MemorySwapMax=0 -p OOMPolicy=continue -- "$@"
  else
    "$@"
  fi
}

# One streaming round trip, run inside a cage by roundtrip().
#   rt_inner <tag> <enc> <dec> <enc opts...>
# writes $WORK/<tag>.{raw,enc,rt}.sha, <tag>.enc.size, <tag>.{enc,dec}.time,
# <tag>.rc (exit codes of gen, tee, enc, tee, dec, sha)
rt_inner() {
  tag=$1 enc=$2 dec=$3; shift 3
  cd "$WORK" || exit 1
  rm -f "$tag".f1 "$tag".f2 "$tag".f3
  mkfifo "$tag".f1 "$tag".f2 "$tag".f3
  sha256sum < "$tag".f1 > "$tag".raw.sha & p1=$!
  sha256sum < "$tag".f2 > "$tag".enc.sha & p2=$!
  wc -c < "$tag".f3 > "$tag".enc.size & p3=$!
  "$GEN" "$SIZE" "$SEED" -v 2> "$tag".gen.log | tee "$tag".f1 |
    /usr/bin/time -f '%e s, %M KB' -o "$tag".enc.time "$enc" -q "$@" - - 2> "$tag".enc.err |
    tee "$tag".f2 "$tag".f3 |
    /usr/bin/time -f '%e s, %M KB' -o "$tag".dec.time "$dec" -q -d - - 2> "$tag".dec.err |
    sha256sum > "$tag".rt.sha
  echo "${PIPESTATUS[*]}" > "$tag".rc
  wait $p1 $p2 $p3
  rm -f "$tag".f1 "$tag".f2 "$tag".f3
}
export -f rt_inner
export WORK GEN SIZE SEED

sha() { cut -c1-64 "$WORK/$1"; }

roundtrip() { # roundtrip <tag> <enc> <dec> <opts...>
  tag=$1
  t0=$(date +%s)
  cage bash -c 'rt_inner "$@"' rt "$@"
  t1=$(date +%s)
  say "[$tag] $(cat "$WORK/$tag.gen.log")"
  say "[$tag] wall $((t1 - t0)) s; enc $(tail -1 "$WORK/$tag.enc.time"); dec $(tail -1 "$WORK/$tag.dec.time")"
  say "[$tag] exit codes (gen tee enc tee dec sha): $(cat "$WORK/$tag.rc")"
  say "[$tag] encoded $(cat "$WORK/$tag.enc.size") bytes, sha $(sha "$tag.enc.sha")"
}

ok_rc() { [ "$(cat "$WORK/$1.rc")" = "0 0 0 0 0 0" ]; }

# a, b
roundtrip a "$OREP" "$OREP" -w1024m -t4
RAW=$(sha a.raw.sha)
say "[a] input sha $RAW"
ok_rc a || bad "a: nonzero exit"
[ "$(sha a.rt.sha)" = "$RAW" ] || bad "a: round trip differs"
ENC_A=$(sha a.enc.sha)

roundtrip b "$OREP" "$OREP" -w1024m -t1
ok_rc b || bad "b: nonzero exit"
[ "$(sha b.raw.sha)" = "$RAW" ] || bad "b: generator not deterministic"
[ "$(sha b.rt.sha)" = "$RAW" ] || bad "b: round trip differs"
[ "$(sha b.enc.sha)" = "$ENC_A" ] || bad "b: -t1 encodes differently from -t4"

# c: -w2040m, encoder and decoder in separate cages (about 4.2G + 2.1G)
c_inner() {
  cd "$WORK" || exit 1
  # the file can not be larger than the input plus framing
  case $SIZE in
    *g|*G) kb=$(( ${SIZE%?} * 1024 * 1024 )) ;;
    *m|*M) kb=$(( ${SIZE%?} * 1024 )) ;;
    *k|*K) kb=${SIZE%?} ;;
    *) kb=$(( SIZE / 1024 )) ;;
  esac
  ulimit -f $(( kb + kb / 8 + 65536 ))
  "$GEN" "$SIZE" "$SEED" |
    /usr/bin/time -f '%e s, %M KB' -o c.enc.time "$1" -q -w2040m -l512 -t4 - c.orep
  echo "${PIPESTATUS[*]}" > c.erc
}
c_dec() {
  cd "$WORK" || exit 1
  /usr/bin/time -f '%e s, %M KB' -o "$2".dec.time "$1" -q -d c.orep - 2> "$2".dec.err |
    sha256sum > "$2".rt.sha
  echo "${PIPESTATUS[*]}" > "$2".drc
}
export -f c_inner c_dec
t0=$(date +%s)
cage bash -c 'c_inner "$@"' c "$OREP"
t1=$(date +%s)
ENC_C=$(sha256sum < "$WORK/c.orep" | cut -c1-64)
say "[c] encode wall $((t1 - t0)) s; enc $(tail -1 "$WORK/c.enc.time"); exit $(cat "$WORK/c.erc")"
say "[c] encoded $(stat -c %s "$WORK/c.orep") bytes, sha $ENC_C"
[ "$(cat "$WORK/c.erc")" = "0 0" ] || bad "c: encoder failed"
t0=$(date +%s)
cage bash -c 'c_dec "$@"' c "$OREP" c
t1=$(date +%s)
say "[c] decode wall $((t1 - t0)) s; dec $(tail -1 "$WORK/c.dec.time"); exit $(cat "$WORK/c.drc")"
[ "$(cat "$WORK/c.drc")" = "0 0" ] || bad "c: decoder failed: $(cat "$WORK/c.dec.err")"
[ "$(sha c.rt.sha)" = "$RAW" ] || bad "c: round trip differs"

# f needs c.orep: decode the 64-bit stream with the i386 decoder too
if [ -n "$OREP32" ]; then
  t0=$(date +%s)
  cage bash -c 'c_dec "$@"' c "$OREP32" f64
  t1=$(date +%s)
  rc=$(cat "$WORK/f64.drc")
  say "[f] i386 decode of the x86_64 -w2040m stream: wall $((t1 - t0)) s; dec $(tail -1 "$WORK/f64.dec.time"); exit $rc; $(head -c 300 "$WORK/f64.dec.err")"
  if [ "$rc" = "0 0" ]; then
    [ "$(sha f64.rt.sha)" = "$RAW" ] || bad "f: i386 decode exit 0 but output differs"
  else
    d=${rc%% *}
    { [ "$d" -ge 1 ] && [ "$d" -lt 128 ] && [ -s "$WORK/f64.dec.err" ]; } ||
      bad "f: i386 decoder did not fail cleanly (exit $d)"
  fi
fi
rm -f "$WORK/c.orep"

# d: reference build
if [ -n "${OREP_REF:-}" ]; then
  roundtrip d "$OREP_REF" "$OREP_REF" -w1024m -t4
  ok_rc d || bad "d: nonzero exit"
  [ "$(sha d.rt.sha)" = "$RAW" ] || bad "d: round trip differs"
  [ "$(sha d.enc.sha)" = "$ENC_A" ] || bad "d: reference encodes differently"
fi

# clean(tag): exit codes of a failed i386 run are clean (no signal, message
# printed); the decoder's output is then not compared
clean_or_ok() { # clean_or_ok <tag> <expected enc sha>
  tag=$1
  if ok_rc "$tag"; then
    [ "$(sha "$tag".enc.sha)" = "$2" ] || bad "$tag: encodes differently from x86_64"
    [ "$(sha "$tag".rt.sha)" = "$RAW" ] || bad "$tag: round trip differs"
    say "[$tag] OK: same bytes as x86_64, round trip right"
  else
    set -- $(cat "$WORK/$tag.rc")
    for x in "$@"; do
      [ "$x" -lt 128 ] || bad "$tag: killed by a signal (exit $x)"
    done
    [ "$5" != 0 ] || [ "$(sha "$tag".rt.sha)" = "$RAW" ] ||
      bad "$tag: decoder exit 0 with wrong output"
    say "[$tag] failed cleanly: enc exit $3, dec exit $5; enc says: $(head -c 300 "$WORK/$tag.enc.err"); dec says: $(head -c 300 "$WORK/$tag.dec.err")"
  fi
}

if [ -n "$OREP32" ]; then
  roundtrip e "$OREP32" "$OREP32" -w1024m -t4
  clean_or_ok e "$ENC_A"
  roundtrip f "$OREP32" "$OREP32" -w2040m -l512 -t4
  clean_or_ok f "$ENC_C"
fi

if [ $fail = 0 ]; then echo "orep_big: all passed (SIZE=$SIZE SEED=$SEED)"; else echo "orep_big: FAILED"; fi
exit $fail
