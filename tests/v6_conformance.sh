#!/usr/bin/env bash
# v6: ida y vuelta, compatibilidad de lectura con v5 y deteccion de corrupcion
# por bloque. v6 no tiene oraculo (ni el C++ ni el Rust lo escriben), asi que
# este harness se apoya en si mismo: comprime, descomprime, compara con la
# entrada, y despues rompe un byte en cada zona y exige el rechazo.
#
#   OSREP_PORT_BIN   el binario a probar (por defecto el Pascal nativo)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

B="${OSREP_PORT_BIN:-pascal/bin/osrep-linux-x86_64}"
[ -x "$B" ] || { say "sin $B -- salteando"; exit 0; }
warn_shared_wine "$B"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

run()  { "$B" "$@" >/dev/null 2>"$TMP/err"; }
rc_of(){ local r=0; "$@" >/dev/null 2>"$TMP/err" || r=$?; echo "$r"; }

say "v6 comprime y descomprime lo mismo que v5"
for f in tiny zeros random mixed text; do
    for o in "-m0" "-m1" "-m3" "-m4" "-m5 -l1000 -ia-" "-m3 -hash-"; do
        rm -f "$TMP/6.osr" "$TMP/5.osr" "$TMP/o6" "$TMP/o5"
        # shellcheck disable=SC2086
        run --format=v6 --seed=7 $o "tests/corpus/$f.bin" "$TMP/6.osr" \
            || fail "$f $o: no comprime v6: $(cat "$TMP/err")"
        # shellcheck disable=SC2086
        run --format=v5 --seed=7 $o "tests/corpus/$f.bin" "$TMP/5.osr" \
            || fail "$f $o: no comprime v5"
        [ "$(head -c 4 "$TMP/6.osr")" = "OSR6" ] || fail "$f $o: falta la magia OSR6"
        run -d "$TMP/6.osr" "$TMP/o6" || fail "$f $o: v6 no descomprime: $(cat "$TMP/err")"
        cmp -s "tests/corpus/$f.bin" "$TMP/o6" || fail "$f $o: v6 no reconstruyo la entrada"
        run -d "$TMP/5.osr" "$TMP/o5" || fail "$f $o: v5 no descomprime"
        cmp -s "$TMP/o5" "$TMP/o6" || fail "$f $o: v5 y v6 dan otro dato"
        pass=$((pass + 1))
    done
done

say "varios bloques: blocks_crc encadena todos"
run --format=v6 --seed=7 -m3 -b1mb tests/corpus/text.bin "$TMP/b6.osr" || fail "no comprime multi-bloque v6"
run -d "$TMP/b6.osr" "$TMP/ob6" || fail "multi-bloque v6 no descomprime"
cmp -s tests/corpus/text.bin "$TMP/ob6" || fail "multi-bloque v6 no reconstruyo la entrada"
r=$(rc_of "$B" --verify "$TMP/b6.osr")
[ "$r" -eq 0 ] || fail "verify de un v6 de varios bloques salio $r: $(cat "$TMP/err")"
szb=$(stat -c%s "$TMP/b6.osr")
cp "$TMP/b6.osr" "$TMP/b6bad.osr"
printf '\377' | dd of="$TMP/b6bad.osr" bs=1 seek=$((szb * 3 / 4)) conv=notrunc status=none
r=$(rc_of "$B" --verify "$TMP/b6bad.osr")
[ "$r" -eq 4 ] || fail "verify de un bloque intermedio danado salio $r, esperado 4"
pass=$((pass + 1))

say "--verify acepta un v6 sano y dice que cubre los bloques guardados"
run --format=v6 --seed=7 -m3 tests/corpus/random.bin "$TMP/r6.osr" || fail "no comprime random v6"
r=$(rc_of "$B" --verify "$TMP/r6.osr")
[ "$r" -eq 0 ] || fail "--verify de un v6 sano salio $r: $(cat "$TMP/err")"
"$B" --verify "$TMP/r6.osr" 2>&1 | grep -q "v6 archive intact" || fail "--verify no dijo 'v6 archive intact'"
"$B" --verify "$TMP/r6.osr" 2>&1 | grep -q "blocks_crc" || fail "--verify no menciona blocks_crc"
pass=$((pass + 1))

say "un byte cambiado en un bloque GUARDADO se detecta sin descomprimir"
sz=$(stat -c%s "$TMP/r6.osr")
cp "$TMP/r6.osr" "$TMP/r6bad.osr"
printf '\377' | dd of="$TMP/r6bad.osr" bs=1 seek=$((sz / 2)) conv=notrunc status=none
r=$(rc_of "$B" --verify "$TMP/r6bad.osr")
[ "$r" -eq 4 ] || fail "verify de un bloque guardado danado salio $r, esperado 4"
grep -q "bad CRC" "$TMP/err" || fail "verify no reporto el CRC del bloque: $(cat "$TMP/err")"
r=$(rc_of "$B" -d "$TMP/r6bad.osr" "$TMP/obad")
[ "$r" -eq 4 ] || fail "-d del bloque guardado danado salio $r, esperado 4"
pass=$((pass + 1))

