#!/usr/bin/env bash
# El ENCODER del port a Pascal contra el Rust (docs/pascal-port.md, fase 5).
#
# El criterio es el del port a Rust contra el C++: la misma entrada y las
# mismas opciones pasan por los dos encoders, con --seed=7, y los archivos
# tienen que ser IDENTICOS byte a byte. El Rust ya es byte-identico al C++ en
# toda esta matriz (tests/encode_conformance.sh), asi que es el oraculo.
#
# La matriz es la de tests/encode_conformance.sh. Lo que el Pascal todavia no
# tiene portado sale con 3 y se cuenta aparte como "no portado", no como fallo:
# el harness crece con cada sub-fase sin cambiar de forma.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || { say "sin cargo -- salteando"; exit 0; }
cargo_rs build --release -p osrep-conformance >/dev/null 2>&1 || fail "no compila el harness Rust"
RS=$RUST_TARGET/release/encode_conformance

ET="${OSREP_PASCAL_ENCODETOOL:-pascal/bin/encodetool}"
warn_shared_wine "$ET"
if [ ! -x "$ET" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/encodetool pascal/encodetool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/encodetool.lpr"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0
notported=0

python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
unit = bytes((i * 17 + 5) & 0xFF for i in range(1 << 19))   # 512 KiB
open(os.path.join(d, "dup4m.bin"), "wb").write(unit * 8)
open(os.path.join(d, "dup20m.bin"), "wb").write(unit * 40)   # cruza bloques y da la vuelta al anillo
open(os.path.join(d, "empty.bin"), "wb").write(b"")
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
# 16 copias de 1 MiB aleatorio: la entrada con la que el port a Rust midio que
# las dos rutas de CDC dan archivos distintos. dup4m es periodica y CDC no
# encuentra fronteras en ella: con esa sola, las dos rutas coinciden y la
# prueba de la ruta polinomial pasaria sin probar nada.
import random
random.seed(1)
blk = bytes(random.randrange(256) for _ in range(1 << 20))
open(os.path.join(d, "rnd16.bin"), "wb").write(blk * 16)
# Empates en la segunda pasada: muchos matches con el mismo origen, que el
# std::sort del C++ (srep.cpp:899) deja en un orden propio. tie10k es la
# entrada minima (512 bytes al azar x2, un byte, x18) y noisy* la forma del
# revisor (una unidad de 4 KiB con 1-40 bytes al azar despues de ~5% de las
# copias). Con las tres la 2.2.1 (Rust y Pascal) escribia otros bytes que el
# C++ en -m3/-m4/-m5 y f (noisy2m tambien en -m0); ver
# tests/cxx_sort_tie_divergence.sh.
r = random.Random(1)
u = bytes(r.randrange(256) for _ in range(512))
open(os.path.join(d, "tie10k.bin"), "wb").write(u * 2 + bytes([r.randrange(256)]) + u * 18)
r = random.Random(20261009)
u = bytes(r.randrange(256) for _ in range(4096))
out = bytearray()
while len(out) < 2 << 20:
    out += u
    if r.random() < 0.05:
        out += bytes(r.randrange(256) for _ in range(r.randint(1, 40)))
open(os.path.join(d, "noisy512k.bin"), "wb").write(out[:512 << 10])
open(os.path.join(d, "noisy2m.bin"), "wb").write(out[:2 << 20])
# Casi-copias para un -l chico (la primera pasada de -m3/-m4/-m5 con
# -l16..-l128 o un -c chico): copias de una unidad al azar con el ultimo byte
# (o el anteultimo) de ~30% de las celdas de 16 bytes subido 1-3, y unos bytes
# al azar despues de ~20% de las copias; una mitad de 64 KiB con unidad de
# 4 KiB y otra con unidad de 1 KiB. La 2.2.x (Rust y Pascal) escribia otros
# bytes que el C++ en todos los casos de -l chico de abajo: dos chunks que
# difieren en el ultimo byte se reemplazaban en add_hash (el C++ ademas
# compara los digests de -m3 ahi) y los ports corrian compress<0> donde el
# C++ corre el escaneo filtrado por bitarr, compress<accel>.
def nearcopies(seed, unit_len):
    r = random.Random(seed)
    unit = bytearray(r.randrange(256) for _ in range(unit_len))
    out = bytearray()
    while len(out) < 65536:
        u = bytearray(unit)
        for c in range(0, unit_len, 16):
            if r.random() < 0.3:
                j = c + 15 - r.randrange(2)
                u[j] = (u[j] + r.randrange(1, 4)) & 0xFF
        out += u
        if r.random() < 0.2:
            out += bytes(r.randrange(256) for _ in range(r.randint(1, 7)))
    return bytes(out[:65536])
open(os.path.join(d, "smalll.bin"), "wb").write(nearcopies(2, 4096) + nearcopies(3, 1024))
# Los bordes del escaneo, mas abajo (directo contra el C++, salvo
# a33929/a200k, fijados por md5):
# zruns.bin (tramos al azar entre tramos de ceros) es donde importa el
# LOOKAHEAD del escaneo acelerado (filtra por bitarr en tandas de hasta 256
# posiciones); nearcopy.bin (64 KiB al azar y tres copias con 200 bytes
# cambiados en cada una) le da a la pasada en memoria de -d matches cercanos,
# y el escaneo guarda candidatos solo entre el final del ultimo match y el
# comienzo del siguiente que encontro esa pasada; a33929.bin y a200k.bin (un
# solo byte repetido) dan bloques de -m3 que no son un numero entero de
# chunks, donde el test de digest lee el primer chunk del bloque siguiente.
r = random.Random(20261015)
out = bytearray()
while len(out) < 240000:
    out += bytes(r.randrange(256) for _ in range(r.randint(500, 3000)))
    out += bytes(r.randint(1000, 5000))
open(os.path.join(d, "zruns.bin"), "wb").write(out)
r = random.Random(7)
base = bytes(r.randrange(256) for _ in range(65536))
out = bytearray(base)
for _ in range(3):
    c = bytearray(base)
    for _ in range(200):
        c[r.randrange(len(c))] = r.randrange(256)
    out += c
open(os.path.join(d, "nearcopy.bin"), "wb").write(out)
open(os.path.join(d, "a33929.bin"), "wb").write(b"A" * 33929)
open(os.path.join(d, "a200k.bin"), "wb").write(b"A" * 200000)
PY

# enc <entrada> <modo> <opciones...>: los dos encoders, --seed=7, cmp.
enc() {
    local input="$1" m="$2"; shift 2
    "$RS" "$m" "$@" --seed=7 "$input" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err" \
        || fail "el Rust fallo en $m $* sobre $input: $(tail -1 "$TMP/rs.err")"
    local rc=0
    "$ET" "$m" "$@" --seed=7 "$input" "$TMP/pa.osr" >/dev/null 2>"$TMP/pa.err" || rc=$?
    if [ "$rc" -eq 3 ]; then
        notported=$((notported + 1))
        return
    fi
    [ "$rc" -eq 0 ] || fail "el Pascal fallo en $m $* sobre $input: $(tail -1 "$TMP/pa.err")"
    cmp -s "$TMP/rs.osr" "$TMP/pa.osr" \
        || fail "$m $* sobre $(basename "$input"): archivos distintos ($(stat -c%s "$TMP/rs.osr") contra $(stat -c%s "$TMP/pa.osr") bytes)"
    pass=$((pass + 1))
}

C=tests/corpus

say "-m0o (REP en memoria, v2)"
for input in $C/mixed.bin $C/text.bin $C/zeros.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m0o -d16mb
    enc "$input" m0o -d2mb -b1mb
    enc "$input" m0o -d16mb -l1024
    enc "$input" m0o -d16mb -dl256
    enc "$input" m0o -d16mb -hash-
    enc "$input" m0o -d16mb -hash=md5
    enc "$input" m0o -d16mb -hash=siphash
done

say "-m4o/-m5o (match finder con tabla de hash, v2)"
for input in $C/mixed.bin $C/text.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m4o
    enc "$input" m4o -b1mb
    enc "$input" m4o -d16mb
    enc "$input" m4o -d16mb -b1mb
    enc "$input" m4o -l1024
    enc "$input" m5o
    enc "$input" m5o -b1mb
    enc "$input" m5o -d16mb
    enc "$input" m5o -l1024
    enc "$input" m5o -l256
done

say "-m3o (chunks con digest, v1; con -d cae a v2)"
for input in $C/mixed.bin $C/text.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m3o
    enc "$input" m3o -b1mb
    enc "$input" m3o -d16mb
    enc "$input" m3o -l1024
done

say "los hashes del bloque, sobre -m4o y -m3o"
for input in $C/mixed.bin "$TMP/dup4m.bin"; do
    for h in -hash- -hash=md5 -hash=sha1 -hash=sha512 -hash=siphash -hash=vmac; do
        enc "$input" m4o "$h"
        enc "$input" m3o "$h"
    done
done

say "-m0/-m3/-m4/-m5 (Index-LZ, v4) y el sufijo f (Future-LZ, v3)"
for input in $C/mixed.bin $C/text.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m0 -d16mb
    enc "$input" m3
    enc "$input" m4
    enc "$input" m5
    enc "$input" m3f
    enc "$input" m4f
    enc "$input" m5f
done

say "la segunda pasada con empates de origen (el orden del std::sort del C++)"
for input in "$TMP/tie10k.bin" "$TMP/noisy512k.bin"; do
    for m in m3 m4 m5 m3f m4f m5f m3v m4v m5v; do
        enc "$input" "$m"
    done
    enc "$input" m4 -b1mb
done
enc "$TMP/noisy2m.bin" m0 -d16mb
enc "$TMP/noisy2m.bin" m0v -d16mb

say "-l o -c chicos: el escaneo filtrado por bitarr y el digest de -m3 en add_hash"
# accel = min(max(L/32, 1), 4) elige compress<accel> (srep.cpp:631-634); -aN/M
# dimensiona bitarr y elige la variante; -a0/-a- es compress<0>. Los valores
# sin comportamiento definido en el C++ (-a3, -l96..-l127, -a0/N, una variante
# mas ancha que el chunk) caen al escaneo simple: el mismo archivo que -a0.
SMALLL_CASES="m3o|-l32 m3|-l32 m4o|-l16 m4|-c64 m5|-c64 m4o|-l32 m5o|-l32 m4|-l64 m3f|-l32
  m3o|-l32_-a0 m3|-l32_-a- m4o|-l16_-a2/2 m3o|-l32_-a2 m4|-l64_-a16 m4o|-l64_-a4/64
  m5|-c64_-a8 m4o|-l16_-a1/16 m4|-l64_-a1/64 m3v|-l32 m4v|-l16 m5v|-c64"
for case in $SMALLL_CASES; do
    IFS='|' read -r m o <<<"$case"
    # shellcheck disable=SC2086
    enc "$TMP/smalll.bin" "$m" ${o//_/ }
done
for case in "m4o|-l32 -a3|-l32 -a0" "m4|-l32 -a5|-l32 -a0" "m3o|-l32 -a0/4|-l32 -a0" \
            "m4|-l16 -a1/32|-l16 -a0" "m5o|-l32 -a1/64|-l32 -a0" "m4o|-l96|-l96 -a0" \
            "m3|-l100|-l100 -a0" "m4|-l32 -a4/8 -a-|-l32 -a0" "m4|-l64 -a2/3|-l64 -a0"; do
    IFS='|' read -r m o plain <<<"$case"
    # shellcheck disable=SC2086
    enc "$TMP/smalll.bin" "$m" $o
    cp "$TMP/pa.osr" "$TMP/fallback.osr"
    # shellcheck disable=SC2086
    "$ET" "$m" $plain --seed=7 "$TMP/smalll.bin" "$TMP/plain.osr" >/dev/null 2>&1 \
        || fail "el Pascal fallo en $m $plain"
    cmp -s "$TMP/fallback.osr" "$TMP/plain.osr" \
        || fail "$m $o no cae al escaneo simple (distinto de $m $plain)"
    pass=$((pass + 1))
done

say "-m1/-m2 (chunking por contenido)"
for input in $C/mixed.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m1o
    enc "$input" m1
    enc "$input" m1f
    enc "$input" m2o
    enc "$input" m2
    enc "$input" m2f
    enc "$input" m1o -l2048
    enc "$input" m1o -b1mb
done

say "CDC por las dos rutas del hash de frontera (CRC32C y polinomial)"
# La CPU decide la ruta (SSE4.2); OSREP_CDC_POLY=1 fuerza la polinomial en los
# dos encoders. Primero, que la entrada distinga las rutas.
"$RS" m1o --seed=7 "$TMP/rnd16.bin" "$TMP/crc.osr" >/dev/null 2>&1
OSREP_CDC_POLY=1 "$RS" m1o --seed=7 "$TMP/rnd16.bin" "$TMP/poly.osr" >/dev/null 2>&1
cmp -s "$TMP/crc.osr" "$TMP/poly.osr" \
    && fail "las dos rutas de CDC dan el mismo archivo: la prueba no distinguiria"
for input in "$TMP/rnd16.bin" "$TMP/dup20m.bin"; do
    for m in m1o m2o m1 m1f; do
        enc "$input" "$m"
        export OSREP_CDC_POLY=1          # explicito: un prefijo delante de una
        enc "$input" "$m"                # funcion no llega seguro a sus hijos
        unset OSREP_CDC_POLY
    done
done
for m in m0o m3o m4o m5o; do
    if [ "$m" = m0o ]; then enc "$TMP/rnd16.bin" "$m" -d16mb; else enc "$TMP/rnd16.bin" "$m"; fi
done

say "v5 (el contenedor por defecto)"
for input in $C/mixed.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin" "$TMP/rnd16.bin"; do
    for m in m0v m1v m2v m3v m4v m5v; do
        if [ "$m" = m0v ]; then enc "$input" "$m" -d16mb; else enc "$input" "$m"; fi
    done
done
# -hash- es el caso propio de v5: no reserva digest (hash_size 0), donde v1-v4
# guardan 16 bytes en cero. Y bloques chicos, y -d, sobre las dos pasadas.
for input in $C/mixed.bin "$TMP/dup20m.bin"; do
    for m in m3v m4v m5v m3 m4f; do
        enc "$input" "$m" -hash-
        enc "$input" "$m" -hash=siphash
        enc "$input" "$m" -hash=sha512
        enc "$input" "$m" -b1mb
        enc "$input" "$m" -d16mb
    done
done

say "entradas degeneradas"
for m in m4o m5o m3o; do
    enc "$TMP/empty.bin" "$m"
    enc "$TMP/tiny.bin" "$m"
    enc $C/tiny.bin "$m"
done
enc "$TMP/empty.bin" m0o -d16mb
enc "$TMP/tiny.bin"  m0o -d16mb
for m in m4 m4f m4v m1v; do
    enc "$TMP/empty.bin" "$m"
    enc "$TMP/tiny.bin" "$m"
done

say "el segundo oraculo: el C++ 1.0.7, directo, en lo que el escribe (v1-v4)"
# El Rust es byte-identico al C++, pero comparar contra los dos es mas fuerte:
# una diferencia contra dos que coinciden entre si es, sin ambiguedad, del
# port nuevo (docs/pascal-port.md, "Dos oraculos, no uno").
CPP="$CXX_BIN/osrep"
if [ -x "$CPP" ] || make_cxx bin/osrep >/dev/null 2>&1; then
    for input in $C/mixed.bin $C/text.bin "$TMP/dup20m.bin" "$TMP/rnd16.bin"; do
        for case in "m0o|-d16mb" "m1o|" "m2o|" "m3o|" "m4o|" "m5o|" "m0|-d16mb" "m1|" "m2|" \
                    "m3|" "m4|" "m5|" "m1f|" "m3f|" "m4f|" "m5f|" "m4o|-d16mb"; do
            IFS='|' read -r m o <<<"$case"
            # shellcheck disable=SC2086
            "$CPP" "-$m" $o --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>&1 \
                || fail "el C++ fallo en -$m $o"
            # shellcheck disable=SC2086
            "$ET" "$m" $o --seed=7 "$input" "$TMP/pa.osr" >/dev/null 2>&1 \
                || fail "el Pascal fallo en $m $o"
            cmp -s "$TMP/cpp.osr" "$TMP/pa.osr" \
                || fail "-$m $o sobre $(basename "$input"): distinto del C++"
            pass=$((pass + 1))
        done
    done
    # -l o -c chicos, directo contra el C++, en lo que el C++ tiene definido
    for case in $SMALLL_CASES; do
        IFS='|' read -r m o <<<"$case"
        case "$m" in *v) continue ;; esac
        # shellcheck disable=SC2086
        "$CPP" "-$m" ${o//_/ } --seed=7 "$TMP/smalll.bin" "$TMP/cpp.osr" >/dev/null 2>&1 \
            || fail "el C++ fallo en -$m ${o//_/ }"
        # shellcheck disable=SC2086
        "$ET" "$m" ${o//_/ } --seed=7 "$TMP/smalll.bin" "$TMP/pa.osr" >/dev/null 2>&1 \
            || fail "el Pascal fallo en $m ${o//_/ }"
        cmp -s "$TMP/cpp.osr" "$TMP/pa.osr" \
            || fail "-$m ${o//_/ } sobre smalll.bin: distinto del C++"
        pass=$((pass + 1))
    done
    # Los empates del orden por origen, directo contra el C++ (sin -m2: el
    # -m2 del C++ no es determinista en todas las entradas).
    for input in "$TMP/tie10k.bin" "$TMP/noisy512k.bin" "$TMP/noisy2m.bin"; do
        for case in "m3|" "m4|" "m5|" "m3f|" "m4f|" "m5f|" "m4|-b1mb" "m0|-d16mb"; do
            IFS='|' read -r m o <<<"$case"
            # shellcheck disable=SC2086
            "$CPP" "-$m" $o --seed=7 "$input" "$TMP/cpp.osr" >/dev/null 2>&1 \
                || fail "el C++ fallo en -$m $o"
            # shellcheck disable=SC2086
            "$ET" "$m" $o --seed=7 "$input" "$TMP/pa.osr" >/dev/null 2>&1 \
                || fail "el Pascal fallo en $m $o"
            cmp -s "$TMP/cpp.osr" "$TMP/pa.osr" \
                || fail "-$m $o sobre $(basename "$input"): distinto del C++ (el orden de los empates de la segunda pasada?)"
            pass=$((pass + 1))
        done
    done
    # Los bordes del escaneo y -ia- (las entradas se describen donde se
    # generan). Con estos casos el C++ da el mismo archivo en cada corrida:
    # cada uno se corrio al menos 300 veces (la mitad en fila, la mitad de a
    # ocho a la vez), con -t1 como aca, con un solo resultado. -t1 es solo con lo que se midieron;
    # la lectura adelantada del bloque siguiente (mas abajo) no tiene orden
    # con ningun -t. Un -aN posterior sin /M vuelve la variante a su valor
    # por defecto (srep.cpp:345-346); encodetool tiene su propio parser, asi
    # que el de la CLI lo prueba rust_cli_conformance con OSREP_PORT_BIN.
    # -l130 y -c130 le dan al C++ el aviso de potencia de dos, exit 1. -ia-
    # (io_accelerator -1, srep.cpp:349-352) apaga el filtro de slices
    # (hash_table.cpp:33-36) que corren -m5, y -m4 con un -c bastante menor
    # que -l; -m3 nunca lo lee, asi que ahi -ia-/-ia+ no tienen que cambiar
    # nada (-dl128 deja a BASE_LEN dividiendo al chunk de 128, donde los ports
    # escriben los bytes del C++). Gana el ultimo -ia. Cada caso fallaba con
    # alguna build que lo de arriba dejaba pasar: zruns con LOOKAHEAD 128,
    # nearcopy con el fin de la ventana de candidatos incluido, y los -ia- de
    # -m4/-m5 con la 02d4823, que ignoraba -ia-.
    cp $C/text.bin "$TMP/text.bin"
    for case in "zruns.bin|m3|-l130" "zruns.bin|m3|-c130" \
                "nearcopy.bin|m4|-l40 -d1mb" "nearcopy.bin|m4o|-l16 -d1mb" \
                "smalll.bin|m4|-l16 -a1/2 -a1" "smalll.bin|m4|-l32 -a2/4 -a2" \
                "text.bin|m5|-l1000 -ia-" "text.bin|m5o|-l1024 -c128 -ia-" \
                "nearcopy.bin|m4|-l1024 -c128 -ia-" "nearcopy.bin|m5|-l1000 -ia+ -ia-" \
                "nearcopy.bin|m5|-l1000 -ia- -ia+" "nearcopy.bin|m3|-l1024 -c128 -dl128 -ia-" \
                "nearcopy.bin|m3|-l1024 -c128 -dl128 -ia+" "text.bin|m3|-ia-"; do
        IFS='|' read -r f m o <<<"$case"
        rc=0
        # shellcheck disable=SC2086
        "$CPP" -t1 "-$m" $o --seed=7 "$TMP/$f" "$TMP/cpp.osr" >/dev/null 2>&1 || rc=$?
        [ "$rc" -le 1 ] || fail "el C++ fallo en -t1 -$m $o sobre $f (exit $rc)"
        # shellcheck disable=SC2086
        "$ET" "$m" $o --seed=7 "$TMP/$f" "$TMP/pa.osr" >/dev/null 2>&1 \
            || fail "el Pascal fallo en $m $o sobre $f"
        cmp -s "$TMP/cpp.osr" "$TMP/pa.osr" \
            || fail "-$m $o sobre $f: distinto del C++ -t1"
        rm -f "$TMP/cpp.osr" "$TMP/pa.osr"
        pass=$((pass + 1))
    done
fi

say "el digest de -m3 leido por adelantado: fijado, porque el C++ tiene una carrera ahi"
# a33929.bin y a200k.bin (un solo byte repetido) con -b261b/-b392b dan bloques
# de -m3 que no son un numero entero de chunks de 130 bytes. El escaneo del
# bloque k se pasa unos bytes de su ultimo chunk, los lee del bloque k+1, y su
# ultimo add_hash compara el digest del chunk (fin del bloque)/L, que solo
# escribe el prepare_buffer del bloque k+1 (HtPrepareAhead). En el C++ los dos
# los escribe el hilo que lee mientras el que comprime corre el bloque k
# (io.cpp:250-265), sin nada que los ordene, con cualquier -t (-t1
# incluido), asi que el archivo de la 1.0.7 cambia de una corrida a otra.
# Medido con -t1, 762 corridas del C++ por caso (180 en fila, el resto de a 8
# o de a 48 a la vez; -m3f 800 mas, de a 64), el archivo fijado salio en:
#   a33929 -m3 -l130 -b261b       757 de 762 (las otras 5: un mismo archivo)
#   a33929 -m3 -l130 -b261b -a0   759 de 762 (las otras 3: ese mismo otro)
#   a200k  -m3 -l130 -b392b       761 de 762
#   a200k  -m3o -l130 -b392b      761 de 762
#   a200k  -m3f -l130 -b392b      1561 de 1562
# Los ports siempre toman el bloque k+1 leido y preparado entero antes de
# comprimir el k. Los md5 son ese archivo (el Rust y el Pascal lo escriben, y
# es el que el C++ da en la mayoria de las corridas); contra una corrida del
# C++ en vivo, este caso fallaria de vez en cuando. Fallaban con la f7ddd1f,
# que leia un digest en cero ahi. El -b en bytes del C++ lleva sufijo b (-b261
# son MB); el de encodetool, no (el sufijo b no lo entiende y queda el -b por
# defecto).
while read -r want f m o; do
    # shellcheck disable=SC2086
    "$ET" "$m" $o --seed=7 "$TMP/$f" "$TMP/pa.osr" >/dev/null 2>&1 \
        || fail "el Pascal fallo en $m $o sobre $f"
    got="$(md5sum < "$TMP/pa.osr" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || fail "$m $o sobre $f: md5 $got, fijado $want (el archivo de la mayoria del C++)"
    rm -f "$TMP/pa.osr"
    pass=$((pass + 1))
done <<'EOF'
3bb728cac4f1991a5262935b783ace1b a33929.bin m3 -l130 -b261
3bb728cac4f1991a5262935b783ace1b a33929.bin m3 -l130 -b261 -a0
790693374c6a276ede29ad58a11dc189 a200k.bin m3 -l130 -b392
07e20d42335672be6c2a3b3a32f45986 a200k.bin m3o -l130 -b392
5d0d1b127567b39e121e26b56f79dfcc a200k.bin m3f -l130 -b392
EOF

say "el desempate del orden por origen, contra el std::sort de libstdc++"
# SortBySrc transcribe el std::sort de libstdc++, que no es estable. encodetool
# sortfixture la corre sobre los arreglos de oracles/cxx/tools/stdsort_fixture.cpp
# (muchos empates, ordenados, al reves, organ pipe, 0..2048 elementos, con el
# corte a heapsort por profundidad) y tiene que imprimir lo mismo que el
# std::sort real. Con OSREP_PASCAL_ENCODETOOL apuntando a un wrapper de wine
# prueba las builds de Windows.
if [ -x "$CXX_BIN/stdsort_fixture" ] || make_cxx bin/stdsort_fixture >/dev/null 2>&1; then
    "$CXX_BIN/stdsort_fixture" > "$TMP/sort.cpp" || fail "stdsort_fixture fallo"
    "$ET" sortfixture | tr -d '\r' > "$TMP/sort.pa" || fail "encodetool sortfixture fallo"
    cmp -s "$TMP/sort.cpp" "$TMP/sort.pa" \
        || fail "SortBySrc no deja los empates como el std::sort de libstdc++"
    pass=$((pass + 1))
else
    fail "no compila $CXX_BIN/stdsort_fixture"
fi

echo "  pascal_encode_conformance: passed=$pass mismatches=0 not_ported=$notported"
