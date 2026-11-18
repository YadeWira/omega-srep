#!/bin/sh
# Build the OREP release binaries from Linux x86_64, plus the Pascal unit
# package (orep.pas, orep_core.c and the core object per target) for
# programs that link OREP statically (PArc).
#
#   scripts/build_orep_release.sh <out dir>
#
# Outputs: orep-linux-x86_64, orep-linux-x86, orep-linux-arm64,
# orep-windows-x86_64.exe, orep-windows-x86.exe, orep-unit-<ver>.tar.gz.
# macOS arm64 is built by .github/workflows/macos-arm64.yml.
# The C core is freestanding; the CLI links libc on Linux for its threads
# (cthreads), like the OSREP CLI, with the same stub for the old
# __libc_csu_* names in FPC's startup code.
set -eu
OUT=${1:?usage: build_orep_release.sh <out dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
X=/mnt/IA_LAB/agentes/osrep/fpc-cross
FPC_X86=${FPC_X86:-$X/lib/fpc/3.2.2/ppcross386}
FPC_A64=${FPC_AARCH64:-$X/lib/fpc/3.2.2/ppcrossa64}
FPC_WIN64=${FPC_WIN64:-$X/bin/fpc-win64}
FPC_WIN32=${FPC_WIN32:-$X/bin/fpc-win32}
CFLAGS="-O2 -fno-builtin -ffreestanding -fno-stack-protector \
 -fno-tree-loop-distribute-patterns -fno-asynchronous-unwind-tables"
VER=$(sed -n "s/.*OREP_VERSION_STR = '\(.*\)';.*/\1/p" "$ROOT/src/orep/orep.pas")

core() { # core <label> <cc> [flags]: compile the C core, refuse libc calls
  label=$1 cc=$2; shift 2
  mkdir -p "$OUT/$label"
  $cc $CFLAGS "$@" -c "$ROOT/src/c/orep_core.c" -o "$OUT/$label/orep_core.o"
  if nm "$OUT/$label/orep_core.o" | grep -q ' U '; then
    echo "$label: orep_core.o calls out:"; nm "$OUT/$label/orep_core.o" | grep ' U '
    exit 1
  fi
}

fpcb() { # fpcb <label> <exe name> <fpc> [args]
  label=$1 exe=$2 fpcbin=$3; shift 3
  "$fpcbin" "$@" -O3 -Xs -Fu"$ROOT/src/orep" -Fl"$OUT/$label" \
    -Fo"$OUT/$label" -FU"$OUT/$label" -o"$OUT/$exe" \
    "$ROOT/src/orep/orep_cli.lpr" >"$OUT/$label/fpc.log" 2>&1 || {
    cat "$OUT/$label/fpc.log"; exit 1; }
  echo "$OUT/$exe"
}

# Linux x86_64
core linux-x86_64 gcc -fno-pic
fpcb linux-x86_64 orep-linux-x86_64 fpc

# Linux x86 (host binutils with --32)
core linux-x86 gcc -m32 -fno-pic
gcc -m32 -c "$ROOT/src/c/osrep_csu_stub.c" -o "$OUT/linux-x86/csu_stub.o"
GCC32=$(dirname "$(gcc -m32 -print-file-name=libgcc.a)")
TB=$OUT/linux-x86/toolbin
mkdir -p "$TB"
printf '#!/bin/sh\nexec as --32 "$@"\n' > "$TB/i386-linux-as"
printf '#!/bin/sh\nexec ld "$@"\n' > "$TB/i386-linux-ld"
printf '#!/bin/sh\nexec ar "$@"\n' > "$TB/i386-linux-ar"
cp "$TB/i386-linux-ld" "$TB/i386-linux-ld.bfd"
chmod +x "$TB"/*
U386=$(dirname "$FPC_X86")/units/i386-linux
PATH="$TB:$PATH" fpcb linux-x86 orep-linux-x86 "$FPC_X86" -n -Tlinux -Pi386 \
  -XPi386-linux- -Fu"$U386" -Fu"$U386/rtl" -Fl/usr/lib32 -Fl"$GCC32" \
  -k"$OUT/linux-x86/csu_stub.o"

# Linux arm64
core linux-arm64 aarch64-linux-gnu-gcc
aarch64-linux-gnu-gcc -c "$ROOT/src/c/osrep_csu_stub.c" -o "$OUT/linux-arm64/csu_stub.o"
GCCA64=$(dirname "$(aarch64-linux-gnu-gcc -print-file-name=libgcc.a)")
UA64=$(dirname "$FPC_A64")/units/aarch64-linux
PA64=$(cd "$(dirname "$FPC_A64")/../../.." && pwd)
PATH="$PA64/bin-aarch64:$PATH" fpcb linux-arm64 orep-linux-arm64 "$FPC_A64" \
  -n -Tlinux -Paarch64 -XPaarch64-linux- -Fu"$UA64" -Fu"$UA64/rtl" \
  -Fl"${AARCH64_LIBC:-/usr/aarch64-linux-gnu/lib}" -Fl"$GCCA64" \
  -k"$OUT/linux-arm64/csu_stub.o"

# Windows
core win64 x86_64-w64-mingw32-gcc
fpcb win64 orep-windows-x86_64.exe "$FPC_WIN64"
core win32 i686-w64-mingw32-gcc
fpcb win32 orep-windows-x86.exe "$FPC_WIN32"

# the unit package
P=$OUT/orep-unit-$VER
rm -rf "$P"
mkdir -p "$P/obj"
cp "$ROOT/src/orep/orep.pas" "$ROOT/src/c/orep_core.c" "$ROOT/spec/orep-format.md" \
  "$ROOT/docs/orep.md" "$ROOT/tests/orep_api.lpr" "$ROOT/LICENSE" "$P/"
for t in linux-x86_64 linux-x86 linux-arm64 win64 win32; do
  mkdir -p "$P/obj/$t"
  cp "$OUT/$t/orep_core.o" "$P/obj/$t/"
done
cat > "$P/README.txt" <<EOF
OREP $VER - Pascal unit (MIT)

  orep.pas        the unit: streaming encoder/decoder, whole-buffer helpers
  orep_core.c     the native match finder and CRC (freestanding C, no libc)
  obj/<target>/   orep_core.o built for each target
  orep-format.md  the stream format
  orep.md         design, API, measurements, suggested settings (Spanish)
  orep_api.lpr    an API test that shows every call (threads, hooks, reset)

Link: put orep_core.o where FPC finds objects (-Fl<dir>), or build with
-dOREP_NO_NATIVE to use the Pascal reference (same bytes, slower).
Rebuild the object with:
  cc -O2 -fno-builtin -ffreestanding -fno-stack-protector \\
     -fno-tree-loop-distribute-patterns -c orep_core.c
EOF
tar -C "$OUT" -czf "$OUT/orep-unit-$VER.tar.gz" "orep-unit-$VER"
echo "$OUT/orep-unit-$VER.tar.gz"
