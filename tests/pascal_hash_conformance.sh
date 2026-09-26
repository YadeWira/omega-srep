#!/usr/bin/env bash
# Los digests del port a Pascal contra `bin/hash_test` (docs/pascal-port.md,
# fase 2).
#
# El oraculo no son vectores publicados sino el MISMO codigo que el encoder
# guarda en cada bloque: las copias vendorizadas de LibTomCrypt/VHash llevan
# parches locales, asi que un vector de la RFC puede pasar y el archivo salir
# distinto igual.
#
# La matriz de tamanos es el punto. Ya atrapo un bug real: el relleno de md5
# estaba bien en ocho de nueve tamanos y mal en 56 bytes exactos, que es el
# borde donde el largo ya no entra en el bloque. Sin 55/56/63/64/65 en la
# lista, ese md5 se daba por bueno. sha512 usa bloques de 128, asi que sus
# bordes son otros y tambien estan.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

PA="${OSREP_PASCAL_HASHTOOL:-pascal/bin/hashtool}"
if [ ! -x "$PA" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/hashtool pascal/hashtool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/hashtool.lpr"
fi
[ -x bin/hash_test ] || make bin/hash_test >/dev/null 2>&1
[ -x bin/hash_test ] || fail "sin oraculo en bin/hash_test"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

# Bordes de bloque de los dos tamanos (64 para md5/sha1, 128 para sha512),
# mas tamanos sueltos y algo grande.
SIZES="0 1 2 3 55 56 57 63 64 65 111 112 113 119 120 127 128 129 255 256 1000 65536 100000"
for n in $SIZES; do
    head -c "$n" /dev/urandom > "$TMP/in-$n" 2>/dev/null || : > "$TMP/in-$n"
done

for algo in md5 sha1 sha512; do
    n_ok=0
    for n in $SIZES; do
        c=$(./bin/hash_test "$algo" none "$TMP/in-$n") \
            || fail "$algo: el oraculo fallo con $n bytes"
        p=$("$PA" "$algo" none "$TMP/in-$n") \
            || fail "$algo: el Pascal fallo con $n bytes"
        [ "$c" = "$p" ] || fail "$algo con $n bytes: oraculo $c, Pascal $p"
        n_ok=$((n_ok + 1))
    done
    say "$algo: $n_ok tamanos, todos identicos al oraculo"
    pass=$((pass + n_ok))
done

say "lo no portado se rechaza en vez de inventar un digest"
for algo in siphash vmac; do
    rc=0; "$PA" "$algo" 00 "$TMP/in-1" >"$TMP/o" 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "$algo devolvio exito y todavia no esta portado"
    [ ! -s "$TMP/o" ] || fail "$algo imprimio algo en stdout sin estar portado"
    pass=$((pass + 1))
done

echo "  pascal_hash_conformance: passed=$pass mismatches=0"
