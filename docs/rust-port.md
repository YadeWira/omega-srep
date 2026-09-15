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
crates/osrep-cli/          the `osrep` binary: args.rs (both parsers), modes.rs
                           (compress/decompress/-i), report.rs (stderr),
                           help.rs (--version/--help)
crates/osrep-conformance/  differential harnesses; mirror the C++ test tools' CLIs
tests/rust_conformance.sh       runs both implementations and diffs the output
tests/container_conformance.sh  validates the container framing against real archives
tests/rust_cli_conformance.sh   runs the CLI against the C++ binary, then runs the
                                CLI shell suite with OSREP_BIN pointed at the port
tests/_osrep_bin.sh             how that redirection works: every CLI-level script
                                resolves its binary through OSREP_BIN
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

For the digests it diffs `tests/hash_test.cpp` (backed by the real
`Compression/SREP/hashes.cpp`) against `hash_conformance` — all five of
`md5`/`sha1`/`sha512`/`siphash`/`vmac` now — at the MD5/SHA-1 64-byte and
SHA-512 128-byte padding boundaries (0, 55, 56, 63, 64, 65, 111, 112, 119, 120,
127, 128, 129, …), which is where hand-written digest ports break. Dedicated
sweeps then cover the paths a boundary bug would hide in: `vmac` over several
keys and lengths around the 4096-byte NH block, and `aes` (AES-256 ECB, not a
`-hash=` algorithm but the primitive `vmac` builds on) over several keys and
block counts.

The container codec has no standalone C++ counterpart to diff against, so
`tests/container_conformance.sh` pins each archive four ways instead: every
field the Rust derives must equal what the encoder was asked for (version, hash
tag, seed/digest sizes, match base), the framing must recover the exact
uncompressed size on its own, re-encoding the header and the v4 footer must
reproduce the file's bytes exactly (which tests the write direction), and
`osrep -i`'s own reading of the same framing must agree on the mode word, the
hash name and the original size. The `-dup` ODUP trailer gets its boundary
checked the same way, with an incompressible input as the exact oracle: every
CDC chunk is unique there, so the body must equal the input byte for byte.

The I/O-LZ decoder has the strongest oracle of all: `tests/decode_conformance.sh`
feeds archives written by the real C++ encoder to the Rust decoder and diffs its
output against the original input, byte for byte. That one comparison exercises
the framing, the record decoding, the literal/match interleaving and both match
sources at once. Two negative cases then check that verification is doing
something rather than being vacuous: flipping a byte inside a block's literals
must fail with a digest mismatch (the region is located with
`container_conformance blocks`, because for a compressible input the trailing
blocks have no literals and the last byte of the file belongs to the match
list), and the same flip with `-hash-` must decode to bytes that *differ* from
the input. Truncated archives must error, never panic.

## Phases