say "tambien en un bloque comprimido"
run --format=v6 --seed=7 -m4 tests/corpus/text.bin "$TMP/t6.osr" || fail "no comprime text v6"
sz=$(stat -c%s "$TMP/t6.osr")
cp "$TMP/t6.osr" "$TMP/t6bad.osr"
printf '\377' | dd of="$TMP/t6bad.osr" bs=1 seek=$((sz / 2)) conv=notrunc status=none
r=$(rc_of "$B" --verify "$TMP/t6bad.osr")
[ "$r" -eq 4 ] || fail "verify de un bloque comprimido danado salio $r, esperado 4"
pass=$((pass + 1))

say "cabecera, footer y truncamiento se rechazan"
cp "$TMP/t6.osr" "$TMP/h.osr"
printf '\377' | dd of="$TMP/h.osr" bs=1 seek=16 conv=notrunc status=none
r=$(rc_of "$B" --verify "$TMP/h.osr")
[ "$r" -eq 4 ] || fail "verify con la cabecera cambiada salio $r, esperado 4"
cp "$TMP/t6.osr" "$TMP/f.osr"
printf '\377' | dd of="$TMP/f.osr" bs=1 seek=$((sz - 1)) conv=notrunc status=none
r=$(rc_of "$B" --verify "$TMP/f.osr")
[ "$r" -eq 4 ] || fail "verify con el footer cambiado salio $r, esperado 4"
head -c $((sz - 10)) "$TMP/t6.osr" > "$TMP/tr.osr"
r=$(rc_of "$B" --verify "$TMP/tr.osr")
[ "$r" -eq 4 ] || fail "verify de un v6 truncado salio $r, esperado 4"
pass=$((pass + 1))

say "-i lee un v6 y -dup con v6 va adentro como en v5"
"$B" -i "$TMP/t6.osr" >/dev/null 2>"$TMP/err" || fail "-i de un v6 fallo: $(cat "$TMP/err")"
pass=$((pass + 1))

for f in text mixed; do
    for o in "-dup -m3" "-dup -m5 --chunk-avg=2048"; do
        rm -f "$TMP/d6.osr" "$TMP/d5.osr" "$TMP/do6" "$TMP/do5"
        # shellcheck disable=SC2086
        run -dup --format=v6 --seed=7 $o "tests/corpus/$f.bin" "$TMP/d6.osr" \
            || fail "$f $o: no comprime -dup v6: $(cat "$TMP/err")"
        # shellcheck disable=SC2086
        run -dup --format=v5 --seed=7 $o "tests/corpus/$f.bin" "$TMP/d5.osr" \
            || fail "$f $o: no comprime -dup v5"
        run -d "$TMP/d6.osr" "$TMP/do6" || fail "$f $o: -dup v6 no descomprime: $(cat "$TMP/err")"
        cmp -s "tests/corpus/$f.bin" "$TMP/do6" || fail "$f $o: -dup v6 no reconstruyo la entrada"
        run -d "$TMP/d5.osr" "$TMP/do5" || fail "$f $o: -dup v5 no descomprime"
        cmp -s "$TMP/do5" "$TMP/do6" || fail "$f $o: -dup v5 y v6 dan otro dato"
        r=$(rc_of "$B" --verify "$TMP/d6.osr")
        [ "$r" -eq 0 ] || fail "$f $o: --verify de un -dup v6 salio $r: $(cat "$TMP/err")"
        "$B" --verify "$TMP/d6.osr" 2>&1 | grep -q -- "-dup meta checksummed" \
            || fail "$f $o: --verify no dijo '-dup meta checksummed'"
        "$B" -i "$TMP/d6.osr" 2>&1 | grep -q -- "-dup:" \
            || fail "$f $o: -i no mostro la linea de -dup"
        pass=$((pass + 1))
    done
done

say "una meta de -dup danada se rechaza con y sin descomprimir"
rm -f "$TMP/d6.osr"
run -dup --format=v6 --seed=7 -m3 tests/corpus/text.bin "$TMP/d6.osr" || fail "no comprime -dup v6"
python3 - "$TMP/d6.osr" "$TMP/d6bad.osr" <<'PY2'
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
n = len(d); f = d[n - 36:]
off = struct.unpack_from('<Q', f, 16)[0]; sz = struct.unpack_from('<I', f, 24)[0]
assert sz > 16
d[off + sz // 2] ^= 0xFF
open(sys.argv[2], 'wb').write(d)
PY2
r=$(rc_of "$B" --verify "$TMP/d6bad.osr")
[ "$r" -eq 4 ] || fail "verify de una meta danada salio $r, esperado 4"
grep -q "dup meta" "$TMP/err" || fail "verify no reporto la meta: $(cat "$TMP/err")"
r=$(rc_of "$B" -d "$TMP/d6bad.osr" "$TMP/do6bad")
[ "$r" -eq 4 ] || fail "-d de una meta danada salio $r, esperado 4"
pass=$((pass + 1))

echo "  v6_conformance: passed=$pass mismatches=0"
