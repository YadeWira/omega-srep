#!/bin/bash
# min A>>s for -osrep (prototype OSREP_MIN_SHIFT): -m1 on everything
set -u
S=/mnt/IA_LAB/agentes/osrep/score; Z=$S/zd; Y=$Z/syn; B=$S/bin
R=/home/forum/git/omega-srep/tools/zpaq-vectors
C6=/mnt/IA_LAB/agentes/osrep/zpaqclean/corpus6
BASE=$S/zpaq-2.11.0/zpaq-std
export TMPDIR=$S/tmpd
cage(){ systemd-run --user --scope --quiet --slice=osrep-review.slice -p MemoryMax=6G -p MemorySwapMax=0 -p OOMPolicy=continue -- nice "$@"; }
waitmem(){ while [ "$(free -g | awk '/^Mem/{print $7}')" -lt 12 ]; do sleep 30; done; }
TH=(--extra=-threads --extra=4 --xextra=-threads --xextra=4)
TARS=(--input $S/corpus/versions.tar --input $S/corpus/pja.tar --input $S/corpus/zpaqstd-history.tar)
DIRS=(--corpus src-zpaqstd=$C6/src-zpaqstd --corpus src-omega=$C6/src-omega --corpus bin-releases=$C6/bin-releases
      --corpus mixed=$C6/mixed:single --corpus disk=$Y/disk --corpus insert=$Y/insert
      --corpus db4k=$Y/db4k --corpus db8k=$Y/db8k --corpus db16k=$Y/db16k)
for s in 1 3 4; do
  if [ $s = 1 ]; then CFG=zpaq:0,zpaq:3,zpaq:6,osrep:0,osrep:3,osrep:6,osrep:d; K=zpaq,osrep
  else CFG=osrep:0,osrep:3,osrep:6,osrep:d; K=osrep; fi
  waitmem; echo "=== $(date +%T) dirs-m1 s$s"
  cage python3 -I $R/bench_versions.py --baseline $BASE --patched $B/osrep-s$s --workdir $Z/w --method=-m1 \
    --configs $CFG "${TH[@]}" "${DIRS[@]}" > $Z/min-dirs-m1-s$s.tsv 2> $Z/min-dirs-m1-s$s.err
  waitmem; echo "=== $(date +%T) tars-m1 s$s"
  cage python3 -I $R/bench_fair.py --baseline $BASE --patched $B/osrep-s$s "${TARS[@]}" --method=-m1 \
    --fragments 0,3,6,d --kinds $K --workdir $Z/wt "${TH[@]}" > $Z/min-tars-m1-s$s.tsv 2> $Z/min-tars-m1-s$s.err
done
echo "=== $(date +%T) runmin done"
