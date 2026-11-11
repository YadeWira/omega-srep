#!/bin/sh
# Cross-build the OSREP CLI for Windows x64 and x86 with FPC + mingw.
#
#   scripts/build_windows.sh <out dir>
#
# FPC_WIN64 / FPC_WIN32 point at the cross compilers; CC64 / CC32 at mingw.
set -eu
OUT=${1:-build/windows}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
FPC_WIN64=${FPC_WIN64:-fpc-win64}
FPC_WIN32=${FPC_WIN32:-fpc-win32}
CC64=${CC64:-x86_64-w64-mingw32-gcc}
CC32=${CC32:-i686-w64-mingw32-gcc}
[ -x "$FPC_WIN64" ] || FPC_WIN64=/mnt/IA_LAB/agentes/osrep/fpc-cross/bin/fpc-win64
[ -x "$FPC_WIN32" ] || FPC_WIN32=/mnt/IA_LAB/agentes/osrep/fpc-cross/bin/fpc-win32

build() {
  label=$1 fpcbin=$2 cc=$3
  mkdir -p "$OUT/$label/obj" "$OUT/$label/units"
  for f in osrep_cdc osrep_match osrep_crc_native; do
    $cc -O3 -fno-builtin -fno-stack-protector \
      -c "$ROOT/src/c/$f.c" -o "$OUT/$label/obj/$f.o"
  done
  "$fpcbin" -Mobjfpc -O2 -Sh -Xs -Fu"$ROOT/src/pascal" \
    -Fo"$OUT/$label/obj" -FU"$OUT/$label/units" -FE"$OUT" \
    "$ROOT/src/pascal/osrep.lpr" >"$OUT/$label/fpc.log" 2>&1 || {
      cat "$OUT/$label/fpc.log"
      exit 1
    }
}

echo "win64: $FPC_WIN64 + $CC64"
build win64 "$FPC_WIN64" "$CC64"
mv "$OUT/osrep.exe" "$OUT/osrep-windows-x86_64.exe"

echo "win32: $FPC_WIN32 + $CC32"
build win32 "$FPC_WIN32" "$CC32"
mv "$OUT/osrep.exe" "$OUT/osrep-windows-x86.exe"

echo "$OUT/osrep-windows-x86_64.exe"
echo "$OUT/osrep-windows-x86.exe"
