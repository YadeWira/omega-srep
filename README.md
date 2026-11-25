# OSREP and OREP

This repository hosts two MIT-licensed products, each with its own release
line:

- **OSREP** (tags `vX.Y.Z`): an LZ77 preprocessor for `.osr` streams with
  huge dictionaries, described first below.
- **OREP** (tags `orep-vX.Y.Z`): a one-pass streaming long-range dedup
  written for the PArc archiver as a replacement for FreeArc's REP; see
  [OREP](#orep).

## OSREP

**OSREP** is a new LZ77 preprocessor for `.osr` streams, built for huge
dictionaries, deterministic output and integrity-checked files. It turns the
input into a compact match/literal stream; it is **not** an entropy coder or an
archiver. The final compression is a separate stage (a backend such as
`zpaq-std`), and OSREP is also meant to be the deduplication engine for that
backend. Its core is Free Pascal, with C/asm hot paths planned for phase 2;
it is licensed MIT, and its own formats are **v6** and **v7**: blocks with CRC-32C and a
VHASH-128 digest, a footer that chains the block CRCs, and a CLI for
preprocessing, decompression, verification and inspection.

- **Status: 0.0.15 checkpoint (pre-release).** The v6 reader and writer are
  implemented in `src/pascal/`: container, CRC-32C, VHASH-128 block digest,
  `-d`, `--verify`, `-i`, `-dup` write/read/restore, `-m0` stored, dedup-only
  `-m1` (fixed-window CDC) and `-m2` (order-1 CDC), a hash-chain match finder
  with `-m3`/`-m4`/`-m5` (greedy, lazy and deeper), stdin/stdout (`-`), and
  parallel block encoding
  (`-tN`, automatic up to 8 threads) whose output is byte-identical to the
  single-thread one, and a memory budget (`-mem128`) that lowers the block
  size to keep the LZ tables under a cap. Decoding is block-wise when every
  match stays inside its block, and a windowed Future-LZ streaming decoder
  covers cross-block archives; `-dup` bodies above 32 MiB are restored from a
  temporary file instead of RAM.
  The tests cover the ten compatibility fixtures in `tests/fixtures/v6/`, the
  encoder round-trip/determinism, `-hash-`, `-dup`, the new golden archives in
  `tests/fixtures/v6-new/`, the native CDC and match finder against the
  Pascal reference, the library (73 checks, 103 with the corpus), the
  frozen v7 archives in `tests/fixtures/v7/` and a structure-aware v7
  fuzzer (`tests/fuzz_v7.sh`).
  Every 0.0.x release is a pre-release; 1.0.0 is the first stable release.
  Implementation notes and the open limitations are in
  `docs/implementation-notes.md`; the 0.0.15 notes are in
  `docs/release-0.0.15.md`.
- **Default method: `-m6`** (long range, format v7, `spec/format-v7.md`): one
  index over the whole input finds repeats at any distance, and the match
  table goes first. Defaults `-l512 --align=16` are for a backend behind
  (xz, zstd, `zpaq -m5`); `-m6 -l64 --align=1` for `zpaq -m1`, and
  `-m6 -l32 --align=1` without a backend. `-m0`..`-m5` still write v6, and
  `-dup` without `-m` keeps `-m3`. The library's default stays `-m3`.
  Measurements against SREP, REP and Omega are in `docs/scoreboard.md`.
- **Format:** v6 (`OSR6`) and v7 (`OSR7`, `-m6`; frozen in 0.0.15). OSREP does **not** read or write the SREP
  v1-v5 formats, and there is no compatibility goal with upstream SREP.
- **License:** MIT, from the first commit of this branch (`LICENSE`).
- **Platforms:** Linux x86_64, x86 (cross-built and tested) and ARM64
  (cross-built, qemu round-trip); Windows x86/x64 cross-built, tested under
  Wine and on Windows 10 + Windows 7 SP1; macOS ARM64 runs in GitHub Actions.
- **Languages:** Free Pascal for the format, container, CLI, library and
  orchestration; C for the 7-Zip plugin, the CDC chunk scan, the match
  finder and CRC-32C; more C/asm hot paths (SIMD, hashes, prefetch/CPUID)
  in phase 2.

## OREP

**OREP** (`src/orep/`, `src/c/orep_core.c`) is a one-pass **streaming**
long-range dedup that runs in front of a backend compressor. It was written
for PArc as a clean-room MIT replacement for FreeArc's REP, with its own
stream format (`spec/orep-format.md`, version 4, frozen on 2026-11-21).

- **Status: orep-v0.0.11 (pre-release, 2026-11-25).** PArc uses it as its
  long-range stage. The stream format 4 is frozen and pinned by
  `tests/fixtures/orep4/`.
- **API:** a zlib-style Pascal unit (`OrepEnc*`/`OrepDec*`, in/out buffers,
  no callbacks) plus memory-to-memory calls; the decoder can hand out its
  output in place (`OrepDecPeek`/`OrepDecSkip`) and be reused
  (`OrepDecReset`); the decoder is bounded on corrupt input.
- **Threads:** the encoder searches with a pipeline of segments on up to N
  threads, with hooks so a host can lend and take back threads from its own
  budget. The stream is the same with any thread count and on every
  platform.
- **Against REP inside PArc** (0.0.9, 11 inputs, `-m1`…`-m9`, 1 and 4
  threads): the total of every level is smaller than REP's (−0.02 to
  −0.19 %) and only 13 of 198 cases are larger, all by under 0.05 %.
  Compression time ties or wins, including TILIN.tar `-m1` with 4 threads
  (5.71 s, like REP, with less CPU); the decoder stage alone ties REP.
