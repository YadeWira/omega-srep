# Where the oracles live, for every test script.
#
# The shipped implementation is pascal/. The C++ 1.0.7 and the Rust port are
# kept under oracles/ as references the Pascal is diffed against (see
# oracles/README.md). Scripts source this after `cd "$ROOT"` and use these
# names instead of literal paths, so the layout is spelled out in one place.
#
# Paths are relative to the repository root.

CXX_DIR=oracles/cxx
CXX_BIN="$CXX_DIR/bin"                  # bin/osrep, bin/dedup_test, bin/hash_test
RUST_DIR=oracles/rust
RUST_TARGET="$RUST_DIR/target"          # target/release/..., target/<triple>/release/...

# make_cxx bin/osrep ...: build C++ targets with the oracle's own Makefile.
make_cxx() { make -C "$CXX_DIR" "$@"; }

# cargo_rs build --release ...: run cargo inside the workspace, so its
# rust-toolchain.toml (pinned 1.77.2) and .cargo/config.toml apply. They are
# looked up from the current directory, not from --manifest-path.
cargo_rs() { (cd "$RUST_DIR" && cargo "$@"); }

# warn_shared_wine TOOL...: avisa por stderr si alguno es un wrapper de wine
# (un script que llama a `wine`) y ni el wrapper ni el entorno nombran un
# WINEPREFIX. En el prefix compartido (~/.wine) un `wineserver -k` de otro
# trabajo mata el .exe en curso, casi siempre con exit 0 y sin salida, y el
# harness ve un FAIL que no es del port (docs/pascal-port.md, "Un `wineserver
# -k` ajeno"). Solo avisa: la corrida sigue.
warn_shared_wine() {
    local t body
    [ -z "${WINEPREFIX:-}" ] || return 0
    for t in "$@"; do
        [ -f "$t" ] && [ "$(head -c 2 "$t")" = '#!' ] || continue
        # sin los comentarios (ni el #! de la primera linea)
        body=$(grep -v '^[[:space:]]*#' "$t") || continue
        grep -qw wine <<<"$body" || continue
        grep -q WINEPREFIX <<<"$body" && continue
        printf 'AVISO: %s corre wine sin WINEPREFIX propio: un `wineserver -k` ajeno\n' "$t" >&2
        printf '  lo mata a mitad de camino (docs/pascal-port.md, "Un `wineserver -k` ajeno")\n' >&2
    done
    return 0
}
