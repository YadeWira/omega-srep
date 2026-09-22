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

**Windows 7 comes out ahead:** the Rust binaries import `ADVAPI32.dll`,
`bcrypt.dll`, `KERNEL32.dll`, `msvcrt.dll` and `ntdll.dll` -- all five present
on an unpatched Windows 7 (`bcrypt.dll` ships with Vista and later; it is where
the CLI draws its hash key from). The current C++ build uses MinGW-w64's UCRT
runtime and needs the `KB2999226` Universal C Runtime installed on the target
machine.

Verified on a real Windows 7 SP1 x64 VM (2026-09-18, the 1.0.7 release
binaries), not just by reading the import table -- an earlier revision of this
paragraph claimed three imports because it was written from a partial `objdump`
read, which is exactly the kind of claim a VM run exists to catch. What the run
covered:

- both `osrep.exe` builds (x64 and x86) start and compress/decompress;
- `-m1`, `-m3`, `-m5` and `-dup` all round-trip byte-for-byte (`fc /b`);
- the x86 build decompresses an archive the x64 build wrote;
- `-i` reports `v5:`, so it is the phase 5c-2 default being exercised;
- with `OSREP_SEED_HEX` pinned, archives written on Win7 x64, Win7 x86 and
  Linux x64 are **byte-identical** at `-m1`/`-m3`/`-m5`/`-dup`. Unpinned, the
  header seed differs per run, which separately confirms the `bcrypt` entropy
  draw works on Win7 rather than silently falling back.

## Retiring the C++ — decided (2026-09-18): keep it, stop shipping it

Phase 5c-2 originally read "retire the C++". It is not being deleted.

The reason is narrow and worth stating plainly, because the phrase "retire"
invites the opposite reading: **the C++ is the oracle this entire port is
verified against.** Every ported module is diffed byte-for-byte against the
shipped C++ binary rather than merely round-tripped through the Rust code.
Deleting it would not remove dead code; it would remove the measuring
instrument. After that, "the port is correct" could only ever mean "the port
agrees with itself", which is a much weaker claim than the one this project
has been making all along.

So what actually changed at 2.0.0:

- The released assets are Rust only. The C++ is not published any more.
- `Compression/` stays in the tree and stays buildable with `make`. The
  differential suites keep running against it via `OSREP_BIN`.
- `srep.cpp` stays at **1.0.7**, the last version the C++ actually shipped in.
  `--version` therefore no longer matches between the two binaries, which is
  correct: since the v5 default they are not interchangeable, and reporting a
  shared version line would assert otherwise.
- The README no longer presents the C++ as the product. Before 2.0.0 it never
  mentioned Rust at all and sent readers straight to `make` — which builds the
  implementation that is no longer released, reports 1.0.7, and writes v4.

This is reversible in one direction only, which is the other half of the
argument: the C++ can be dropped at any later point, but it cannot be
meaningfully recovered as an oracle once the Rust code has drifted past it.
There is no deadline on making that call, and no cost to deferring it.

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
| **5c-2** | `--format=v5` as the default, release assets, tag, `gh release`, retire the C++. | **in progress** — the default is flipped and the whole suite is green over it (`tests/rust_cli_conformance.sh` 187 + the ten CLI scripts, `format_v5_conformance` 50, `dup_v5_conformance` 10, `encode_conformance` 174, `rust_conformance` 519/0). The three release binaries are built at 2.0.0 and the two Windows ones are verified on a real Win7 SP1 VM (see the Windows 7 note above). Retiring the C++ is **decided and done, in the form described below**: it stays as the oracle and stops being released. Only the tag and `gh release` are left. |

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