- **Platforms:** Linux x86_64, x86 and ARM64; Windows x64 and x86 (tested on
  Windows 10); macOS ARM64.
- **Docs:** `docs/orep.md` (design, in Spanish), the release notes
  `docs/release-orep-0.0.1.md` … `docs/release-orep-0.0.9.md`, and the wiki
  page *OREP*.

## OSREP priority

The product comes first: finish the v6 preprocessor, the CLI, the encoder
modes and the deduplication engine, and measure them against SREP 3.93a,
Omega SREP 3.0.0 and the zpaq-std/zpaqfranz deduplicator. The library, the
7-Zip plugin and the third-party integrations are frozen until that is done;
see `docs/ROADMAP.md`.

## Library

OSREP is **library-first**: the core is `libosrep`, a shared object with a C
ABI (`include/osrep.h`), and the CLI is a client of the same v6 core. L0 is
in place: `osrep_compress`/`osrep_decompress` in memory, `osrep_free`,
`osrep_options`, a thread-local `osrep_last_error`, and `test_lib.c` against
the header. The library's `.osr` is byte-for-byte the CLI's for the same
options.

```sh
src/lib/build.sh build/lib          # build/lib/libosrep.so (or .dylib/.dll)
cc -Iinclude src/lib/test_lib.c -Lbuild/lib -losrep -o test_lib
./tests/lib.sh                      # C ABI, corpus, threads, CLI comparison
./tests/lib_7z.sh                   # 7-Zip: -m0=OSREP and OSREP+LZMA2
```

`libosrep` is also a **7-Zip codec plugin**, the method `OSREP`, as `pja.so`
is for PJA. Put the library in 7-Zip's `Codecs/` folder (or run the test,
which builds a private copy) and use:

```sh
7z a -m0=OSREP -m1=LZMA2 files.7z files/     # 7-Zip-zstd: -m1=zstd
7z x files.7z                                # needs the plugin
```

OSREP is the preprocessor; LZMA2 (or zstd on 7-Zip-zstd) is the final coder.
The method ID `03 7F 03` is the experimental slot until 7-Zip assigns one.

The API, packaging and integration plan for external projects — the **PJA**
family (**PJA**, **PMPA**, **PRA**, **PPA**, **PAIA**) and **zpaq-std** — are
in `docs/osrep-library.md`. PJA's `libpja` is the model: one shared object, a
C header, the CLI as a client, the 7-Zip plugin, and the same FPC + C + asm
build.

## Where it comes from

OSREP is new code, not a continuation of a codebase. The method and the format
have a history:

- **SREP** — Bulat Ziganshin's huge-dictionary LZ77 **preprocessor**
  (2009–2014, frozen at 3.93a): it produced a match stream for a backend
  compressor; it was never a complete compressor by itself.
- **Omega SREP** — the previous project (1.0–3.0.0) that made a Free Pascal
  port of SREP and designed the v6 container. OSREP keeps the v6 format and
  the lessons, but the implementation is a clean-room rewrite. Omega SREP
  stays in `main` and in the tags up to `v3.0.0` as legacy; it is **not**
  covered by OSREP's MIT license, and its code must not be mixed with this
  branch.

OSREP reads the v6 archives written by Omega SREP 3.0.0
(`tests/fixtures/v6/`), but it does not depend on it to build or run.

## Layout

```
spec/        format-v6.md, payload.md, cli.md (normative)
include/     osrep.h, the C ABI of libosrep
src/pascal/  container, CLI, encoder/decoder, the clean Pascal API
src/lib/     the FPC library, osrep.h's exports, build and test_lib.c
src/c/       CRC-32C, SIMD memops, AES/VMAC, SHA, hot loops (planned)
src/asm/     prefetch, CPUID/HWCAP (planned)
tests/       corpus, golden, v6 read-compatibility fixtures, lib.sh
docs/        plan, native-code rules
```

## Clean room

The implementation is written from `spec/` and `tests/fixtures/` only. The
rules for the implementation session are in `CLEAN-ROOM.md`; the plan is
`docs/clean-room-plan.md`.
