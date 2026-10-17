#!/usr/bin/env bash
# Pruebas de los propios harnesses, no del port: lo que tiene que pasar cuando
# algo sale mal, que una corrida verde no ejercita nunca.
#
#   1. warn_shared_wine (tests/_paths.sh) avisa por cada wrapper de wine sin
#      WINEPREFIX propio -- tambien con wine64 o con "WINEPREFIX" solo en un
#      comentario -- y por ningun otro script.
#   2. tests/_osrep_bin.sh da ese aviso por su `$OSREP`, asi que lo da todo
#      script que corre con OSREP_BIN=<wrapper>.
#   3. pascal_v5_conformance.sh: si el Pascal muere en silencio en la llamada
#      directa del spill (la que mira vmw), el harness da un FAIL con nombre y
#      guarda la evidencia, con exit 1 y con exit 0 (asi termina casi siempre
#      un .exe cuyo wineserver se fue; docs/pascal-port.md, "Un `wineserver
#      -k` ajeno"). Necesita cargo y el decodetool del Pascal (o fpc); sin
#      ellos dice SKIP y no cuenta como pasada.
#
# Nada de esto corre wine: los wrappers de la parte 1 y 2 no se ejecutan, o
# salen antes de llegar a la linea de wine.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source tests/_paths.sh

