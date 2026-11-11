#!/bin/sh
# Cross-build the OSREP CLI for Linux AArch64 with FPC + the aarch64 gcc.
#
#   scripts/build_arm64.sh <out dir>
#
# FPC_AARCH64 points at ppcrossa64; CC_AARCH64 at the cross gcc. The stub is
# for the old __libc_csu_init/fini names in FPC's cprt0.o, removed from
# modern glibc.
set -eu
OUT=${1:?usage: build_arm64.sh <out dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_AARCH64=${FPC_AARCH64:-/mnt/IA_LAB/agentes/osrep/fpc-cross/lib/fpc/3.2.2/ppcrossa64}
CC_AARCH64=${CC_AARCH64:-aarch64-linux-gnu-gcc}
mkdir -p "$OUT/obj" "$OUT/units"
OUT=$(cd "$OUT" && pwd)
UNITROOT=$(dirname "$FPC_AARCH64")/units/aarch64-linux
PREFIX=$(cd "$(dirname "$FPC_AARCH64")/../../.." && pwd)
GCCLIB=$(dirname "$($CC_AARCH64 -print-file-name=libgcc.a)")
LIBC=${AARCH64_LIBC:-/usr/aarch64-linux-gnu/lib}

for f in osrep_cdc osrep_match osrep_crc osrep_csu_stub; do
  $CC_AARCH64 -O3 -fno-builtin -fno-stack-protector \
    -c "$ROOT/src/c/$f.c" -o "$OUT/obj/$f.o"
done

PATH="$PREFIX/bin-aarch64:$PATH" "$FPC_AARCH64" -n -Tlinux -Paarch64 \
  -XPaarch64-linux- \
  -Fu"$UNITROOT" -Fu"$UNITROOT/rtl" -Fu"$ROOT/src/pascal" \
  -Fl"$LIBC" -Fl"$GCCLIB" -k"$OUT/obj/osrep_csu_stub.o" \
  -Fo"$OUT/obj" -FU"$OUT/units" -FE"$OUT" -Xs \
  "$ROOT/src/pascal/osrep.lpr" >"$OUT/fpc.log" 2>&1 || {
    cat "$OUT/fpc.log"
    exit 1
  }
echo "$OUT/osrep"
