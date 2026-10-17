#!/usr/bin/env bash
# El port a Pascal contra el binario Rust publicado (docs/pascal-port.md).
#
# Fase 1: `--version` y `--help`, byte a byte. Suena trivial y no lo es -- es
# la unica prueba que hoy distingue "compila" de "produce lo mismo", y ya
# atrapo una diferencia real: `WriteLn` en Windows traduce LF a CRLF, asi que
# la version ingenua de --version salia con 39 bytes en vez de 38. Por eso
# src/outraw.pas escribe al handle directo.
#
# A medida que avancen las fases esto crece hacia la suite completa; el plan es
# que termine llamando a tests/rust_cli_conformance.sh con OSREP_BIN apuntando
# al binario Pascal, que ya funciona sin tocar una linea.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

RS="${OSREP_RUST_BIN:-$RUST_TARGET/x86_64-unknown-linux-gnu/release/osrep}"
PA="${OSREP_PASCAL_BIN:-pascal/bin/osrep-linux-x86_64}"
warn_shared_wine "$PA"

[ -x "$RS" ] || { say "sin binario Rust en $RS -- salteando"; exit 0; }
if [ ! -x "$PA" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    bash pascal/build.sh >/dev/null 2>&1 || fail "pascal/build.sh fallo"
fi

# absolutos, para los casos que corren con el directorio cambiado
case "$RS" in /*) RSX="$RS";; *) RSX="$ROOT/$RS";; esac
case "$PA" in /*) PAX="$PA";; *) PAX="$ROOT/$PA";; esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

say "--version y --help, byte a byte contra el binario Rust"
for flag in --version --help -V -h '-?'; do
    "$RS" "$flag" >"$TMP/r.out" 2>"$TMP/r.err"; rrc=$?
    "$PA" "$flag" >"$TMP/p.out" 2>"$TMP/p.err"; prc=$?
    [ "$rrc" -eq "$prc" ] || fail "$flag: exit $prc en Pascal, $rrc en Rust"
    cmp -s "$TMP/r.out" "$TMP/p.out" \
        || fail "$flag: stdout difiere ($(stat -c%s "$TMP/r.out") vs $(stat -c%s "$TMP/p.out") bytes)"
    # Los dos escriben a stdout y dejan stderr vacio; si eso cambia hay que
    # saberlo, porque un consumidor que captura el fd equivocado no ve nada.
    [ ! -s "$TMP/p.err" ] || fail "$flag: el Pascal escribio en stderr"
    pass=$((pass + 1))
done

say "las terminaciones de linea son LF, tambien en los binarios de Windows"
# No se pueden ejecutar aca, asi que se inspecciona el .exe: si el codigo
# usara la capa de texto, la salida traeria CRLF en Windows. La verificacion
# real es en la VM Win7 en cada release; esto es el control barato que corre
# siempre.
"$PA" --help | grep -qU $'\r' && fail "el --help de Pascal trae CR" || true
pass=$((pass + 1))

say "el .exe de 32 bits es large address aware, como el i686 del Rust"
# Sin el flag Windows le da 2 GB de direcciones, y comprimir desde stdin sin
# -s (el match finder dimensionado para 25 GiB) sale con "Out of memory".
X86=pascal/bin/osrep-windows-x86.exe
if [ -f "$X86" ] && command -v objdump >/dev/null 2>&1; then
    objdump -p "$X86" | grep -qi 'large address aware' \
        || fail "$X86 no es large address aware ({\$SETPEFLAGS \$20} en osrep.lpr)"
    pass=$((pass + 1))
fi

say "los .exe piden DEP y ASLR, como los de MinGW del Rust"
# FPC deja DllCharacteristics en 0: sin NX_COMPAT ni DYNAMIC_BASE, Windows
# no aplica DEP ni ASLR al proceso. DYNAMIC_BASE sin .reloc no sirve de nada.
for exe in pascal/bin/osrep-windows-x86.exe pascal/bin/osrep-windows-x86_64.exe; do
    [ -f "$exe" ] && command -v objdump >/dev/null 2>&1 || continue
    pe=$(LC_ALL=C objdump -p "$exe"); sec=$(LC_ALL=C objdump -h "$exe")
    for f in NX_COMPAT DYNAMIC_BASE; do
        printf '%s\n' "$pe" | grep -q "$f" || fail "$exe sin $f ({\$SETPEOPTFLAGS} en osrep.lpr)"
    done
    case "$exe" in *x86_64*)
        printf '%s\n' "$pe" | grep -q HIGH_ENTROPY_VA || fail "$exe sin HIGH_ENTROPY_VA" ;;
    esac
    printf '%s\n' "$sec" | grep -q '\.reloc' || fail "$exe sin .reloc (-WR en build.sh)"
    pass=$((pass + 1))
done

# Fase 7: la CLI entera. Lo que sigue compara el Pascal con el Rust desde la
# linea de comandos; la puerta completa es tests/rust_cli_conformance.sh con
# OSREP_PORT_BIN apuntando al Pascal (OSREP_PASCAL_FULL=1 la corre al final).
IN="$TMP/in.bin"
cat tests/corpus/text.bin tests/corpus/mixed.bin > "$IN"

say "la misma linea de comandos da el mismo archivo, byte a byte"
# --seed=7 en todas: sin semilla la clave es aleatoria y los dos difieren a
# proposito. Incluye lo que la fase 6 no podia cubrir sin CLI: el corte Gear,
# --dup-paranoid y las --chunk-*.
while IFS= read -r args; do
    [ -n "$args" ] || continue
    rm -f "$TMP/r.osr" "$TMP/p.osr" "$TMP/r.ix" "$TMP/p.ix"
    a_r=${args//@IX@/$TMP/r.ix}; a_p=${args//@IX@/$TMP/p.ix}
    rrc=0; "$RS" --seed=7 $a_r "$IN" "$TMP/r.osr" >/dev/null 2>&1 || rrc=$?
    prc=0; "$PA" --seed=7 $a_p "$IN" "$TMP/p.osr" >/dev/null 2>&1 || prc=$?
    [ "$rrc" -eq "$prc" ] || fail "[$args]: exit $prc en Pascal, $rrc en Rust"
    if [ -e "$TMP/r.osr" ]; then
        cmp -s "$TMP/r.osr" "$TMP/p.osr" || fail "[$args]: los archivos difieren"
    fi
    if [ -e "$TMP/r.ix" ]; then
        cmp -s "$TMP/r.ix" "$TMP/p.ix" || fail "[$args]: los indices difieren"
    fi
    # rc 1 es el warning de -l, que avisa justamente que el archivo puede
    # salir corrupto: no se descomprime
    if [ "$prc" -eq 0 ]; then
        rm -f "$TMP/p.out"
        a_d=""; [ -e "$TMP/p.ix" ] && a_d="-index=$TMP/p.ix"
        "$PA" -d $a_d "$TMP/p.osr" "$TMP/p.out" >/dev/null 2>&1 \
            || fail "[$args]: el Pascal no descomprime su propio archivo"
        cmp -s "$IN" "$TMP/p.out" || fail "[$args]: la vuelta no da la entrada"
    fi
    pass=$((pass + 1))
done <<'ARGS'

-m0
-m1
-m2
-m4
-m5
-m3f
-m5o
--format=v4
--format=v4 -m3f
--format=v4 -m4o
--format=v4 -m1f -index=@IX@
--format=v4 -m5o -index=@IX@
-m4 -hash=sha1
-m3 -hash=siphash
-m5 -hash=sha512
-m3 -hash-
-m4 -b1mb
-m3 -l256
-m4 -c512
-m3 -l100
-m0 -d16m
-m3 -d8m
-dup
-dup --format=v4
-dup -m5
-dup -m1
-dup --chunk-hash=gear
-dup --chunk-avg=8192 --chunk-min=2048 --chunk-max=32768
-dup --chunk-buf=65536
-dup --dup-paranoid
-dup --format=v4 --chunk-hash=gear --dup-paranoid
-v0 -m4
-t4 -a1 -slp -ia- -rem=x -m3
ARGS

say "por un pipe: stdin a stdout, con y sin -s"
for args in "" "--format=v4" "--format=v4 -m5f" "-m0" "-s$(stat -c%s "$IN")" "-s99999999"; do
    "$RS" --seed=7 $args - - <"$IN" >"$TMP/r.pipe" 2>/dev/null || fail "[$args]: el Rust fallo por pipe"
    "$PA" --seed=7 $args - - <"$IN" >"$TMP/p.pipe" 2>/dev/null || fail "[$args]: el Pascal fallo por pipe"
    cmp -s "$TMP/r.pipe" "$TMP/p.pipe" || fail "[$args]: por pipe los archivos difieren"
    "$PA" -d - - <"$TMP/p.pipe" >"$TMP/p.out" 2>/dev/null || fail "[$args]: -d por pipe fallo"
    cmp -s "$IN" "$TMP/p.out" || fail "[$args]: la vuelta por pipe no da la entrada"
    pass=$((pass + 1))
done

say "los errores: el mismo codigo y el mismo texto"
# Los que no dependen de un archivo danado; esos (el Debug de los decoders)
# tienen su propia seccion, mas abajo.
"$RS" --seed=7 "$IN" "$TMP/ok.osr" >/dev/null 2>&1
while IFS= read -r args; do
    [ -n "$args" ] || continue
    a=${args//@OK@/$TMP/ok.osr}
    rrc=0; (cd "$TMP" && "$RSX" $a </dev/null >r.o 2>r.e) || rrc=$?
    prc=0; (cd "$TMP" && "$PAX" $a </dev/null >p.o 2>p.e) || prc=$?
    [ "$rrc" -eq "$prc" ] || fail "[$args]: exit $prc en Pascal, $rrc en Rust"
    cmp -s "$TMP/r.e" "$TMP/p.e" || fail "[$args]: stderr difiere: '$(cat "$TMP/p.e")' vs '$(cat "$TMP/r.e")'"
    cmp -s "$TMP/r.o" "$TMP/p.o" || fail "[$args]: stdout difiere"
    pass=$((pass + 1))
done <<'ARGS'
-bogus
-c3
-m3x
-b
-bfoo
-dfoo
-d:
-dq:l64
-mem
-memfoo
-vfoo
-t
-l
-hash=
--format=v6
--chunk-hash=x
--chunk-avg=x
--chunk-avg=-1
a b c
-i a b
--verify a b
nonexistent.bin
-d nonexistent.osr
-i nonexistent.osr
--verify nonexistent.osr
-m1 -d64m
-dup -m0
-dup --seed=x
-m3 -index=x.ix
-index=x.ix
--format=v4 -m3 -index=x.ix
--format=v4 -dup -m3f
@OK@ @OK@
-i @OK@
--verify @OK@
ARGS

say "-s menor que lo que llega por stdin: el mismo rechazo"
for args in "" "--format=v4"; do
    rrc=0; "$RS" $args -s1000 - - <"$IN" >"$TMP/r.o" 2>"$TMP/r.e" || rrc=$?
    prc=0; "$PA" $args -s1000 - - <"$IN" >"$TMP/p.o" 2>"$TMP/p.e" || prc=$?
    [ "$rrc" -eq "$prc" ] || fail "-s1000 $args: exit $prc en Pascal, $rrc en Rust"
    cmp -s "$TMP/r.e" "$TMP/p.e" || fail "-s1000 $args: stderr difiere: '$(cat "$TMP/p.e")'"
    [ ! -s "$TMP/p.o" ] || fail "-s1000 $args: el Pascal escribio un archivo igual"
    pass=$((pass + 1))
done

say "los warnings: el mismo texto y el mismo codigo"
# La linea de progreso trae tiempos, asi que se comparan solo las lineas de
# warning.
for args in "-m3 -l100" "-m4 -c1000" "-dup -m1" "-dup -m2"; do
    rm -f "$TMP/r.osr" "$TMP/p.osr"
    rrc=0; "$RS" --seed=7 $args "$IN" "$TMP/r.osr" >/dev/null 2>"$TMP/r.e" || rrc=$?
    prc=0; "$PA" --seed=7 $args "$IN" "$TMP/p.osr" >/dev/null 2>"$TMP/p.e" || prc=$?
    [ "$rrc" -eq "$prc" ] || fail "[$args]: exit $prc en Pascal, $rrc en Rust"
    grep -ai 'warning' "$TMP/r.e" > "$TMP/r.w" || true
    grep -ai 'warning' "$TMP/p.e" > "$TMP/p.w" || true
    [ -s "$TMP/r.w" ] || fail "[$args]: el Rust no avisa nada (el caso no prueba lo que dice)"
    cmp -s "$TMP/r.w" "$TMP/p.w" || fail "[$args]: el warning difiere: '$(cat "$TMP/p.w")'"
    pass=$((pass + 1))
done

say "OSREP_SEED_HEX: la clave del archivo, repetida tal cual"
# Sin --seed: si el Pascal ignorara la variable sortearia una clave y el
# archivo no coincidiria.
# La variable tiene que medir exactamente la clave del hash (vmac 32 bytes,
# siphash 16); de otro largo se ignora, y eso tambien se prueba.
K16=00112233445566778899aabbccddeeff
for case in "vmac:$K16$K16" "siphash:$K16" "siphash:${K16}AB"; do
    hash=${case%%:*}; hex=${case#*:}
    rm -f "$TMP/r.osr" "$TMP/p.osr"
    OSREP_SEED_HEX=$hex "$RS" --seed=7 -hash=$hash "$IN" "$TMP/r.osr" >/dev/null 2>&1
    OSREP_SEED_HEX=$hex "$PA" --seed=7 -hash=$hash "$IN" "$TMP/p.osr" >/dev/null 2>&1
    cmp -s "$TMP/r.osr" "$TMP/p.osr" || fail "OSREP_SEED_HEX $case: los archivos difieren"
    pass=$((pass + 1))
done
# sin --seed, con la variable bien medida: tiene que ganarle al sorteo
OSREP_SEED_HEX=$K16$K16 "$RS" "$IN" "$TMP/r.osr" >/dev/null 2>&1
OSREP_SEED_HEX=$K16$K16 "$PA" "$IN" "$TMP/p.osr" >/dev/null 2>&1
cmp -s "$TMP/r.osr" "$TMP/p.osr" || fail "OSREP_SEED_HEX sin --seed: los archivos difieren"
pass=$((pass + 1))
# y sin nada, dos corridas dan claves distintas: la clave es por corrida
"$PA" "$IN" "$TMP/a1.osr" >/dev/null 2>&1; "$PA" "$IN" "$TMP/a2.osr" >/dev/null 2>&1
cmp -s "$TMP/a1.osr" "$TMP/a2.osr" && fail "dos corridas sin semilla dieron el mismo archivo"
pass=$((pass + 1))

say "un solo nombre: .osr decide la direccion y el otro sale de el"
mkdir "$TMP/names"; cp "$IN" "$TMP/names/x.bin"
( cd "$TMP/names" && "$PAX" --seed=7 x.bin >/dev/null 2>&1 ) || fail "osrep x.bin fallo"
[ -e "$TMP/names/x.bin.osr" ] || fail "osrep x.bin no escribio x.bin.osr"
mv "$TMP/names/x.bin" "$TMP/names/orig.bin"
( cd "$TMP/names" && "$PAX" -d x.bin.osr >/dev/null 2>&1 ) || fail "osrep -d x.bin.osr fallo"
cmp -s "$TMP/names/orig.bin" "$TMP/names/x.bin" || fail "osrep -d x.bin.osr no reconstruyo x.bin"
pass=$((pass + 1))

say "un archivo danado: el mismo stderr y el mismo codigo que el Rust, byte a byte"
# La CLI del Rust imprime los errores de los decoders con Debug
# (`format!("{e:?}: {finame}")`, modes.rs): Container(Truncated),
# BadData("v5 footer"), DigestMismatch { block: 0 }, Io(Os { .. }), y con
# -dup Decode(..). Hay consumidores que parsean ese stderr, asi que el Pascal
# tiene que dar el mismo texto, no uno parecido (src/decfault.pas). Cada
# contenedor, truncado en el header, la semilla, los bloques y el footer, y
# con bytes cambiados en todos esos lugares; -d, --verify y -i. El barrido
# grande (decenas de miles de mutaciones) se corre aparte; esto es la red
# rapida, y al final exige haber visto cada forma del Debug, para que un
# encoder que cambie los offsets no la deje vacia en silencio.
D="$TMP/dmg"; mkdir "$D"
python3 - "$D" <<'PY' || fail "no se pudo armar la entrada de los archivos danados"
import os, random, sys
d = sys.argv[1]
random.seed(7)
unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
half = bytes(random.randrange(256) for _ in range(30000))
open(os.path.join(d, "in.bin"), "wb").write(unit * 6 + half + unit * 6 + half + unit * 4)
far = [bytes(random.randrange(256) for _ in range(64 * 1024)) for _ in range(16)]
open(os.path.join(d, "far.bin"), "wb").write(b"".join(far) * 2)
PY
dmk() { # $1=nombre, el resto opciones del encoder (en $D, nombres relativos)
    local name="$1"; shift
    (cd "$D" && "$RSX" -v0 --seed=7 -b64k "$@" in.bin "$name.osr" >/dev/null 2>&1) \
        || fail "no se pudo armar $name.osr"
}
dmk v5 -m3
dmk v5dup -m3 -dup
dmk v4 --format=v4 -m3
dmk v4dup --format=v4 -m3 -dup
dmk v3 --format=v4 -m3f
dmk v3ix --format=v4 -m3f -index=v3ix.ix
dmk v2ix --format=v4 -m5o -index=v2ix.ix
dmk v1 --format=v4 -m3o
# -dup con el trailer ODUP detras de un Future-LZ o un I/O LZ: el Rust solo lo
# escribe sobre Index-LZ, el C++ sobre cualquiera (y con -index=). -i los
# describe despues de 2.3.0; antes decia "Not an Omega SREP".
DUPX=""
if [ -x "$CXX_BIN/osrep" ]; then
    for spec in "v3dup -m3f" "v2dup -m3o" "v3dupix -m3f -index=v3dupix.ix"; do
        set -- $spec; name="$1"; shift
        (cd "$D" && "$ROOT/$CXX_BIN/osrep" --seed=7 -b64k -dup --chunk-hash=gear "$@" in.bin "$name.osr" >/dev/null 2>&1) \
            || fail "no se pudo armar $name.osr con el C++"
        DUPX="$DUPX $name"
    done
fi
# Un archivo que termina en "ODUP" (aca, el v4 -dup de arriba): un Future-LZ
# o un I/O LZ termina en sus ultimos literales, asi que el suyo termina en ese
# trailer, meta y todo. 2.3.0 y el C++ 1.0.7 lo tomaban por un -dup y
# -d archivo salida fallaba (por stdin lo restauraban, ver abajo); -d ahora
# lo decodifica como uno comun cuando el archivo
# de atras del trailer no se sostiene y el entero si. Las mutaciones de abajo
# le pegan al trailer de mentira; nestdup es el -dup del -dup (el trailer de
# afuera es de verdad).
odp() { # $1=nombre, el resto opciones del encoder; la entrada es v4dup.osr
    local name="$1"; shift
    (cd "$D" && "$RSX" -v0 --seed=7 -b64k "$@" v4dup.osr "$name.osr" >/dev/null 2>&1) \
        || fail "no se pudo armar $name.osr"
}
odp odpf --format=v4 -m3f
odp odpo --format=v4 -m3o -hash-
odp odpfix --format=v4 -m3f -index=odpfix.ix
odp nestdup --format=v4 -m3 -dup
for name in odpf odpo odpfix; do
    [ "$(tail -c 4 "$D/$name.osr")" = ODUP ] || fail "$name.osr no termina en ODUP: no prueba nada"
done
(cd "$D" && "$RSX" -v0 --seed=7 -m5 -b64k far.bin far.osr >/dev/null 2>&1) || fail "no se pudo armar far.osr"
: > "$D/empty.osr"
printf 'this is not an archive\n%.0s' 1 2 3 4 5 6 > "$D/text.osr"
: > "$D/seen"
dpass=0
# los dos, en $D, con los mismos argumentos: el mismo codigo y el mismo stderr.
# Sin subshells ni cmp: con ~500 comparaciones, los forks eran mas de la mitad
# del tiempo. `read -d ''` lee el archivo entero (stderr no trae NUL).
cd "$D"
same() {
    local rrc=0 prc=0 re pe
    "$RSX" "$@" </dev/null >/dev/null 2>r.e || rrc=$?
    "$PAX" "$@" </dev/null >/dev/null 2>p.e || prc=$?
    IFS= read -r -d '' re <r.e || true
    IFS= read -r -d '' pe <p.e || true
    [ "$rrc" -eq "$prc" ] || fail "[$*]: exit $prc en Pascal, $rrc en Rust
      Rust:   $re
      Pascal: $pe"
    [ "$re" = "$pe" ] || fail "[$*]: stderr difiere
      Rust:   $re
      Pascal: $pe"
    printf '%s' "$re" >> seen
    dpass=$((dpass + 1))
}
check3() { # $1=archivo, el resto opciones de -d
    local f="$1"; shift
    same -v0 -d "$@" "$f" o.out
    same -v0 --verify "$f"
    same -v0 -i "$@" "$f"
}
# --verify y -i no decodifican: sobre un v1-v4 solo parsean el contenedor, y
# eso lo cubren de sobra los truncados. Un byte cambiado se mira con -d.
checkd() { # $1=archivo, el resto opciones de -d
    local f="$1"; shift
    case "$name" in v5*|*dup*|odp*) check3 "$f" "$@" ;; *) same -v0 -d "$@" "$f" o.out ;; esac
}
# $1=origen $2=posicion $3=destino: el byte en $2 pasa a 0 (o a 0xFF si ya era 0)
zap() {
    local b v
    cp "$1" "$3"
    b=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
    if [ "${b:-0}" -eq 0 ]; then v=255; else v=0; fi
    printf "$(printf '\\%03o' "$v")" | dd of="$3" bs=1 seek="$2" conv=notrunc 2>/dev/null
}
for name in v5 v5dup v4 v4dup v3 v3ix v2ix v1 $DUPX odpf odpo odpfix nestdup; do
    a="$D/$name.osr"; n=$(stat -c%s "$a")
    ix=""; [ -e "$D/$name.ix" ] && ix="-index=$name.ix"
    # sano: -i tiene que describirlo, y los dos igual
    same -v0 -i $ix "$name.osr"
    grep -q 'ERROR' r.e && fail "-i $ix $name.osr: $(cat r.e)"
    case "$name" in *dup*) grep -q '^-dup: ' r.e || fail "-i $name.osr sin la linea -dup: $(cat r.e)" ;; esac
    case "$name" in odp*|nestdup)
        grep -q '^-dup: ' r.e && [ "$name" != nestdup ] && fail "-i $name.osr: una linea -dup en uno comun"
        same -v0 -d $ix "$name.osr" o.out
        cmp -s o.out v4dup.osr || fail "-d $ix $name.osr no devolvio v4dup.osr"
        same -v0 --verify "$name.osr"
        ;;
    esac
    for c in 0 3 16 27 28 60 $((n / 2)) $((n - 32)) $((n - 24)) $((n - 1)); do
        [ "$c" -ge 0 ] && [ "$c" -lt "$n" ] || continue
        head -c "$c" "$a" > "$D/m.osr"
        check3 m.osr $ix
    done
    for p in 0 4 5 6 8 10 12 20 24 40 89 105 $((n / 2)) \
             $((n - 32)) $((n - 26)) $((n - 20)) $((n - 12)) $((n - 1)); do
        [ "$p" -ge 0 ] && [ "$p" -lt "$n" ] || continue
        zap "$a" "$p" "$D/m.osr"
        checkd m.osr $ix
    done
    # el indice danado, con el archivo sano
    if [ -n "$ix" ]; then
        m=$(stat -c%s "$D/$name.ix")
        for c in 0 4 $((m - 1)); do
            head -c "$c" "$D/$name.ix" > "$D/m.ix"; same -v0 -d -index=m.ix "$name.osr" o.out
            same -v0 -i -index=m.ix "$name.osr"
        done
        for p in 0 3 8 12 $((m / 2)); do
            zap "$D/$name.ix" "$p" "$D/m.ix"; same -v0 -d -index=m.ix "$name.osr" o.out
        done
        same -v0 -i "$name.osr"
        same -v0 -i -index=nonexistent.ix "$name.osr"
    fi
done
# El archivo que termina en "ODUP", en cada modo v4 y con -hash-: los dos
# escriben los mismos bytes (y el C++ tambien, asi que lo que el escribe se
# decodifica igual), y los dos lo restauran.
for m in m0 m0f m0o m1 m1f m1o m2 m2f m2o m3 m3f m3o m4 m4f m4o m5 m5f m5o m3f/-hash- m0o/-hash- m5/-hash-; do
    h=""; case "$m" in */*) h="${m#*/}"; m="${m%%/*}" ;; esac
    rm -f rw.osr pw.osr cw.osr
    "$RSX" -v0 --seed=7 -b64k --format=v4 $h -$m v4dup.osr rw.osr >/dev/null 2>&1 || fail "-$m $h: el Rust no comprimio"
    "$PAX" -v0 --seed=7 -b64k --format=v4 $h -$m v4dup.osr pw.osr >/dev/null 2>&1 || fail "-$m $h: el Pascal no comprimio"
    cmp -s rw.osr pw.osr || fail "-$m $h de v4dup.osr: el Pascal escribio otros bytes"
    if [ -n "$DUPX" ]; then
        "$ROOT/$CXX_BIN/osrep" --seed=7 -b64k $h -$m v4dup.osr cw.osr >/dev/null 2>&1 \
            && cmp -s rw.osr cw.osr || fail "-$m $h de v4dup.osr: no son los bytes del C++"
    fi
    same -v0 -d rw.osr o.out
    cmp -s o.out v4dup.osr || fail "-d de -$m $h de v4dup.osr no devolvio la entrada"
    same -v0 -i rw.osr
    same -v0 --verify rw.osr
