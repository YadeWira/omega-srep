#!/bin/bash
# Used for tools/scoreboard/orep-2026-11-17.log: one pipeline row
# (preprocessor, then lzma), paths are the ones of the measuring machine.
# job.sh <name> <backend m4|m7> <pre...>: one pipeline row
cd /mnt/IA_LAB/agentes/osrep/score/orep
N=$1; BE=$2; shift 2
IN=${IN:-tilin_512m.tar}
FA=/mnt/IA_LAB/agentes/osrep/score/fa/linux/fa
O=t/$N.$BE.pre
case "$1" in
  none) cp "$IN" $O;;
  rep:*) rm -f $O.fa; $FA a $O.fa -m$1 "$IN" >/dev/null 2>&1; mv $O.fa $O;;
  *) build4/orep -q "$@" "$IN" $O;;
esac
case $BE in
  m4) L="dict=96MiB,lc=4,lp=0,pb=2,mode=normal,nice=16,mf=hc4,depth=8";;
  m7) L="dict=64MiB,lc=4,lp=0,pb=2,mode=normal,nice=273,mf=bt4";;
esac
t0=$(date +%s.%N)
z=$(xz --format=raw --lzma1=$L -T1 -c $O | wc -c)
t1=$(date +%s.%N)
echo "$BE $N pre=$(stat -c%s $O) final=$z lzma_s=$(echo "$t1 - $t0" | bc)"
rm -f $O
