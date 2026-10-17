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
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || { say "sin cargo -- salteando"; exit 0; }
cargo_rs build --release -p osrep-conformance >/dev/null 2>&1 \
    || fail "no compila el harness Rust"
DC=$RUST_TARGET/release/decode_conformance
RS="${OSREP_RUST_BIN:-$RUST_TARGET/x86_64-unknown-linux-gnu/release/osrep}"
[ -x "$RS" ] || cargo_rs build --release --target x86_64-unknown-linux-gnu >/dev/null 2>&1
[ -x "$RS" ] || fail "no hay encoder Rust en $RS"

DT="${OSREP_PASCAL_DECODETOOL:-pascal/bin/decodetool}"
warn_shared_wine "$DT"
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

# Cada corrida deja su stdout, su stderr y su codigo en $TMP: rs.* el Rust,
# pa.* el Pascal. Asi un FAIL puede mostrar las dos salidas enteras.
run_rs() { RS_RC=0; "$DC" v5 "$@" >"$TMP/rs.o" 2>"$TMP/rs.e" || RS_RC=$?; }
run_pa() { PA_RC=0; "$DT" "$@" >"$TMP/pa.o" 2>"$TMP/pa.e" || PA_RC=$?; }

# Un FAIL de abajo con todo lo necesario para diagnosticarlo despues: el
# archivo y su md5, codigo, stdout y stderr de los dos, la salida del Pascal
# y una segunda corrida del Pascal (si esa pasa, fue algo del entorno). Se
# guarda fuera de $TMP, que el trap borra. Hubo un FAIL bajo wine32 que no se
# repitio y del que no quedo mas que la linea del FAIL (docs/pascal-port.md,
# "Un `wineserver -k` ajeno").
fail_diag() { # $1=mensaje $2=archivo $3=salida del Pascal, el resto opciones
    local msg="$1" arc="$2" pout="$3"; shift 3
    local keep rc2=0 f
    keep=$(mktemp -d "${OSREP_KEEP_DIR:-${TMPDIR:-/tmp}}/pascal_v5_fail.XXXXXX") \
        || keep=$(mktemp -d) || fail "$msg (y no se pudo guardar el diagnostico)"
    cp "$arc" "$keep/"
    for f in rs.o rs.e pa.o pa.e; do cp "$TMP/$f" "$keep/" 2>/dev/null || :; done
    [ ! -e "$TMP/r.out" ] || cp "$TMP/r.out" "$keep/rust.out"
    [ ! -e "$pout" ] || cp "$pout" "$keep/pascal.out"
    "$DT" "$arc" "$keep/again.out" "$@" >"$keep/again.o" 2>"$keep/again.e" || rc2=$?
    {
        printf '%s\n' "$msg"
        printf '  archivo: %s, %s bytes, md5 %s; opciones: %s\n' "$(basename "$arc")" \
            "$(stat -c%s "$arc")" "$(md5sum <"$arc" | cut -c1-32)" "${*:-(ninguna)}"
        for f in rust:rs:"${RS_RC:-?}" pascal:pa:"${PA_RC:-?}"; do
            IFS=: read -r who p code <<<"$f"
            printf '  %s: rc=%s\n    stdout: %s\n    stderr: %s\n' "$who" "$code" \
                "$(tr '\n' '|' 2>/dev/null <"$TMP/$p.o")" "$(tr '\n' '|' 2>/dev/null <"$TMP/$p.e")"
        done
        for f in "$keep/rust.out" "$keep/pascal.out" "$keep/again.out"; do
            [ ! -e "$f" ] || printf '  %s: %s bytes, md5 %s\n' "$(basename "$f")" \
                "$(stat -c%s "$f")" "$(md5sum <"$f" | cut -c1-32)"
        done
        printf '  el Pascal otra vez: rc=%s, stdout: %s, stderr: %s\n' "$rc2" \
            "$(tr '\n' '|' <"$keep/again.o")" "$(tr '\n' '|' <"$keep/again.e")"
        # decodetool siempre escribe algo: "ok ..." al salir con 0, un mensaje
        # al salir con cualquier otro codigo. Mudo, con el codigo que sea (bajo
        # wine casi siempre 0, tambien 1 y 131), es que no termino.
        [ -z "${PA_RC:-}" ] || [ -s "$TMP/pa.o" ] || [ -s "$TMP/pa.e" ] || printf '%s\n' \
            "  el Pascal salio $PA_RC sin escribir nada: no termino. Bajo wine, es lo que da" \
            "  un wineserver que se va (un \`wineserver -k\` en el mismo WINEPREFIX)."
        printf '  guardado en %s\n' "$keep"
    } >&2
    fail "$msg"
}