done
# un v5 que termina en su propio footer nunca se olfatea como trailer ODUP:
# el footer termina en un CRC, que es "ODUP" en uno de cada 2^32 archivos, y
# 2.3.0 entonces rechazaba un archivo sano con "the -dup meta is missing or
# corrupt". Se arma uno eligiendo bits que nadie lee (v5odup): los dos lo
# tienen que restaurar.
v5odup() {
python3 - "$1" <<'PY2'
import struct, sys
# Make a v5 archive's footer CRC spell "ODUP" and keep it valid: the high half
# of meta_offset, which nothing reads when there is no meta, is solved for.
# This project's CRC-32C starts at 0 and has no final xor, so it is linear.
T = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
    T.append(c)
def crc(b):
    c = 0
    for x in b:
        c = T[(c ^ x) & 0xFF] ^ (c >> 8)
    return c
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); f = len(b) - 32
base = bytearray(b[f:f + 28]); base[20:24] = bytes(4)
want = struct.unpack("<I", b"ODUP")[0] ^ crc(base)
cols = []
for i in range(32):
    u = bytearray(28); u[20 + i // 8] = 1 << (i % 8); cols.append([crc(u), 1 << i])
pick = 0
for bit in reversed(range(32)):
    r = next((k for k in range(len(cols)) if cols[k][0] >> bit & 1), None)
    if r is None: continue
    v, m = cols.pop(r)
    for c in cols:
        if c[0] >> bit & 1: c[0] ^= v; c[1] ^= m
    if want >> bit & 1: want ^= v; pick ^= m
assert want == 0
base[20:24] = struct.pack("<I", pick)
b[f:f + 28] = base; b[f + 28:f + 32] = struct.pack("<I", crc(base))
assert b[-4:] == b"ODUP"
open(p, "wb").write(b)
PY2
}
cp v5.osr m.osr
v5odup m.osr || fail "no se pudo armar un v5 terminado en ODUP"
same -v0 -d m.osr o.out
cmp -s o.out in.bin || fail "un v5 terminado en ODUP no se restauro: $(cat r.e)"
# 2.3.0 y el C++ 1.0.7 fallaban en -d archivo salida con odpf.osr, pero por
# stdin lo restauraban (el trailer se olfatea solo entre dos archivos con
# nombre): es el atajo que da el CHANGELOG, y los dos lo siguen haciendo
rrc=0; "$RSX" -v0 -d - r.out <odpf.osr >/dev/null 2>r.e || rrc=$?
prc=0; "$PAX" -v0 -d - p.out <odpf.osr >/dev/null 2>p.e || prc=$?
[ "$rrc" -eq 0 ] && [ "$prc" -eq 0 ] && cmp -s r.out v4dup.osr && cmp -s p.out v4dup.osr \
    || fail "-d - salida < odpf.osr: Rust $rrc '$(cat r.e)', Pascal $prc '$(cat p.e)'"
