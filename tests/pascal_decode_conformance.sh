#!/usr/bin/env bash
# El decoder del port a Pascal contra el binario Rust
# (docs/pascal-port.md, fase 4).
#
# Fase 4a: I/O-LZ (v1 y v2, el sufijo `o`). El criterio no es "descomprime",
# es "devuelve exactamente los bytes que entraron" -- y sobre archivos que
# produjo otra implementacion, no los propios.
#
# La matriz de tamanos de bloque no es decorativa: con un solo bloque los
# matches nunca salen del buffer en memoria, y la rama que los trae del
# archivo de salida ya escrito no se ejecuta jamas. Con -b512kb sobre 12 MiB
# son 24 bloques y esa rama es la mayoria del trabajo.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

RS="${OSREP_RUST_BIN:-target/x86_64-unknown-linux-gnu/release/osrep}"
DT="${OSREP_PASCAL_DECODETOOL:-pascal/bin/decodetool}"
[ -x "$RS" ] || { say "sin binario Rust -- salteando"; exit 0; }
if [ ! -x "$DT" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/decodetool pascal/decodetool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/decodetool.lpr"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

# Tres formas de entrada: con duplicados (matches largos), incompresible
# (casi todo literales) y una mezcla.
cat tests/corpus/text.bin tests/corpus/text.bin tests/corpus/text.bin > "$TMP/dup.bin" 2>/dev/null \
    || head -c 3000000 /dev/urandom > "$TMP/dup.bin"
head -c 2000000 /dev/urandom > "$TMP/rnd.bin"
cat "$TMP/rnd.bin" "$TMP/dup.bin" > "$TMP/mix.bin"

say "I/O-LZ: round-trip byte a byte sobre archivos del binario Rust"
n=0
for src in dup rnd mix; do
  for m in m1o m2o m3o m4o m5o; do
    for hash in vmac siphash md5 sha1 sha512; do
      for b in 8mb 1mb 512kb; do
        a="$TMP/a.osr"
        "$RS" --format=v4 --seed=7 "-$m" "-hash=$hash" "-b$b" \
            "$TMP/$src.bin" "$a" >/dev/null 2>&1 || continue
        rm -f "$TMP/out"
        "$DT" "$a" "$TMP/out" >/dev/null 2>&1 \
            || fail "$src/$m/$hash/-b$b: el decoder fallo"
        cmp -s "$TMP/$src.bin" "$TMP/out" \
            || fail "$src/$m/$hash/-b$b: la salida difiere del original"
        n=$((n + 1)); pass=$((pass + 1))
      done
    done
  done
done
say "$n combinaciones, todas byte a byte"

say "con los checksums apagados tambien, que es el camino sin digest"
for m in m3o m1o; do
    "$RS" --format=v4 --seed=7 "-$m" -hash- -b1mb "$TMP/dup.bin" "$TMP/nh.osr" >/dev/null 2>&1
    rm -f "$TMP/out"
    "$DT" "$TMP/nh.osr" "$TMP/out" >/dev/null 2>&1 || fail "$m -hash-: el decoder fallo"
    cmp -s "$TMP/dup.bin" "$TMP/out" || fail "$m -hash-: la salida difiere"
    pass=$((pass + 1))
done

say "un archivo danado se rechaza, y no deja salida a medias"
"$RS" --format=v4 --seed=7 -m3o -b512kb "$TMP/dup.bin" "$TMP/base.osr" >/dev/null 2>&1
SZ=$(stat -c%s "$TMP/base.osr")

# Un bit en los datos: el digest del bloque tiene que cazarlo.
python3 - "$TMP/base.osr" "$TMP/c1.osr" "$((SZ * 3 / 4))" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read()); d[int(sys.argv[3])] ^= 0x01
open(sys.argv[2],'wb').write(d)
PY
rc=0; "$DT" "$TMP/c1.osr" "$TMP/bad1" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "un bit dado vuelta en los datos paso sin detectarse"
[ ! -e "$TMP/bad1" ] || fail "el decoder dejo una salida a medias tras fallar"
pass=$((pass + 1))

