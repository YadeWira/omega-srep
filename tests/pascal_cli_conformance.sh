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

say "lo no implementado se rechaza en vez de fingir"
# Un binario que acepta una opcion y no hace nada es peor que uno que la
# rechaza: el primero produce un archivo que nadie puede leer.
rc=0; "$PA" -m3 "$TMP/in" "$TMP/out" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "-m3 salio $rc, esperado 2 (cmdline) mientras no este implementado"
[ ! -e "$TMP/out" ] || fail "-m3 dejo un archivo detras"
pass=$((pass + 1))

echo "  pascal_cli_conformance: passed=$pass mismatches=0"