Spilling goes to a scratch file, one `-vmblock` slot per block index, exactly as
the C++'s `VIRTUAL_MEMORY_MANAGER` does (`decompress.cpp:276`/`:296` seek to
`block*VMBLOCK_SIZE`). The file is opened on the *first* spill, not eagerly: the
C++ allocates its name up front and `fopen`s it in `save_to_disk`
(`decompress.cpp:249`), so a decode that never spills -- most of them -- touches
no disk either way. It is removed when the decode ends, including when
`-vmfile=` named it, which is what the C++'s destructor does: the block area is
scratch, but it has to live somewhere other than RAM, or the `-mem` budget the
manager enforces means nothing. `save_to_disk` evicts the largest-destination
matches first, returns 0 when it cannot make progress, and every caller turns
that into a clean `BadData` rather than a retry — the contract the 1.0.6
spill-hang fix introduced. `decode_conformance` forces the path with
`--mem`/`--vmblock` and asserts the spill actually ran (`vmw > 0`), because a
transparent re-encoding that silently never executes would otherwise look like
a pass. `tests/vm_tempfile_leak_regression.sh` had the same problem in the other
direction: its "spilling" decode used `-mem=8mb -vmblock=256k`, which for
`far.bin` never evicts anything, so the cleanup it asserted was never exercised.
It now uses the budget `decode_conformance` proves spills.

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

