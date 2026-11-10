#!/bin/sh
# libosrep: OSREP as a shared library (include/osrep.h), from
# src/lib/osrep_lib.pas and the core in src/pascal, position-independent.
#
#   src/lib/build.sh <out dir>   -> libosrep.so (libosrep.dylib, osrep.dll)
#
# FPC picks the compiler and its target options (fpc by default;
# "fpc -Twin64 -Px86_64" cross-compiles to Windows x64).
set -eu
OUT=${1:?usage: build.sh <out dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
PASCAL="$SRC/pascal"
FPC=${FPC:-fpc}
CC=${CC:-cc}
mkdir -p "$OUT/units" "$OUT/c"
OUT=$(cd "$OUT" && pwd)
# Windows: a native build (MSYS, Git Bash: by uname) or a cross one
WIN=; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; esac
case "$FPC" in *mingw*|*-Twin*) WIN=1 ;; esac
if [ -n "$WIN" ]; then
  PIC=
  CPIC=
  NAME=osrep.dll
else
  PIC=-Cg
  CPIC=-fPIC
  NAME=libosrep.so
fi
# macOS: the install name is @rpath/libosrep.dylib, not the build path, so
# a program linked against it finds it by its own rpath (as libpja)
LDN=
if [ -z "$WIN" ] && [ "$(uname -s)" = Darwin ]; then
  NAME=libosrep.dylib
  LDN="-k-install_name -k@rpath/libosrep.dylib"
fi
echo "units from $PASCAL, C object in $OUT/c"
CFLAGS="-O2 -fwrapv -ffp-contract=off -fno-stack-protector -fno-builtin"
# shellcheck disable=SC2086
$CC $CFLAGS $CPIC -c "$HERE/osrep7z.c" -o "$OUT/c/osrep7z.o"
$CC $CFLAGS $CPIC -c "$SRC/c/osrep_cdc.c" -o "$OUT/c/osrep_cdc.o"
$CC $CFLAGS $CPIC -c "$SRC/c/osrep_match.c" -o "$OUT/c/osrep_match.o"
$CC $CFLAGS $CPIC -c "$SRC/c/osrep_crc.c" -o "$OUT/c/osrep_crc.o"
# MSYS would rewrite FreePascal's -Fu paths; no conversion for its arguments
# shellcheck disable=SC2086
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' $FPC -O2 -Sh $PIC $LDN \
  -Fu"$PASCAL" -Fo"$OUT/c" -FU"$OUT/units" -o"$OUT/$NAME" "$HERE/osrep_lib.pas" \
  > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
echo "$OUT/$NAME"
