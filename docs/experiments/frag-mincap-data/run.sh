#!/bin/bash
S=/mnt/IA_LAB/agentes/osrep/score; T=$S/smalltree
C6=/mnt/IA_LAB/agentes/osrep/zpaqclean/corpus6
export TMPDIR=$S/tmp
cd $T
bv(){ python3 -I /home/forum/git/omega-srep/tools/zpaq-vectors/bench_versions.py --baseline $S/zpaq-2.11.0/zpaq-std --patched $S/zpaq-2.11.0-osrep/zpaq-std --workdir $T/w --extra=-threads --extra=4 --xextra=-threads --xextra=4 "$@"; }
for m in -m1 -m5; do
  if [ $m = -m1 ]; then C=(--corpus src-omega=$C6/src-omega --corpus pja=$T/pja --corpus bin-releases=$C6/bin-releases --corpus src-zpaqstd=$C6/src-zpaqstd --corpus mixed=$C6/mixed:single)
  else C=(--corpus src-omega=$C6/src-omega --corpus pja=$T/pja --corpus bin-releases=$C6/bin-releases --corpus mixed=$C6/mixed:single); fi
  bv --method=$m "${C[@]}" --configs zpaq:0,zpaq:3,zpaq:6,zpaq:9,osrep:0,osrep:3,osrep:6,osrep:9 > base$m.tsv 2> base$m.err
  for cap in 4096 8192; do
    OSREP_MINCAP=$cap bv --method=$m "${C[@]}" --configs osrep:6,osrep:9 > cap$cap$m.tsv 2> cap$cap$m.err
  done
done
echo DONE