| | scope | status |
|---|---|---|
| **0** | Fix the real bugs in C++ first (corrupt-meta read, 64-bit hash trust, spill backstop, CLI validation) and rewrite `docs/format-spec.md` to match the code — the oracle and the contract must be right before porting against them. | **done** |
| **1** | Workspace, toolchain pin, cross-compile config, differential harness. | **done** |
| **2** | Leaf modules: `dedup`, the digests `md5`/`sha1`/`sha512`/`siphash`, `aes` (AES-256 encrypt-only, the `vmac` primitive) and `vmac`/`vhash` (the default hash, VMAC-128). | **done** |
| **3a** | Container framing: archive header, hash-descriptor table, version predicates, block header, v4 index footer + block-size table, ODUP trailer — read v1–v4 and write v4, byte-exact in both directions. | **done** |
| **4a** | The I/O-LZ decoder (format v1/v2): record decoding, the literal/match interleaving, both match sources (read back from the output sink, and LZ77 replication within the block, which is `memcpy_lz_match`'s forward byte copy and NOT memmove), and per-block digest verification through the already-ported hashes. | **done** |
| **4b** | `MEMORY_MANAGER`, the VM spill manager and the Future/Index-LZ decoder (v3/v4): both are driven only by `decompress_FUTURE_LZ`, so they port together rather than standing alone. | **done** |
| **4c** | The encoder: hash-table match finder, `compress` (-m3/-m4/-m5 + accelerator), CDC (-m1/-m2), in-memory REP (-m0) and the Future/Index-LZ second pass. Gate: byte-identical archives across the whole matrix. | **done** — every mode (`-m0`…`-m5`) and every suffix (`o`/`f`/default) is byte-identical to the C++: 174/174 in `tests/encode_conformance.sh` |
| **5a** | v5 format design: container, record codec, rejection rules, verification strategy. | **done** — `docs/format-spec-v5.md` |
| **5b** | v5 writer, v5 decoder, the `-dup` wrapper and the equivalence/round-trip gate. | **done** — `tests/format_v5_conformance.sh` (50/50) checks the stream against the byte-verified Future-LZ path *and* round-trips through the real decoder, `-dup` included; `tests/dup_v5_conformance.sh` (10/10) diffs the wrapper against the C++ oracle. |
| **5c-1** | The CLI: the full option surface, the three modes, stdin/stdout with the tempfile spooling, `-i`, `-bar`, `-delete`, and the suite wired to run over it. | **done** — `tests/rust_cli_conformance.sh` (186) diffs the Rust binary against the C++ on identical argv and then runs the ten CLI-level shell scripts with `OSREP_BIN` pointed at the port |
| **5c-2** | `--format=v5` as the default, release assets, tag, `gh release`, retire the C++. | not started |

### Phase 4c notes worth keeping

* **`DictionaryCompressor`'s window is `-dc`, not `-c`.** The C++ builds it as
  `DictionaryCompressor(dictsize, dict_hashsize, dict_min_match, dict_chunk,
  BASE_LEN, ...)` (`srep.cpp:663`), and `dict_chunk` defaults to
  `dict_min_match / 8` = 64 (`srep.cpp:456`) — while `-l`/`-c` default to 512.
  Porting the compressor with `-l`'s window produces archives that decode
  fine but disagree with the C++ from the first match on. This cost a
  differential bisect through `prepare_buffer` (a C++ probe linking the real
  `compress_inmem.cpp` settled it in one run).
* **The dictionary ring is zero-filled in practice.** The C++ allocates it with
  `BigAlloc` (uninitialized) but never reads a region it has not written — the
  `LowBound`/`DataStart` bounds exist precisely for that — so the port's
  zeroed `Vec` agrees, and `--seed=N` reproducibility on the C++ side is what
  proves those regions are never read.
* **Every non-`-m0` mode gets a fence match in `aux_statbuf`**
  (`srep.cpp:723-724`, `if (!INMEM_COMPRESSION)`): `lit_len = len+1`,
  `offset = BASE_LEN`, `match_len = BASE_LEN`. Its match starts one byte past
  the block, so `compress`'s walk (`i >= match_start`) never reaches it — it
  only terminates the list. With `-d` the in-memory pass's matches come first
  and the fence follows, which is how `-m0` combines with `-m4`/`-m5`.
* **`match_len`'s `goto stop` lands *after* the final in-block compare**
  (`hash_table.cpp:393`), so every early exit — a short read from the input,
  or the match running into `last_p` — skips that compare. A `break` out of
  the reread block is not equivalent: with a short read, `old_offset` is still
  below the block start and the tail's index wraps.
* **`SliceHash::check` reads `h[chunk + 1]` one entry past the array** for the
  last chunk of the file: the scanner's per-batch advance of four can
  overshoot `next_chunk` by up to three positions, which shifts the
  `add_hash` chunk index. In the C++ that read lands in the allocation's page
  padding (zero); the port allocates the extra entry explicitly.
* **The port reads blocks at explicit offsets.** The C++ re-reads the input
  for `match_len` through a *second* handle (`ftemp`, `srep.cpp:638`); the
  port has one handle, and `match_len` seeks it freely, so the sequential
  block reads must re-anchor to their known offset or they silently continue
  from wherever the last reread left the position.
* **`-m3`'s digests are keyed by a PRNG and never stored.** `VDigest::init`
  (`hashes.cpp:402`) keys both VMAC instances from `cryptographic_prng()`, so
  a bit-exact port would be impossible — except that the 20-byte digests only
  ever get compared for equality against digests from the same instances
  (`hash_table.cpp:321`), and never reach the archive. Any shared key gives
  identical *decisions*, so the port pins it to zeroes. `VDigest::compute`
  writes `vhash1` at offset 0 and `vhash2` at offset 4, so the digest is
  `v1[0..4] ++ v2[0..16]` — the first tag's last 12 bytes are overwritten.

* **v4 writes 4-word records with base 0, even for `-m3`.** `ROUND_MATCHES`
  only shapes the *first* pass's intra-block records, which are temporary; the
  second pass always re-encodes with `FUTURELZ_BASE_LEN`, and `header[3]`
  (which the decoder uses as the record base) is `IO_LZ ? BASE_LEN : 0`. That
  is why `-m3`'s v4 archive has `header[3] = 0` and 16-byte records while
  `-m3o`'s v1 archive has `BASE_LEN` and 12-byte ones.
* **What each container writes during the first pass**: I/O-LZ writes
  `header → match list → literals` inline; Index-LZ writes `header` (with
  `statsize = 0`) `→ literals` and leaves every match list to the tail; Future-LZ
  writes nothing at all (`no_writes = FUTURE_LZ`, `io.cpp:270`) and the second
  pass re-emits `header → match list → literals` per block.
* **The second pass re-emits with a trim**: a match is clipped to
  `[max(src, block.start), min(dest end, block.end)]` and skipped entirely if
  it belongs to an earlier block; `saved_i` is what lets the next block
  re-examine those. `lz_match_heap`/`ram` in the C++ only feed the progress
  report and are not modelled.

* **CDC's boundary hash is a runtime CPU choice, and both routes are
  ported.** `crc32c()` (`hashes.cpp:226`) selects `CrcRollingHash<uint32>` and
  falls back to `PolynomialRollingHash<uint64>`; the 4c-0 experiment showed the
  two produce different archives, so `cdc.rs` keeps both. The fallback is
  unreachable on any SSE4.2 machine, so `OSREP_CDC_POLY=1` (a test hook like
  the C++'s `OSREP_SEED_HEX`) forces it and the polynomial route is diffed
  against an oracle built with `#if GCC_VERSION >= 403` patched to `#if 0`.
* **A CDC chunk's 32 hash bytes carry both the digest and the table index.**
  `CDC_Thread::compute_single_chunk_hash` writes `vhash1` at 0 and `vhash2` at
  16 -- *not* the overlapping `VDigest` layout -- because `find_match_CDC`
  reads the first 20 bytes as the digest and the 8 after them as the `BigHash`
  index.
* **`COMPARE_DIGESTS` is `method <= -m3`, `PRECOMPUTE_DIGESTS` is `method ==
  -m3`.** `-m1`/`-m2` therefore allocate `digestarr` and compare chunk digests
  *without* precomputing them, and `-m4`/`-m5` have no digest array at all.

### Phase 4c pre-port experiments (run before writing any Rust)

Each of these decides how much of the encoder the port has to reproduce, so they
ran against the C++ binary first, on a redundant input (16 copies of a 1 MiB
random block — 16.8 MB → ~1.05 MB at `-m0/-m3/-m4/-m5`, ~1.13 MB at `-m1`) with
`--seed=7` so archives are byte-comparable:

| experiment | result |
|---|---|
| `-a0` vs `-a1` vs `-a16` vs default, and `-ia+` vs `-ia-` (`-m3/-m4/-m5`, and `-f`) | **byte-identical** — the accelerator, `bitarr` and the prefetch/batching machinery are output-neutral. The port implements one path: the plain per-position rolling hash. |
| `-t1` vs `-t8` vs default (`-m0`…`-m5`, `-m1f`, `-m5f`) | **byte-identical** — thread count does not affect output. The port is single-threaded per block. |
| `-m1` built normally vs built with `#if GCC_VERSION >= 403` forced to `#if 0` (`hashes.cpp:204`, which makes `crc32c()` the `false` macro at `hashes.cpp:236`) | **different archives** (1,125,378 vs 1,158,094 bytes) — the two CDC routes are real algorithms, not a tuning knob. Both must be ported. |

Two consequences worth recording:

* **`crc32c()` is a runtime check** (`hashes.cpp:226`, CPUID SSE4.2), so `-m1`
  output is CPU-dependent in the C++. The port implements both routes —
  `CrcRollingHash<uint32>` over the hardware CRC32C instruction (what any SSE4.2
  x86 takes, i.e. effectively every x86_64) and `PolynomialRollingHash<uint64>`
  (the fallback) — and the differential gate needs **two** `-m1` oracles. The
  fallback oracle is reproducible with that one-line `#if 0` sed.
* **`tests/corpus` is `-m1`/`-m2`-blind**: every file there compresses at 100 %
  through `-m1` because CDC never finds a duplicate chunk (measured 0 chunk
  boundaries leading to a match on `text.bin`). Any `-m1`/`-m2` differential test
  built on that corpus would pass vacuously, for both the CRC and polynomial
  routes. The encoder harness therefore adds its own dup-friendly input.

Also confirmed while measuring: `-m4` collapses the 16× duplicated input to
almost exactly one copy's worth of bytes (1,048,760 ≈ 1 MiB + framing), which is
the shape the match-finder port has to reproduce.


Phase 4b keeps two details of the C++ that are not obvious from the format spec.
The first is `maximum_save`: `srep.cpp:459` clamps it to `vm_block - 24` whenever
`vm_block > 24`, and the archive does **not** record the value — encoder and
decoder must agree through the shared default `-vmblock` (8 MiB). It decides
whether a match long enough to be a nuisance is held in memory or re-read from
the output file, and it is also what guarantees every *stored* match fits one VM
block. The port applies the same clamp.

The second is the match heap. The C++ uses a `std::multiset` ordered by
destination and erases with `lz_matches.erase(*it)`, which resolves to the *key*
overload: it drops every element equivalent to that key, i.e. every match sharing
that destination. A `BTreeMap<dest, Vec<Match>>` is the exact shape of those
equivalence classes, and `take_class` reproduces the key-erase.

Spilling is modelled faithfully but backed by memory rather than a scratch file:
a VM block is written and read by the same process within one decode and is
never observable outside it, so there is nothing to match on disk. What is kept
is the *behaviour*: `save_to_disk` evicts the largest-destination matches first,
returns 0 when it cannot make progress, and every caller turns that into a
clean `BadData` rather than a retry — the contract the 1.0.6 spill-hang fix
introduced. `decode_conformance` forces the path with `--mem`/`--vmblock` and
asserts the spill actually ran (`vmw > 0`), because a transparent re-encoding
that silently never executes would otherwise look like a pass.

The rule that makes phase 4 tractable: **separate the algorithm from the
container.** The match stream is identical in v4 and v5, so the ported LZ core
can be verified byte-for-byte against the C++ by emitting v4 — v5 is a different
wrapper around the same payload.

The decoder's IO is a plain `Read + Write + Seek` sink rather than a bespoke
abstraction, because that is exactly what the C++ relies on: one `FILE*` opened
`"w+b"` that is both written to and seeked back into, so a match starting in an
earlier block can be re-read. A write-only file is not enough and fails with
`EBADF` on the first back-reference. What is still missing is the CLI-level
policy the C++ wraps around it — spooling to a tempfile when the real output is
stdout and the format needs read-back (`srep.cpp:1124-1136`) — which belongs
with the binary in phase 5.

### Phase 5b notes worth keeping

* **The v5 `-dup` meta is the `.dupref` payload, not a wrapper around it.** The
  blob the footer points at is that payload verbatim plus a trailing CRC-32C
  (`docs/format-spec-v5.md` §2), so `meta_size` is `payload.len() + 4` and the
  blob still starts with `DUPR`. Writing a second `DUPR` header in front of a
  payload that already carries one is invisible to a test that feeds the writer
  arbitrary bytes -- the round-trip works either way -- so `v5::meta_tests`
  builds a real `.dupref` blob and asserts the bytes on disk are it plus the
  CRC. The reader is likewise the *same* payload the v4 ODUP trailer carries,
  which is what lets `tests/dup_v5_conformance.sh` diff the two.
* **`decode_v5` reads the footer before the blocks.** With a meta blob between
  them it is the only thing that says where the block list ends; the reader
  tracks how many bytes it has consumed and checks that against
  `len - FOOTER_SIZE - meta_size` rather than trusting the stream position,
  which a buffered caller would have already run past.
* **A disabled hash has no digest field at all in v5** (`hash_size = 0`), where
  v1-v4 always reserve the descriptor's 16 bytes. Sizing the per-block header
  from the descriptor writes those 16 bytes anyway, and every block behind the
  first one desynchronizes. This was latent until the `-dup` matrix reached
  `-hash-`: it needs a block that actually has records to show up, so
  `tests/format_v5_conformance.sh` now covers `-hash-` and SipHash's 8 bytes
  (the size the v4 `-16` bias used to wrap to 248) in the plain matrix too.
* **The v5 record rebuild is anchored at the source.** `at` in
  `second_pass.rs` tracks `src`, which is the anchor v5 writes down
  (`docs/format-spec-v5.md` §3). Decoding the words with the *destination*
  anchor instead still yields the right `distance` -- the subtraction wraps back
  to the same value -- but it drives `src` below zero on any match whose offset
  exceeds its source position, which is a debug-build panic and a
  silently-kept-correct answer in release. Matching offsets are common (the
  first far-away reference in a small block), so this is not a corner.
* **The `-dup` wrapper reproduces the C++ archive byte for byte in v4.** The
  dedup body and the `.dupref` meta are each verified against the C++ on their
  own, and the wrapper only decides where the meta goes -- so `DupMode::V4`
  (write the body as Index-LZ, append `meta || u64_le(meta_size) || "ODUP"`) is
  a whole-archive oracle for the orchestration, tempfile and all. v5 swaps the
  trailer for the footer's `meta_offset`/`meta_size`, which is the only
  difference the format makes.
* **`--format=v4` is already exercised**; what is left of it is argv. The
  container is chosen by `Mode`, which the encoder has written and diffed since
  phase 4c, and `dup::encode`'s `DupMode` picks the trailer accordingly.
* **The wrapper's tempfiles are `Drop`-scoped.** The C++ unlinks its
  temporaries on every path it remembers to and leaks them on the rest (its
  signal handler never calls `removeTemporaryFiles`); the port cannot forget,
  which is the one place it deliberately does better than the oracle.

### Phase 5c notes worth keeping

* **The Rust CLI writes v4 by default, and `--format=v5` opts in.** That is the
  reversal of the phase 5a plan (which had v5 default) and it is deliberate for
  now: v4 is what the 1.0.x binaries read, and defaulting to it means the whole
  existing CLI suite passes against the port **without a single assertion
  changed** -- which is the only way to argue the port is drop-in. Flipping the
  default is a separate step with two visible consequences: the hash seed moves
  from archive bytes `[16:48]` (v4's 16-byte header) to `[28:60]`, and `-dup`'s
  meta moves out of the ODUP trailer and into the container
  (`tests/futurelz_race_regression.sh` and `tests/dup_native_roundtrip.sh` are
  the two scripts that assert those layouts).
* **`OSREP_SEED_HEX` and `--seed=N` are two different mechanisms, and the C++
  order matters.** The hex hook replays the key bytes a specific archive
  recorded (it is how the Future-LZ race was pinned), `--seed=N` expands a
  number through xorshift64, and the env var wins (`srep.cpp:646-650`). Without
  either, the C++ draws from Fortuna -- which is why the *core* refuses a keyed
  hash with no seed at all (`EncodeError::NeedsSeed`) but the *CLI* still has to
  work: it draws its own key from the OS. That gap is invisible in the library
  harnesses (they always pass `--seed`) and shows up the moment the shell suite
  runs `osrep -m4 in out`, which is how the first round of porting this found it.
* **The progress callback reports per block; the cadence is the CLI's.** The
  C++ prints from inside its block loops, throttled by a timer
  (`srep.cpp:800-810`, `:1260-1268`). The port splits it: the core calls back
  once per block with `(done, total)`, and `report::Bar` decides which of those
  become `PROGRESS` lines. That is the only reason `-bar` needed the encoder and
  the three decoders to grow a parameter. The one place it does not reach is the
  `-dup` post-pass on decompression: the C++ sees the body go through srep_main
  and reports it, the port decodes the body and hands it to
  `dedup::decode_streaming`, which has no progress hook, so a `-dup` decode under
  `-bar` prints nothing.
* **`decode_io_lz`'s `-bar` measurement has to happen before anything is read.**
  Seeking to the end to learn the file length and then back to the start is fine
  at the top of the function and silently fatal in the middle: it rewinds past
  the archive header the caller has already parsed, and the next read sees the
  header as a block. The harnesses pass `None`, so nothing but the CLI could
  have caught it.
* **What the CLI accepts and does not act on**: `-t` (the port is single-threaded
  per block), `-a`/`-ia`/`-slp`/`-pc`/`-mmap`/`-nommap`/`-rem` -- all proven
  output-neutral by the phase 4c pre-port experiments. `-mem` and `-vmblock=`
  map onto the spill budget. `-vmfile=` is accepted but never written, because
  the port models the VM spill in memory; that is why
  `tests/vm_tempfile_leak_regression.sh` finds an empty `$TMPDIR` by
  construction rather than by cleanup. `-index=` is refused outright: silently
  ignoring it would leave a user with an archive they believe has an index.
* **`-i` needs no match walk.** The C++ derives the original size for Index-LZ
  from the footer arithmetic plus a walk of every match; the port reads the
  per-block `origsize` out of the framing, which is the same number and does not
  have to reconstruct anything. The one field that is *not* real is the
  "Decompression memory" figure, which the C++ computes as the peak RAM its
  spill would need and the port has no equivalent measurement for.
* **`--help` and `--version` are reproduced from `dup_wrapper.cpp`, not from
  `srep.cpp`.** The wrapper answers both flags before `srep_main` runs, so its
  text is the one users see -- and a drop-in that prints a different synopsis is
  a worse drop-in.

## Open questions

* **Licence.** The C++ core is Bulat Ziganshin's ("All rights reserved", with a
  commercial-licence offer); `_Encryption/hashes/siphash/siphash.c` carries no
  licence header at all. Two of the ported modules are clearer: `vmac/vmac.c`
  is explicitly placed in the public domain by its authors, and
  `ciphers/aes/aes.c` is LibTomCrypt's "free for all purposes" notice. Whether
  the Rust port is a faithful translation (a derivative work) or a clean-room
  implementation from the format spec is still not decided, so the workspace
  deliberately declares no licence. Settle this before publishing anything from
  the Rust tree.
* **MSRV.** The 1.77.2 pin caps dependency choice at 2024-era crates. Keep the
  dependency set small; `osrep-core` currently has none.
