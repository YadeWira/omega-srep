#!/usr/bin/env bash
# -dup y --verify del port a Pascal (docs/pascal-port.md, fase 6).
#
#   * -dup: el archivo del Pascal tiene que ser IDENTICO al del Rust (v5, con
#     la meta adentro) y al del C++ (v4, con el trailer ODUP), y volver a la
#     entrada por el decoder del Pascal.
#   * --verify: la salida y el codigo de salida de verifytool tienen que ser
#     los de `osrep --verify` del Rust, en archivos sanos, en v1-v4, en lo que
#     no es un .osr y en un barrido de mutaciones. La CLI imprime el error con
#     el Debug del Rust, asi que el nombre del error tambien cuenta.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || { say "sin cargo -- salteando"; exit 0; }
cargo build --release -p osrep-conformance >/dev/null 2>&1 || fail "no compila el harness Rust"
RE=target/release/encode_conformance
OS="${OSREP_RUST_BIN:-target/x86_64-unknown-linux-gnu/release/osrep}"
[ -x "$OS" ] || cargo build --release --target x86_64-unknown-linux-gnu >/dev/null 2>&1
[ -x bin/osrep ] || make bin/osrep >/dev/null 2>&1

ET="${OSREP_PASCAL_ENCODETOOL:-pascal/bin/encodetool}"
DT="${OSREP_PASCAL_DECODETOOL:-pascal/bin/decodetool}"
VT="${OSREP_PASCAL_VERIFYTOOL:-pascal/bin/verifytool}"
for t in "$ET" "$DT" "$VT"; do [ -x "$t" ] || fail "falta $t (pascal/build.sh)"; done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

python3 - "$TMP" <<'PY'
import os, sys, random
d = sys.argv[1]
unit = bytes((i * 31 + 7) & 0xFF for i in range(1 << 19))
open(os.path.join(d, "dup2m.bin"), "wb").write(unit * 4)
# un bloque repetido y una cola que no es un chunk entero: la meta trae
# corridas de TAG_REF y un unico al final
open(os.path.join(d, "dup5m.bin"), "wb").write(unit * 10 + bytes(range(256)) * 260)
random.seed(3)
blk = bytes(random.randrange(256) for _ in range(1 << 19))
open(os.path.join(d, "rnd5m.bin"), "wb").write(blk * 10 + b"a tail that is not a whole chunk")
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
PY

say "-dup: el archivo, byte a byte, y de vuelta por el decoder del Pascal"
for input in "$TMP/dup2m.bin" "$TMP/dup5m.bin" "$TMP/rnd5m.bin" "$TMP/tiny.bin"; do
    for case in "m1v|" "m2v|" "m3v|" "m4v|" "m5v|" "m4v|-hash-" "m4v|-hash=sha1" "m4v|-hash=siphash" \
                "m3v|-b1mb" "m1|" "m3|" "m4|" "m5|" "m4|-hash=md5"; do
        IFS='|' read -r m o <<<"$case"
        # shellcheck disable=SC2086
        "$RE" "$m" --dup $o --seed=7 "$input" "$TMP/r.osr" >/dev/null 2>&1 \
            || fail "el Rust fallo en $m --dup $o"
        # shellcheck disable=SC2086
        "$ET" "$m" --dup $o --seed=7 "$input" "$TMP/p.osr" >/dev/null 2>"$TMP/p.err" \
            || fail "el Pascal fallo en $m --dup $o: $(tail -1 "$TMP/p.err")"
        cmp -s "$TMP/r.osr" "$TMP/p.osr" \
            || fail "$m --dup $o sobre $(basename "$input"): distinto del Rust"
        case "$m" in
            m[0-9])   # v4: el C++ es el oraculo del archivo entero
                # shellcheck disable=SC2086
                ./bin/osrep -dup "-$m" $o --seed=7 "$input" "$TMP/c.osr" >/dev/null 2>&1 \
                    || fail "el C++ fallo en -dup -$m $o"
                cmp -s "$TMP/c.osr" "$TMP/p.osr" \
                    || fail "-dup -$m $o sobre $(basename "$input"): distinto del C++" ;;
        esac
        rm -f "$TMP/d.out"
        "$DT" "$TMP/p.osr" "$TMP/d.out" --dup >/dev/null 2>&1 \
            || fail "$m --dup $o: el decoder del Pascal no lo abrio"
        cmp -s "$input" "$TMP/d.out" || fail "$m --dup $o: el round-trip no reconstruye la entrada"
        pass=$((pass + 1))
    done
