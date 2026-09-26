#!/usr/bin/env bash
# El decoder Future/Index-LZ (v3/v4) del port a Pascal contra el Rust
# (docs/pascal-port.md, fase 4b).
#
# El criterio es mas estricto que "descomprime bien". Para cada archivo, la
# LINEA ENTERA de estadisticas del Pascal tiene que coincidir con la del
# harness Rust (`decode_conformance future-lz`):
#
#     ok blocks=N origsize=N verified=0|1 vmw=N vmr=N
#
# `vmw`/`vmr` son los bytes que pasaron por el spill a disco. Una politica de
# desalojo distinta todavia reconstruye los bytes correctos -- el spill es
# transparente -- pero cuenta bytes distintos. Exigir que coincidan prueba que
# se porto EL MISMO algoritmo, no uno que casualmente da la misma salida. El
# gate original solo pide vmw>0; esto pide el numero exacto.
#
# Los presupuestos no son arbitrarios. Con 1 MiB / vmblock 128 KiB el spill
# mueve 2359296 bytes; con 512 KiB / 64 KiB, CERO -- menos memoria y ningun
# spill, porque el recorte `maximum_save = vm_block - 24` deja a los matches de
# 64 KiB fuera del memory manager. Esa fila falla si el recorte esta mal
# portado aunque la salida salga bien.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || { say "sin cargo -- salteando"; exit 0; }
[ -x target/release/decode_conformance ] \
    || cargo build --release --bin decode_conformance >/dev/null 2>&1
DC=target/release/decode_conformance
[ -x "$DC" ] || fail "no hay harness Rust en $DC"
[ -x bin/osrep ] || make bin/osrep >/dev/null 2>&1
OSREP=bin/osrep

DT="${OSREP_PASCAL_DECODETOOL:-pascal/bin/decodetool}"
if [ ! -x "$DT" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/decodetool pascal/decodetool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/decodetool.lpr"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

# Las mismas entradas que tests/decode_conformance.sh, con la misma semilla.
python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
random.seed(20260913)
unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
half = bytes(random.randrange(256) for _ in range(40000))
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
open(os.path.join(d, "repeat.bin"), "wb").write(unit * 75)
open(os.path.join(d, "random.bin"), "wb").write(bytes(random.randrange(256) for _ in range(200000)))
open(os.path.join(d, "mixed.bin"), "wb").write(unit * 8 + half + unit * 8 + half)
open(os.path.join(d, "dup.bin"), "wb").write(unit * 4 + unit * 4)
far = [bytes(random.randrange(256) for _ in range(64 * 1024)) for _ in range(32)]
open(os.path.join(d, "far.bin"), "wb").write(b"".join(far) * 2)
PY

compare() {  # $1=label $2=archivo $3=original $4...=opciones de presupuesto
    local label="$1" arc="$2" src="$3"; shift 3
    local want got
    want=$("$DC" future-lz "$arc" "$TMP/r.out" "$@" 2>&1) \
        || fail "[$label] el harness Rust fallo: $want"
    rm -f "$TMP/p.out"
    got=$("$DT" "$arc" "$TMP/p.out" "$@" 2>/dev/null) \
        || fail "[$label] el Pascal fallo (salida: $got)"
    [ "$want" = "$got" ] \
        || fail "[$label $*] estadisticas distintas
      Rust:   $want
      Pascal: $got"
    cmp -s "$src" "$TMP/p.out" || fail "[$label $*] los bytes reconstruidos difieren"
    pass=$((pass + 1))
}

say "Future/Index-LZ: la linea de estadisticas entera, contra el Rust"
for case in "v3-m3f|-m3f" "v3-m5f|-m5f" "v3-m1f|-m1f" "v3-m2f|-m2f" "v3-m4f|-m4f" \
            "v4-m3|-m3" "v4-m5|-m5" "v4-m1|-m1" "v4-m2|-m2" \
            "v3-siphash|-m3f -hash=siphash" "v3-sha512|-m4f -hash=sha512" \
            "v4-md5|-m3 -hash=md5" "v3-hashoff|-m3f -hash-"; do
    IFS='|' read -r label flags <<<"$case"
    for input in tiny repeat random mixed dup; do
        arc="$TMP/$label.$input.osr"
        # shellcheck disable=SC2086
        $OSREP $flags -b64k -t1 "$TMP/$input.bin" "$arc" >/dev/null 2>&1 \
            || fail "[$label/$input] el encoder rechazo las opciones"
        compare "$label/$input" "$arc" "$TMP/$input.bin"
    done
done
say "$pass archivos: bytes y estadisticas identicos"

say "el spill a disco: los mismos bytes movidos, bajo cuatro presupuestos"
for c in "v3|-m5f" "v4|-m5"; do
    IFS='|' read -r label flags <<<"$c"
    arc="$TMP/spill.$label.osr"
    # shellcheck disable=SC2086
    $OSREP $flags -b64k -t1 "$TMP/far.bin" "$arc" >/dev/null 2>&1
    compare "spill.$label" "$arc" "$TMP/far.bin"
    compare "spill.$label" "$arc" "$TMP/far.bin" --mem=1048576 --vmblock=131072
    compare "spill.$label" "$arc" "$TMP/far.bin" --mem=524288 --vmblock=65536
    compare "spill.$label" "$arc" "$TMP/far.bin" --mem=2097152 --vmblock=262144
done
# Y que el spill haya CORRIDO de verdad en el caso que lo exige: si el
# numero coincide pero es cero en los dos lados, el test no probo nada.
got=$("$DT" "$TMP/spill.v4.osr" "$TMP/p.out" --mem=1048576 --vmblock=131072 2>/dev/null)
vmw=$(printf '%s' "$got" | sed -n 's/.*vmw=\([0-9]*\).*/\1/p')
[ "${vmw:-0}" -gt 0 ] || fail "el caso de spill no derramo nada (vmw=$vmw): el test seria vacio"
pass=$((pass + 1))

say "lo danado se rechaza sin dejar salida"
base="$TMP/v4-m3.dup.osr"
SZ=$(stat -c%s "$base")
python3 - "$base" "$TMP/c1.osr" "$((SZ / 2))" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read()); d[int(sys.argv[3])] ^= 0x01
open(sys.argv[2],'wb').write(d)
PY
rc=0; "$DT" "$TMP/c1.osr" "$TMP/bad" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "un bit dado vuelta en un archivo v4 paso sin detectarse"
[ ! -e "$TMP/bad" ] || fail "quedo una salida a medias"
head -c $((SZ - 7)) "$base" > "$TMP/c2.osr"
rc=0; "$DT" "$TMP/c2.osr" "$TMP/bad" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "un v4 al que le falta el final del footer no fue rechazado"
[ ! -e "$TMP/bad" ] || fail "quedo una salida a medias"
pass=$((pass + 2))