say()  { printf '  %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0

# --- 1. warn_shared_wine ------------------------------------------------ #
say "warn_shared_wine: que wrappers avisan"
n=0
wrapper() { # $1=si|no (avisa o no), el resto las lineas despues del #!
    local want="$1" f got; shift
    n=$((n + 1)); f="$TMP/w$n"
    { printf '#!/bin/sh\n'; printf '%s\n' "$@"; } >"$f"
    got=no
    # shellcheck disable=SC2016
    if env -u WINEPREFIX bash -c 'source tests/_paths.sh; warn_shared_wine "$1"' _ "$f" 2>&1 \
        | grep -q '^AVISO: '; then got=si; fi
    [ "$got" = "$want" ] || fail "warn_shared_wine sobre [$*]: avisa=$got, tenia que ser $want"
    pass=$((pass + 1))
}
wrapper si 'exec wine ./x.exe "$@"'
wrapper si 'exec env WINEDEBUG=-all wine ./x.exe "$@"'
wrapper si 'exec wine64 ./x.exe "$@"'
wrapper si 'exec /usr/lib/wine/wine64 ./x.exe "$@"'
wrapper si 'exec wine-stable ./x.exe "$@"'
wrapper si 'exec wine ./x.exe "$@" # WINEPREFIX: lo pone el que llama'
wrapper si '# WINEPREFIX lo pone el que llama' 'exec wine64 ./x.exe "$@"'
wrapper no 'exec env WINEDEBUG=-all WINEPREFIX=/p wine ./x.exe "$@"'
wrapper no 'WINEPREFIX=/p exec wine64 ./x.exe "$@"'
wrapper no 'export WINEPREFIX=/p' 'exec wine ./x.exe "$@"  # el propio'
wrapper no '# antes era: exec wine ./x.exe' 'exec ./x "$@"'
wrapper no 'exec winetricks "$@"'
wrapper no 'exec ./decodetool "$@"'
# con WINEPREFIX en el entorno no avisa nunca; un binario (sin #!) tampoco
printf '#!/bin/sh\nexec wine ./x.exe\n' >"$TMP/env"
# shellcheck disable=SC2016
out=$(WINEPREFIX=/p bash -c 'source tests/_paths.sh; warn_shared_wine "$1"' _ "$TMP/env" 2>&1)
[ -z "$out" ] || fail "warn_shared_wine avisa con WINEPREFIX en el entorno: $out"
printf '\177ELF wine wine64\n' >"$TMP/elf"
# shellcheck disable=SC2016
out=$(env -u WINEPREFIX bash -c 'source tests/_paths.sh; warn_shared_wine "$1"' _ "$TMP/elf" 2>&1)
[ -z "$out" ] || fail "warn_shared_wine avisa por un archivo que no es un script: $out"
pass=$((pass + 2))

# --- 2. _osrep_bin.sh ---------------------------------------------------- #
say "tests/_osrep_bin.sh avisa por su OSREP_BIN"
# sale antes de la linea de wine: la sonda de --format=v4 lo ejecuta
printf '#!/bin/sh\nexit 3\nexec wine64 ./osrep.exe "$@"\n' >"$TMP/osrep-wine"
chmod +x "$TMP/osrep-wine"
# shellcheck disable=SC2016
out=$(env -u WINEPREFIX OSREP_BIN="$TMP/osrep-wine" bash -c 'source tests/_osrep_bin.sh' 2>&1) \
    || fail "source tests/_osrep_bin.sh fallo: $out"
grep -q "^AVISO: $TMP/osrep-wine " <<<"$out" \
    || fail "tests/_osrep_bin.sh no avisa por un OSREP_BIN que corre wine sin WINEPREFIX: [$out]"
# shellcheck disable=SC2016
out=$(WINEPREFIX=/p OSREP_BIN="$TMP/osrep-wine" bash -c 'source tests/_osrep_bin.sh' 2>&1) \
    || fail "source tests/_osrep_bin.sh fallo: $out"
[ -z "$out" ] || fail "tests/_osrep_bin.sh avisa con WINEPREFIX en el entorno: $out"
pass=$((pass + 2))

# --- 3. el spill de pascal_v5_conformance.sh ----------------------------- #
say "pascal_v5_conformance: un Pascal mudo en el chequeo de vmw del spill"
DT="${OSREP_PASCAL_DECODETOOL:-pascal/bin/decodetool}"
# el de pascal/bin se compila si falta, como en el harness; uno dado no
if [ -z "${OSREP_PASCAL_DECODETOOL:-}" ] && [ ! -x "$DT" ] && command -v fpc >/dev/null 2>&1; then
    mkdir -p pascal/bin/units-linux
    fpc -Mobjfpc -O2 -Xs -vw -Fupascal/src -FUpascal/bin/units-linux \
        -opascal/bin/decodetool pascal/decodetool.lpr >/dev/null 2>&1 \
        || fail "no compila pascal/decodetool.lpr"
fi
case "$DT" in /*) ;; *) DT="$ROOT/$DT" ;; esac
if ! command -v cargo >/dev/null 2>&1 || [ ! -x "$DT" ]; then
    say "SKIP: hace falta cargo y $DT (o fpc)"
else
    # La primera llamada con --mem=1048576 es el compare() del spill; la
    # segunda, la que mira vmw: esa sale con $1 sin escribir nada.
    for rc in 1 0; do
        inj="$TMP/dt-mudo-$rc"; cnt="$TMP/cuenta-$rc"; keep="$TMP/keep-$rc"
        mkdir -p "$keep"
        cat >"$inj" <<EOF
#!/usr/bin/env bash
case " \$* " in
*" --mem=1048576 "*)
    n=\$(( \$(cat '$cnt' 2>/dev/null || echo 0) + 1 )); echo "\$n" >'$cnt'
    [ "\$n" -ne 2 ] || exit $rc ;;
esac
exec '$DT' "\$@"
EOF
        chmod +x "$inj"
        hrc=0
        out=$(OSREP_PASCAL_DECODETOOL="$inj" OSREP_KEEP_DIR="$keep" \
              bash tests/pascal_v5_conformance.sh 2>&1) || hrc=$?
        [ "$hrc" -ne 0 ] || fail "[exit $rc] el harness paso con un Pascal mudo"
        [ "$(cat "$cnt" 2>/dev/null)" -ge 2 ] \
            || fail "[exit $rc] el harness no llego al chequeo de vmw (rc=$hrc): $(tail -5 <<<"$out")"
        if [ "$rc" -ne 0 ]; then
            want='FAIL: [spill vmw] el Pascal fallo'
        else
            want='FAIL: el caso de spill no derramo nada (vmw=)'
        fi
        grep -qF "$want" <<<"$out" \
            || fail "[exit $rc] sin la linea \"$want\" (rc=$hrc): $(tail -5 <<<"$out")"
        grep -qF "el Pascal salio $rc sin escribir nada" <<<"$out" \
            || fail "[exit $rc] sin el aviso de un Pascal que no termino: $(tail -8 <<<"$out")"
        saved=$(sed -n 's/^  guardado en //p' <<<"$out")
        [ -n "$saved" ] && [ -f "$saved/spill.osr" ] \
            || fail "[exit $rc] no guardo la evidencia (guardado en: '$saved')"
        # sin corrida del Rust en este chequeo: nada suyo de otro caso
        for f in rs.o rs.e rust.out; do
            [ ! -e "$saved/$f" ] || fail "[exit $rc] guardo $f de otro caso como evidencia"
        done
        pass=$((pass + 1))
    done
fi

echo "  harness_selftest: passed=$pass"
