#!/usr/bin/env bash
# El ENCODER del port a Pascal contra el Rust (docs/pascal-port.md, fase 5).
#
# El criterio es el del port a Rust contra el C++: la misma entrada y las
# mismas opciones pasan por los dos encoders, con --seed=7, y los archivos
# tienen que ser IDENTICOS byte a byte. El Rust ya es byte-identico al C++ en
# toda esta matriz (tests/encode_conformance.sh), asi que es el oraculo.
#
# La matriz es la de tests/encode_conformance.sh. Lo que el Pascal todavia no
# tiene portado sale con 3 y se cuenta aparte como "no portado", no como fallo:
# el harness crece con cada sub-fase sin cambiar de forma.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v cargo >/dev/null 2>&1 || { say "sin cargo -- salteando"; exit 0; }
cargo build --release -p osrep-conformance >/dev/null 2>&1 || fail "no compila el harness Rust"
RS=target/release/encode_conformance

ET="${OSREP_PASCAL_ENCODETOOL:-pascal/bin/encodetool}"
if [ ! -x "$ET" ]; then
    command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/encodetool pascal/encodetool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/encodetool.lpr"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0
notported=0

python3 - "$TMP" <<'PY'
import os, sys
d = sys.argv[1]
unit = bytes((i * 17 + 5) & 0xFF for i in range(1 << 19))   # 512 KiB
open(os.path.join(d, "dup4m.bin"), "wb").write(unit * 8)
open(os.path.join(d, "dup20m.bin"), "wb").write(unit * 40)   # cruza bloques y da la vuelta al anillo
open(os.path.join(d, "empty.bin"), "wb").write(b"")
open(os.path.join(d, "tiny.bin"), "wb").write(b"osrep")
PY

# enc <entrada> <modo> <opciones...>: los dos encoders, --seed=7, cmp.
enc() {
    local input="$1" m="$2"; shift 2
    "$RS" "$m" "$@" --seed=7 "$input" "$TMP/rs.osr" >/dev/null 2>"$TMP/rs.err" \
        || fail "el Rust fallo en $m $* sobre $input: $(tail -1 "$TMP/rs.err")"
    local rc=0
    "$ET" "$m" "$@" --seed=7 "$input" "$TMP/pa.osr" >/dev/null 2>"$TMP/pa.err" || rc=$?
    if [ "$rc" -eq 3 ]; then
        notported=$((notported + 1))
        return
    fi
    [ "$rc" -eq 0 ] || fail "el Pascal fallo en $m $* sobre $input: $(tail -1 "$TMP/pa.err")"
    cmp -s "$TMP/rs.osr" "$TMP/pa.osr" \
        || fail "$m $* sobre $(basename "$input"): archivos distintos ($(stat -c%s "$TMP/rs.osr") contra $(stat -c%s "$TMP/pa.osr") bytes)"
    pass=$((pass + 1))
}

C=tests/corpus

say "-m0o (REP en memoria, v2)"
for input in $C/mixed.bin $C/text.bin $C/zeros.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m0o -d16mb
    enc "$input" m0o -d2mb -b1mb
    enc "$input" m0o -d16mb -l1024
    enc "$input" m0o -d16mb -dl256
    enc "$input" m0o -d16mb -hash-
    enc "$input" m0o -d16mb -hash=md5
    enc "$input" m0o -d16mb -hash=siphash
done

say "-m4o/-m5o (match finder con tabla de hash, v2)"
for input in $C/mixed.bin $C/text.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m4o
    enc "$input" m4o -b1mb
    enc "$input" m4o -d16mb
    enc "$input" m4o -d16mb -b1mb
    enc "$input" m4o -l1024
    enc "$input" m5o
    enc "$input" m5o -b1mb
    enc "$input" m5o -d16mb
    enc "$input" m5o -l1024
    enc "$input" m5o -l256
done

say "-m3o (chunks con digest, v1; con -d cae a v2)"
for input in $C/mixed.bin $C/text.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m3o
    enc "$input" m3o -b1mb
    enc "$input" m3o -d16mb
    enc "$input" m3o -l1024
done

say "los hashes del bloque, sobre -m4o y -m3o"
for input in $C/mixed.bin "$TMP/dup4m.bin"; do
    for h in -hash- -hash=md5 -hash=sha1 -hash=sha512 -hash=siphash -hash=vmac; do
        enc "$input" m4o "$h"
        enc "$input" m3o "$h"
    done
done

say "-m0/-m3/-m4/-m5 (Index-LZ, v4) y el sufijo f (Future-LZ, v3)"
for input in $C/mixed.bin $C/text.bin $C/random.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m0 -d16mb
    enc "$input" m3
    enc "$input" m4
    enc "$input" m5
    enc "$input" m3f
    enc "$input" m4f
    enc "$input" m5f
done

say "-m1/-m2 (chunking por contenido)"
for input in $C/mixed.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    enc "$input" m1o
    enc "$input" m1
    enc "$input" m1f
    enc "$input" m2o
    enc "$input" m2
    enc "$input" m2f
    enc "$input" m1o -l2048
    enc "$input" m1o -b1mb
done

say "v5 (el contenedor por defecto)"
for input in $C/mixed.bin "$TMP/dup4m.bin" "$TMP/dup20m.bin"; do
    for m in m0v m1v m3v m4v m5v; do
        if [ "$m" = m0v ]; then enc "$input" "$m" -d16mb; else enc "$input" "$m"; fi
    done
done

say "entradas degeneradas"
for m in m4o m5o m3o; do
    enc "$TMP/empty.bin" "$m"
    enc "$TMP/tiny.bin" "$m"
    enc $C/tiny.bin "$m"
done
enc "$TMP/empty.bin" m0o -d16mb
enc "$TMP/tiny.bin"  m0o -d16mb

echo "  pascal_encode_conformance: passed=$pass mismatches=0 not_ported=$notported"