say "un bloque que declara mas de lo que trae no reserva lo declarado"
# Un archivo de ~100 bytes cuyo primer bloque dice traer 3 GiB, de literales o
# de salida. Tiene que fallar con EL MISMO error que el Rust, y sin ocupar lo
# declarado: el Rust ocupa 11 MiB. Hasta el 2026-09-26 el Pascal reservaba los
# 3 GiB de entrada (SetLength llena de ceros, asi que son reales), y un fuzzer
# con decenas de estos en paralelo tumbo la maquina por OOM. En i386 ademas
# fallaba con "Range check error": el largo no entra en un SizeInt.
#
# El binario nativo corre con el espacio de direcciones limitado a 256 MiB:
# reservar lo declarado da "Out of memory" y el error deja de coincidir. Bajo
# wine no se puede limitar asi, y ahi queda solo la comparacion del error.
python3 - "$TMP/v4-m1.tiny.osr" "$TMP" <<'PY'
import struct, sys
src = open(sys.argv[1], 'rb').read()
at = 16 + ((struct.unpack_from('<I', src, 8)[0] >> 16) & 255)   # primer bloque
for name, off in (("lit", 0), ("orig", 4)):
    b = bytearray(src)
    struct.pack_into('<I', b, at + off, 3 << 30)
    open(f"{sys.argv[2]}/claims3g-{name}.osr", 'wb').write(b)
