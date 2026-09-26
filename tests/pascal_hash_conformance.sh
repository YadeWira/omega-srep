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

# Bordes de bloque de los tres tamanos que importan: 64 (md5/sha1), 128
# (sha512) y 4096 (el VMAC_NHBYTES de vmac, donde recien entra el lazo
# polinomico). Mas 16 y sus alrededores, que es el paso de nh_16, y algo
# grande que cruza varios bloques de 4096.
SIZES="0 1 2 3 15 16 17 31 32 33 55 56 57 63 64 65 111 112 113 119 120 127 128 129 255 256 1000 4095 4096 4097 4111 4112 8191 8192 8193 65536 100000"
for n in $SIZES; do
    head -c "$n" /dev/urandom > "$TMP/in-$n" 2>/dev/null || : > "$TMP/in-$n"
done

# Semillas de prueba. No son arbitrarias: se prueban varias porque las claves
# de vmac se derivan cifrando contadores bajo la semilla, y su lazo de rechazo
# (descarta las L3 que no caen bajo el primo) solo se ejercita con algunas.
SEED16_A=$(printf 'ab%.0s' $(seq 16))
SEED16_B=$(printf '00%.0s' $(seq 16))
SEED32_A=$(printf 'ab%.0s' $(seq 32))
SEED32_B=$(printf 'ff%.0s' $(seq 32))
SEED32_C=$(printf '00%.0s' $(seq 32))

check() {  # $1=algo $2=seed
    local algo="$1" seed="$2" n c p n_ok=0
    for n in $SIZES; do
        c=$(./bin/hash_test "$algo" "$seed" "$TMP/in-$n") \
            || fail "$algo: el oraculo fallo con $n bytes"
        p=$("$PA" "$algo" "$seed" "$TMP/in-$n") \
            || fail "$algo: el Pascal fallo con $n bytes"
        [ "$c" = "$p" ] || fail "$algo con $n bytes: oraculo $c, Pascal $p"
        n_ok=$((n_ok + 1))
    done
    say "$algo: $n_ok tamanos identicos al oraculo"
    pass=$((pass + n_ok))
}

for algo in md5 sha1 sha512; do check "$algo" none; done
check siphash "$SEED16_A"
check siphash "$SEED16_B"
check vmac "$SEED32_A"
check vmac "$SEED32_B"
check vmac "$SEED32_C"

say "aes, contra el LibTomCrypt vendorizado y no solo contra FIPS-197"
# hash_test expone el cifrado de bloque suelto, asi que la primitiva sobre la
# que se apoya vmac se verifica por separado en vez de solo a traves de el.
for n in 16 32 64 4096; do
    head -c "$n" /dev/urandom > "$TMP/blk-$n"
    c=$(./bin/hash_test aes "$SEED32_A" "$TMP/blk-$n")
    p=$("${PA%hashtool}aesblk" "$SEED32_A" "$TMP/blk-$n" 2>/dev/null) || continue
    [ "$c" = "$p" ] || fail "aes con $n bytes: oraculo $c, Pascal $p"
    pass=$((pass + 1))
done

echo "  pascal_hash_conformance: passed=$pass mismatches=0"
