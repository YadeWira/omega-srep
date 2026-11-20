#!/bin/bash
# OREP decoder fuzzing against an independent oracle (tests/orep_spec.py,
# written from spec/orep-format.md only). Streams are built and mutated at
# the structure level with the CRCs recomputed, so the decoders must accept
# or reject on the structure itself, not on a CRC.
#
#   tests/orep_fuzz.sh <build dir> [N cases | --long <seconds>] [--seed S]
#                      [--bin "orep orep-ref ..."]
# FUZZ_ENC=<orep binary> encodes the seed streams (default <build dir>/orep).
#
# For every case and every binary (default orep and orep-ref in the build
# dir): decode file->file and stdin->stdout under a timeout; require no
# crash/hang, accept/reject equal to the oracle, and the oracle's bytes when
# accepted. A rejection with "out of memory" is tolerated only when the ring
# the stream asks for is over half the -M limit. Disagreements are copied to
# $FUZZ_KEEP (default $TMPDIR/orep-fuzz-keep). Exit 1 on any disagreement on
# a non-ambiguous case.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${1:?usage: orep_fuzz.sh <build dir> [N | --long secs] [--seed S]}
shift
N=3000
LONG=0
SEED=$(( $(date +%s) % 100000 ))
BINS="orep orep-ref"
while [ $# -gt 0 ]; do
  case $1 in
    --long) LONG=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --bin) BINS=$2; shift 2 ;;
    *) N=$1; shift ;;
  esac
done
: "${TMPDIR:?set TMPDIR}"
W=$TMPDIR/orep-fuzz.$$
KEEP=${FUZZ_KEEP:-$TMPDIR/orep-fuzz-keep}
MEM=256m
MEMB=$((256 * 1024 * 1024))
TO=${FUZZ_TIMEOUT:-20}
mkdir -p "$W/seeds" "$KEEP"
trap 'rm -rf "$W"' EXIT
ulimit -f 200000     # 100 MB per file at most
PY=python3
SPEC=$ROOT/tests/orep_spec.py

# ---- seed streams from the real encoder (small chunks so slots are crossed)
NAT=${FUZZ_ENC:-$B/orep}   # encoder for the seed streams
$PY - "$W/seeds" "$ROOT/tests/corpus" <<'EOF'
import sys, random
d, c = sys.argv[1], sys.argv[2]
rnd = open(c + '/random.bin', 'rb').read()
txt = open(c + '/text.bin', 'rb').read()
r = random.Random(7)
# repeats at many distances, runs, short periods, text
out = bytearray()
for k in range(30):
    out += rnd[k * 3000:k * 3000 + 4000]
    out += rnd[r.randrange(0, 60000):][:r.randrange(100, 6000)]
    out += bytes([k]) * r.randrange(0, 300)
    out += (b'ab%d' % k) * r.randrange(0, 50)
open(d + '/mix.in', 'wb').write(out[:300000])
open(d + '/text.in', 'wb').write((txt[:60000] * 4)[:200000])
open(d + '/runs.in', 'wb').write(b'\0' * 70000 + rnd[:5000] + b'\1' * 70000)
open(d + '/tiny.in', 'wb').write(b'hello')
open(d + '/empty.in', 'wb').write(b'')
EOF
i=0
for f in mix text runs tiny empty; do
  for o in "-b64k -w128k" "-b64k -w64k -a1" "-b64k -w100000 -a4096 -l4096" "-b64k -w100000 -a3 -l16" \
           "-b128k -w1m -l16 -s16" "-b64k -w1k -a4"; do
    i=$((i + 1))
    timeout 60 "$NAT" -q $o "$W/seeds/$f.in" "$W/seeds/s$i-$f.orep" 2>/dev/null
    if ! $PY "$SPEC" decode "$W/seeds/s$i-$f.orep" "$W/seeds/chk" >/dev/null ||
       ! cmp -s "$W/seeds/chk" "$W/seeds/$f.in"; then
      echo "ORACLE/ENCODER MISMATCH on seed $f ($o)"; exit 1
    fi
    $PY "$SPEC" roundtrip "$W/seeds/s$i-$f.orep" >/dev/null ||
      { echo "builder does not reproduce seed $f ($o)"; exit 1; }
  done
