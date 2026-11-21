#!/bin/bash
# OREP: round trips, native == reference (same bytes), small windows that
# wrap the ring, stdin/stdout, corrupt or truncated streams rejected without
# crashing, the pinned format 4 streams (tests/fixtures/orep4), streaming
# and API edge cases (orep_edge.sh) and structure-aware fuzzing against the
# spec oracle (orep_fuzz.sh).
#
#   tests/orep.sh [build dir]      (default: builds into $TMPDIR/orep-test)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=${TMPDIR:?set TMPDIR}/orep-test.$$
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
B=${1:-}
if [ -z "$B" ]; then
  B=$W/build
  "$ROOT/scripts/build_orep.sh" "$B" >/dev/null || { echo "build failed"; exit 1; }
fi
NAT=$B/orep
REF=$B/orep-ref
ulimit -f 4000000
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# inputs: the corpus files and a generated multi-version one
C=$ROOT/tests/corpus
python3 - "$W/versions.bin" "$C/random.bin" <<'EOF'
import sys
src = open(sys.argv[2], 'rb').read()[:300000]
out = bytearray()
for v in range(12):
    b = bytearray(src)
    for k in range(40):
        p = (k * 7919 + v * 104729) % (len(b) - 8)
        b[p:p + 4] = b'v%03d' % v
    out += b
