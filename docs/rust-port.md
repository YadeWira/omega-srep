# Rust port

Omega SREP is being ported to Rust **gradually**, module by module, with the
C++ implementation kept as the reference oracle until the port reaches parity.
Nothing is rewritten from a re-reading of a spec: each ported module is diffed
byte-for-byte against the shipped C++ binary by `tests/rust_conformance.sh`.

## Decisions

| | |
|---|---|
| **Approach** | Drop-in reimplementation. The Rust binary must be interchangeable with the C++; no FFI, no long-term dual-language build. The C++ is retired once parity is reached. |
| **Format** | Keep *reading* v1–v4 `.osr` exactly as they are today (existing archives keep working). The Rust encoder will *write* a new, cleaner **v5** container; `--format=v4` stays available during the transition. |
| **Correctness gate** | Differential testing against the C++ binary (see below), not round-trip alone. |
| **Retirement** | The C++ stays under a tag as the oracle for the duration of the port. |

## Toolchain: why Rust 1.77.2

Rust **1.78 raised the minimum supported Windows version to Windows 10** for
every `*-pc-windows-*` target (`msvc`, `gnu` and `gnullvm`; x86_64 and i686).
Omega SREP targets Windows 7 x64/x86, so `rust-toolchain.toml` pins **1.77.2**,
the last stable release that supports Win7 without nightly and the Tier 3
`*-win7-windows-*` targets (which ship no prebuilt `std`).

This pin is workspace-wide, so Linux and Windows builds use the same compiler.

| target | triple |
|---|---|
| Linux x64 | `x86_64-unknown-linux-gnu` |
| Windows x64 (Win7+) | `x86_64-pc-windows-gnu` |
| Windows x86 (Win7+) | `i686-pc-windows-gnu` |

Windows builds cross-compile from Linux with the same mingw-w64 toolchain the
C++ build uses (`.cargo/config.toml` wires up the linkers), so no Visual Studio
is required.

**Windows 7 comes out ahead:** the Rust binaries import only `KERNEL32.dll`,
`msvcrt.dll` and `ntdll.dll`, all present on an unpatched Windows 7. The
current C++ build uses MinGW-w64's UCRT runtime and needs the
`KB2999226` Universal C Runtime installed on the target machine. (Verified by
inspecting the PE import table; a real Win7 VM run is still on the checklist.)

## Layout

```
crates/osrep-core/         library; modules are ported here
crates/osrep-cli/          the `osrep` binary
crates/osrep-conformance/  differential harness; mirrors tests/dedup_test.cpp's CLI
tests/rust_conformance.sh  runs both implementations and diffs the output
```

`crates/osrep-conformance` deliberately reproduces the C++ test tool's command
names, options and printed text, so the two can be compared directly:

```bash
cargo build --release -p osrep-conformance
tests/rust_conformance.sh          # builds both sides, then diffs
```

The harness covers, per input × parameter set: `encode` (identical blobs),
cross-decode in both directions, `split-encode` (identical meta and body),
`encode-streaming` with and without `--paranoid` (identical meta and body — this
is the path `osrep -dup` actually uses), `selftest` stdout, and the corrupt
forward-ref meta (both must reject with `DEDUP_ERR_BAD_REF` and not crash).

## Phases

| | scope | status |
|---|---|---|
| **0** | Fix the real bugs in C++ first (corrupt-meta read, 64-bit hash trust, spill backstop, CLI validation) and rewrite `docs/format-spec.md` to match the code — the oracle and the contract must be right before porting against them. | **done** |
| **1** | Workspace, toolchain pin, cross-compile config, differential harness. | **done** |
| **2** | Leaf modules: `dedup` (done), then `hashes` (VMAC/SipHash must match exactly for `--seed=N` to stay byte-stable). | in progress |
| **3** | Container/IO: header/footer/block codec (read v1–v4, write v4 and v5), buffered IO, mmap, the VM spill manager. | not started |
| **4** | The LZ core: hash-table match finder, `compress` (-m3/-m4/-m5 + accelerator), CDC (-m1/-m2), in-memory REP (-m0), the Future/Index-LZ second pass and the three decoders. Gate: byte-identical v4 archives across the whole matrix. | not started |
| **5** | v5 format, CLI, retire the C++. | not started |

The rule that makes phase 4 tractable: **separate the algorithm from the
container.** The match stream is identical in v4 and v5, so the ported LZ core
can be verified byte-for-byte against the C++ by emitting v4 — v5 is a different
wrapper around the same payload.

## Open questions

* **Licence.** The C++ core is Bulat Ziganshin's ("All rights reserved", with a
  commercial-licence offer); `_Encryption/hashes/siphash/siphash.c` carries no
  licence header at all. Whether the Rust port is a faithful translation (a
  derivative work) or a clean-room implementation from the format spec is not
  decided, so the workspace deliberately declares no licence. Settle this before
  publishing anything from the Rust tree.
* **MSRV.** The 1.77.2 pin caps dependency choice at 2024-era crates. Keep the
  dependency set small; `osrep-core` currently has none.