PY
LIM=""
[ "$(head -c 4 "$DT" | od -An -c | tr -d ' ')" = '177ELF' ] && LIM="ulimit -v 262144;"
for name in lit orig; do
    arc="$TMP/claims3g-$name.osr"
    want=$("$DC" future-lz "$arc" "$TMP/r.out" 2>&1 >/dev/null \
           | sed 's/^decode_conformance: //; s/^broken compressed data: //') || true
    rm -f "$TMP/r.out"
    rc=0
    got=$(bash -c "$LIM exec \"\$@\"" _ "$DT" "$arc" "$TMP/bad" 2>&1 >/dev/null) || rc=$?
    got=$(printf '%s' "$got" | sed -n 's/^  ERROR! //p')
    [ "$rc" -ne 0 ] || fail "[claims3g-$name] un bloque de 3 GiB en 100 bytes paso"
    [ ! -e "$TMP/bad" ] || fail "[claims3g-$name] quedo una salida a medias"
    [ -n "$want" ] && [ "$want" = "$got" ] \
        || fail "[claims3g-$name] otro error que el Rust
      Rust:   $want
      Pascal: $got"
    pass=$((pass + 1))
done

say "el spill: el slot se arma a medida, y el temporal va donde lo pone el Rust"
mkdir -p "$TMP/vm"
# -vmblock de 256 MiB con 1 MiB de memoria: los dos fallan igual (no hay lugar
# para restaurar un slot), pero hasta el 2026-09-26 el Pascal reservaba el
# slot entero, lleno de ceros, en cada derrame -- 258 MiB contra 11 del Rust --
# y en i386 un -vmblock >= 2^32 llegaba truncado a SetLength: el empaquetado
# escribia fuera del buffer. Con el espacio limitado (nativo), reservarlo
# entero da "Out of memory" y el error deja de coincidir. (El caso de 2^32 en
# si escribe slots de 4 GiB y no entra en un harness; se verifico a mano.)
want=$(TMPDIR="$TMP/vm" "$DC" future-lz "$TMP/spill.v4.osr" "$TMP/r.out" \
         --mem=1048576 --vmblock=268435456 2>&1 >/dev/null \
       | sed 's/^decode_conformance: //; s/^broken compressed data: //') || true
rm -f "$TMP/r.out"
rc=0
got=$(TMPDIR="$TMP/vm" bash -c "$LIM exec \"\$@\"" _ "$DT" "$TMP/spill.v4.osr" "$TMP/bad" \
        --mem=1048576 --vmblock=268435456 2>&1 >/dev/null) || rc=$?
got=$(printf '%s' "$got" | sed -n 's/^  ERROR! //p')
[ "$rc" -ne 0 ] && [ ! -e "$TMP/bad" ] || fail "[vmblock 256M] rc=$rc o quedo salida"
[ -n "$want" ] && [ "$want" = "$got" ] \
    || fail "[vmblock 256M] otro error que el Rust
      Rust:   $want
      Pascal: $got"
[ -z "$(ls -A "$TMP/vm")" ] || fail "[vmblock 256M] quedo un temporal del spill"
pass=$((pass + 1))

# El directorio del spill es el de `std::env::temp_dir()`: en Unix SOLO
# $TMPDIR. El GetTempDir de FPC miraba antes TEMP y TMP, asi que con esas
# apuntando a otro lado el Pascal fallaba (o derramaba en otro disco) y el
# Rust no. Solo nativo: bajo wine rige el directorio temporal de Windows.
if [ -n "$LIM" ]; then
    want=$(TMPDIR="$TMP/vm" "$DC" future-lz "$TMP/spill.v4.osr" "$TMP/r.out" \
             --mem=1048576 --vmblock=131072 2>/dev/null)
    got=$(env TEMP=/no/existe TMP=/no/existe TMPDIR="$TMP/vm" "$DT" "$TMP/spill.v4.osr" \
            "$TMP/p.out" --mem=1048576 --vmblock=131072 2>/dev/null) \
        || fail "[TEMP/TMP] con TEMP y TMP en otro lado el spill fallo: tiene que usar TMPDIR"
    [ "$want" = "$got" ] || fail "[TEMP/TMP] estadisticas distintas
      Rust:   $want
      Pascal: $got"
    cmp -s "$TMP/r.out" "$TMP/p.out" || fail "[TEMP/TMP] los bytes difieren"
    [ -z "$(ls -A "$TMP/vm")" ] || fail "[TEMP/TMP] quedo un temporal del spill"
    rm -f "$TMP/r.out" "$TMP/p.out"
    pass=$((pass + 1))
fi

echo "  pascal_futurelz_conformance: passed=$pass mismatches=0"
