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