open(sys.argv[1], 'wb').write(out)
EOF
# runs and short periods between random data (the period candidate and
# the run filter, -r)
python3 - "$W/periods.bin" "$C/random.bin" <<'EOF'
import sys
src = open(sys.argv[2], 'rb').read()
out = bytearray()
for k in range(160):
    out += src[(k * 4099) % 60000:(k * 4099) % 60000 + 700 + k * 13]
    p = 1 + k % 16
    pat = src[k * 31:k * 31 + p]
    out += (pat * (1 + (200 + k * 37) // p))[:200 + k * 37]
    out += bytes([k & 255]) * (100 + k * 11 % 900)
open(sys.argv[1], 'wb').write(out)
EOF
INPUTS="$C/text.bin $C/mixed.bin $C/random.bin $C/zeros.bin $C/tiny.bin $W/versions.bin $W/periods.bin"
: > "$W/empty.bin"
INPUTS="$INPUTS $W/empty.bin"

rt() { # rt <file> <opts...>: both builds, same bytes, round trip
  local f=$1; shift
  "$NAT" -q "$@" "$f" "$W/n.orp" || { bad "encode $f $*"; return; }
  "$REF" -q "$@" "$f" "$W/r.orp" || { bad "ref encode $f $*"; return; }
  cmp -s "$W/n.orp" "$W/r.orp" || bad "native != reference: $f $*"
  "$NAT" -q -d "$W/n.orp" "$W/n.dec" || { bad "decode $f $*"; return; }
  cmp -s "$f" "$W/n.dec" || bad "round trip $f $*"
  "$REF" -q -d "$W/n.orp" "$W/r.dec" || { bad "ref decode $f $*"; return; }
  cmp -s "$f" "$W/r.dec" || bad "ref round trip $f $*"
}

echo "== round trips"
for f in $INPUTS; do
  rt "$f"
  rt "$f" -l16 -s16
  rt "$f" -w64k -b64k
  rt "$f" -w100k -b64k -l16
  rt "$f" -w300k -b128k -l64 -a16
  rt "$f" -w1m -b64k -l512
  rt "$f" -w300k -b64k -c1
  rt "$f" -w300k -b64k -c2 -l32 -a1
  rt "$f" -w300k -b64k -c2 -l256 -r512
  rt "$f" -w1m -b64k -l64 -r100 -D7
done

echo "== same bytes with any number of threads"
for f in "$C/mixed.bin" "$W/versions.bin" "$C/text.bin" "$W/periods.bin"; do
  for o in "" "-w64k -b64k -l16" "-l512 -b64k" "-c1 -b64k" "-c2 -l256 -r512 -b64k"; do
    "$NAT" -q $o "$f" "$W/t1.orp"
    for t in 2 3 4 8; do
      "$NAT" -q $o -t$t "$f" "$W/tn.orp" || bad "encode -t$t $f $o"
      cmp -s "$W/t1.orp" "$W/tn.orp" || bad "-t$t differs from -t1: $f $o"
    done
    "$REF" -q $o -t3 "$f" "$W/tn.orp" || bad "ref encode -t3 $f $o"
    cmp -s "$W/t1.orp" "$W/tn.orp" || bad "ref -t3 differs: $f $o"
  done
done

echo "== API (pieces, tiny buffers, reset, flush, thread hooks, whole buffers)"
mkdir -p "$W/api-nat" "$W/api-ref"
FPC=${FPC:-fpc}
if [ -f "$B/nat/orep_core.o" ] &&
   $FPC -O2 -Fu"$ROOT/src/orep" -Fo"$B/nat" -Fl"$B/nat" -FU"$W/api-nat" -o"$W/api-nat/orep_api" \
     "$ROOT/tests/orep_api.lpr" >"$W/api-nat/fpc.log" 2>&1 &&
   $FPC -O2 -dOREP_NO_NATIVE -Fu"$ROOT/src/orep" -FU"$W/api-ref" \
     -o"$W/api-ref/orep_api" "$ROOT/tests/orep_api.lpr" >"$W/api-ref/fpc.log" 2>&1; then
  for f in "$C/mixed.bin" "$C/text.bin" "$C/tiny.bin" "$W/empty.bin" "$W/versions.bin"; do
    for t in 1 3 5; do
      "$W/api-nat/orep_api" "$f" $t >/dev/null || bad "API checks: $f -t$t"
    done
    "$W/api-ref/orep_api" "$f" 2 >/dev/null || bad "API checks (reference): $f"
  done
else
  bad "cannot build tests/orep_api.lpr"
  tail -20 "$W/api-nat/fpc.log" "$W/api-ref/fpc.log" 2>/dev/null
fi

echo "== versions found"
"$NAT" -q -w1m "$W/versions.bin" "$W/v.orp"
s=$(wc -c < "$W/v.orp" | tr -d " ")
[ "$s" -lt 400000 ] || bad "versions.bin: $s bytes, the repeats were not found"

echo "== stdin / stdout"
"$NAT" -q - - < "$C/mixed.bin" > "$W/s.orp" || bad "stdin encode"
"$NAT" -q -d - - < "$W/s.orp" > "$W/s.dec" || bad "stdout decode"
cmp -s "$C/mixed.bin" "$W/s.dec" || bad "stdin/stdout round trip"

echo "== memory limit"
"$NAT" -q -w64m "$C/text.bin" "$W/m.orp"
if "$NAT" -q -d -M1m "$W/m.orp" "$W/m.dec" 2>/dev/null; then
  bad "-M1m accepted a stream that needs more"
fi

echo "== corrupt and truncated streams"
"$NAT" -q -w1m -b64k "$W/versions.bin" "$W/c.orp"
python3 - "$W/c.orp" "$W" <<'EOF'
import sys, random
data = open(sys.argv[1], 'rb').read()
random.seed(7)
for i in range(300):
    b = bytearray(data)
    kind = i % 3
    if kind == 0:
        b = b[:random.randrange(len(b))]
    elif kind == 1:
        for _ in range(random.randint(1, 4)):
            p = random.randrange(len(b))
            b[p] ^= 1 << random.randrange(8)
    else:
        p = random.randrange(28, len(b))
        b[p:p + 2] = bytes([random.randrange(256), random.randrange(256)])
    open('%s/bad%03d.orp' % (sys.argv[2], i), 'wb').write(b)
EOF
crash=0; accepted=0
for f in "$W"/bad*.orp; do
  "$NAT" -q -d "$f" "$W/bad.dec" 2>/dev/null; rc=$?
  if [ $rc -ge 2 ]; then crash=$((crash + 1)); echo "  rc=$rc on $f"; fi
  if [ $rc -eq 0 ] && ! cmp -s "$W/bad.dec" "$W/versions.bin"; then
    accepted=$((accepted + 1))
  fi
  "$REF" -q -d "$f" "$W/bad.dec" 2>/dev/null; rc=$?
  if [ $rc -ge 2 ]; then crash=$((crash + 1)); echo "  ref rc=$rc on $f"; fi
done
[ $crash -eq 0 ] || bad "$crash corrupt streams crashed the decoder"
[ $accepted -eq 0 ] || bad "$accepted corrupt streams decoded to wrong data"

echo "== pinned format 4 streams (frozen format, tests/fixtures/orep4)"
FX=$ROOT/tests/fixtures/orep4
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
nfx=0
while IFS=$'\t' read -r ssha id input osha args; do
  [ -n "$id" ] || continue
  f=$FX/$id.orp
  [ -f "$f" ] || { bad "missing fixture $id"; continue; }
  [ "$(sha "$f")" = "$ssha" ] || bad "fixture $id changed"
  for d in "$NAT" "$REF"; do
    "$d" -q -d "$f" "$W/fx.out" || { bad "decode fixture $id ($d)"; continue; }
    [ "$(sha "$W/fx.out")" = "$osha" ] || bad "fixture $id decodes wrong ($d)"
    "$d" -q -d - - < "$f" > "$W/fx.out" || bad "stdin decode fixture $id ($d)"
    [ "$(sha "$W/fx.out")" = "$osha" ] || bad "fixture $id decodes wrong from stdin ($d)"
  done
  if command -v python3 >/dev/null 2>&1; then
    o=$(python3 "$ROOT/tests/orep_spec.py" decode "$f" | cut -d' ' -f3)
    [ "$o" = "$osha" ] || bad "oracle on fixture $id"
  fi
  nfx=$((nfx + 1))
done < "$FX/manifest.tsv"
[ $nfx -ge 11 ] || bad "only $nfx pinned fixtures"
echo "  $nfx streams"

echo "== streaming and API edge cases (tests/orep_edge.sh)"
bash "$ROOT/tests/orep_edge.sh" "$B" >"$W/edge.log" 2>&1 ||
  { tail -20 "$W/edge.log"; bad "tests/orep_edge.sh"; }

echo "== structure-aware fuzzing against the spec oracle (tests/orep_fuzz.sh)"
if [ "${BASH_VERSINFO[0]}" -ge 4 ] && command -v timeout >/dev/null 2>&1; then
  bash "$ROOT/tests/orep_fuzz.sh" "$B" "${OREP_FUZZ_N:-400}" --seed 1 >"$W/fuzz.log" 2>&1 ||
    { tail -20 "$W/fuzz.log"; bad "tests/orep_fuzz.sh"; }
  tail -1 "$W/fuzz.log"
else
  echo "  skipped (needs bash 4 and timeout)"
fi

if [ $fail -eq 0 ]; then echo "orep: all checks passed"; else exit 1; fi
