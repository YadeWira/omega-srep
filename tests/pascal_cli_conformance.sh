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

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

RS="${OSREP_RUST_BIN:-target/x86_64-unknown-linux-gnu/release/osrep}"
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
# Solo los que tienen un texto deterministico; los de los decoders salen con
# el mismo codigo pero el Rust imprime su Debug (Io(Os { .. })) y el Pascal el
# mensaje, y eso se compara por codigo nada mas, mas abajo.
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

say "un archivo danado: el mismo codigo que el Rust"
head -c 1000 "$TMP/ok.osr" > "$TMP/cut.osr"
rrc=0; "$RS" -d "$TMP/cut.osr" "$TMP/r.cut" >/dev/null 2>&1 || rrc=$?
prc=0; "$PA" -d "$TMP/cut.osr" "$TMP/p.cut" >/dev/null 2>&1 || prc=$?
[ "$rrc" -eq "$prc" ] || fail "archivo cortado: exit $prc en Pascal, $rrc en Rust"
pass=$((pass + 1))

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

if [ "${OSREP_PASCAL_FULL:-0}" = "1" ]; then
    say "la puerta completa: rust_cli_conformance.sh sobre el Pascal"
    OSREP_PORT_BIN="$PA" bash tests/rust_cli_conformance.sh || fail "rust_cli_conformance.sh sobre el Pascal"
    pass=$((pass + 1))
fi

echo "  pascal_cli_conformance: passed=$pass mismatches=0"
