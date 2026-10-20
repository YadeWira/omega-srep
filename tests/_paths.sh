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

# ensure_corpus: tests/corpus/ is in .gitignore, so a fresh worktree has none.
# Harnesses that need it used to substitute another input on the quiet
# (/dev/urandom, /dev/zero) or skip the cases: the run passed while testing
# something else, and a failure was not reproducible. Generate the corpus from
# its fixed seeds instead, and let the harness fail if that is impossible.
ensure_corpus() {
    local f
    for f in text.bin zeros.bin random.bin mixed.bin tiny.bin; do
        [ -f "tests/corpus/$f" ] && continue
        printf 'ensure_corpus: falta tests/corpus/%s, lo genero con tests/gen_corpus.sh\n' "$f" >&2
        bash tests/gen_corpus.sh >&2 || return 1
        [ -f "tests/corpus/$f" ] || return 1
    done
}

# det_random BYTES SEED: BYTES pseudo-random bytes on stdout, the same ones on
# every run. For the inputs that have to be incompressible (the no-match path);
# the fixed seed keeps any failure reproducible, which /dev/urandom did not.
# It is the generator tests/gen_corpus.sh already uses for random.bin.
det_random() {
    python3 -c 'import random, sys
r = random.Random(int(sys.argv[2]))
sys.stdout.buffer.write(r.randbytes(int(sys.argv[1])))' "$1" "$2"
}

# warn_shared_wine TOOL...: avisa por stderr si alguno es un wrapper de wine
# (un script que llama a `wine` o `wine64`) y ni el wrapper ni el entorno
# nombran un WINEPREFIX. En el prefix compartido (~/.wine) un `wineserver -k`
# de otro trabajo mata el .exe en curso, casi siempre con exit 0 y sin salida,
# y el harness ve un FAIL que no es del port (docs/pascal-port.md, "Un
# `wineserver -k` ajeno"). Solo avisa: la corrida sigue.
warn_shared_wine() {
    local t body
    [ -z "${WINEPREFIX:-}" ] || return 0
    for t in "$@"; do
        [ -f "$t" ] && [ "$(head -c 2 "$t")" = '#!' ] || continue
        # sin los comentarios, de linea entera (y el #! de la primera) o al
        # final de una linea: un "# WINEPREFIX lo pone el que llama" no es
        # un WINEPREFIX
        body=$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//' "$t") || continue
        # wine, wine64, .../wine64, wine-stable; no "winetricks" ni "mywine"
        grep -qE '(^|[^[:alnum:]_])wine(64)?([^[:alnum:]_]|$)' <<<"$body" || continue
        grep -q WINEPREFIX <<<"$body" && continue
        printf 'AVISO: %s corre wine sin WINEPREFIX propio: un `wineserver -k` ajeno\n' "$t" >&2
        printf '  lo mata a mitad de camino (docs/pascal-port.md, "Un `wineserver -k` ajeno")\n' >&2
    done
    return 0
}
