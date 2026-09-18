# Resolve the `osrep` under test, for the CLI-level scripts.
#
# `OSREP_BIN` puts a different build through the whole suite -- that is how
# tests/rust_cli_conformance.sh runs the Rust port against it. Left unset (the
# default) the C++ oracle in bin/osrep is used, and built if it is missing.
#
# Scripts source this after `cd "$ROOT"`, and use `"$OSREP"` in place of a
# literal path. `bin/dedup_test` is deliberately *not* parameterized: it stays
# the C++ oracle the -dup tests cross-check against.

OSREP="${OSREP_BIN:-bin/osrep}"
if [ -z "${OSREP_BIN:-}" ] && [ ! -x "$OSREP" ]; then
    make "$OSREP" >/dev/null 2>&1 || true
fi
if [ ! -x "$OSREP" ]; then
    echo "missing $OSREP" >&2
    exit 1
fi

# `$OSREP_V4`: the flag that forces the v4 container, or empty when the binary
# under test has no such option.
#
# Since phase 5c-2 the Rust port writes v5 by default; the C++ oracle only ever
# writes v4 and rejects `--format=` outright. Scripts that assert a *v4-specific*
# layout -- the ODUP trailer, the header's seed offset -- use this so they keep
# testing that layout against either build, instead of silently testing whatever
# the default happens to be. Probed by behaviour, because `--format` is
# the default happens to be. The probe has to be a real compression: `--version`
# and `--help` are answered *before* the option parser runs, so
# `--format=v4 --version` exits 0 on the C++ too and would report support that
# is not there.
OSREP_V4=""
_osrep_v4_probe="$(mktemp -d)"
: >"$_osrep_v4_probe/in"
if "$OSREP" --format=v4 -m4 "$_osrep_v4_probe/in" "$_osrep_v4_probe/out" >/dev/null 2>&1; then
    OSREP_V4="--format=v4"
fi
rm -rf "$_osrep_v4_probe"
unset _osrep_v4_probe
