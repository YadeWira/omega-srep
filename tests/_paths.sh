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
