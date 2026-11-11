#!/bin/sh
# Cross-build the OSREP CLI for Linux i386 with FPC's ppcross386 + gcc -m32.
#
#   scripts/build_linux_x86.sh <out dir>
#
# FPC_X86 points at ppcross386. The i386 libc lives in /usr/lib32 and the
# 32-bit libgcc in gcc's .../32 directory.
set -eu
OUT=${1:?usage: build_linux_x86.sh <out dir>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FPC_X86=${FPC_X86:-/mnt/IA_LAB/agentes/osrep/fpc-cross/lib/fpc/3.2.2/ppcross386}
UNITROOT=$(dirname "$FPC_X86")/units/i386-linux
GCC32=$(dirname "$(gcc -m32 -print-file-name=libgcc.a)")
mkdir -p "$OUT/obj" "$OUT/units" "$OUT/toolbin"
OUT=$(cd "$OUT" && pwd)
# FPC asks for i386-linux-{as,ld,ar}; the host binutils handle the 32-bit
# target with the --32 / -m flags.
cat > "$OUT/toolbin/i386-linux-as" <<'EOF'
#!/bin/sh
exec as --32 "$@"
EOF
cat > "$OUT/toolbin/i386-linux-ld" <<'EOF'
#!/bin/sh
exec ld "$@"
EOF
cp "$OUT/toolbin/i386-linux-ld" "$OUT/toolbin/i386-linux-ld.bfd"
cat > "$OUT/toolbin/i386-linux-ar" <<'EOF'
#!/bin/sh
exec ar "$@"
EOF
chmod +x "$OUT/toolbin/"*

for f in osrep_cdc osrep_match osrep_crc_native osrep_csu_stub; do
  gcc -m32 -O3 -fno-builtin -fno-stack-protector \
    -c "$ROOT/src/c/$f.c" -o "$OUT/obj/$f.o"
done

PATH="$OUT/toolbin:$PATH" "$FPC_X86" -n -Tlinux -Pi386 -XPi386-linux- \
  -Fu"$UNITROOT" -Fu"$UNITROOT/rtl" -Fu"$ROOT/src/pascal" \
  -Fl/usr/lib32 -Fl"$GCC32" -k"$OUT/obj/osrep_csu_stub.o" \
  -Fo"$OUT/obj" -FU"$OUT/units" -FE"$OUT" -Xs \
  "$ROOT/src/pascal/osrep.lpr" >"$OUT/fpc.log" 2>&1 || {
    cat "$OUT/fpc.log"
    exit 1
  }
echo "$OUT/osrep"