done
# -dup con -m0 no tiene sentido (no hay tabla de chunks): los dos lo rechazan
rc=0; "$ET" m0v --dup --seed=7 "$TMP/dup2m.bin" "$TMP/p.osr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "-dup con -m0 salio $rc, esperado 1"
pass=$((pass + 1))
# y un archivo sin -dup pasa por el camino de siempre
"$ET" m4v --seed=7 "$TMP/dup2m.bin" "$TMP/plain.osr" >/dev/null 2>&1
"$DT" "$TMP/plain.osr" "$TMP/d.out" --dup >/dev/null 2>&1 || fail "--dup sobre un archivo comun fallo"
cmp -s "$TMP/dup2m.bin" "$TMP/d.out" || fail "--dup sobre un archivo comun no reconstruyo la entrada"
pass=$((pass + 1))

say "la meta danada: los dos fallan, sin dejar la salida"
"$ET" m4v --dup --seed=7 "$TMP/dup5m.bin" "$TMP/g.osr" >/dev/null 2>&1
"$ET" m4 --dup --seed=7 "$TMP/dup5m.bin" "$TMP/g4.osr" >/dev/null 2>&1
python3 - "$TMP" <<'PY'
import struct, sys
d = sys.argv[1]
b = bytearray(open(f"{d}/g.osr", "rb").read())
off = struct.unpack_from("<Q", b, len(b) - 32 + 16)[0]
b2 = bytearray(b); b2[off + 30] ^= 0x40            # dentro del .dupref: el CRC lo caza
open(f"{d}/bad5.osr", "wb").write(b2)
c = bytearray(open(f"{d}/g4.osr", "rb").read())
c[len(c) - 12] ^= 0xFF                             # meta_size del trailer ODUP
open(f"{d}/bad4.osr", "wb").write(c)
PY
for k in bad5 bad4; do
    rc=0; "$DT" "$TMP/$k.osr" "$TMP/k.out" --dup >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 4 ] || fail "[$k] salio $rc, esperado 4"
    [ ! -e "$TMP/k.out" ] || fail "[$k] quedo la salida"
    pass=$((pass + 1))
done

say "--verify: la misma salida y el mismo codigo que osrep --verify"
verify_same() { # $1=etiqueta $2=archivo
    local want got wr=0 gr=0
    want=$("$OS" --verify "$2" 2>&1 >/dev/null) || wr=$?
    got=$("$VT" "$2" 2>&1 >/dev/null) || gr=$?
    [ "$wr" -eq "$gr" ] || fail "[$1] codigo distinto: Rust $wr, Pascal $gr
      Rust:   $want
      Pascal: $got"
    [ "$want" = "$got" ] || fail "[$1] otra salida
      Rust:   $want
      Pascal: $got"
    pass=$((pass + 1))
}
for input in "$TMP/dup5m.bin" "$TMP/rnd5m.bin" "$TMP/tiny.bin" tests/corpus/mixed.bin; do
    for case in "m3v|" "m4v|-hash-" "m1v|" "m5v|-b1mb" "m4v|--dup" "m4v|-hash=siphash"; do
        IFS='|' read -r m o <<<"$case"
        # shellcheck disable=SC2086
        "$ET" "$m" $o --seed=7 "$input" "$TMP/v.osr" >/dev/null 2>&1 || fail "no se armo $m $o"
        verify_same "$m $o $(basename "$input")" "$TMP/v.osr"
    done
done
"$ET" m4 --seed=7 "$TMP/dup5m.bin" "$TMP/v4.osr" >/dev/null 2>&1
verify_same "un v4" "$TMP/v4.osr"
"$ET" m4o --seed=7 "$TMP/dup5m.bin" "$TMP/v2.osr" >/dev/null 2>&1
verify_same "un v2" "$TMP/v2.osr"
verify_same "no es un .osr" "$TMP/dup2m.bin"
: > "$TMP/empty.osr"
verify_same "vacio" "$TMP/empty.osr"

say "--verify sobre un barrido de mutaciones"
"$ET" m4v --dup --seed=7 -hash=sha1 "$TMP/dup5m.bin" "$TMP/mv.osr" >/dev/null 2>&1
python3 - "$TMP" <<'PY'
import sys
d = sys.argv[1]
src = open(f"{d}/mv.osr", "rb").read()
n = 0
offs = list(range(0, min(400, len(src)))) + list(range(max(0, len(src) - 300), len(src)))
for i in offs:
    b = bytearray(src); b[i] ^= 0x5A
    open(f"{d}/m.{n:04d}.osr", "wb").write(b); n += 1
for cut in (1, 4, 27, 28, 60, len(src) // 2, len(src) - 33, len(src) - 1):
    open(f"{d}/m.{n:04d}.osr", "wb").write(src[:cut]); n += 1
open(f"{d}/m.{n:04d}.osr", "wb").write(src + b"junk"); n += 1
PY
for k in "$TMP"/m.*.osr; do
    verify_same "$(basename "$k")" "$k"
done

echo "  pascal_dup_conformance: passed=$pass mismatches=0"
