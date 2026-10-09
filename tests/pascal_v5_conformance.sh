#!/usr/bin/env bash
# El decoder v5 del port a Pascal contra el Rust (docs/pascal-port.md, fase
# 4c), con el mismo criterio que la 4b: la LINEA ENTERA de estadisticas del
# Pascal tiene que coincidir con la del harness Rust (`decode_conformance v5`),
#
#     ok blocks=N origsize=N verified=0|1 vmw=N vmr=N
#
# y los bytes reconstruidos tambien. v5 comparte el decoder de bloques con
# v3/v4 (L = 0, records LEB128 en lugar de STATs), asi que lo nuevo es el
# contenedor: footer leido primero, CRC-32C de header y footer, conteos de
# bloques que tienen que coincidir, la meta de -dup entre los bloques y el
# footer. Por eso la mitad de este harness son archivos danados, y ahi no
# alcanza con que los dos fallen: el Pascal tiene que dar EL MISMO ERROR.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || { say "sin cargo -- salteando"; exit 0; }
cargo build --release -p osrep-conformance >/dev/null 2>&1 \
    || fail "no compila el harness Rust"
DC=target/release/decode_conformance
RS="${OSREP_RUST_BIN:-target/x86_64-unknown-linux-gnu/release/osrep}"
[ -x "$RS" ] || cargo build --release --target x86_64-unknown-linux-gnu >/dev/null 2>&1
[ -x "$RS" ] || fail "no hay encoder Rust en $RS"

DT="${OSREP_PASCAL_DECODETOOL:-pascal/bin/decodetool}"
if [ ! -x "$DT" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/decodetool pascal/decodetool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/decodetool.lpr"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

# Las mismas entradas que los otros harnesses, con la misma semilla.
python3 - "$TMP" <<'PY'
import os, random, sys
d = sys.argv[1]
random.seed(20260913)
unit = bytes((i * 31 + 7) & 0xFF for i in range(4096))
half = bytes(random.randrange(256) for _ in range(40000))
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
open(os.path.join(d, "repeat.bin"), "wb").write(unit * 75)
open(os.path.join(d, "random.bin"), "wb").write(bytes(random.randrange(256) for _ in range(200000)))
open(os.path.join(d, "mixed.bin"), "wb").write(unit * 8 + half + unit * 8 + half)
open(os.path.join(d, "dup.bin"), "wb").write(unit * 4 + unit * 4)
far = [bytes(random.randrange(256) for _ in range(64 * 1024)) for _ in range(32)]
open(os.path.join(d, "far.bin"), "wb").write(b"".join(far) * 2)
PY

# Lo que dice cada uno al fallar, sin los prefijos de cada harness.
rust_err()   { sed 's/^decode_conformance: //; s/^broken compressed data: //'; }
pascal_err() { sed -n 's/^  ERROR! //p'; }

# Con -dup, decode_v5 reconstruye el stream ya deduplicado: el original lo
# arma despues el post-paso de la CLI (fase 6). Ahi el original es "-" y se
# comparan los dos decoders entre si, byte a byte.
compare() { # $1=etiqueta $2=archivo $3=original o "-", el resto opciones
    local label="$1" arc="$2" src="$3"; shift 3
    local want got
    want=$("$DC" v5 "$arc" "$TMP/r.out" "$@" 2>/dev/null) \
        || fail "[$label $*] el Rust no decodifico su propio archivo"
    [ "$src" = - ] || cmp -s "$src" "$TMP/r.out" || fail "[$label] el Rust no reconstruyo la entrada"
    got=$("$DT" "$arc" "$TMP/p.out" "$@" 2>/dev/null) \
        || fail "[$label $*] el Pascal fallo donde el Rust decodifico"
    [ "$want" = "$got" ] || fail "[$label $*] estadisticas distintas
      Rust:   $want
      Pascal: $got"
    cmp -s "$TMP/r.out" "$TMP/p.out" || fail "[$label $*] los bytes reconstruidos difieren"
    pass=$((pass + 1))
}

# Un archivo danado: los dos fallan, con el mismo error, sin dejar salida.
broken() { # $1=etiqueta $2=archivo, el resto opciones
    local label="$1" arc="$2"; shift 2
    local want got out rc=0 r=0
    out=$("$DC" v5 "$arc" "$TMP/r.out" "$@" 2>&1 >/dev/null) || r=$?
    rm -f "$TMP/r.out"
    [ "$r" -ne 0 ] || return 1       # el Rust lo acepto: no es un caso danado
    want=$(printf '%s\n' "$out" | rust_err)
    out=$("$DT" "$arc" "$TMP/bad" "$@" 2>&1 >/dev/null) || rc=$?
    got=$(printf '%s\n' "$out" | pascal_err)
    [ "$rc" -eq 4 ] || fail "[$label] el Rust fallo ($want) y el Pascal salio $rc"
    [ ! -e "$TMP/bad" ] || fail "[$label] quedo una salida a medias"
    [ "$want" = "$got" ] || fail "[$label] otro error que el Rust
      Rust:   $want
      Pascal: $got"
    pass=$((pass + 1))
    return 0
}

say "v5: la linea de estadisticas entera, contra el Rust"
for case in "m1|-m1" "m2|-m2" "m3|-m3" "m4|-m4" "m5|-m5" \
            "md5|-m3 -hash=md5" "sha1|-m3 -hash=sha1" "sha512|-m4 -hash=sha512" \
            "siphash|-m5 -hash=siphash" "hashoff|-m3 -hash-" \
            "dup|-m3 -dup" "dup-m5|-m5 -dup -hash=sha1"; do
    IFS='|' read -r label flags <<<"$case"
    for input in tiny repeat random mixed dup; do
        arc="$TMP/$label.$input.osr"
        # shellcheck disable=SC2086
        "$RS" $flags -b64k -t1 --seed=7 "$TMP/$input.bin" "$arc" >/dev/null 2>&1 \
            || fail "[$label/$input] el encoder rechazo las opciones"
        src="$TMP/$input.bin"
        case "$flags" in *-dup*) src=- ;; esac
        compare "$label/$input" "$arc" "$src"
    done
