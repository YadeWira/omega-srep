#!/usr/bin/env bash
# Construye los cinco targets que shipeamos, con el cross propio, y las
# herramientas de prueba que los harnesses diffean contra el oraculo.
# Ver /mnt/IA_LAB/agentes/osrep/fpc-cross/PROCEDENCIA.md.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
X="${OSREP_FPC_CROSS:-/mnt/IA_LAB/agentes/osrep/fpc-cross/lib/fpc/3.2.2}"
OUT="${OSREP_PASCAL_OUT:-$ROOT/pascal/bin}"   # override: construir sin pisar binarios en uso
mkdir -p "$OUT/units-linux" "$OUT/units-linux32" "$OUT/units-linux-aarch64" \
         "$OUT/units-win64" "$OUT/units-win32"  # -FU no los crea

# -Mobjfpc explicito: en el modo por defecto (fpc) Integer mide 2 bytes y el
# formato cambiaria de tamano. src/widths.pas lo convierte en error de
# compilacion, pero mejor no llegar ahi.
FLAGS="-Mobjfpc -O2 -Xs -vw -Fu$ROOT/pascal/src"

# i386-linux: ppcross386 ya apunta a Linux, pero las unidades de la RTL y de
# los paquetes hay que darselas una por una; FPC no expande el glob de -Fu
# cuando son subdirectorios.
LIN32_FU=(-Fu"$X/units/i386-linux")
for _d in "$X/units/i386-linux"/*/; do LIN32_FU+=(-Fu"${_d%/}"); done

# aarch64-linux: ppcrossa64 mas las unidades del target, y el directorio de
# binutils con aarch64-linux-{as,ld,...} (-FD).
AARCH64_FU=(-Fu"$X/units/aarch64-linux")
for _d in "$X/units/aarch64-linux"/*/; do AARCH64_FU+=(-Fu"${_d%/}"); done
AARCH64_BINDIR="${OSREP_AARCH64_BINDIR:-/mnt/IA_LAB/agentes/osrep/fpc-cross/bin-aarch64}"

# $1=compilador $2=salida $3=programa, el resto flags de target. Si falla,
# muestra lo que dijo el compilador en vez de tragarselo.
compile() {
    local cc="$1" out="$2" prog="$3"; shift 3
    local log="$OUT/build.log"
    if ! "$cc" $FLAGS "$@" -o"$OUT/$out" "$ROOT/pascal/$prog.lpr" >"$log" 2>&1; then
        grep -E 'Error|Fatal' "$log" >&2 || cat "$log" >&2
        echo "FALLO: $prog -> $out" >&2
        exit 1
    fi
}

# $1=programa $2..6=nombres de salida para linux-x64, linux-x86,
# linux-aarch64, win64 y win32
build5() {
    local prog="$1" lin="$2" lin32="$3" a64="$4" w64="$5" w32="$6"
    compile fpc "$lin" "$prog" -FU"$OUT/units-linux"
    compile "$X/ppcross386" "$lin32" "$prog" -Tlinux -Pi386 "${LIN32_FU[@]}" -FU"$OUT/units-linux32"
    compile "$X/ppcrossa64" "$a64" "$prog" -Tlinux -Paarch64 -FD"$AARCH64_BINDIR" \
        "${AARCH64_FU[@]}" -FU"$OUT/units-linux-aarch64"
    compile "$X/ppcrossx64" "$w64" "$prog" -Twin64 -Px86_64 -WR \
        -Fu"$X/units/x86_64-win64/*" -FU"$OUT/units-win64"
    compile "$X/ppcross386" "$w32" "$prog" -Twin32 -Pi386 -WR \
        -Fu"$X/units/i386-win32/*" -FU"$OUT/units-win32"
    printf '  %-13s %9s %9s %9s %9s %9s\n' "$prog" \
        "$(stat -c%s "$OUT/$lin")" "$(stat -c%s "$OUT/$lin32")" \
        "$(stat -c%s "$OUT/$a64")" "$(stat -c%s "$OUT/$w64")" "$(stat -c%s "$OUT/$w32")"
}

echo "construyendo (bytes):   linux-x86_64 linux-x86 linux-aarch64 win-x86_64  win-x86"
build5 osrep osrep-linux-x86_64 osrep-linux-x86 osrep-linux-aarch64 \
       osrep-windows-x86_64.exe osrep-windows-x86.exe
for tool in hashtool containertool decodetool encodetool verifytool; do
    build5 "$tool" "$tool" "${tool}-x86" "${tool}-aarch64" "${tool}64.exe" "${tool}32.exe"
done