rm -f r.out p.out
dpass=$((dpass + 1))
# Los 8 bytes delante de un "ODUP" olfateado no son un tamano para reservar:
# en un comun son bytes de la entrada, hasta el largo del archivo, y -d leia
# esa "meta" antes de recorrer nada (en win32, con mas de 2^31 salia Io; con
# mas de 2^32 SetLength cortaba el largo y ReadUpTo desbordaba el heap). Un
# archivo ralo de 1 TiB, con y sin "DUPR" donde empezaria la meta: ninguno es
# un archivo osrep y ninguno lee la meta. Nativo, con el espacio de
# direcciones limitado, volver a leerla es un fallo y no un OOM.
PWINE=0
if [ "$(head -c 2 "$PA")" = '#!' ] && grep -q wine "$PA"; then PWINE=1; fi
FL=$((1 << 40))
for spec in "4096 0" "64 1"; do
    read -r back tag <<<"$spec"
    rm -f sp.osr
    truncate -s $((FL - 12)) sp.osr
    python3 -c 'import struct, sys; sys.stdout.buffer.write(struct.pack("<Q", int(sys.argv[1])) + b"ODUP")' \
        $((FL - 12 - back)) >>sp.osr
    [ "$tag" = 1 ] && printf DUPR | dd of=sp.osr bs=1 seek="$back" conv=notrunc status=none
    rrc=0; (ulimit -v 4194304; "$RSX" -v0 -d sp.osr o.out) </dev/null >/dev/null 2>r.e || rrc=$?
    prc=0; ([ "$PWINE" = 1 ] || ulimit -v 4194304; "$PAX" -v0 -d sp.osr o.out) </dev/null >/dev/null 2>p.e || prc=$?
    [ "$rrc" -eq "$prc" ] && cmp -s r.e p.e \
        || fail "-d de un trailer ralo ($back, DUPR $tag): Pascal $prc '$(cat p.e)', Rust $rrc '$(cat r.e)'"
    case "$tag" in
        0) [ "$rrc" -eq 4 ] && grep -qxF "  ERROR! the -dup meta is missing or corrupt" r.e ;;
        1) [ "$rrc" -eq 3 ] && grep -qxF "  ERROR! Decode(Container(NotAnOsrepFile))" r.e ;;
    esac || fail "-d de un trailer ralo ($back, DUPR $tag): $rrc '$(cat r.e)'"
    rm -f sp.osr o.out
    dpass=$((dpass + 1))
done
# el largo del footer de un v4 una unidad menos: la tabla de tamanos deja de
# ser multiplo de 4, que es otro sitio de TableMismatch que el de arriba
n=$(stat -c%s v4.osr)
b=$(od -An -tu1 -j $((n - 16)) -N1 v4.osr | tr -d ' ')
cp v4.osr m.osr
printf "$(printf '\\%03o' $(( (b + 255) % 256 )))" | dd of=m.osr bs=1 seek=$((n - 16)) conv=notrunc 2>/dev/null
same -v0 -d m.osr o.out
grep -qF 'Container(TableMismatch)' r.e || fail "el footer de v4 recortado no dio TableMismatch: $(cat r.e)"
check3 empty.osr
check3 text.osr
# por stdin: el nombre en el mensaje es "-"
head -c 100 "$D/v4.osr" > "$D/m.osr"
rrc=0; "$RSX" -v0 -d - o.out <m.osr >/dev/null 2>r.e || rrc=$?
prc=0; "$PAX" -v0 -d - o.out <m.osr >/dev/null 2>p.e || prc=$?
[ "$rrc" -eq "$prc" ] && cmp -s "$D/r.e" "$D/p.e" \
    || fail "-d - de un archivo cortado: '$(cat "$D/p.e")' ($prc) vs '$(cat "$D/r.e")' ($rrc)"
dpass=$((dpass + 1))

# Errores de E/S de verdad: un disco lleno, un -vmfile= que no se puede abrir,
# un directorio como entrada, un tope de tamano de archivo. Solo en el nativo:
# el codigo y el mensaje de un Os { .. } son del sistema, y el .exe bajo wine
# da los de Windows (y el Rust de referencia es el de Linux).
case "$PA" in *linux*)
    SP="-v0 -mem1mb -vmblock=128kb"
    # far.osr tiene que derramar con $SP: si no, -vmfile= no se abre nunca. Lo
    # asegura el NotFound que se exige al final (solo sale de ese caso).
    mkdir "$D/adir"
    same -v0 -d v5.osr /dev/full
    same -v0 -d v4.osr /dev/full
    same -v0 -d v1.osr /dev/full
    same -v0 -d v5dup.osr /dev/full
    same $SP -vmfile=/nonexistent/dir/vm -d far.osr o.out
    same $SP -vmfile=adir -d far.osr o.out
    same $SP -vmfile=/dev/full -d far.osr o.out
    same -v0 -d adir o.out
    same -v0 -d adir -
    same -v0 -d -index=adir v3ix.osr o.out
    same -v0 -d -index=/dev/null v2ix.osr o.out
    same -v0 --seed=7 in.bin /dev/full
    same -v0 --seed=7 --format=v4 -m3o in.bin /dev/full
    same -v0 --seed=7 -dup in.bin /dev/full
    for f in far.osr v4dup.osr; do
        rrc=0; (ulimit -f 200 && trap '' XFSZ && "$RSX" -v0 -d "$f" o.out </dev/null >/dev/null 2>r.e) || rrc=$?
        prc=0; (ulimit -f 200 && trap '' XFSZ && "$PAX" -v0 -d "$f" o.out </dev/null >/dev/null 2>p.e) || prc=$?
        [ "$rrc" -eq "$prc" ] && cmp -s "$D/r.e" "$D/p.e" \
            || fail "-d $f con ulimit -f: '$(cat "$D/p.e")' ($prc) vs '$(cat "$D/r.e")' ($rrc)"
        cat "$D/r.e" >> "$D/seen"
        dpass=$((dpass + 1))
    done
    # stdout lleno: el Rust escribe por un LineWriter, asi que un archivo que
    # cabe entero en su buffer falla recien en el flush (otro mensaje)
    printf 'x' > "$D/x.bin"
    for f in in.bin x.bin; do
        rrc=0; "$RSX" -v0 --seed=7 -hash- "$f" - </dev/null >/dev/full 2>r.e || rrc=$?
        prc=0; "$PAX" -v0 --seed=7 -hash- "$f" - </dev/null >/dev/full 2>p.e || prc=$?
        [ "$rrc" -eq "$prc" ] && cmp -s "$D/r.e" "$D/p.e" \
            || fail "$f a un stdout lleno: '$(cat "$D/p.e")' ($prc) vs '$(cat "$D/r.e")' ($rrc)"
        cat "$D/r.e" >> "$D/seen"
        dpass=$((dpass + 1))
    done
    ;;
esac
# Archivos raros como entrada o salida: /dev/null, pipes, FIFOs, <(cmd),
# /proc, /dev/zero. El Rust solo falla donde falla una llamada al sistema (un
# seek sobre un pipe da ESPIPE, uno sobre /dev/null da 0 y sigue), y el Pascal
# tiene que dar lo mismo: el mismo codigo, el mismo stderr y la misma salida,
# y nunca colgarse. Antes de la rama perf8-io, -d a /dev/null de un v5 de
# varios bloques fallaba con "Success"; a un pipe, v3/v4 salian bien con
# basura y v1 y -dup se colgaban leyendo su propio pipe; un FIFO como salida
# se colgaba en el open; desde un FIFO, <(cmd) o /proc daba NotAnOsrepFile;
# -i/--verify no leian un pipe; y un lector que se iba mataba al proceso con
# SIGPIPE. Solo en el nativo: bajo wine esos dispositivos no existen.
# Cada caso con timeout: un cuelgue es un fallo, no una espera.
case "$PA" in *linux*)
    # $1=descripcion, $2=bash que corre "$B"; compara codigo, stderr y stdout
    samesh() {
        local rrc=0 prc=0
        B="$RSX" timeout 30 bash -c "set -o pipefail; $2" </dev/null >r.o 2>r.e || rrc=$?
        B="$PAX" timeout 30 bash -c "set -o pipefail; $2" </dev/null >p.o 2>p.e || prc=$?
        [ "$prc" -ne 124 ] || fail "$1: el Pascal se colgo"
        [ "$rrc" -ne 124 ] || fail "$1: el Rust se colgo"
        [ "$rrc" -eq "$prc" ] || fail "$1: exit $prc en Pascal, $rrc en Rust
      Rust:   $(cat r.e)
      Pascal: $(cat p.e)"
        cmp -s r.e p.e || fail "$1: stderr difiere
      Rust:   $(cat r.e)
      Pascal: $(cat p.e)"
        cmp -s r.o p.o || fail "$1: stdout difiere"
        cat r.e >> seen
        dpass=$((dpass + 1))
    }
    : > e.bin
    "$RSX" -v0 --seed=7 e.bin e5.osr >/dev/null 2>&1 || fail "no se pudo armar e5.osr"
    "$RSX" -v0 --seed=7 --format=v4 e.bin e4.osr >/dev/null 2>&1 || fail "no se pudo armar e4.osr"
    # el caso de /dev/null solo muerde con mas de un bloque (el seek al
    # segundo devuelve 0 y no lo que se pidio)
    nb=$("$RSX" --verify v5.osr 2>&1 | sed -n 's/.*intact\. \([0-9]*\) blocks.*/\1/p')
    [ "${nb:-0}" -ge 2 ] || fail "v5.osr tiene ${nb:-0} bloques; el caso de /dev/null necesita 2 o mas"
    for f in v5 v4 v3 v1 v5dup v4dup; do
        # /dev/null: lseek devuelve 0 sin error; el Rust sigue
        samesh "-d $f a /dev/null" '"$B" -v0 -d '$f'.osr /dev/null'
        # una salida que no admite seek: ESPIPE en el Rust, para todas las versiones
        samesh "-d $f a /dev/stdout por un pipe" '"$B" -v0 -d '$f'.osr /dev/stdout | od -c | tail -3'
        samesh "-d $f a >(cmd)" '"$B" -v0 -d '$f'.osr >(cat >/dev/null)'
        samesh "-d $f a un FIFO" 'rm -f fo; mkfifo fo; (timeout 5 cat fo >/dev/null) & "$B" -v0 -d '$f'.osr fo; r=$?; wait; rm -f fo; exit $r'
        # una entrada que no admite seek
        samesh "-d <(cat $f) a un archivo" '"$B" -v0 -d <(cat '$f'.osr) o.out; r=$?; rm -f o.out; exit $r'
        samesh "-d <(cat $f) a stdout" '"$B" -v0 -d <(cat '$f'.osr) - | od -c | tail -3'
        samesh "-d de un FIFO ($f)" 'rm -f fi; mkfifo fi; (timeout 5 cat '$f'.osr >fi) & "$B" -v0 -d fi o.out; r=$?; wait; rm -f fi o.out; exit $r'
        # -i y --verify leen el pipe entero, como el Rust
        samesh "-i <(cat $f)" '"$B" -v0 -i <(cat '$f'.osr)'
        samesh "--verify <(cat $f)" '"$B" -v0 --verify <(cat '$f'.osr)'
        samesh "--verify de un FIFO ($f)" 'rm -f fi; mkfifo fi; (timeout 5 cat '$f'.osr >fi) & "$B" -v0 --verify fi; r=$?; wait; rm -f fi; exit $r'
        samesh "-i - por un pipe ($f)" 'cat '$f'.osr | "$B" -v0 -i -'
    done
    # sin bloques, nada hace seek hasta medir la salida: "Can't write the output"
    samesh "-d de un v5 vacio a un pipe" '"$B" -v0 -d e5.osr /dev/stdout | cat'
    samesh "-d de un v4 vacio a un pipe" '"$B" -v0 -d e4.osr /dev/stdout | cat'
    # /proc: el seek al final da EINVAL
    samesh "-d /proc/self/status a stdout" '"$B" -v0 -d /proc/self/status - | cat'
    samesh "-d /proc/self/status a un archivo" '"$B" -v0 -d /proc/self/status o.out; r=$?; rm -f o.out; exit $r'
    samesh "-i /proc/self/status" '"$B" -v0 -i /proc/self/status'
    samesh "--verify /proc/self/status" '"$B" -v0 --verify /proc/self/status'
    samesh "-d /dev/null" '"$B" -v0 -d /dev/null - | cat'
    # /dev/zero: el Rust 2.1.2 lo leia entero antes de mirar la magia. Con el
    # espacio de direcciones limitado, volver a eso es un fallo y no un OOM.
    for m in -i --verify; do
        samesh "$m /dev/zero" '(ulimit -v 1048576; "$B" -v0 '$m' /dev/zero)'
        samesh "$m - </dev/zero" '(ulimit -v 1048576; "$B" -v0 '$m' - </dev/zero)'
    done
    # el lector que se va: EPIPE y "Can't write to stdout", no SIGPIPE (141).
    # far.osr da 2 MiB, mas que el buffer de un pipe: el corte es seguro.
    samesh "-d a un pipe que se cierra" '"$B" -v0 -d far.osr - | head -c 10 >/dev/null'
    # comprimir a un FIFO o a un pipe: el archivo sale entero y despues falla
    # el seek que lo mide (o, con -dup, mide 0); antes se colgaba en el open
    for c in "" "--format=v4" "-m3f --format=v4" "-dup" "-dup --format=v4" "-m0"; do
        samesh "comprimir $c a un FIFO" 'rm -f fo; mkfifo fo; (timeout 5 md5sum <fo >fo.sum) & "$B" -v0 --seed=7 '"$c"' in.bin fo; r=$?; wait; cat fo.sum; rm -f fo fo.sum; exit $r'
        samesh "comprimir $c a /dev/stdout" '"$B" -v0 --seed=7 '"$c"' in.bin /dev/stdout | md5sum'
        samesh "comprimir $c desde un FIFO" 'rm -f fi; mkfifo fi; (timeout 5 cat in.bin >fi) & "$B" -v0 --seed=7 '"$c"' fi o.out; r=$?; wait; md5sum <o.out; rm -f fi o.out; exit $r'
    done
    # un -dup con matches que caen en un bloque anterior: el Rust 2.1.2 abria
    # el cuerpo solo para escribir y fallaba con EBADF al releerlo
    for f in v5dup v4dup; do
        same -v0 -d -mem0 -vmblock=4k "$f.osr" o.out
        "$PAX" -v0 -d -mem0 -vmblock=4k "$f.osr" o.out >/dev/null 2>&1 \
            && cmp -s in.bin o.out || fail "-d -mem0 -vmblock=4k $f.osr no reconstruyo la entrada"
    done
    ;;