done
say "$pass archivos: bytes y estadisticas identicos"

say "el spill a disco: los mismos bytes movidos, bajo cuatro presupuestos"
"$RS" -m5 -b64k -t1 --seed=7 "$TMP/far.bin" "$TMP/spill.osr" >/dev/null 2>&1
compare "spill" "$TMP/spill.osr" "$TMP/far.bin"
compare "spill" "$TMP/spill.osr" "$TMP/far.bin" --mem=1048576 --vmblock=131072
compare "spill" "$TMP/spill.osr" "$TMP/far.bin" --mem=524288 --vmblock=65536
compare "spill" "$TMP/spill.osr" "$TMP/far.bin" --mem=2097152 --vmblock=262144
got=$("$DT" "$TMP/spill.osr" "$TMP/p.out" --mem=1048576 --vmblock=131072 2>/dev/null)
vmw=$(printf '%s' "$got" | sed -n 's/.*vmw=\([0-9]*\).*/\1/p')
[ "${vmw:-0}" -gt 0 ] || fail "el caso de spill no derramo nada (vmw=$vmw): el test seria vacio"
pass=$((pass + 1))

say "el contenedor danado: los dos fallan con el mismo error"
# Un archivo multi-bloque con meta de -dup, y uno sin: cada campo del header y
# del footer, con su CRC recalculado para llegar al chequeo de atras del CRC.
"$RS" -m3 -b64k -t1 --seed=7 -dup "$TMP/dup.bin" "$TMP/c.dup.osr" >/dev/null 2>&1
"$RS" -m3 -b64k -t1 --seed=7 -hash=sha1 "$TMP/mixed.bin" "$TMP/c.plain.osr" >/dev/null 2>&1
python3 - "$TMP" <<'PY' || fail "no se pudieron armar los archivos danados"
import struct, sys
d = sys.argv[1]
T = [0] * 256
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    T[i] = c
def crc(b):          # el CRC-32C del proyecto: init 0, sin XOR final
    c = 0
    for x in b:
        c = T[(c ^ x) & 0xFF] ^ (c >> 8)
    return c
def fix_header(b):
    struct.pack_into('<I', b, 24, crc(bytes(b[0:24])))
def fix_footer(b):
    at = len(b) - 32
    struct.pack_into('<I', b, at + 28, crc(bytes(b[at:at + 28])))
n = 0
def out(b):
    global n
    open(f'{d}/k.{n:03d}.osr', 'wb').write(bytes(b)); n += 1
