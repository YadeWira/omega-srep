#!/usr/bin/env bash
# La capa de contenedor v6 (Container.pas) sin pasar por la CLI: round-trip de
# cabecera, header de bloque y footer, rechazo de cada byte cambiado, y el
# encadenado de block_crc. Es la base de v6; el encoder/decoder todavia no la
# usan, asi que esta es la prueba que la mantiene honesta mientras se cablea.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

command -v fpc >/dev/null 2>&1 || { say "sin fpc -- salteando"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fpc -Mobjfpc -O1 -vw -Fupascal/src -FU"$TMP" -o"$TMP/v6test" \
    tests/v6_frame_selftest.lpr >"$TMP/build.log" 2>&1 \
    || { cat "$TMP/build.log" >&2; fail "no compila tests/v6_frame_selftest.lpr"; }
"$TMP/v6test"