esac
# ningun texto de una excepcion de FPC llega al usuario (decfault.pas,
# FaultOfException): todo error de E/S sale con la forma del Rust
if grep -qE 'Stream (read|write) error|EReadError|EWriteError|EStreamError|Access violation' seen; then
    fail "un mensaje de FPC llego al stderr: $(grep -E 'Stream|Error:|violation' seen | head -3)"
fi
# cada forma del Debug tiene que haber aparecido al menos una vez
for want in 'Container(Truncated)' 'Container(NoFooter)' 'Container(NotAnOsrepFile)' \
            'Container(UnsupportedVersion(' 'Container(FooterExceedsFile)' 'Container(TableMismatch)' \
            'Container(UnsupportedFooterVersion(' \
            'BadData("v5 footer")' 'BadData("v5 record")' 'BadData("future-lz' 'BadData("record does not fit' \
            'DigestMismatch { block: ' 'Decode(' 'is damaged: Bad' 'Not an Omega SREP compressed file' \
            'Io(Custom { kind: UnexpectedEof'; do
    grep -qF "$want" "$D/seen" || fail "ningun caso dio '$want': la seccion ya no prueba esa forma"
done
case "$PA" in *linux*)
    for want in 'Io(Os { code: 28, kind: StorageFull' 'Io(Os { code: 2, kind: NotFound' \
                'Io(Os { code: 21, kind: IsADirectory' 'Io(Os { code: 27, kind: FileTooLarge' \
                'dedup failed, rc=8' 'Encode(Io)' "Can't write to stdout"; do
        grep -qF "$want" "$D/seen" || fail "ningun caso dio '$want': la seccion ya no prueba esa forma"
    done
    ;;
esac
cd "$ROOT"
say "$dpass comparaciones de stderr y codigo"
pass=$((pass + dpass))

say "los porcentajes: el mismo texto que el Rust, tambien en los empates"
# El Rust imprime `format!("{:.2}")` de un f64: el decimal EXACTO del Double,
# redondeado, y un empate exacto va al par. 861*100/12000 es 7.175 en los
# racionales pero 7.17499999999999982... como Double, y sale "7.17"; el
# FloatToStrF de FPC daba "7.18" (y el .exe de 32 bits, que calculaba en el x87
# con precision Extended, a veces otro Double). Estos tamanos de text.bin estan
# elegidos (barridos con el Rust) para que algun porcentaje caiga en un empate
# racional: c = la linea final al comprimir, d = al descomprimir, i = la de -i,
# s = el "% of file" de -i. La linea final trae segundos, que no se comparan.
PS="$TMP/pct"; mkdir "$PS"
head -c 16000 tests/corpus/text.bin > "$PS/src"
pct_line() { tr '\r' '\n' < "$1" | grep -a ' -> ' | sed -E 's/  [0-9]+\.[0-9]{3} sec$//'; }
is_tie() { [ "$2" -gt 0 ] && [ $(( (20000 * $1) % $2 )) -eq 0 ] && [ $(( (20000 * $1 / $2) % 2 )) -eq 1 ]; }
ties=0
while read -r n opts; do
    [ -n "$n" ] || continue
    head -c "$n" "$PS/src" > "$PS/in"
    for w in r p; do
        if [ "$w" = r ]; then bin="$RS"; else bin="$PA"; fi
        rm -f "$PS/$w.osr" "$PS/$w.out"
        "$bin" --seed=7 $opts "$PS/in" "$PS/$w.osr" >/dev/null 2>"$PS/$w.ce" \
            || fail "pct $n [$opts]: $w no comprimio"
        "$bin" -d "$PS/$w.osr" "$PS/$w.out" >/dev/null 2>"$PS/$w.de" \
            || fail "pct $n [$opts]: $w no descomprimio"
        "$bin" -i "$PS/$w.osr" >/dev/null 2>"$PS/$w.ie" || fail "pct $n [$opts]: -i de $w fallo"
    done
    cmp -s "$PS/r.osr" "$PS/p.osr" || fail "pct $n [$opts]: los archivos difieren"
    cmp -s "$PS/in" "$PS/p.out" || fail "pct $n [$opts]: la vuelta no da la entrada"
    for e in ce de; do
        r=$(pct_line "$PS/r.$e"); p=$(pct_line "$PS/p.$e")
        [ -n "$r" ] || fail "pct $n [$opts]: el Rust no imprimio la linea final ($e)"
        [ "$r" = "$p" ] || fail "pct $n [$opts]: '$p' en Pascal, '$r' en Rust"
    done
    cmp -s "$PS/r.ie" "$PS/p.ie" || fail "pct $n [$opts]: -i difiere: '$(cat "$PS/p.ie")' vs '$(cat "$PS/r.ie")'"
    # que el caso siga siendo un empate: si el encoder cambia los tamanos, la
    # seccion pasaria sin probar nada
    c=$(stat -c%s "$PS/r.osr")
    s=$(tr -d ',' < "$PS/r.ie" | sed -n 's/.* = \([0-9]*\) bytes.*/\1/p')
    if is_tie "$c" "$n" || is_tie "$n" "$c" || { [ -n "$s" ] && is_tie "$s" "$c"; }; then
        ties=$((ties + 1))
    fi
    pass=$((pass + 1))
done <<'PCT'
256 -m3 -l0
768 -m3 -l0
1280 -m3 -l0
4000 -m3 -l0
5920 -m3 -l0
12000 -m3 -l0
136 -m3 -l0
648 -m3 -l0
1699 -m3 -l0
1827 -m3 -l0
1891 -m3 -l0
4067 -m3 -l0
5859 -m3 -l0
6179 -m3 -l0
9315 -m3 -l0
10659 -m3 -l0
14819 -m3 -l0
256 --format=v4 -m3
1280 --format=v4 -m3
3840 --format=v4 -m3
6400 --format=v4 -m3
9472 --format=v4 -m3
152 --format=v4 -m3
2184 --format=v4 -m3
PCT
[ "$ties" -ge 20 ] || fail "solo $ties de los casos de porcentajes son empates: rebarrer los tamanos"
say "$ties empates de porcentaje, el mismo texto"

say "-delete borra la entrada solo si todo salio bien"
cp "$IN" "$TMP/del.bin"
"$PA" --seed=7 -delete "$TMP/del.bin" "$TMP/del.osr" >/dev/null 2>&1 || fail "-delete: la compresion fallo"
[ ! -e "$TMP/del.bin" ] || fail "-delete no borro la entrada"
"$PA" -d -delete "$TMP/del.osr" "$TMP/del.bin" >/dev/null 2>&1 || fail "-delete: -d fallo"
[ ! -e "$TMP/del.osr" ] || fail "-d -delete no borro el archivo"
cmp -s "$IN" "$TMP/del.bin" || fail "-delete: la vuelta no da la entrada"
cp "$IN" "$TMP/del.bin"
"$PA" --seed=7 -l100 -delete "$TMP/del.bin" "$TMP/del2.osr" >/dev/null 2>&1 || true
[ -e "$TMP/del.bin" ] || fail "-delete borro la entrada aunque hubo un warning"
pass=$((pass + 1))

say "una corrida que falla se lleva su salida, y nada mas"
# Hasta la 2.3.0 (y en el C++ 1.0.7) una corrida que fallaba dejaba lo que
# habia escrito: los bloques anteriores a un DigestMismatch, un archivo
# cortado por OutOfMemory, un -index= vacio, el principio del post-paso de
# -dup. Ahora se borran los archivos regulares que la corrida creo o trunco,
# y nada mas: ni stdout, ni un FIFO, ni un dispositivo, ni un symlink nombrado
# como salida, ni la entrada, ni un archivo que no abrio. Los dos binarios en
# directorios aparte: el mismo codigo, el mismo stderr y lo mismo en disco
# (nombre, tipo y tamano). Con wine, sin symlinks, FIFOs ni ulimit: el
# OutOfMemory sale de -b3g en el .exe de 32 bits y de -b100000g en el de 64
# (y en el Rust de referencia); en el nativo, de -b3g con 1 GiB de direcciones.
F="$TMP/fail"; mkdir -p "$F/in"
{ head -c 1048576 tests/corpus/text.bin; head -c 2097152 tests/corpus/random.bin; } > "$F/in/in.bin"
"$RS" -v0 --seed=7 -b1mb "$F/in/in.bin" "$F/in/ok.osr" >/dev/null 2>&1 || fail "no se pudo armar ok.osr"
"$RS" -v0 --seed=7 --format=v4 -b1mb "$F/in/in.bin" "$F/in/ok4.osr" >/dev/null 2>&1 || fail "no se pudo armar ok4.osr"
"$RS" -v0 --seed=7 --format=v4 -m3f -b1mb -index="$F/in/ok.ix" "$F/in/in.bin" "$F/in/okf.osr" >/dev/null 2>&1 \
    || fail "no se pudo armar okf.osr"
"$RS" -v0 --seed=7 -dup --format=v4 "$F/in/in.bin" "$F/in/dup.osr" >/dev/null 2>&1 || fail "no se pudo armar dup.osr"
for v in ok ok4; do
    cp "$F/in/$v.osr" "$F/in/bad$v.osr"
    printf '\125\252\125\252' | dd of="$F/in/bad$v.osr" bs=1 seek=$(( $(stat -c%s "$F/in/$v.osr") * 3 / 4 )) \
        conv=notrunc 2>/dev/null
done
cp "$F/in/ok.ix" "$F/in/bad.ix"
printf '\125\252\125\252' | dd of="$F/in/bad.ix" bs=1 seek=8 conv=notrunc 2>/dev/null
# el primer chunk unico de la meta ODUP (sin checksum en v4) de ~2 GiB: el
# post-paso escribe el cuerpo entero en la salida y despues se queda corto
python3 - "$F/in/dup.osr" "$F/in/badmeta.osr" <<'PY'
import struct, sys
b = bytearray(open(sys.argv[1], 'rb').read())
assert b[-4:] == b'ODUP'
at = len(b) - 12 - struct.unpack('<Q', b[-12:-4])[0]
assert b[at:at + 4] == b'DUPR' and b[at + 24] == 0
b[at + 28] = 0x7f
open(sys.argv[2], 'wb').write(b)
PY
FWINE=0
if [ "$(head -c 2 "$PA")" = '#!' ] && grep -q wine "$PA"; then FWINE=1; fi
if [ "$FWINE" = 1 ]; then
    PRE_R=''; BIG_R=-b100000g; PRE_P=''
    if grep -q 'x86_64' "$PA"; then BIG_P=-b100000g; else BIG_P=-b3g; fi
else
    PRE_R='ulimit -v 1048576;'; BIG_R=-b3g; PRE_P="$PRE_R"; BIG_P=-b3g
