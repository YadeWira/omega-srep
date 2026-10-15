# Oracles

The released `osrep` is the Free Pascal implementation in `pascal/`. The two
directories here are the earlier implementations, kept in-tree and buildable
as the references the Pascal is checked against. **Neither is shipped**, and
neither is needed to build or use `osrep`; they are needed only to run the
differential tests.

| directory | what it is |
|---|---|
| `cxx/` | the original **C++**, frozen at **1.0.7** (the 1.0.x releases). Writes the v4 container only. |
| `rust/` | the **Rust** port, the released binary from 2.0.0 to 2.1.2. Byte-identical to the C++ in every mode, and writes v5 by default. |

## Why they stay

There are two of them, and they agree with each other. A mismatch against a
single oracle is ambiguous (which one is right?); a mismatch against two that
agree byte-for-byte means the Pascal is wrong. Deleting either would not
remove dead code, it would remove the measuring instrument: "the port is
correct" would shrink to "the port agrees with itself". See
[`docs/pascal-port.md`](../docs/pascal-port.md), "Dos oráculos, no uno", and
[`docs/rust-port.md`](../docs/rust-port.md) for how the Rust was diffed against
the C++ in the first place.

## Building

The C++, with its own Makefile (output in `oracles/cxx/bin/`):

```bash
  $ make -C oracles/cxx bin/osrep bin/hash_test bin/dedup_test
```

`bin/hash_test` and `bin/dedup_test` are built from `cxx/tools/`, next to the
libFuzzer harnesses. Windows and 32-bit builds: `docs/windows-build.md`,
`docs/32bit-support.md`.

The Rust, from inside the workspace (output in `oracles/rust/target/`):

```bash
  $ cd oracles/rust
  $ cargo build --release --target x86_64-unknown-linux-gnu -p osrep-cli
  $ cargo build --release -p osrep-conformance
```

Run cargo from `oracles/rust/`, not with `--manifest-path` from elsewhere:
`rust-toolchain.toml` (pinned to **1.77.2**, the last Rust that targets
Windows 7) and `.cargo/config.toml` (the MinGW linkers) are looked up from the
current directory.

The test scripts find both through `tests/_paths.sh`, and most build what
they need when it is missing. `OSREP_BIN`, `OSREP_RUST_BIN` and
`OSREP_PORT_BIN` still point a suite at a different binary.