* **The Rust CLI wrote v4 by default until phase 5c-2, and now writes v5.**
  Defaulting to v4 first was deliberate: it meant the whole existing CLI suite
  passed against the port **without a single assertion changed**, which is the
  only way to argue the port is drop-in. That argument has been made, so the
  default flipped. Both predicted consequences showed up exactly as written --
  the hash seed moved from archive bytes `[16:48]` (v4's 16-byte header) to
  `[28:60]`, and `-dup`'s meta left the ODUP trailer for the container -- and
  they are now handled rather than merely predicted:
  * `tests/rust_cli_conformance.sh`'s layer 1 pins `--format=v4` on the Rust
    side. The oracle only writes v4, so the question that layer asks is "can
    the port still reproduce the oracle exactly when asked for the oracle's
    format", which outlives the flip. Layer 2 runs the suite over the v5
    default.
  * `tests/_osrep_bin.sh` exports **`$OSREP_V4`**: `--format=v4` when the binary
    under test has the option, empty otherwise. The scripts that parse a
    *v4-specific* layout by hand -- `dup_native_roundtrip.sh` (test 4 walks the
    ODUP trailer), `dup_corruption_fuzz.sh` (every offset is measured from that
    trailer) and `dup_ref_oob_regression.sh` (rebuilds the meta from it) -- use
    it, so they keep testing the layout they are written for against either
    build. The probe must be a real compression: `--version`/`--help` are
    answered before the option parser runs, so `--format=v4 --version` exits 0
    on the C++ too and reports support that is not there.
  * `tests/futurelz_race_regression.sh` derives the seed offset from the magic
    (`OSR5` -> 28, else 16) instead of pinning a container, so a determinism
    regression keeps being tested against whatever the default is.
* **The C++ refuses a v5 archive cleanly** -- `rc=4`, "Not an Omega SREP
  compressed file", no output written -- which is what a user still on a 1.0.x
  binary now hits. That is a contract, not an accident, so
  `rust_cli_conformance.sh` asserts it for both `-d` and `-i`: the failure mode
  worth guarding against is not the refusal but a crash or a partial file.
* **`--format` is documented in `--help` as of 5c-2.** It was deliberately
  absent while it was a transitional opt-in, but once v5 became the default,
  `--format=v4` turned into the only way back to a container the released
  binaries read -- an escape hatch nobody can find is not one. No gate diffs the
  help text against the C++, so this costs nothing.
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
  map onto the spill budget, and `-vmfile=` names the spill file.
* **`-index=` is implemented** (it was the last refusal to go). It routes the
  per-block match lists to a second file: I/O-LZ writes them in the first
  pass, Future-LZ re-emits them in the second, so the sink is threaded through
  both, and the decoder reads them from there instead of the archive. Archive
  *and* index are byte-identical to the C++ for every `f` and `o` mode, and
  each implementation reads the other's pair.

  It is refused for the default container, and that refusal was added to the
  C++ too. Index-LZ's decoder locates its match lists by seeking inside the
  archive and never opens the index, so `-m3 -index=x` exited 0 and produced
  an archive that failed with "broken compressed data" -- the port would
  otherwise have had to reproduce silent data loss to stay faithful.
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

## Licence — decided (2026-09-18): proceed, and keep declaring none

The owner's call, made with the situation below on the table: **finish the port
and publish it, on the same footing as the C++ has been published since 1.0.0.**
No licence field, no `LICENSE` file, attribution left intact. This is not a
question to re-open on the next session; it is a risk accepted knowingly.

**What the sources actually say** (verified by reading the headers):

| component | licence |
|---|---|
| `srep.cpp`, `hashes.cpp`, the core | "Copyright (C) 2009-2014 Bulat Ziganshin. **All rights reserved**", plus an offer to sell a commercial licence |
| `hashes/vmac/vmac.c` | explicitly placed in the **public domain** by Krovetz and Wei Dai |
| `ciphers/aes/aes.c` | LibTomCrypt, "free for all purposes" |
| `hashes/siphash/siphash.c` | **no licence header at all** — worth tracing upstream, the reference implementations are usually CC0 |

**Why this port cannot claim clean-room**: the method is a faithful translation
by design — "Nothing is rewritten from a re-reading of a spec" is the first
paragraph of this document, the gate is a byte-for-byte diff against the C++,
and the phase notes cite `srep.cpp:663`, `hash_table.cpp:393` and reproduce
quirks (the `-16` digest bias, the fence match, where `goto stop` lands) that
exist only because of how the original is written. Copyright covers
translations, so treat the port as a derivative work of an "all rights
reserved" original.

**The basis for proceeding is practical, not legal.** Recording this explicitly
so nobody later repeats a premise that does not hold: source being *public* is
not a licence; *non-commercial* use is not an exemption (it weighs in a
fair-use analysis and limits damages, nothing more); *abandonment* does not
extinguish copyright — there is no such legal category as abandonware, and the
term runs for the author's life plus 70 years in most jurisdictions, so 2009-2014
code is nowhere near expiry; and losing a domain cedes nothing. What actually
makes the risk low is that this is a non-commercial fork of a hobby project
frozen in 2014, by an author who has moved to other work, with no revenue to
claw back, full attribution kept, and a history of him *offering* to license
rather than of hostility.

**Facts as of 2026-09-18, so the calculus can be re-checked rather than
re-argued:**

* `freearc.org` resolves and returns 200, but the project site is gone — the
  domain was lost and now serves an unrelated Indonesian WordPress blog.
* Bulat Ziganshin is **active**, not absent: he pushed to
  `Bulat-Ziganshin/EasyProtoBuf` on 2026-09-18 and has 47 public repos. It is
  his *compression* line that is dormant — `Bulat-Ziganshin/FA` (FreeArc'Next)
  last pushed 2023-12-25, `MT-LZ` and `Compression-Research` in 2016.
* He has starred `YadeWira/nanozip-re` — so he is aware of this owner's GitHub
  presence and has raised no objection. (He has **not** starred `omega-srep`;
  do not overstate this as awareness of, or consent to, this project.)
* The C++ side already carries the same exposure: the repo is public, has no
  licence, and has shipped binaries in eight releases since 1.0.0. The port
  adds visibility, not a new category of risk.

**What would change this**: a message from Bulat (the owner will relay it), or
wanting to do something the current footing cannot support — putting a real
licence on the tree, letting third parties redistribute with confidence, or
anything commercial. Any of those needs his explicit permission, which is one
email to the address in the source headers; the passage of time will not supply
it.

## Open questions

* **MSRV.** The 1.77.2 pin caps dependency choice at 2024-era crates. Keep the
  dependency set small; `osrep-core` currently has none.