fi
# $1 = una linea de bash, corrida en un directorio nuevo con "$B" el binario,
# los insumos en "$I" y $BIG el -b que no entra; $2.. = lo que no debe quedar
fcase() {
    local side bin pre big rc line="$1"; shift
    for side in r p; do
        rm -rf "${F:?}/$side"; mkdir "$F/$side"
        if [ "$side" = r ]; then bin="$RSX"; pre="$PRE_R"; big="$BIG_R"; else bin="$PAX"; pre="$PRE_P"; big="$BIG_P"; fi
        rc=0
        (cd "$F/$side" && B="$bin" I="$F/in" BIG="$big" timeout 120 bash -c "$pre $line") \
            </dev/null >"$F/$side.o" 2>"$F/$side.e" || rc=$?
        echo "$rc" > "$F/$side.rc"
        (cd "$F/$side" && find . -mindepth 1 -printf '%y %s %p\n' | LC_ALL=C sort) > "$F/$side.ls"
    done
    cmp -s "$F/r.rc" "$F/p.rc" || fail "[$line]: exit $(cat "$F/p.rc") en Pascal, $(cat "$F/r.rc") en Rust: $(cat "$F/p.e")"
    [ "$(cat "$F/p.rc")" != 0 ] || [ "$line" != "${line%| wc -c}" ] || fail "[$line]: no fallo"
    cmp -s "$F/r.e" "$F/p.e" || fail "[$line]: stderr difiere: '$(cat "$F/p.e")' vs '$(cat "$F/r.e")'"
    cmp -s "$F/r.o" "$F/p.o" || fail "[$line]: stdout difiere"
    cmp -s "$F/r.ls" "$F/p.ls" || fail "[$line]: queda otra cosa en disco: $(diff "$F/r.ls" "$F/p.ls" | head -4)"
    for f; do [ ! -e "$F/p/$f" ] && [ ! -L "$F/p/$f" ] || fail "[$line]: quedo $f"; done
    pass=$((pass + 1))
}
fcase '"$B" -v0 -d "$I/badok.osr" o.out' o.out
fcase '"$B" -v0 -d "$I/badok4.osr" o.out' o.out
fcase 'echo keep > o.out; "$B" -v0 -d "$I/badok.osr" o.out' o.out
fcase 'cp "$I/badok.osr" a.osr; "$B" -v0 -d -delete a.osr o.out' o.out
fcase '"$B" -v0 -d -index=x.ix "$I/okf.osr" o.out' o.out
fcase '"$B" -v0 -d -index="$I/bad.ix" "$I/okf.osr" o.out' o.out
fcase '"$B" -v0 -d "$I/badmeta.osr" o.out' o.out
fcase '"$B" -v0 --seed=7 $BIG "$I/in.bin" x.osr' x.osr
fcase '"$B" -v0 --seed=7 --format=v4 -m3f -index=x.ix $BIG "$I/in.bin" x.osr' x.osr x.ix
fcase '"$B" -v0 --seed=7 -dup $BIG "$I/in.bin" x.osr' x.osr
fcase 'echo keep > x.osr; "$B" -v0 --seed=7 $BIG "$I/in.bin" x.osr' x.osr
fcase 'cp "$I/in.bin" a.bin; "$B" -v0 --seed=7 -delete $BIG a.bin x.osr' x.osr
fcase '"$B" -v0 --seed=7 --format=v4 -m3f -index=x.ix nope.bin x.osr' x.osr x.ix
fcase 'echo keep > x.osr; "$B" -v0 --seed=7 nope.bin x.osr'
grep -q keep "$F/p/x.osr" || fail "una corrida que no abrio x.osr la cambio"
# la entrada con otro nombre como salida: se rechaza antes del open (ver la
# seccion siguiente), asi que no hay nada que truncar ni que borrar
fcase 'cp "$I/badok.osr" a.osr; "$B" -v0 -d a.osr ./a.osr'
cmp -s "$F/p/a.osr" "$F/in/badok.osr" || fail "-d a.osr ./a.osr cambio a.osr"
# lo que la corrida lee nunca se borra: -index= con el nombre de la salida
fcase 'cp "$I/ok.ix" k.ix; "$B" -v0 -d -index=k.ix "$I/okf.osr" ./k.ix'
cmp -s "$F/p/k.ix" "$F/in/ok.ix" || fail "-d -index=k.ix ... ./k.ix cambio k.ix"
fcase '"$B" -v0 -d "$I/badok.osr" - | wc -c'
if [ "$FWINE" = 0 ]; then
    fcase 'echo t > t.out; ln -s t.out l.out; "$B" -v0 -d "$I/badok.osr" l.out'
    [ -L "$F/p/l.out" ] || fail "se borro el symlink por el que se escribio"
    fcase 'mkfifo fo; (timeout 10 cat fo >/dev/null) & "$B" -v0 -d "$I/badok.osr" fo; r=$?; wait; exit $r'
    [ -p "$F/p/fo" ] || fail "se borro el FIFO"
    fcase '"$B" -v0 -d "$I/badok.osr" /dev/null'
fi

# Un anillo que no se puede mapear entero es OutOfMemory, como el zeroed_vec
# del Rust: antes el Pascal crecia a medida con SetLength, y con -d grande y
# un -b chico comprimia (exit 0) donde el Rust fallaba; sin tope, -b100000g
# crecia hasta que lo mataban. Este es el caso acotado (1 GiB de direcciones).
if [ "$FWINE" = 0 ]; then
    fcase '"$B" -v0 --seed=7 -b256mb -d1g -dh1mb "$I/in.bin" x.osr' x.osr
fi

say "ningun archivo que la corrida escribe es uno que lee, ni otro que escribe"
# El C++ rechaza una salida con el nombre de la entrada comparando los textos
# ("Input and output files should have different names", exit 3), asi que
# `osrep x.bin ./x.bin` truncaba la entrada y salia con 0 y un archivo de
# nada. Los ports siguen una regla (src/streamio.pas, "los archivos de una
# corrida"; util.rs del Rust): todo archivo que la corrida escribe -- el
# archivo o la salida de -d, -index= al comprimir, -temp=, -vmfile=, los
# temporales, y el archivo de stdout si la salida es - -- se abre sin truncar
# y se rechaza, con ese mensaje, si es un archivo que la corrida lee (la
# entrada o el de stdin, -index= al descomprimir) u otro que escribe, por
# identidad (dispositivo e inodo; volumen e indice en Windows, y con wine los
# hard links y las redirecciones del shell llegan con el mismo indice); recien
# despues se trunca. Los nombres que ya existen se comparan antes del primer
# open, asi un rechazo deja todo como estaba. Solo archivos regulares. Cada
# caso es una repro de una revision de las ramas r231. Ademas: -temp= se
# borra al terminar (como el C++, srep.cpp:1336), -vmfile= solo si se pudo
# abrir, -delete con stdin no borra un archivo "-", y -b0 es OutOfMemory.
cp "$D/far.osr" "$D/far.bin" "$F/in/"
# $1 = el codigo esperado, $2 = la linea (como en fcase), $3.. = archivos que
# tienen que quedar iguales a su copia en $F/in
scase() {
    local want="$1" line="$2" side bin rc f; shift 2
    for side in r p; do
        rm -rf "${F:?}/$side"; mkdir "$F/$side"
        if [ "$side" = r ]; then bin="$RSX"; else bin="$PAX"; fi
        rc=0
        (cd "$F/$side" && B="$bin" I="$F/in" timeout 120 bash -c "$line") \
            </dev/null >"$F/$side.o" 2>"$F/$side.e" || rc=$?
        echo "$rc" > "$F/$side.rc"
        (cd "$F/$side" && find . -mindepth 1 -printf '%y %s %p\n' | LC_ALL=C sort) > "$F/$side.ls"
    done
    [ "$(cat "$F/p.rc")" = "$want" ] || fail "[$line]: exit $(cat "$F/p.rc"), no $want: $(cat "$F/p.e")"
    cmp -s "$F/r.rc" "$F/p.rc" || fail "[$line]: exit $(cat "$F/p.rc") en Pascal, $(cat "$F/r.rc") en Rust: $(cat "$F/r.e")"
    if [ "$want" != 0 ]; then
        cmp -s "$F/r.e" "$F/p.e" || fail "[$line]: stderr difiere: '$(cat "$F/p.e")' vs '$(cat "$F/r.e")'"
    fi
    cmp -s "$F/r.o" "$F/p.o" || fail "[$line]: stdout difiere"
    cmp -s "$F/r.ls" "$F/p.ls" || fail "[$line]: queda otra cosa en disco: $(diff "$F/r.ls" "$F/p.ls" | head -4)"
    for f; do cmp -s "$F/p/$f" "$F/in/$f" || fail "[$line]: cambio $f"; done
    pass=$((pass + 1))
}
# otras escrituras y links de la entrada, y de -index= a la vuelta
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 in.bin ./in.bin' in.bin
scase 3 'cp "$I/in.bin" in.bin; ln in.bin y.bin; "$B" -v0 --seed=7 in.bin y.bin' in.bin
scase 3 'cp "$I/ok.osr" ok.osr; ln ok.osr ok; "$B" -v0 -d ok.osr' ok.osr
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 --format=v4 -m3f -index=./in.bin in.bin o.osr' in.bin
scase 3 'cp "$I/ok.ix" ok.ix; "$B" -v0 -d -index=ok.ix "$I/okf.osr" ./ok.ix' ok.ix
# dos salidas que son un archivo: se rechaza al abrir la segunda, y la
# primera, nueva, se borra
scase 3 '"$B" -v0 --seed=7 --format=v4 -m3f -index=o.osr "$I/in.bin" ./o.osr'
scase 3 '"$B" -v0 --seed=7 -temp=t.tmp - ./t.tmp < "$I/in.bin"'
# -vmfile= sobre lo que lee el decoder
scase 3 'cp "$I/far.osr" far.osr; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=./far.osr -d far.osr o.out' far.osr
scase 3 'cp "$I/ok.ix" ok.ix; "$B" -v0 -vmfile=./ok.ix -d -index=ok.ix "$I/okf.osr" o.out' ok.ix
scase 3 'echo x > o.out; "$B" -v0 -vmfile=./o.out -d "$I/far.osr" o.out'
grep -qx x "$F/p/o.out" || fail "-vmfile=./o.out: cambio o.out"
# -vmfile= se abre en el primer derrame: con el nombre de una salida nueva se
# rechaza cuando llega ese derrame, y un decode que no derrama nunca lo abre.
# Con otra escritura la salida todavia no existia, nada lo veia antes, el
# derrame la truncaba y el final del decode la borraba -- exit 0 y nada en
# disco, con -delete tampoco el archivo (bajo wine el Pascal fallaba por el
# recurso compartido y el Rust win64 la borraba igual)
scase 3 '"$B" -v0 -mem1mb -vmblock=128kb -vmfile=o.out -d "$I/far.osr" o.out'
scase 3 'cp "$I/far.osr" far.osr; "$B" -v0 -delete -mem1mb -vmblock=128kb -vmfile=./o.out -d far.osr o.out' far.osr
[ ! -e "$F/p/o.out" ] || fail "-vmfile=./o.out: quedo la salida rechazada"
scase 0 '"$B" -v0 -vmfile=o.out -d "$I/far.osr" o.out'
cmp -s "$F/p/o.out" "$F/in/far.bin" || fail "-vmfile=o.out sin derrame: la vuelta difiere"
# los archivos que abrio el shell para stdin y stdout tambien cuentan, aunque
# ningun nombre de la linea los delate: como la salida, -temp=, -index= o
# -vmfile=
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 - in.bin < in.bin' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -b0 - in.bin < in.bin' in.bin
scase 3 'cp "$I/badok.osr" badok.osr; "$B" -v0 -d - badok.osr < badok.osr' badok.osr
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -d - ok.osr < ok.osr' ok.osr
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -temp=in.bin - o.osr < in.bin' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 --format=v4 -m3f -index=in.bin - o.osr < in.bin' in.bin
scase 3 'cp "$I/far.osr" far.osr; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=far.osr -d - o.out < far.osr' far.osr
scase 3 '"$B" -v0 --seed=7 -temp=./o.osr < "$I/in.bin" > o.osr'
scase 3 '"$B" -v0 --seed=7 --format=v4 -m3f -index=./o.osr - - < "$I/in.bin" > o.osr'
scase 3 '"$B" -v0 -mem1mb -vmblock=128kb -vmfile=o.out -d "$I/far.osr" - > o.out'
[ -e "$F/p/o.out" ] || fail "-vmfile= sobre stdout: se borro"
# y como uno al otro, o como la entrada: stdout agregado (`>> x`) o abierto
# para leer y escribir (`1<> x`) sobre el archivo que la corrida lee, stdin y
# stdout el mismo archivo. Hasta la 2.3.0 todos con exit 0: la entrada
# danada, o con -delete borrada
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin - >> in.bin' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 in.bin - 1<> in.bin' in.bin
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -delete -d ok.osr - >> ok.osr' ok.osr
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -d ok.osr - >> ok.osr' ok.osr
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -d ok.osr - 1<> ok.osr' ok.osr
scase 3 'cp "$I/ok.ix" ok.ix; "$B" -v0 -d -index=ok.ix "$I/okf.osr" - >> ok.ix' ok.ix
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 - - < in.bin >> in.bin' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 - - < in.bin 1<> in.bin' in.bin
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -d - - < ok.osr 1<> ok.osr' ok.osr
# el archivo de stderr tambien, cuando la corrida escribe ahi al terminar
# bien (las lineas de progreso y resumen, -bar, los avisos): `2>&1` con la
# salida a stdout metia el resumen adentro del archivo (y nohup hace lo mismo
# desde una terminal), `2>o` lo escribia sobre los primeros bytes de la
# salida, `2>>x` al final de la entrada. Todos con exit 0, y con -delete sin
# la entrada. Con -v0 no va nada ahi, y `-v0 x - > o 2>&1` sigue andando
scase 3 'cp "$I/in.bin" in.bin; "$B" --seed=7 -delete in.bin - > o.osr 2>&1' in.bin
grep -qF 'Input and output files should have different names' "$F/p/o.osr" || fail "2>&1: el mensaje no esta en o.osr"
scase 3 'cp "$I/in.bin" in.bin; "$B" --seed=7 -delete in.bin o.osr 2>o.osr' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" --seed=7 -delete in.bin o.osr 2>>o.osr' in.bin
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -d -delete ok.osr - > o.out 2>&1' ok.osr
scase 3 'cp "$I/ok.osr" ok.osr; "$B" -d -delete ok.osr o.out 2>>o.out' ok.osr
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 -bar --seed=7 -delete in.bin - > o.osr 2>&1' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 -l100 --seed=7 in.bin - > o.osr 2>&1' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 -dup -m1 --seed=7 -delete in.bin o.osr 2>o.osr' in.bin
scase 3 'cp "$I/in.bin" in.bin; "$B" --seed=7 - o.osr < in.bin 2>>in.bin'
# stderr sobre la entrada: el mensaje del rechazo todavia cae ahi, pero la
# entrada no se lee mientras crece ni se borra
scase 3 'cp "$I/in.bin" in.bin; "$B" --seed=7 -delete in.bin o.osr 2>>in.bin'
cmp -s -n "$(stat -c%s "$F/in/in.bin")" "$F/p/in.bin" "$F/in/in.bin" || fail "2>>in.bin: cambio in.bin"
scase 0 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin - > o.osr 2>&1'
"$PAX" -v0 -d "$F/p/o.osr" "$F/p/o.out" </dev/null >/dev/null 2>&1 && cmp -s "$F/p/o.out" "$F/in/in.bin" \
    || fail "-v0 ... - > o.osr 2>&1: la vuelta difiere"