# Con -dup, decode_v5 reconstruye el stream ya deduplicado: el original lo
# arma despues el post-paso de la CLI (fase 6). Ahi el original es "-" y se
# comparan los dos decoders entre si, byte a byte.
compare() { # $1=etiqueta $2=archivo $3=original o "-", el resto opciones
    local label="$1" arc="$2" src="$3"; shift 3
    local want got
    # nada de un caso anterior puede pasar por evidencia de este
    PA_RC=; rm -f "$TMP/pa.o" "$TMP/pa.e" "$TMP/r.out" "$TMP/p.out"
    run_rs "$arc" "$TMP/r.out" "$@"
    [ "$RS_RC" -eq 0 ] || fail_diag "[$label $*] el Rust no decodifico su propio archivo" "$arc" - "$@"
    want=$(cat "$TMP/rs.o")
    [ "$src" = - ] || cmp -s "$src" "$TMP/r.out" || fail "[$label] el Rust no reconstruyo la entrada"
    run_pa "$arc" "$TMP/p.out" "$@"
    [ "$PA_RC" -eq 0 ] \
        || fail_diag "[$label $*] el Pascal fallo donde el Rust decodifico" "$arc" "$TMP/p.out" "$@"
    got=$(cat "$TMP/pa.o")
    [ "$want" = "$got" ] || fail_diag "[$label $*] estadisticas distintas
      Rust:   $want
      Pascal: $got" "$arc" "$TMP/p.out" "$@"
    cmp -s "$TMP/r.out" "$TMP/p.out" \
        || fail_diag "[$label $*] los bytes reconstruidos difieren" "$arc" "$TMP/p.out" "$@"
    pass=$((pass + 1))
}

# Un archivo danado: los dos fallan, con el mismo error, sin dejar salida.
broken() { # $1=etiqueta $2=archivo, el resto opciones
    local label="$1" arc="$2"; shift 2
    local want got
    run_rs "$arc" "$TMP/r.out" "$@"
    rm -f "$TMP/r.out"
    [ "$RS_RC" -ne 0 ] || return 1   # el Rust lo acepto: no es un caso danado
    want=$(rust_err <"$TMP/rs.e")
    run_pa "$arc" "$TMP/bad" "$@"
    got=$(pascal_err <"$TMP/pa.e")
    [ "$PA_RC" -eq 4 ] \
        || fail_diag "[$label] el Rust fallo ($want) y el Pascal salio $PA_RC" "$arc" "$TMP/bad" "$@"
    [ ! -e "$TMP/bad" ] || fail_diag "[$label] quedo una salida a medias" "$arc" "$TMP/bad" "$@"
    [ "$want" = "$got" ] || fail_diag "[$label] otro error que el Rust
      Rust:   $want
      Pascal: $got" "$arc" "$TMP/bad" "$@"
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
    rm -f "$TMP/r.out" "$TMP/p.out"
    run_rs "$k" "$TMP/r.out"
    [ "$RS_RC" -eq 0 ] || continue
    run_pa "$k" "$TMP/p.out"
    [ "$PA_RC" -eq 0 ] || fail_diag "[$(basename "$k")] el Rust lo acepto y el Pascal no" "$k" "$TMP/p.out"
    want=$(cat "$TMP/rs.o"); got=$(cat "$TMP/pa.o")
    [ "$want" = "$got" ] || fail_diag "[$(basename "$k")] estadisticas distintas: $want / $got" "$k" "$TMP/p.out"
    cmp -s "$TMP/r.out" "$TMP/p.out" || fail_diag "[$(basename "$k")] bytes distintos" "$k" "$TMP/p.out"
    pass=$((pass + 1))
done

echo "  pascal_v5_conformance: passed=$pass mismatches=0"
