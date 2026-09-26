#!/usr/bin/env bash
# Construye los tres targets que shipeamos, con el cross propio, y las
# herramientas de prueba que los harnesses diffean contra el oraculo.
# Ver /mnt/IA_LAB/agentes/osrep/fpc-cross/PROCEDENCIA.md.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
X="${OSREP_FPC_CROSS:-/mnt/IA_LAB/agentes/osrep/fpc-cross/lib/fpc/3.2.2}"
OUT="${OSREP_PASCAL_OUT:-$ROOT/pascal/bin}"   # override: construir sin pisar binarios en uso
mkdir -p "$OUT/units-linux" "$OUT/units-win64" "$OUT/units-win32"  # -FU no los crea

# -Mobjfpc explicito: en el modo por defecto (fpc) Integer mide 2 bytes y el
# formato cambiaria de tamano. src/widths.pas lo convierte en error de
# compilacion, pero mejor no llegar ahi.
FLAGS="-Mobjfpc -O2 -Xs -vw -Fu$ROOT/pascal/src"

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

# $1=programa $2..4=nombres de salida para linux, win64 y win32
build3() {
    local prog="$1" lin="$2" w64="$3" w32="$4"
    compile fpc "$lin" "$prog" -FU"$OUT/units-linux"
    compile "$X/ppcrossx64" "$w64" "$prog" -Twin64 -Px86_64 \
        -Fu"$X/units/x86_64-win64/*" -FU"$OUT/units-win64"
    compile "$X/ppcross386" "$w32" "$prog" -Twin32 -Pi386 \
        -Fu"$X/units/i386-win32/*" -FU"$OUT/units-win32"
    printf '  %-13s %9s %9s %9s\n' "$prog" \
        "$(stat -c%s "$OUT/$lin")" "$(stat -c%s "$OUT/$w64")" "$(stat -c%s "$OUT/$w32")"
}

echo "construyendo (bytes):   linux-x86_64 win-x86_64  win-x86"
build3 osrep osrep-linux-x86_64 osrep-windows-x86_64.exe osrep-windows-x86.exe
for tool in hashtool containertool decodetool; do
    build3 "$tool" "$tool" "${tool}64.exe" "${tool}32.exe"
done