scase 0 'cp "$I/in.bin" in.bin; "$B" --seed=7 in.bin o.osr > log 2>&1; rm log' in.bin
# un rechazo deja todo como estaba: un nombre que ya existe se compara antes
# del primer open, no despues del que lo truncaria
scase 3 'echo old > o.osr; "$B" -v0 --seed=7 --format=v4 -m3f -index=./o.osr "$I/in.bin" o.osr'
grep -qx old "$F/p/o.osr" || fail "-index=./o.osr: cambio o.osr"
scase 3 'echo old > o.osr; "$B" -v0 --seed=7 -temp=./o.osr - o.osr < "$I/in.bin"'
grep -qx old "$F/p/o.osr" || fail "-temp=./o.osr: cambio o.osr"
scase 3 'echo old > k.ix; "$B" -v0 --seed=7 --format=v4 -m3f -index=k.ix -temp=./k.ix - o.osr < "$I/in.bin"'
grep -qx old "$F/p/k.ix" || fail "-temp=./k.ix: cambio k.ix"
scase 0 'cp "$I/ok.osr" ok.osr; ln ok.osr ok; "$B" -i ok.osr' ok.osr
scase 0 '"$B" -v0 --seed=7 -temp=t.tmp - o.osr < "$I/in.bin"'
[ ! -e "$F/p/t.tmp" ] && [ -s "$F/p/o.osr" ] || fail "-temp=: el spool quedo, o no hay archivo"
scase 2 'echo keep > t.tmp; "$B" -v0 --seed=7 -s10 -temp=t.tmp - o.osr < "$I/in.bin"'
[ ! -e "$F/p/t.tmp" ] || fail "-temp=: el spool quedo tras una corrida que fallo"
scase 3 '"$B" -v0 --seed=7 -temp=nodir/t.tmp - o.osr < "$I/in.bin"'
scase 0 '"$B" -v0 -mem1mb -vmblock=128kb -vmfile=v.vm -d "$I/far.osr" o.out'
[ ! -e "$F/p/v.vm" ] && cmp -s "$F/p/o.out" "$F/in/far.bin" || fail "-vmfile=: quedo, o la vuelta difiere"
scase 0 'echo keep > ./-; "$B" -v0 --seed=7 -delete - o.osr < "$I/in.bin"'
[ -e "$F/p/-" ] || fail "-delete - borro un archivo llamado -"
scase 0 'echo keep > ./-; "$B" -v0 --seed=7 -delete < "$I/in.bin" > o.osr'
[ -e "$F/p/-" ] || fail "-delete por pipe borro un archivo llamado -"
scase 4 '"$B" -v0 --seed=7 -b0 "$I/in.bin" o.osr'
scase 3 '"$B" -v0 --seed=7 -b0 -dup "$I/in.bin" o.osr'
# una entrada que cambia mientras se lee: un writer que agrega, un byte
# reescrito en su lugar, un rename encima (el guardar de un editor, una
# rotacion de logs). Hasta r231-files exit 0, un archivo que no se
# descomprime (o con lo viejo) y -delete borraba la entrada; ahora la corrida
# compara el archivo al que lleva el nombre, su largo y sus horas antes y
# despues (StampInput), y falla con exit 3. Sin carreras: la corrida no
# termina antes de que el consumidor vacie la salida, y el consumidor cambia
# la entrada al recibir el primer byte (despues de la estampa, antes del
# chequeo). Bajo wine: tamano, indice y LastWriteTime
for m in 'printf x >> t' 'printf y | dd of=t bs=1 seek=100 conv=notrunc 2>/dev/null' 'cp t t.new; mv t.new t'; do
    for run in 'cp "$I/in.bin" t; "$B" -v0 --seed=7 -delete t -' 'cp "$I/ok.osr" t; "$B" -v0 -d -delete t -'; do
        scase 3 'set -o pipefail; '"$run"' | { dd bs=1 count=1 of=/dev/null 2>/dev/null; '"$m"'; cat >/dev/null; }'
        grep -qx '  ERROR! t changed while it was being read' "$F/p.e" && [ -e "$F/p/t" ] \
            || fail "[$run / $m]: $(cat "$F/p.e")"
    done
done
scase 0 'set -o pipefail; cp "$I/in.bin" t; "$B" -v0 --seed=7 -delete t - | { dd bs=1 count=1 of=/dev/null 2>/dev/null; cat >/dev/null; }'
[ ! -e "$F/p/t" ] || fail "-delete t - sin cambios: quedo t"
# -d de un nombre que no es un archivo: la salida derivada (a.osr para a, b
# para b.osr) se creaba antes de mirar la entrada, y un archivo que estaba
# con ese nombre se truncaba y despues se borraba como salida parcial (el C++
# la deja vacia). Ahora la entrada se prueba antes (ProbeArchive), con el
# mismo mensaje
scase 4 'cp "$I/ok.osr" a.osr; cp "$I/in.bin" a; "$B" -v0 -d a'
cmp -s "$F/p/a.osr" "$F/in/ok.osr" || fail "-d a: cambio a.osr"
scase 4 'cp "$I/ok.osr" b; cp "$I/in.bin" b.osr; "$B" -v0 -d b.osr'
cmp -s "$F/p/b" "$F/in/ok.osr" || fail "-d b.osr: cambio b"
scase 4 'cp "$I/ok.osr" c; printf OSR > c.osr; "$B" -v0 -d c.osr'
cmp -s "$F/p/c" "$F/in/ok.osr" || fail "-d c.osr: cambio c"
scase 4 'cp "$I/ok.osr" o.out; "$B" -v0 -d - o.out < "$I/in.bin"'
cmp -s "$F/p/o.out" "$F/in/ok.osr" || fail "-d - o.out: cambio o.out"
# un anillo que no entra en 64 bits: -b2^63 daba la vuelta a 0 los dos
# bloques de margen en el Rust (panic, exit 101), y un -d a un bloque de 2^64
# redondeaba a un anillo chico (el Rust abortaba, el Pascal decia "Out of
# memory" desde el diccionario en memoria). A unos bytes de 2^64 el que daba
# la vuelta era el Pascal: sumaba al anillo su cola de 64 bytes y quedaba un
# numero chico, y escribia un archivo de nada con exit 0 (con -delete, sin la
# entrada), o reventaba, o decia "Out of memory" donde el Rust dice
# OutOfMemory
for b in -b9223372036854775808b -b9223372036854775809b "-d18446744073709551615b -b3m" \
         "-m0 -d18446744073709551615b -b3m" -b9223372036854775776b -b9223372036854775790b \
         -b9223372036854775807b "-d9223372036854775806b -b4611686018427387903b"; do
    scase 4 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete '"$b"' in.bin o.osr' in.bin
done
if [ "$FWINE" = 0 ]; then
    scase 3 'ln -s o.out v; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=v -d "$I/far.osr" o.out'
    [ -L "$F/p/v" ] && [ ! -e "$F/p/o.out" ] || fail "-vmfile= por un symlink a la salida"
    scase 3 'cp "$I/in.bin" in.bin; ln -s in.bin y.bin; "$B" -v0 --seed=7 in.bin y.bin' in.bin
    scase 0 '"$B" -v0 --seed=7 /dev/null /dev/../dev/null'
    scase 3 '"$B" -v0 --seed=7 /dev/null /dev/null'
    scase 0 'ln -s target t.tmp; "$B" -v0 --seed=7 -temp=t.tmp - o.osr < "$I/in.bin"'
    [ -L "$F/p/t.tmp" ] && [ -s "$F/p/target" ] || fail "-temp= por un symlink: se borro algo"
    # la unica excepcion: -temp= o -index= un symlink a una salida que todavia
    # no existe. El open por el symlink crea el archivo de la salida, y un
    # nombre nunca se borra por un symlink, asi que la corrida rechazada lo deja
    scase 3 'ln -s o.osr lnk; "$B" -v0 --seed=7 -temp=lnk - o.osr < "$I/far.bin"'
    scase 3 'ln -s o.osr lnk; "$B" -v0 --seed=7 --format=v4 -m3f -index=lnk "$I/in.bin" o.osr'
    # el open falla: el nombre no es de esta corrida (antes se borraba)
    scase 4 'echo x > ro; chmod 444 ro; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=ro -d "$I/far.osr" o.out'
    [ -e "$F/p/ro" ] || fail "-vmfile= de solo lectura: se borro"
    # nombres de /dev y /proc que llevan a un archivo que la corrida lee: el de
    # stdin, el de stdout, o la entrada misma una vez abierta (en el fd 3,
    # antes que la salida). Con stdin cerrado los dos binarios tienen el fd 0
    # sobre "/" (src/stdfds.pas), y el /dev/null que el runtime del Rust abre
    # para el se cierra al empezar main: el fd 3 es la entrada en los dos.
    # Hasta la rama r231-stdfds quedaba abierto, la entrada iba al fd 4, el fd
    # 3 era un /dev/null, y `-d -delete y.osr /proc/self/fd/3 <&-` decodificaba
    # ahi y borraba y.osr en el Rust (exit 0)
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin /dev/stdin < in.bin' in.bin
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin /dev/stdout 1<> in.bin' in.bin
    scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -d -delete ok.osr /dev/stdin < ok.osr' ok.osr
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin /proc/self/fd/3' in.bin
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -temp=/dev/stdin - o.osr < in.bin' in.bin
    scase 3 'cp "$I/far.osr" far.osr; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=/proc/self/fd/0 -d - o.out < far.osr' far.osr
    scase 3 'cp "$I/ok.osr" ok.osr; "$B" -v0 -d -delete ok.osr /proc/self/fd/3 <&-' ok.osr
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin /proc/self/fd/3 <&-' in.bin
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 -delete in.bin /proc/self/fd/4 <&- 3>&- 4>&-' in.bin
    grep -qF "Can't open /proc/self/fd/4 for write" "$F/p.e" || fail "/proc/self/fd/4 <&-: $(cat "$F/p.e")"
    scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 --format=v4 -m3f -index=/proc/self/fd/3 -delete in.bin o.osr <&- 3>&-' in.bin
    # las tablas del match finder dimensionadas para los 25 GiB por defecto de
    # stdin, con 1 GiB de direcciones: el Rust abortaba (exit 134, con la
    # cabecera en disco) y el Pascal decia "Out of memory"
    scase 4 '(ulimit -v 1048576; exec "$B" -v0 --seed=7 -b3g - x.osr < "$I/in.bin")'
    # -temp= un dispositivo o un FIFO: el spool no se puede releer, y con
    # /dev/null salia un archivo de nada con exit 0 (el C++ escribe el bueno;
    # en Windows NUL ya fallaba)
    scase 3 '"$B" -v0 --seed=7 -temp=/dev/null - o.osr < "$I/in.bin"'
    grep -qF "Can't open tempfile" "$F/p.e" || fail "-temp=/dev/null: $(cat "$F/p.e")"
    # un fd 0, 1 o 2 O_PATH heredado: el runtime del Rust abre un /dev/null
    # por cada uno, y solo se cerraba el del fd 0 cerrado. Quedaba en el fd 3,
    # la entrada iba al 4, y `-delete t /proc/self/fd/3` escribia el archivo
    # en /dev/null y borraba t (exit 0); el Pascal lo rechaza
    for n in 0 1 2 012; do
        scase 3 'cp "$I/in.bin" in.bin; python3 -c "import os, sys
