#!/bin/bash
S=/mnt/IA_LAB/agentes/osrep/score; T=$S/smalltree
Z0=$S/zpaq-2.11.0/zpaq-std; Z1=$S/zpaq-2.11.0-osrep/zpaq-std
FIX=(-touch 20240101000000 -timestamp 2024-01-01_00:00:00 -threads 4)
cd $T/pja
for m in -m1 -m5; do for n in 6 9; do
  rm -f /mnt/IA_LAB/agentes/osrep/score/smalltree/d1/a.zpaq /mnt/IA_LAB/agentes/osrep/score/smalltree/d1/b.zpaq
  $Z0 a $T/d1/a.zpaq v0 $m -fragment $n "${FIX[@]}" >/dev/null 2>&1
  $Z1 a $T/d1/b.zpaq v0 $m -fragment $n -osrep "${FIX[@]}" >/dev/null 2>&1
  a=$(stat -c%s $T/d1/a.zpaq); b=$(stat -c%s $T/d1/b.zpaq)
  echo "$m N$n zpaq $a osrep $b $(python3 -c "print('%+.2f%%'%(($b/$a-1)*100))")"
done; done