for name in ('c.dup', 'c.plain'):
    src = bytearray(open(f'{d}/{name}.osr', 'rb').read())
    at = len(src) - 32
    for off, val in ((4, 4), (4, 6), (5, 2), (5, 0x80), (6, 0), (6, 2), (6, 77),
                     (7, 0), (7, 15), (12, 0), (13, 3)):
        b = bytearray(src); b[off] = val; out(b)                    # sin arreglar el CRC
        b = bytearray(src); b[off] = val; fix_header(b); out(b)     # con el CRC al dia
    for off, val in ((4, 0), (5, 3), (8, 1), (9, 1), (16, 1), (24, 0), (24, 9)):
        b = bytearray(src); b[at + off] = val; out(b)
        b = bytearray(src); b[at + off] = val; fix_footer(b); out(b)
    b = bytearray(src); b[at] ^= 1; out(b)                          # magia del footer
    b = bytearray(src[:at]) + b'junk' + src[at:]; out(b)            # basura antes del footer
    # cada byte, invertido, de los primeros 600 y de los ultimos 200. Salvo
    # la magia "OSR5": `decode_conformance v5` fuerza el decoder v5, y
    # decodetool, como la CLI, elige por la magia -- un archivo sin ella ya no
    # es un v5, y que lo diga es el despacho (fase 7), no este decoder.
    for i in list(range(4, min(600, len(src)))) + list(range(max(4, len(src) - 200), len(src))):
        b = bytearray(src); b[i] ^= 0x5A; out(b)
    # desde 4 bytes: con menos ni siquiera esta la magia (ver arriba)
    for cut in sorted({4, 5, 27, 28, 59, 60, 61, 100, len(src) // 2, len(src) - 33, len(src) - 32, len(src) - 1}):
        if 0 < cut < len(src): out(src[:cut])
PY
"$RS" -m3 -t1 --seed=7 "$TMP/tiny.bin" "$TMP/t.osr" >/dev/null 2>&1
# un bloque que declara 3 GiB: de literales, de salida y de lista de records
python3 - "$TMP" <<'PY'
import struct, sys
d = sys.argv[1]
src = bytearray(open(f'{d}/t.osr', 'rb').read())
at = 28 + 32                       # header + semilla de vmac: la primera cabecera de bloque
for name, off in (('lit', 0), ('orig', 4), ('stat', 8)):
    b = bytearray(src); struct.pack_into('<I', b, at + off, 3 << 30)
    open(f'{d}/k.claim-{name}.osr', 'wb').write(bytes(b))
PY
# Dos casos que las mutaciones sueltas no alcanzan, y que se agregaron al ver
# que un decoder con el bug pasaba igual:
#   * dos chequeos rotos A LA VEZ (conteo de bloques y flags/meta), con los
#     CRC al dia: solo asi se ve en que ORDEN se chequean;
#   * varints de 10 bytes en la lista de records. El encoder nunca los
#     escribe, pero el decimo byte solo puede aportar el bit 63: con 2 es un
#     record roto, con 1 es valido.
"$RS" -m3 -b64k -t1 --seed=7 -hash- "$TMP/tiny.bin" "$TMP/t0.osr" >/dev/null 2>&1
python3 - "$TMP" <<'PY' || fail "no se pudieron armar los casos de orden y de varint"
import struct, sys
d = sys.argv[1]
T = [0] * 256
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    T[i] = c
def crc(b):
    c = 0
    for x in b:
        c = T[(c ^ x) & 0xFF] ^ (c >> 8)
    return c
def fix(b):
    struct.pack_into('<I', b, 24, crc(bytes(b[0:24])))
    at = len(b) - 32
    struct.pack_into('<I', b, at + 28, crc(bytes(b[at:at + 28])))
src = bytearray(open(f'{d}/c.plain.osr', 'rb').read())
b = bytearray(src); b[5] |= 1; b[len(b) - 32 + 4] ^= 1; fix(b)
open(f'{d}/k.orden.osr', 'wb').write(bytes(b))
# -hash-: header 28, sin semilla, la cabecera del unico bloque en 28; sin records
src = bytearray(open(f'{d}/t0.osr', 'rb').read())
lit, orig, stat = struct.unpack_from('<III', src, 28)
assert stat == 0 and src[7] == 0
for name, last in (('varint2', 2), ('varint1', 1), ('varint-largo', 0x81)):
    recs = bytes([0xFF] * 9 + [last]) + (b'\x00' if last == 0x81 else b'') + b'\x00\x00'
    b = bytearray(src[:28]) + struct.pack('<III', lit, orig, len(recs)) + recs + src[40:]
    at = len(b) - 32
    struct.pack_into('<Q', b, at + 8, len(recs))          # stat_size del footer
    fix(b)
    open(f'{d}/k.{name}.osr', 'wb').write(bytes(b))
PY

accepted=0
for k in "$TMP"/k.*.osr; do
    # lo que el Rust acepta (un bit en un literal, por ejemplo) se compara
    # abajo, como decodificacion
    broken "$(basename "$k")" "$k" || accepted=$((accepted + 1))
done
say "$pass comprobaciones hasta aca; $accepted mutaciones que el Rust acepta"

say "lo que el Rust acepta de esas mutaciones, el Pascal lo reconstruye igual"
for k in "$TMP"/k.*.osr; do
    r=0; want=$("$DC" v5 "$k" "$TMP/r.out" 2>/dev/null) || r=$?
    [ "$r" -eq 0 ] || continue
    got=$("$DT" "$k" "$TMP/p.out" 2>/dev/null) || fail "[$(basename "$k")] el Rust lo acepto y el Pascal no"
    [ "$want" = "$got" ] || fail "[$(basename "$k")] estadisticas distintas: $want / $got"
    cmp -s "$TMP/r.out" "$TMP/p.out" || fail "[$(basename "$k")] bytes distintos"
    pass=$((pass + 1))
done

echo "  pascal_v5_conformance: passed=$pass mismatches=0"