fd = os.open(\"/\", os.O_PATH)
for k in sys.argv[1]: os.dup2(fd, int(k))
os.close(fd); os.execv(sys.argv[2], sys.argv[2:])" '"$n"' "$B" -v0 --seed=7 -delete in.bin /proc/self/fd/3' in.bin
    done
    # el -d de un -dup v4: el Rust tenia abierto el cuerpo (en el fd 4) durante
    # el post-paso, y los fds siguientes no eran los del Pascal
    scase 4 'cp "$I/dup.osr" dup.osr; "$B" -v0 -d dup.osr /proc/self/fd/5' dup.osr
else
    # bajo wine el error del open es el de Windows: el codigo y que quede
    rm -rf "${F:?}/p"; mkdir "$F/p"; echo x > "$F/p/ro"; chmod 444 "$F/p/ro"
    rc=0; (cd "$F/p" && "$PAX" -v0 -mem1mb -vmblock=128kb -vmfile=ro -d "$F/in/far.osr" o.out) \
        </dev/null >/dev/null 2>"$F/p.e" || rc=$?
    [ "$rc" = 4 ] && [ -e "$F/p/ro" ] && [ ! -e "$F/p/o.out" ] \
        || fail "-vmfile= de solo lectura bajo wine: exit $rc, $(ls "$F/p")"
    pass=$((pass + 1))
    # Windows no distingue mayusculas: x.bin y X.BIN son un archivo, que el
    # Rust de Linux no ve, asi que se compara con lo que tiene que dar
    for line in 'cp "$I/in.bin" in.bin; "$PAX" -v0 --seed=7 in.bin IN.BIN' \
                'cp "$I/ok.osr" ok.osr; "$PAX" -v0 -d ok.osr OK.OSR' \
                'cp "$I/in.bin" in.bin; "$PAX" -v0 --seed=7 --format=v4 -m3f -index=IN.BIN in.bin o.osr' \
                'cp "$I/far.osr" far.osr; "$PAX" -v0 -mem1mb -vmblock=128kb -vmfile=FAR.OSR -d far.osr o.out'; do
        rm -rf "${F:?}/p"; mkdir "$F/p"
        rc=0; (cd "$F/p" && PAX="$PAX" I="$F/in" bash -c "$line") </dev/null >/dev/null 2>"$F/p.e" || rc=$?
        [ "$rc" = 3 ] && grep -qF 'Input and output files should have different names' "$F/p.e" \
            && [ "$(find "$F/p" -type f | wc -l)" = 1 ] \
            || fail "[$line] bajo wine: exit $rc, '$(cat "$F/p.e")', $(ls "$F/p")"
        for f in in.bin ok.osr far.osr; do
            [ ! -e "$F/p/$f" ] || cmp -s "$F/p/$f" "$F/in/$f" || fail "[$line] bajo wine: cambio $f"
        done
        pass=$((pass + 1))
    done
    # En el drive_c del prefijo, wine da el numero de serie del drive (C:) a
    # un handle abierto por un nombre, y 0 a los handles estandar y a lo que
    # se abre por Z:: un archivo, dos identidades. Comparando las dos,
    # `>> x`, `1<> x`, `< x` y un hard link fuera de drive_c pasaban, con exit
    # 0 y la entrada borrada o pisada. Ahora en Windows decide el indice, y un
    # serial 0 vale por cualquiera.
    WP=$(grep -o 'WINEPREFIX=[^ ]*' "$PA" | head -1 | cut -d= -f2)
    if [ -n "$WP" ] && [ -d "$WP/drive_c" ]; then
        WD="$WP/drive_c/osrep_cli_$$"; WN="osrep_cli_$$"
        for line in 'cp "$I/in.bin" x; "$PAX" -v0 --seed=7 -delete x - >> x' \
                    'cp "$I/ok.osr" x; "$PAX" -v0 -d -delete x - 1<> x' \
                    'cp "$I/in.bin" x; "$PAX" -v0 --seed=7 - x < x' \
                    'cp "$I/in.bin" x; "$PAX" --seed=7 -delete x - > o 2>&1' \
                    'cp "$I/in.bin" x; ln x "$H/hl" && cd "$H" && "$PAX" -v0 --seed=7 -delete "C:\\$WN\\x" hl'; do
            rm -rf "${WD:?}" "${F:?}/p"; mkdir "$WD" "$F/p"
            rc=0; (cd "$WD" && PAX="$PAX" I="$F/in" H="$F/p" WN="$WN" bash -c "$line") </dev/null >/dev/null 2>"$F/p.e" || rc=$?
            [ "$rc" = 3 ] && [ -e "$WD/x" ] || fail "[$line] en drive_c: exit $rc, '$(cat "$F/p.e")', $(ls "$WD")"
            for f in in.bin ok.osr; do
                case "$line" in *'"$I/'$f'" x'*) cmp -s "$WD/x" "$F/in/$f" || fail "[$line] en drive_c: cambio x";; esac
            done
            pass=$((pass + 1))
        done
        rm -rf "${WD:?}"
    fi
    # El .exe de 32 bits: un -b que no entra en 4 GiB se satura en vez de dar
    # la vuelta. -b4g y sus multiplos quedaban en 0 ("Division by zero"; el
    # Rust i686, panic) y -b4097m en 1 MiB, otro archivo. Ahora OutOfMemory,
    # como -b5g. El Rust de referencia es x86_64, asi que se compara contra
    # lo que tiene que dar.
    if ! grep -q 'x86_64' "$PA"; then
        for b in 4g 8g 4097m 100000g 5g; do
            rm -rf "${F:?}/p"; mkdir "$F/p"
            rc=0; (cd "$F/p" && "$PAX" -v0 --seed=7 -b$b "$F/in/in.bin" x.osr) </dev/null >/dev/null 2>"$F/p.e" || rc=$?
            [ "$rc" = 4 ] && [ "$(cat "$F/p.e")" = "$(printf '\n  ERROR! OutOfMemory')" ] && [ ! -e "$F/p/x.osr" ] \
                || fail "-b$b en el .exe de 32 bits: exit $rc, '$(cat "$F/p.e")', $(ls "$F/p")"
        done
        pass=$((pass + 1))
    fi
fi

say "-bar: el contrato PROGRESS"
"$PA" -bar --seed=7 "$IN" "$TMP/bar.osr" 2>&1 >/dev/null | grep -a '^PROGRESS' > "$TMP/bar" || true
last=$(tail -1 "$TMP/bar")
[ "$last" = "PROGRESS $(stat -c%s "$IN") $(stat -c%s "$IN")" ] || fail "-bar: la ultima linea es '$last'"
pass=$((pass + 1))

# TStream.Read toma la cuenta como LongInt: con un bloque de 2 GiB o mas la
# cuenta truncada salia negativa, Read devolvia 0 y el Pascal escribia un
# archivo SIN bloques con exit 0. Solo en el nativo: en i386 un anillo de
# 2x2 GiB no entra, y el Rust de referencia es x86_64.
case "$PA" in *linux*)
    say "-b de 2 GiB o mas: el mismo archivo, y vuelve"
    for b in 2g 3g 4g; do
        "$RS" --seed=7 -b$b "$IN" "$TMP/rb.osr" >/dev/null 2>&1 || fail "-b$b: el Rust fallo"
        "$PA" --seed=7 -b$b "$IN" "$TMP/pb.osr" >/dev/null 2>&1 || fail "-b$b: el Pascal fallo"
        cmp -s "$TMP/rb.osr" "$TMP/pb.osr" || fail "-b$b: archivos distintos"
        "$PA" -d "$TMP/pb.osr" "$TMP/pb.out" >/dev/null 2>&1 || fail "-b$b: -d fallo"
        cmp -s "$IN" "$TMP/pb.out" || fail "-b$b: la vuelta no da la entrada"
        rm -f "$TMP/pb.out"
    done
    pass=$((pass + 1))
    ;;
esac

# Nombres fuera de ASCII. En Linux son bytes y pasan tal cual; en Windows el
# Pascal leia la linea con ParamStr (ANSI) y abria con la pagina ANSI, asi
# que "ñandú_файл_文件.bin" llegaba como "?and?_????_??.bin" y no se abria
# (docs/pascal-port.md, trampas). Con OSREP_PASCAL_BIN apuntando a un wrapper
# de wine esto prueba el .exe: los nombres cruzan unix -> UTF-16 -> el .exe
# -> UTF-16 -> unix, y tienen que volver los mismos bytes.
# Windows no admite comillas dobles en un nombre de archivo, asi que con
# wine el nombre con comillas lleva solo la simple.
WINE=0
if [ "$(head -c 2 "$PA")" = '#!' ] && grep -q wine "$PA"; then WINE=1; fi
say "nombres no ASCII: archivos, directorios, -index=, -temp=, -dup, pipes y errores"
U="$TMP/uni"
UD='dír каталог 目录 😀'
NAMES=('ñandú é.bin' 'файл.bin' '文件.bin' '😀 emoji.bin')
if [ "$WINE" = 1 ]; then NAMES+=("it's a b.bin"); else NAMES+=("it's \"q\" a b.bin"); fi
head -c 300000 tests/corpus/mixed.bin > "$TMP/uni.in"
for side in r p; do mkdir -p "$U/$side/$UD" "$U/$side/tmp ñ文"; done
# $1=r|p, el resto los argumentos; corre en el directorio no ASCII, con la
# salida en <side>.o/.e/.rc
urun() {
    local side=$1 bin; shift
    if [ "$side" = r ]; then bin="$RSX"; else bin="$PAX"; fi
    local rc=0
    (cd "$U/$side/$UD" && "$bin" "$@") <"${UIN:-/dev/null}" >"$U/$side.o" 2>"$U/$side.e" || rc=$?
    echo "$rc" > "$U/$side.rc"
}
# los dos lados con los mismos argumentos; mismo codigo, y si fallo, el
# mismo stderr byte a byte (con exito trae tiempos)
uboth() {
    urun r "$@"; urun p "$@"
    local rrc prc; rrc=$(cat "$U/r.rc"); prc=$(cat "$U/p.rc")
    [ "$rrc" = "$prc" ] || fail "no ASCII [$*]: exit $prc en Pascal, $rrc en Rust: $(cat "$U/p.e")"
    if [ "$rrc" != 0 ]; then
        cmp -s "$U/r.e" "$U/p.e" || fail "no ASCII [$*]: stderr difiere: '$(cat "$U/p.e")' vs '$(cat "$U/r.e")'"
    fi
    cmp -s "$U/r.o" "$U/p.o" || fail "no ASCII [$*]: stdout difiere"
}
usame() {  # el mismo archivo en los dos lados
    [ -e "$U/r/$UD/$1" ] || fail "no ASCII: el Rust no escribio '$1'"
    [ -e "$U/p/$UD/$1" ] || fail "no ASCII: el Pascal no escribio '$1'"
    cmp -s "$U/r/$UD/$1" "$U/p/$UD/$1" || fail "no ASCII: '$1' difiere"
}
for n in "${NAMES[@]}"; do
    for side in r p; do cp "$TMP/uni.in" "$U/$side/$UD/$n"; done
    # un nombre solo: el archivo sale al lado, con .osr; y vuelve
    uboth --seed=7 "$n"; usame "$n.osr"
    uboth --verify "$n.osr"
    cmp -s "$U/r.e" "$U/p.e" || fail "no ASCII: --verify '$n.osr' no dice lo mismo: '$(cat "$U/p.e")'"
    uboth -i "$n.osr"
    cmp -s "$U/r.e" "$U/p.e" || fail "no ASCII: -i '$n.osr' no dice lo mismo"
    for side in r p; do mv "$U/$side/$UD/$n" "$U/$side/$UD/$n.orig"; done
    uboth -d "$n.osr"; usame "$n"
    cmp -s "$TMP/uni.in" "$U/p/$UD/$n" || fail "no ASCII: -d '$n.osr' no da la entrada"
    # -dup, con los temporales del cuerpo
    uboth --seed=7 -dup "$n" "dup $n.osr"; usame "dup $n.osr"
    uboth -d "dup $n.osr" "dup $n.out"; usame "dup $n.out"
    cmp -s "$TMP/uni.in" "$U/p/$UD/dup $n.out" || fail "no ASCII: -dup '$n' no vuelve"
    # -index= en los dos sentidos
    uboth --seed=7 --format=v4 -m3f "-index=índice $n.ix" "$n" "v4 $n.osr"
    usame "v4 $n.osr"; usame "índice $n.ix"
    uboth -d "-index=índice $n.ix" "v4 $n.osr" "v4 $n.out"; usame "v4 $n.out"
    cmp -s "$TMP/uni.in" "$U/p/$UD/v4 $n.out" || fail "no ASCII: -index= '$n' no vuelve"
    # -temp=: el spool de stdin con nombre no ASCII, en un directorio no ASCII
    UIN="$TMP/uni.in" uboth --seed=7 "-temp=../tmp ñ文/spool $n" - "st $n.osr"; usame "st $n.osr"
    # y se borra al terminar, como en el C++ (srep.cpp:1336)
    [ ! -e "$U/r/tmp ñ文/spool $n" ] && [ ! -e "$U/p/tmp ñ文/spool $n" ] \
        || fail "no ASCII: el spool de -temp= quedo"
    # stdin a stdout: los bytes del archivo no pasan por ninguna conversion
    UIN="$U/p/$UD/$n" uboth --seed=7 - -
    UIN="$U/p/$UD/$n.osr" uboth -d - -
    cmp -s "$TMP/uni.in" "$U/p.o" || fail "no ASCII: -d - - no da la entrada"
    # los errores que nombran el archivo: el texto byte a byte
    uboth --seed=7 "falta $n"
    uboth -d "falta $n.osr"
    uboth -i "falta $n"
    uboth --verify "falta $n"
    uboth --seed=7 "$n" "no hay dir ñ/$n.osr"
    uboth --seed=7 --format=v4 -m3f "-index=no hay dir ñ/$n.ix" "$n" "x.osr"
    uboth "$n" "ñ $n" "文 $n"
    uboth "-ñ$n"
    pass=$((pass + 1))
done
# los mismos nombres de los dos lados, ni uno de mas
( cd "$U/r/$UD" && ls -A ) > "$U/r.ls"; ( cd "$U/p/$UD" && ls -A ) > "$U/p.ls"
cmp -s "$U/r.ls" "$U/p.ls" || fail "no ASCII: los directorios no tienen los mismos nombres: $(diff "$U/r.ls" "$U/p.ls" | head -5)"
pass=$((pass + 1))
# $TMPDIR no ASCII: solo nativo (bajo wine el temporal sale del registro, no
# de $TMPDIR; el .exe se prueba con TMP/TEMP desde adentro de Windows)
if [ "$WINE" = 0 ]; then
    for t in "$U/r/tmp ñ文" "$U/no existe ñ"; do
        TMPDIR="$t" UIN="$U/p/$UD/${NAMES[0]}.osr" uboth -d - -
        TMPDIR="$t" UIN="$TMP/uni.in" uboth --seed=7 - "tmpdir.osr"
    done
    pass=$((pass + 1))
fi

