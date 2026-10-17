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
    same -v0 -i "$f"
}
# --verify y -i no decodifican: sobre un v1-v4 solo parsean el contenedor, y
# eso lo cubren de sobra los truncados. Un byte cambiado se mira con -d.
checkd() { # $1=archivo, el resto opciones de -d
    local f="$1"; shift
    case "$name" in v5*) check3 "$f" "$@" ;; *) same -v0 -d "$@" "$f" o.out ;; esac
}
# $1=origen $2=posicion $3=destino: el byte en $2 pasa a 0 (o a 0xFF si ya era 0)
zap() {
    local b v
    cp "$1" "$3"
    b=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
    if [ "${b:-0}" -eq 0 ]; then v=255; else v=0; fi
    printf "$(printf '\\%03o' "$v")" | dd of="$3" bs=1 seek="$2" conv=notrunc 2>/dev/null
}
for name in v5 v5dup v4 v4dup v3 v3ix v2ix v1; do
    a="$D/$name.osr"; n=$(stat -c%s "$a")
    ix=""; [ -e "$D/$name.ix" ] && ix="-index=$name.ix"
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
        done
        for p in 0 3 8 12 $((m / 2)); do
            zap "$D/$name.ix" "$p" "$D/m.ix"; same -v0 -d -index=m.ix "$name.osr" o.out
        done
    fi
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

say "un archivo con dos nombres se rechaza; los temporales con nombre, solo si se abrieron"
# El C++ rechaza una salida con el nombre de la entrada comparando los textos
# ("Input and output files should have different names", exit 3), asi que
# `osrep x.bin ./x.bin` truncaba la entrada y salia con 0 y un archivo de
# nada, y `-d a.osr ./a.osr` perdia el archivo. Los ports comparan ademas la
# identidad (dispositivo e inodo; volumen e indice en Windows) en cada par que
# la corrida lee y escribe: entrada y salida, -index= y la entrada (al
# comprimir) o la salida (al descomprimir), el spool de -temp= y el archivo,
# -vmfile= y lo que el decoder lee o escribe. Solo archivos regulares. Con
# wine tambien: los hard links llegan con el mismo indice. Ademas: -temp= se
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
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 in.bin ./in.bin' in.bin
scase 3 'cp "$I/in.bin" in.bin; ln in.bin y.bin; "$B" -v0 --seed=7 in.bin y.bin' in.bin
scase 3 'cp "$I/ok.osr" ok.osr; ln ok.osr ok; "$B" -v0 -d ok.osr' ok.osr
scase 3 'cp "$I/in.bin" in.bin; "$B" -v0 --seed=7 --format=v4 -m3f -index=./in.bin in.bin o.osr' in.bin
scase 3 '"$B" -v0 --seed=7 --format=v4 -m3f -index=o.osr "$I/in.bin" ./o.osr'
scase 3 '"$B" -v0 --seed=7 -temp=t.tmp - ./t.tmp < "$I/in.bin"'
scase 3 'cp "$I/far.osr" far.osr; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=./far.osr -d far.osr o.out' far.osr
scase 3 'cp "$I/ok.ix" ok.ix; "$B" -v0 -vmfile=./ok.ix -d -index=ok.ix "$I/okf.osr" o.out' ok.ix
scase 3 '"$B" -v0 -vmfile=o.out -d "$I/far.osr" o.out'
scase 3 'echo x > o.out; "$B" -v0 -vmfile=./o.out -d "$I/far.osr" o.out'
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
if [ "$FWINE" = 0 ]; then
    scase 3 'cp "$I/in.bin" in.bin; ln -s in.bin y.bin; "$B" -v0 --seed=7 in.bin y.bin' in.bin
    scase 0 '"$B" -v0 --seed=7 /dev/null /dev/../dev/null'
    scase 0 'ln -s target t.tmp; "$B" -v0 --seed=7 -temp=t.tmp - o.osr < "$I/in.bin"'
    [ -L "$F/p/t.tmp" ] && [ -s "$F/p/target" ] || fail "-temp= por un symlink: se borro algo"
    # el open falla: el nombre no es de esta corrida (antes se borraba)
    scase 4 'echo x > ro; chmod 444 ro; "$B" -v0 -mem1mb -vmblock=128kb -vmfile=ro -d "$I/far.osr" o.out'
    [ -e "$F/p/ro" ] || fail "-vmfile= de solo lectura: se borro"
else
    # bajo wine el error del open es el de Windows: el codigo y que quede
    rm -rf "${F:?}/p"; mkdir "$F/p"; echo x > "$F/p/ro"; chmod 444 "$F/p/ro"
    rc=0; (cd "$F/p" && "$PAX" -v0 -mem1mb -vmblock=128kb -vmfile=ro -d "$F/in/far.osr" o.out) \
        </dev/null >/dev/null 2>"$F/p.e" || rc=$?
    [ "$rc" = 4 ] && [ -e "$F/p/ro" ] && [ ! -e "$F/p/o.out" ] \
        || fail "-vmfile= de solo lectura bajo wine: exit $rc, $(ls "$F/p")"
    pass=$((pass + 1))
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

if [ "${OSREP_PASCAL_FULL:-0}" = "1" ]; then
    say "la puerta completa: rust_cli_conformance.sh sobre el Pascal"
    OSREP_PORT_BIN="$PA" bash tests/rust_cli_conformance.sh || fail "rust_cli_conformance.sh sobre el Pascal"
    pass=$((pass + 1))
fi

echo "  pascal_cli_conformance: passed=$pass mismatches=0"
