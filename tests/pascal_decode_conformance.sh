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

say "lo que todavia no esta portado lo dice, en vez de intentarlo"
# v4 (Index-LZ, el default) y v5 son las fases 4b y 4c.
for fmt_mode in "v4 -m3" "v5 -m3"; do
    set -- $fmt_mode
    "$RS" --format=$1 --seed=7 "$2" "$TMP/dup.bin" "$TMP/np.osr" >/dev/null 2>&1
    rc=0; "$DT" "$TMP/np.osr" "$TMP/np.out" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || fail "$1 $2 salio $rc, esperado 3 (no portado)"
    [ ! -e "$TMP/np.out" ] || fail "$1 $2 dejo un archivo detras"
    pass=$((pass + 1))
done

echo "  pascal_decode_conformance: passed=$pass mismatches=0"