say "fd 0, 1 y 2 cerrados o llenos: lo mismo que el Rust, y ningun texto adentro de un archivo"
# Con un fd 0-2 cerrado, el primer open del programa toma ese numero. Hasta la
# 2.3.0, `osrep x x.osr <&- 2>&-` dejaba el archivo de salida en el fd 2 y el
# progreso y el resumen se escribian ADENTRO del archivo (exit 0; con -delete
# se perdia la entrada), y `-d` los metia en los datos. src/stdfds.pas reserva
# los tres al arrancar, como el runtime del Rust, salvo que el fd 1 queda
# solo lectura: los datos mandados a un stdout cerrado son un error, no un
# descarte (con /dev/null, el Rust de la 2.3.0 hacia `-delete x - >&-` con
# exit 0 y borraba x). Y un stderr o stdout que falla (/dev/full) no cambia
# nada: el Rust hacia panic (exit 101) con el archivo a medias.
# Bajo wine, de los fds de unix solo 1 y 2: un fd 0 cerrado es un handle que
# falla al leer (ERROR_INVALID_FUNCTION, "Can't read"), donde Linux y un
# Windows sin handle leen vacio, y con los tres cerrados se rompe el propio
# wine. Lo que en Windows es un handle que falta (nulo, como un proceso sin
# consola, o INVALID_HANDLE_VALUE) se prueba con tests/win_null_std_handles.c,
# si hay mingw: el .exe con handles nulos o invalidos tiene que dar lo mismo
# que el Rust de Linux con esos fds cerrados ("L:nkn" contra "02", "L:kik"
# contra "1").
FD="$TMP/fd"
mkdir -p "$FD/fix"
{ head -c 150000 tests/corpus/text.bin; head -c 50000 tests/corpus/random.bin; head -c 90000 tests/corpus/text.bin; } > "$FD/fix/in.txt"
fdsize=$(stat -c%s "$FD/fix/in.txt")
"$RS" --seed=7 -b64kb "$FD/fix/in.txt" "$FD/fix/a.osr" >/dev/null 2>&1 || fail "fd: el Rust no comprime"
head -c 2000 "$FD/fix/a.osr" > "$FD/fix/bad.osr"
# El borde del primer write del LineWriter del Rust: con un archivo de 1024
# bytes justos y sin '\n' todavia no escribio nada (exit 3, "Can't write to
# stdout"); con 1025, ya dentro del encode ("Io", exit 4). El Pascal usaba
# >= 1024. Entradas sin '\n' cuyo archivo mide 1024 y 1025, en v5 y v4, con
# la primera semilla que no mete un '\n' en ninguno de los dos.
tr -d '\n' < tests/corpus/random.bin | head -c 1000 > "$FD/nonl.bin"
fdedge() {   # $1=largo de la entrada para 1024 $2=flags; deja la semilla en FDSEED
    local n=$1 f=$2 s k ok
    head -c "$n" "$FD/nonl.bin" > "$FD/fix/e$n.bin"; head -c $((n + 1)) "$FD/nonl.bin" > "$FD/fix/e$((n + 1)).bin"
    FDSEED=
    for s in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        ok=1
        for k in 0 1; do
            # shellcheck disable=SC2086
            "$RS" --seed=$s $f "$FD/fix/e$((n + k)).bin" "$FD/e.osr" >/dev/null 2>&1 || fail "fd: el Rust no comprime e$((n + k)).bin"
            [ "$(stat -c%s "$FD/e.osr")" -eq $((1024 + k)) ] || fail "fd: e$((n + k)).bin no da un archivo de $((1024 + k)) bytes [$f]"
            [ "$(tr -cd '\n' < "$FD/e.osr" | wc -c)" -eq 0 ] || ok=0
        done
        [ "$ok" = 1 ] && { FDSEED=$s; return; }
    done
    fail "fd: ninguna semilla da archivos sin '\n' [$f]"
}
fdedge 904 ""; FDS5=$FDSEED
fdedge 920 --format=v4; FDS4=$FDSEED
rm -f "$FD/e.osr"
# Solo en Linux: la salida o la entrada nombrada /dev/stdin o
# /proc/self/fd/0 (bajo wine no abren, y el Rust de Linux si)
FDLINUX=
if [ "$WINE" = 0 ]; then
    FDCOMBOS="n 0 1 2 01 02 12 012 f1 f2 w0"
    FDLINUX="/dev/null|--seed=7 in.txt /dev/stdin
/dev/null|-d a.osr /proc/self/fd/0
/dev/null|--seed=7 /dev/stdin o.osr
/dev/null|-d /dev/stdin o.dec"
else
    FDCOMBOS="n 1 2 12 f1 f2"
    FDEXE=$(grep -o '[^ "]*\.exe' "$PA" | head -1)
    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 && [ -f "$FDEXE" ] \
       && x86_64-w64-mingw32-gcc -municode -O1 -o "$TMP/nullstd.exe" tests/win_null_std_handles.c 2>/dev/null; then
        FDEXE=$(WINEDEBUG=-all winepath -w "$FDEXE" 2>/dev/null)
        FDCOMBOS="$FDCOMBOS L:nkk L:knk L:kkn L:nnk L:nkn L:knn L:nnn L:ikk L:kik L:kki"
    else
        say "sin mingw o sin el .exe del wrapper: los handles nulos no se prueban"
    fi
fi
# $1=binario $2=directorio $3=combinacion $4=stdin, el resto los argumentos.
# Deja <dir>/rc, <dir>/out y <dir>/err (los que siguen abiertos) y los
# archivos de salida en <dir>/w.
fdrun() {
    local bin=$1 dir=$2 cl=$3 src=$4; shift 4
    mkdir -p "$dir/w"; cp "$FD/fix/"* "$dir/w/"
    local r0="<$src" r1='>"$dir/out"' r2='2>"$dir/err"'
    case $cl in *0*) r0='<&-';; esac
    case $cl in *1*) r1='>&-';; esac
    case $cl in *2*) r2='2>&-';; esac
    case $cl in f1) r1='>/dev/full';; f2) r2='2>/dev/full';; w0) r0='0>"$dir/w0"';; esac
    local rc=0
    (cd "$dir/w" && eval "timeout 60 \"\$bin\" \"\$@\" $r0 $r1 $r2") || rc=$?
    echo "$rc" > "$dir/rc"
    rm -f "$dir/w/in.txt" "$dir/w/a.osr" "$dir/w/bad.osr"
}
# lo mismo, por el lanzador: $1=directorio $2=mascara $3=stdin, el resto
# los argumentos
fdlaunch() {
    local dir=$1 mask=$2 src=$3; shift 3
    mkdir -p "$dir/w"; cp "$FD/fix/"* "$dir/w/"
    local rc=0
    (cd "$dir/w" && WINEDEBUG=-all timeout 60 wine "$TMP/nullstd.exe" "$mask" "$FDEXE" "$@" \
        <"$src" >"$dir/out" 2>"$dir/err") || rc=$?
    echo "$rc" > "$dir/rc"
    rm -f "$dir/w/in.txt" "$dir/w/a.osr" "$dir/w/bad.osr"
}
# la mascara del lanzador como los fds cerrados equivalentes: un handle
# nulo (n) o INVALID_HANDLE_VALUE (i) es un fd cerrado
fdmask() {
    local m=$1 c=""
    [ "${m:0:1}" != k ] && c="${c}0"; [ "${m:1:1}" != k ] && c="${c}1"; [ "${m:2:1}" != k ] && c="${c}2"
    echo "$c"
}
fdnorm() { [ -e "$1" ] && sed -E 's/[0-9]+(\.[0-9]+)? sec/T sec/g; s/[0-9]+ mb\/s/M mb\/s/g' "$1"; }
fdn=0
while IFS='|' read -r src args; do
    [ -n "$args" ] || continue
    for cl in $FDCOMBOS; do
        rm -rf "$FD/r" "$FD/p"
        case $cl in
        L:*)
            rcl=$(fdmask "${cl#L:}")
            # shellcheck disable=SC2086
            fdrun "$RSX" "$FD/r" "$rcl" "$src" $args
            # shellcheck disable=SC2086
            fdlaunch "$FD/p" "${cl#L:}" "$src" $args
            ;;
        *)
            rcl=$cl
            # shellcheck disable=SC2086
            fdrun "$RSX" "$FD/r" "$cl" "$src" $args
            # shellcheck disable=SC2086
            fdrun "$PAX" "$FD/p" "$cl" "$src" $args
            ;;
        esac
        what="[$args] ($cl)"
        [ "$(cat "$FD/r/rc")" = "$(cat "$FD/p/rc")" ] \
            || fail "fd $what: exit $(cat "$FD/p/rc") en Pascal, $(cat "$FD/r/rc") en Rust"
        cmp -s <(fdnorm "$FD/r/out") <(fdnorm "$FD/p/out") || fail "fd $what: stdout difiere"
        cmp -s <(fdnorm "$FD/r/err") <(fdnorm "$FD/p/err") \
            || fail "fd $what: stderr difiere: '$(cat "$FD/p/err")' vs '$(cat "$FD/r/err")'"
        ( cd "$FD/r/w" && ls -A ) > "$FD/r.ls"; ( cd "$FD/p/w" && ls -A ) > "$FD/p.ls"
        cmp -s "$FD/r.ls" "$FD/p.ls" || fail "fd $what: otros archivos: $(tr '\n' ' ' <"$FD/p.ls") vs $(tr '\n' ' ' <"$FD/r.ls")"
        while IFS= read -r f; do
            cmp -s "$FD/r/w/$f" "$FD/p/w/$f" || fail "fd $what: '$f' difiere"
        done < "$FD/p.ls"
        # sin comparar con nadie: lo que se escribio a un archivo es lo mismo
        # que sin cerrar nada, salvo cuando la entrada era el stdin cerrado
        if [ "$cl" = n ]; then
            rm -rf "$FD/n"; cp -r "$FD/p/w" "$FD/n"
        elif ! { [ "$src" != /dev/null ] && case $rcl in *0*) true;; *) false;; esac; }; then
            while IFS= read -r f; do
                [ "$f" = w0 ] && continue
                cmp -s "$FD/n/$f" "$FD/p/w/$f" || fail "fd $what: '$f' no es el de la corrida sin fds cerrados"
            done < "$FD/p.ls"
        fi
        fdn=$((fdn + 1))
    done
done <<ARGS
/dev/null|--version
/dev/null|--help
$FD/fix/in.txt|--seed=7 -s$fdsize
$FD/fix/a.osr|-d
/dev/null|--seed=7 -b64kb in.txt o.osr
/dev/null|--seed=7 -bar in.txt o.osr
/dev/null|--seed=7 -dup in.txt o.osr
/dev/null|--seed=7 --format=v4 -m3f in.txt o.osr
$FD/fix/in.txt|--seed=7 -s$fdsize - o.osr
$FD/fix/in.txt|--seed=7 -temp=t.tmp -s$fdsize - -
/dev/null|--seed=7 in.txt -
/dev/null|--seed=7 -m0 in.txt -
/dev/null|--seed=7 --format=v4 in.txt -
/dev/null|--seed=7 -bar --format=v4 in.txt -
/dev/null|--seed=$FDS5 e904.bin -
/dev/null|--seed=$FDS5 e905.bin -
/dev/null|--seed=$FDS4 --format=v4 e920.bin -
/dev/null|--seed=$FDS4 --format=v4 -bar e921.bin -
$FDLINUX
/dev/null|-d a.osr o.dec
$FD/fix/a.osr|-d - o.dec
/dev/null|-d a.osr -
/dev/null|-i a.osr
$FD/fix/a.osr|-i -
/dev/null|--verify a.osr
$FD/fix/a.osr|--verify -
/dev/null|nonexistent o.osr
/dev/null|-d bad.osr o.dec
/dev/null|-bogus
ARGS
say "$fdn corridas con fds cerrados, las mismas que el Rust"
pass=$((pass + 1))
# -delete con stdout cerrado o lleno: la salida falla y la entrada se queda.
# En Linux tambien con la salida /dev/stdout o /proc/self/fd/1, que reabren
# lo que hay detras del fd 1: reservado sobre un directorio, el open falla.
# Y lo mismo con el fd 0 cerrado y la salida /dev/stdin, /proc/self/fd/0 o
# /dev/fd/0: sobre /dev/null, `-delete x /dev/stdin <&-` borraba x; y con el
# fd 2 cerrado y la salida /dev/stderr o /proc/self/fd/2.
if [ "$WINE" = 0 ]; then
    FDOUTS="- /dev/stdout /proc/self/fd/1 /dev/stdin /proc/self/fd/0 /dev/fd/0 /dev/stderr /proc/self/fd/2"
else
    FDOUTS="-"
fi
for spec in "in.txt|--seed=7 -delete in.txt" "a.osr|-delete -d a.osr"; do
    keep=${spec%%|*}; args=${spec#*|}
    for o in $FDOUTS; do
        case $o in
        */0|/dev/stdin) FDRS="'<&- 2>/dev/null' '<&- >/dev/null 2>&-' '<&- >&- 2>&-'";;
        */2|/dev/stderr) FDRS="'2>&-' '<&- 2>&-' '>/dev/null 2>&-'";;
        *) FDRS="'>&- 2>/dev/null' '>&- 2>&-' '<&- >&- 2>&-' '>/dev/full 2>/dev/null'";;
        esac
        eval "set -- $FDRS"
        for r; do
            [ "$WINE" = 1 ] && [ "$r" = '<&- >&- 2>&-' ] && continue
            rm -rf "$FD/q"; mkdir -p "$FD/q"; cp "$FD/fix/"* "$FD/q/"
            rc=0; (cd "$FD/q" && eval "\"\$PAX\" $args $o $r") || rc=$?
            [ "$rc" != 0 ] || fail "fd [$args $o $r]: exit 0 sin poder escribir"
            [ -e "$FD/q/$keep" ] || fail "fd [$args $o $r]: -delete borro $keep sin haber escrito nada"
        done
    done
done
pass=$((pass + 1))

if [ "${OSREP_PASCAL_FULL:-0}" = "1" ]; then
    say "la puerta completa: rust_cli_conformance.sh sobre el Pascal"
    OSREP_PORT_BIN="$PA" bash tests/rust_cli_conformance.sh || fail "rust_cli_conformance.sh sobre el Pascal"
    pass=$((pass + 1))
fi

echo "  pascal_cli_conformance: passed=$pass mismatches=0"
