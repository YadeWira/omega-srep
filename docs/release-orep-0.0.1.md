# OREP 0.0.1 — streaming long-range dedup, a REP replacement (pre-release)

**2026-11-17.** First release of **OREP**, a one-pass streaming long-range
dedup that goes in front of a backend compressor (lzma, zstd...). It was
written for **PArc** as an MIT replacement for FreeArc's REP (GPL):
clean-room (neither `rep.cpp` nor `srep.cpp` was read), with its own format.
OREP lives in the OSREP repository but has its own release line
(`orep-vX.Y.Z`). Pre-release: the stream format (`spec/orep-format.md`,
version 1) is a draft and can still change.

## What it is

- **Streaming, one pass.** The input goes through a ring of
  `ceil(W/C)*C + C` bytes (window W up to ~3.75 GB, block C 4 MiB by
  default); each block is searched against the whole window and written with
  its match columns first, the literals and a CRC-32C.
- **Content-defined anchors** (gear hash) looked up in a 4-way bucketed
  table, matches verified and extended both ways; a match that reaches the
  end of a block continues in the next one.
- **Alignment for the backend.** Match lengths are a multiple of `-a`
  (default 4) and the block is padded so that every literal keeps its input
  position modulo `-a`, which lzma's position contexts (pb2) use.
- **Bounded decoder.** Every block is validated before anything is copied,
  and its output is released only after the CRC check; corrupt data never
  makes it read or write outside its ring. A memory limit rejects streams
  that need more.
- **Deterministic.** The same parameters give the same bytes on every
  platform; the C core and the Pascal reference (`-dOREP_NO_NATIVE`) give
  the same stream.
- **API** (`src/orep/orep.pas`): zlib style (`OrepEncRun`/`OrepDecRun` with
  in/out buffers and `OREP_RUN`/`OREP_FLUSH`/`OREP_FINISH`), whole-buffer
  helpers, memory estimates for a limiter, no callbacks, no global mutable
  state (one state per thread).

## Numbers

Against REP from FreeArc'Next 0.11 (`-mrep:96m`, its default minimum length
512), each output compressed with the lzma of `parc -m4`
(`lzma:96m:normal:16:mc8:lc4`, run as
`xz --format=raw --lzma1=dict=96MiB,lc=4,lp=0,pb=2,mode=normal,nice=16,mf=hc4,depth=8`);
OREP with `-w96m` and its defaults (`-l64 -a4`):

| corpus | no preprocessor | REP | OREP | vs REP |
|---|---:|---:|---:|---:|
| zpaqstd-history.tar | 6,475,595 | 6,330,866 | 6,247,803 | **−1.31%** |
| versions.tar | 5,474,742 | 5,440,237 | 5,393,973 | **−0.85%** |
| silesia.tar | 54,704,070 | 54,769,356 | 54,333,022 | **−0.80%** |
| enwik8 | 30,339,891 | 30,338,496 | 30,261,237 | **−0.25%** |
| pja.tar | 1,371,469 | 1,361,970 | 1,360,143 | **−0.13%** |
| game-assets.tar | 303,578,873 | 303,520,426 | 303,365,351 | **−0.05%** |
| tilin_512m.tar | 255,466,616 | 255,185,911 | 255,097,990 | **−0.03%** |

On text and multi-version data `-l32 -a1` does better (history −1.90%,
versions −1.44%, enwik8 −0.98%, pja −0.56%) but loses on binaries.

With a strong lzma behind (`parc -m7`: `lzma:64m:max`, bt4 nice 273)
short matches only get in the way. Against `-mrep:512m`, OREP `-l512 -a4`:
silesia **−0.47%**, tilin **−0.03%**, versions +0.11%, history +0.13%;
with `-s16` (denser anchors) versions +0.05% and history −0.00% (ties).

Suggested settings for PArc: `-w96m -l256` for its fast presets,
`-w96m -l64 -a4` (text: `-l32 -a1`) in front of a normal-mode lzma
(`-m3`..`-m5`), `-l512 -a4 -s16` in front of `lzma:max` (`-m6`..`-m9`).

- **Speed, one thread** (Xeon E5 v4): `-l64` 1.5 s of CPU for silesia
  (212 MB), 4.2 s for game-assets (584 MB); `-l512` about 290 MB/s. REP uses
  a similar amount of CPU but spreads it over ~4 threads, so it is faster in
  wall time: **threads are the next step for OREP**.
- **Decoder:** 0.7–1 GB/s of output.
- **Memory** (`-w96m`): encoder ~270 MB with `-l64`, ~150 MB with `-l512`;
  decoder ~135 MB.

Details and method: `docs/orep.md`.

## Files

- `orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
  `orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`:
  the CLI (`orep [options] in out`, `orep -d in out`, `-` = stdin/stdout).
- `orep-unit-0.0.1.tar.gz`: `orep.pas`, `orep_core.c` and the core object
  for each Linux/Windows target, to link OREP into a Free Pascal program.
- `SHA256SUMS`.

All binaries give the same stream for the same input and options.

## Tests

`tests/orep.sh`: round trips with several parameter sets (including 64 KiB
windows that wrap the ring many times), native == reference byte for byte,
stdin/stdout, the memory limit, and 300 truncated or corrupted streams (none
crashes the decoder or decodes to wrong data). Run on Linux x86_64 and in the
macOS arm64 workflow. The five Linux/Windows binaries give the same
stream hashes under qemu and wine, and on a real Windows 10 (x64 and x86:
three files × three option sets, round trips and `-d` to stdout).

## Limitations

- One thread.
- Format version 1 is a draft until it is frozen.
- The best `-l`/`-a`/`-s` depend on the data and on the backend (see
  above); the defaults are for a normal-mode lzma.

## License

MIT.
