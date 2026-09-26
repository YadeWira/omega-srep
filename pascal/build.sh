#!/usr/bin/env bash
# Construye los tres targets que shipeamos, con el cross propio.
# Ver /mnt/IA_LAB/agentes/osrep/fpc-cross/PROCEDENCIA.md.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
X="${OSREP_FPC_CROSS:-/mnt/IA_LAB/agentes/osrep/fpc-cross/lib/fpc/3.2.2}"
OUT="$ROOT/pascal/bin"
mkdir -p "$OUT"

# -Mobjfpc explicito: en el modo por defecto (fpc) Integer mide 2 bytes y el
# formato cambiaria de tamano. src/widths.pas lo convierte en error de
# compilacion, pero mejor no llegar ahi.
FLAGS="-Mobjfpc -O2 -Xs -vw -Fu$ROOT/pascal/src"

build() { # $1=etiqueta $2=compilador $3..=flags de target
    local tag="$1" cc="$2"; shift 2
    local u="$OUT/units-$tag"
    mkdir -p "$u"          # el compilador NO crea el directorio de -FU
    "$cc" $FLAGS "$@" -FU"$u" -o"$OUT/$3" "$ROOT/pascal/osrep.lpr" >/dev/null
    printf '  %-12s %s\n' "$tag" "$(ls -l "$OUT/$3" | awk '{print $5" bytes"}')"
}

echo "construyendo:"
mkdir -p "$OUT/units-linux"
fpc $FLAGS -FU"$OUT/units-linux" -o"$OUT/osrep-linux-x86_64" "$ROOT/pascal/osrep.lpr" >/dev/null
printf '  %-12s %s bytes\n' "linux-x86_64" "$(stat -c%s "$OUT/osrep-linux-x86_64")"

mkdir -p "$OUT/units-win64"
"$X/ppcrossx64" $FLAGS -Twin64 -Px86_64 -Fu"$X/units/x86_64-win64/*" \
    -FU"$OUT/units-win64" -o"$OUT/osrep-windows-x86_64.exe" "$ROOT/pascal/osrep.lpr" >/dev/null
printf '  %-12s %s bytes\n' "win-x86_64" "$(stat -c%s "$OUT/osrep-windows-x86_64.exe")"

mkdir -p "$OUT/units-win32"
"$X/ppcross386" $FLAGS -Twin32 -Pi386 -Fu"$X/units/i386-win32/*" \
    -FU"$OUT/units-win32" -o"$OUT/osrep-windows-x86.exe" "$ROOT/pascal/osrep.lpr" >/dev/null
printf '  %-12s %s bytes\n' "win-x86" "$(stat -c%s "$OUT/osrep-windows-x86.exe")"