done
rm -f "$W/seeds"/*.in "$W/seeds/chk"

total=0; bad=0; ambig=0; memok=0; nvalid=0; ninvalid=0; runs=0
declare -A tagbad
T0=$(date +%s)

run_one() { # bin mode case out -> sets rc, txt
  local bin=$1 mode=$2 c=$3 o=$4
  if [ "$mode" = file ]; then
    timeout -s KILL "$TO" "$bin" -d -q -M$MEM "$c" "$o" 2>"$W/err"
  else
    timeout -s KILL "$TO" "$bin" -d -q -M$MEM - - <"$c" >"$o" 2>"$W/err"
  fi
  rc=$?
  txt=$(head -c 200 "$W/err")
}

batch() {
  local seed=$1 n=$2 D=$W/b
  rm -rf "$D"
  $PY "$SPEC" gen --seed "$seed" --n "$n" --dir "$D" --seeds-dir "$W/seeds" ||
    { echo "generator failed (seed $seed)"; exit 1; }
  while IFS=$'\t' read -r fn verdict x R src tag amb; do
    total=$((total + 1))
    case $verdict in valid) nvalid=$((nvalid + 1)) ;; *) ninvalid=$((ninvalid + 1)) ;; esac
    for b in $BINS; do
      for mode in file pipe; do
        runs=$((runs + 1))
        run_one "$B/$b" $mode "$D/$fn" "$D/out"
        why=""
        if [ $rc -ge 124 ] || [[ $txt == *"Runtime error"* ]] ||
           [[ $txt == *"Exception"* ]] || [[ $txt == *"check error"* ]] ||
           [[ $txt == *"overflow"* ]] || [[ $txt == *"Access violation"* ]] ||
           [[ $txt == *"Invalid pointer"* ]]; then
          why="crash/hang/runtime error rc=$rc: $txt"
        elif [ "$verdict" = valid ]; then
          if [ $rc -ne 0 ]; then
            if [[ $txt == *memory* ]] && [ "$R" -gt $((MEMB / 2)) ]; then
              memok=$((memok + 1)); continue
            fi
            why="rejected a valid stream: $txt"
          elif [ "$(sha256sum <"$D/out" | cut -c1-64)" != "$x" ]; then
            why="accepted with wrong output"
          fi
        else
          [ $rc -eq 0 ] && why="accepted an invalid stream ($verdict: $x)"
          [ $rc -eq 1 ] || [ -n "$why" ] || why="exit $rc"
        fi
        if [ -n "$why" ]; then
          if [ "$amb" = ambig ] && [[ $why != crash* ]]; then
            ambig=$((ambig + 1))
            tagbad["AMBIG $tag | $why"]=$((${tagbad["AMBIG $tag | $why"]:-0} + 1))
            cp "$D/$fn" "$KEEP/ambig-$fn" 2>/dev/null
          else
            bad=$((bad + 1))
            echo "DISAGREE $b $mode $fn [$src $tag] oracle=$verdict $x: $why"
            cp "$D/$fn" "$KEEP/$fn"
          fi
        fi
      done
    done
  done <"$D/manifest.tsv"
}

if [ "$LONG" -gt 0 ]; then
  s=$SEED
  while [ $(( $(date +%s) - T0 )) -lt "$LONG" ]; do
    batch $s 500
    s=$((s + 1))
    echo "  ... $(( $(date +%s) - T0 )) s: $total cases, $runs runs, $bad disagreements"
  done
else
  left=$N; s=$SEED
  while [ $left -gt 0 ]; do
    k=$(( left < 500 ? left : 500 ))
    batch $s $k
    left=$((left - k)); s=$((s + 1))
  done
fi
echo "seed $SEED: $total cases ($nvalid valid, $ninvalid invalid), $runs decoder runs, \
$bad disagreements, $ambig on ambiguous points, $memok memory-limit rejections"
for k in "${!tagbad[@]}"; do echo "  ${tagbad[$k]}x $k"; done | sort | head -40
[ $bad -eq 0 ]
