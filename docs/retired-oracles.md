# Retired oracles

The C++ 1.0.7 and the Rust 2.1.2 used to live in `oracles/`, as the reference
implementations the Free Pascal port was diffed against. They were removed
from `main` on 2026-11-10, when the golden suite, the CLI fixtures, the hash
vectors, the v6 self-tests and the mutation audit made the repository able to
test itself. They are not gone: the tags and the tarball below keep both
trees, buildable.

## Where they are

| what | where |
|---|---|
| the C++ tree | tag **`oracle-cxx-1.0.7`** |
| the Rust tree | tag **`oracle-rust-2.1.2`** |
| both, in one tarball | release asset `omega-srep-oracles-cxx-1.0.7-rust-2.1.2.tar.gz` on the `oracle-cxx-1.0.7` release |

Both annotated tags point at `b57e4e8`, the last commit that contains
`oracles/`. The tarball has `cxx/`, `rust/` and a copy of this file at its
root; extract it and `OSREP_ORACLES` points at that root. The tags are the
source of truth if the release asset is ever lost:

```bash
  $ git worktree add /tmp/oracles oracle-cxx-1.0.7
  $ export OSREP_ORACLES=/tmp/oracles/oracles
```

## Why they left

They were the measuring instrument, not dead code: a mismatch against one
oracle is ambiguous, and two that agree byte for byte make the Pascal the
wrong one. Retiring them needed a replacement measure, not a deletion:

* `tests/golden/` pins the archives (now the v4/v5 cases recorded from both
  references, plus the v6 cases recorded from the port) and the CLI
  transcripts and the hash vectors;
* the golden v5 cases pin the v5 writer while the port still has it; the
  format stays readable after v5 becomes read-only in 3.0.0;
* `tests/mutations/` audits the suite with 15 injected defects (see
  `docs/retire-oracles.md`, Fase D);
* `tests/gates.sh core` runs all of that with no oracle, no `g++` and no
  `cargo`; `full` adds the differential suites when the archive is available.

The C++ also had undefined behaviour and races the port deliberately does not
copy (see `docs/pascal-port.md`); the golden pins the ports' answer where the
C++ was not a contract. The original `oracles/README.md` is part of the
tarball.

## Running the differential suites

Extract the tarball anywhere and point `OSREP_ORACLES` at the directory that
contains `cxx/` and `rust/`:

```bash
  $ tar xzf omega-srep-oracles-cxx-1.0.7-rust-2.1.2.tar.gz
  $ export OSREP_ORACLES=$PWD/omega-srep-oracles
  $ bash tests/gates.sh full
```

`tests/_paths.sh` derives `CXX_DIR`, `CXX_BIN`, `RUST_DIR` and `RUST_TARGET`
from `OSREP_ORACLES`; the scripts build what they need when it is missing.
`gates.sh full` fails with instructions when `OSREP_ORACLES` is unset, so a
differential run never skips in silence. `OSREP_BIN`, `OSREP_RUST_BIN` and
`OSREP_PORT_BIN` still point a suite at a different binary.

## Building them

The C++, with its own Makefile (output in `$OSREP_ORACLES/cxx/bin/`):

```bash
  $ make -C "$OSREP_ORACLES/cxx" bin/osrep bin/hash_test bin/dedup_test
```

The Rust, from inside the workspace (output in `$OSREP_ORACLES/rust/target/`):

```bash
  $ cd "$OSREP_ORACLES/rust"
  $ cargo build --release --target x86_64-unknown-linux-gnu -p osrep-cli
  $ cargo build --release -p osrep-conformance
```

Run cargo from `rust/`, not with `--manifest-path` from elsewhere:
`rust-toolchain.toml` (pinned to **1.77.2**, the last Rust that targets
Windows 7) and `.cargo/config.toml` (the MinGW linkers) are looked up from the
current directory. Windows and 32-bit C++ builds are described in
`docs/windows-build.md` and `docs/32bit-support.md`; the C++ sources in the
tarball are the same ones those documents were written against.

## What replaced the C++ fuzz

`tests/fuzz.sh` now runs its deterministic round-trip fuzz against the Pascal
by default (`OSREP_BIN` still points it elsewhere), and
`tests/fuzz_regression.sh` replays the captured crash samples through the
Pascal decoder, so the robustness gate is the shipped decoder. The C++-only
harnesses (`local_hardening.sh`, the pgo scripts) went with the tags; they
exercised the oracle, not the port.
