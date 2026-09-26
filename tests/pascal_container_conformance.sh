#!/usr/bin/env bash
# El armazon del archivo, leido y reescrito por el port a Pascal
# (docs/pascal-port.md, fase 3).
#
# Dos preguntas distintas, y la segunda es la que suele quedar sin hacer:
#
#   1. LEER. Los campos que el Pascal saca del archivo tienen que coincidir
#      con lo que reporta el binario Rust -- version del contenedor, hash y
#      tamano original.
#   2. ESCRIBIR. Reencodear lo parseado tiene que dar los MISMOS BYTES que el
#      archivo real. Un round-trip contra uno mismo no ve un encoder roto:
#      hay que comparar contra bytes que produjo otra implementacion.
#
# Mas el rechazo: un archivo corrupto tiene que fallar limpio y decir por que.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

RS="${OSREP_RUST_BIN:-target/x86_64-unknown-linux-gnu/release/osrep}"
CT="${OSREP_PASCAL_CONTAINERTOOL:-pascal/bin/containertool}"
[ -x "$RS" ] || { say "sin binario Rust -- salteando"; exit 0; }
if [ ! -x "$CT" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/containertool pascal/containertool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/containertool.lpr"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

head -c 300000 /dev/urandom > "$TMP/rnd.bin"
cat tests/corpus/text.bin > "$TMP/txt.bin" 2>/dev/null || cp "$TMP/rnd.bin" "$TMP/txt.bin"

field() { "$CT" "$1" | grep "^$2 " | cut -d' ' -f2-; }

say "lee el armazon de acuerdo con el oraculo, y lo reescribe byte a byte"
n=0
for fmt in v4 v5; do
  for m in m1 m3 m4 m5; do
    for hash in vmac siphash md5 sha1 sha512; do
      for src in rnd txt; do
        a="$TMP/$fmt-$m-$hash-$src.osr"
        "$RS" --format=$fmt --seed=7 "-$m" "-hash=$hash" "$TMP/$src.bin" "$a" \
            >/dev/null 2>&1 || continue

        # 1. leer: el hash y el tamano original tienen que coincidir
        got_hash=$(field "$a" hash_name)
        [ "$got_hash" = "$hash" ] \
            || fail "$fmt/$m/$hash: el Pascal leyo hash '$got_hash'"
        # `-i` del oraculo nombra el hash en su primera linea
        "$RS" -i "$a" 2>&1 | head -1 | grep -q -- "-hash=$hash" \
            || fail "$fmt/$m/$hash: el oraculo no reporta ese hash"

        if [ "$fmt" = v5 ]; then
            osz=$(field "$a" original_size)
            real=$(stat -c%s "$TMP/$src.bin")
            [ "$osz" = "$real" ] \
                || fail "$fmt/$m/$hash: original_size $osz, real $real"
        fi

        # 2. escribir: reencodear tiene que dar los mismos bytes
        "$CT" "$a" | grep -q "^reencode_header identical" \
            || fail "$fmt/$m/$hash: el header reencodeado difiere"
        if "$CT" "$a" | grep -q "^footer ok"; then
            "$CT" "$a" | grep -q "^reencode_footer identical" \
                || fail "$fmt/$m/$hash: el footer reencodeado difiere"
        fi
        n=$((n + 1)); pass=$((pass + 1))
      done
    done
  done
done
say "$n archivos, todos leidos igual que el oraculo y reescritos identicos"

say "rechaza lo corrupto, y dice por que"
base="$TMP/v5-m3-vmac-txt.osr"
[ -f "$base" ] || fail "falta el archivo de referencia"

# magic roto -> no es un .osr
python3 - "$base" "$TMP/bad-magic.osr" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read()); d[0] ^= 0xFF
open(sys.argv[2],'wb').write(d)
PY
"$CT" "$TMP/bad-magic.osr" | grep -q "not-an-osrep-file\|bad-crc" \
    || fail "un magic roto no fue rechazado"
pass=$((pass + 1))

# un bit del header -> el CRC tiene que cazarlo
python3 - "$base" "$TMP/bad-crc.osr" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read()); d[12] ^= 0x01
open(sys.argv[2],'wb').write(d)
PY
"$CT" "$TMP/bad-crc.osr" | grep -q "^header bad-crc" \
    || fail "una corrupcion del header v5 no fue cazada por el CRC"
pass=$((pass + 1))

# un bit de flags desconocido -> rechazo, no "lo ignoro"
python3 - "$base" "$TMP/bad-flags.osr" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read())
d[5] |= 0x80                      # bit no definido
c = 0
tbl = [0]*256
for i in range(256):
    x = i
    for _ in range(8):
        x = (x >> 1) ^ (0x82F63B78 if x & 1 else 0)
    tbl[i] = x
for b in d[:24]:
    c = tbl[(c ^ b) & 0xFF] ^ (c >> 8)   # init 0, sin xor final
d[24:28] = c.to_bytes(4, 'little')
open(sys.argv[2],'wb').write(d)
PY
"$CT" "$TMP/bad-flags.osr" | grep -q "^header bad-flags" \
    || fail "un bit de flags desconocido no fue rechazado (con el CRC recalculado)"
pass=$((pass + 1))

# truncado
head -c 20 "$base" > "$TMP/short.osr"
"$CT" "$TMP/short.osr" | grep -q "truncated\|not-an-osrep-file" \
    || fail "un archivo truncado no fue rechazado"
pass=$((pass + 1))

echo "  pascal_container_conformance: passed=$pass mismatches=0"
