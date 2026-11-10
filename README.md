# OSREP

**OSREP** is a clean-room, MIT-licensed implementation of the `.osr`
huge-dictionary LZ77 compressor. It is the successor of the previous
**Omega SREP** project, restarted with new code and a single format: **v6**.

- **Status: phase 1b (0.0.2).** The v6 reader and the MVP `-m3` encoder are
  implemented in `src/pascal/`: container, CRC-32C, VHASH-128 block digest,
  `-d`, `--verify`, `-i`, `-dup` read/restore, and a new hash-chain encoder.
  The tests cover the ten compatibility fixtures in `tests/fixtures/v6/`, the
  encoder round-trip/determinism, `-hash-`, and new golden archives in
  `tests/fixtures/v6-new/`. Every 0.0.x release is a pre-release; 1.0.0 is
  the first stable release. Implementation notes and the open limitations are
  in `docs/implementation-notes.md`.
- **Format:** v6 only (`OSR6`). OSREP reads the v6 archives written by the
  legacy Omega SREP 3.0.0; it does **not** read or write the SREP v1-v5
  formats, and there is no compatibility goal with upstream SREP.
- **License:** MIT, from the first commit of this branch (`LICENSE`).
- **Platforms (planned):** Linux x86_64/i386/ARM64, Windows x86/x64 (7+),
  macOS 11+ ARM64.
- **Languages:** Free Pascal for the format, container, CLI and orchestration;
  C with intrinsics for CRC/SIMD/hashes; FPC asm for prefetch/CPUID.

## Legacy

The previous project, **Omega SREP 3.0.0**, lives in the `main` branch and in
the tags up to `v3.0.0`, with its releases. It is a derivative of SREP 3.93a
and is **not** covered by OSREP's MIT license. It is kept for history and for
reading its v6 archives; do not mix its code with this branch.

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
