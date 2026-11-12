#!/bin/bash
# Clean -osrep patch: (A) without -osrep archives byte-identical to baseline;
# (B) -osrep archives identical across -t1/-t8/default/-noturbo; (C) baseline
# extracts every -osrep archive to the original bytes; (D) -osrep without
# -fragment is -osrep -fragment 3.
set -u
# usage: osrep-switch-test.sh BASELINE_ZPAQ PATCHED_ZPAQ VERSIONS_TAR PJA_TAR
[ "$#" -eq 4 ] || { echo "usage: $0 BASELINE PATCHED VERSIONS_TAR PJA_TAR" >&2; exit 2; }
BASE=$1; NEW=$2
T="$(mktemp -d "${TMPDIR:-/tmp}/osrep-switch.XXXXXX")"; trap 'rm -rf "$T"' EXIT
FIX=(-touch 20240101000000 -timestamp 2024-01-01_00:00:00)
SMALL="$(cd "$(dirname "$0")/../../tests/corpus" && pwd)"
V=$3; P=$4
fails=0; ok(){ echo "OK   $*"; }; bad(){ echo "FAIL $*"; fails=$((fails+1)); }
arc(){ local bin=$1 out=$2; shift 2; rm -f "$out"; "$bin" a "$out" "$@" "${FIX[@]}" >/dev/null 2>&1; }
# A
for data in "$SMALL" "$V"; do for m in -m0 -m1 -m5; do for extra in "" -noturbo; do
  [ "$data" = "$V" ] && [ "$m" = -m5 ] && continue
  arc $BASE $T/b.zpaq "$data" $m $extra; arc $NEW $T/n.zpaq "$data" $m $extra
  if cmp -s $T/b.zpaq $T/n.zpaq; then ok "A identical $(basename $data) $m $extra ($(stat -c%s $T/n.zpaq))"; else bad "A differ $(basename $data) $m $extra"; fi
done; done; done
# B + C
for data in "$SMALL" "$V" "$P"; do defsha=""; for frag in "" "-fragment 0" "-fragment 3" "-fragment 6"; do
  ref=""
  for th in "" "-t1" "-t8" "-noturbo"; do
    arc $NEW $T/o.zpaq "$data" -m1 -osrep $frag $th
    s=$(sha256sum < $T/o.zpaq | cut -c1-16)
    if [ -z "$ref" ]; then ref=$s; cp $T/o.zpaq $T/ref.zpaq; sz=$(stat -c%s $T/o.zpaq)
    elif [ "$s" = "$ref" ]; then :; else bad "B $(basename $data) $frag $th differs from default threads"; fi
  done
  ok "B $(basename $data) -osrep $frag: same archive with default/-t1/-t8/-noturbo ($sz bytes)"
  [ -z "$frag" ] && defsha=$ref
  if [ "$frag" = "-fragment 3" ]; then
    if [ "$ref" = "$defsha" ]; then ok "D $(basename $data): -osrep without -fragment is -fragment 3"; else bad "D $(basename $data): default -osrep differs from -fragment 3"; fi
  fi
  rm -rf $T/x; mkdir -p $T/x
  $BASE x $T/ref.zpaq -to $T/x >/dev/null 2>&1
  if [ -d "$data" ]; then src="$data"; else src=$(dirname "$data"); fi
  if diff -rq "$data" "$T/x$data" >/dev/null 2>&1; then ok "C baseline extracts $(basename $data) -osrep $frag"; else bad "C extract $(basename $data) $frag"; fi
done; done
# -osrep with a -fragment it rejects must exit with an error, not hang
rm -f "$T/bad.zpaq"
timeout 60 "$NEW" a "$T/bad.zpaq" "$P" -m1 -osrep -fragment 22 >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then ok "-osrep -fragment 22 refused (exit $rc)"; else bad "-osrep -fragment 22 exit $rc (124 = hung)"; fi
echo "fails=$fails"; [ "$fails" -eq 0 ]