# Truncado a la mitad.
head -c $((SZ / 2)) "$TMP/base.osr" > "$TMP/c2.osr"
rc=0; "$DT" "$TMP/c2.osr" "$TMP/bad2" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "un archivo truncado no fue rechazado"
[ ! -e "$TMP/bad2" ] || fail "el decoder dejo una salida a medias tras truncamiento"
pass=$((pass + 1))

say "decodetool no revienta: todo error sale con codigo, sin runtime error ni salida a medias"
# Hasta el 2026-09-26, no poder abrir el archivo o crear la salida terminaba en
# el runtime error 217 de FPC (una excepcion sin capturar).
rc=0; "$DT" "$TMP/no-existe.osr" "$TMP/o1" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "un archivo que no existe salio $rc, esperado 4"
[ ! -e "$TMP/o1" ] || fail "un archivo que no existe dejo una salida creada"
rc=0; "$DT" "$TMP/base.osr" "$TMP/no-existe/o2" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "una salida imposible de crear salio $rc, esperado 4"
echo previa > "$TMP/o3"
rc=0; "$DT" "$TMP/no-existe.osr" "$TMP/o3" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && [ "$(cat "$TMP/o3")" = previa ] \
    || fail "un error de lectura borro o piso una salida que ya existia (rc=$rc)"
pass=$((pass + 3))

# Un v1 con base_len = 0 divide por cero al primer record. El Rust hace panic
# (101) justo ahi y el C++ muere con SIGFPE; el Pascal tiene que fallar limpio
# y sin dejar la salida, que antes quedaba creada. (Un v3 con el byte de
# version cambiado a 1: su header trae base_len = 0.)
"$RS" --format=v4 -m3f -b64k -t1 -hash- "$TMP/dup.bin" "$TMP/v1l0.osr" >/dev/null 2>&1
printf '\001' | dd of="$TMP/v1l0.osr" bs=1 seek=8 conv=notrunc 2>/dev/null
rc=0; "$DT" "$TMP/v1l0.osr" "$TMP/o4" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || fail "un v1 con base_len = 0 salio $rc, esperado 4"
[ ! -e "$TMP/o4" ] || fail "un v1 con base_len = 0 dejo la salida"
pass=$((pass + 1))

# Los numeros de las opciones, como `str::parse::<u64>` del harness Rust: un
# '+' opcional y digitos. TryStrToQWord aceptaba hex, octal, binario y
# espacios al principio.
DC=target/release/decode_conformance
if [ -x "$DC" ]; then
    "$RS" --format=v4 -m3 -b64k -t1 "$TMP/dup.bin" "$TMP/flz.osr" >/dev/null 2>&1
    for v in 1048576 +1048576 0x100000 '$100000' '%101' '&17' ' 1048576' '1048576 ' \
             18446744073709551615 18446744073709551616 '' + -1 1_000; do
        r=0; "$DC" future-lz "$TMP/flz.osr" "$TMP/r.out" "--mem=$v" >/dev/null 2>&1 || r=$?
        p=0; "$DT" "$TMP/flz.osr" "$TMP/p.out" "--mem=$v" >/dev/null 2>&1 || p=$?
        if { [ "$r" -eq 0 ] && [ "$p" -eq 0 ]; } || { [ "$r" -eq 2 ] && [ "$p" -eq 2 ]; }; then
            pass=$((pass + 1))
        else
            fail "--mem='$v': el Rust salio $r y el Pascal $p"
        fi
    done
fi

say "lo que todavia no esta portado lo dice, en vez de intentarlo"
# v5 es la fase 4c. (v3/v4 ya estan, y los cubre
# tests/pascal_futurelz_conformance.sh con mucho mas detalle.)
"$RS" --format=v5 --seed=7 -m3 "$TMP/dup.bin" "$TMP/np.osr" >/dev/null 2>&1
rc=0; "$DT" "$TMP/np.osr" "$TMP/np.out" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "v5 salio $rc, esperado 3 (no portado)"
[ ! -e "$TMP/np.out" ] || fail "v5 dejo un archivo detras"
pass=$((pass + 1))

echo "  pascal_decode_conformance: passed=$pass mismatches=0"
