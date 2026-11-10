# OSREP

**OSREP** is a new LZ77 preprocessor for `.osr` streams, built for huge
dictionaries, deterministic output and integrity-checked files. It turns the
input into a compact match/literal stream; it is **not** an entropy coder or an
archiver. The final compression is a separate stage (a backend such as
`zpaq-std`), and OSREP is also meant to be the deduplication engine for that
backend. It is written in Free Pascal with C/asm hot paths, licensed MIT, and
its own format is **v6**: blocks with CRC-32C and a VHASH-128 digest, a footer
that chains the block CRCs, and a CLI for preprocessing, decompression,
verification and inspection.

- **Status: phase 1b (0.0.2).** The v6 reader and the MVP `-m3` preprocessor are
  implemented in `src/pascal/`: container, CRC-32C, VHASH-128 block digest,
  `-d`, `--verify`, `-i`, `-dup` read/restore, and a new hash-chain match finder.
  The tests cover the ten compatibility fixtures in `tests/fixtures/v6/`, the
  encoder round-trip/determinism, `-hash-`, and new golden archives in
  `tests/fixtures/v6-new/`. Every 0.0.x release is a pre-release; 1.0.0 is
  the first stable release. Implementation notes and the open limitations are
  in `docs/implementation-notes.md`.
- **Format:** v6 only (`OSR6`). OSREP does **not** read or write the SREP
  v1-v5 formats, and there is no compatibility goal with upstream SREP.
- **License:** MIT, from the first commit of this branch (`LICENSE`).
- **Platforms (planned):** Linux x86_64/i386/ARM64, Windows x86/x64 (7+),
  macOS 11+ ARM64.
- **Languages:** Free Pascal for the format, container, CLI and orchestration;
  C with intrinsics for CRC/SIMD/hashes; FPC asm for prefetch/CPUID.

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
src/pascal/  container, CLI, encoder/decoder orchestration
src/c/       CRC-32C, SIMD memops, AES/VMAC, SHA, hot loops
src/asm/     prefetch, CPUID/HWCAP
tests/       corpus, golden, v6 read-compatibility fixtures, C/asm differential
docs/        plan, native-code rules
```

## Clean room

The implementation is written from `spec/` and `tests/fixtures/` only. The
rules for the implementation session are in `CLEAN-ROOM.md`; the plan is
`docs/clean-room-plan.md`.
