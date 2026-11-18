# OREP 0.0.4 — half the memory with big windows, compact header (pre-release)

**2026-11-18.** Fixes from an audit of where OREP lost against REP
(`docs/orep-audit-2026-11-18.md`). **Stream format version 3** (version 2
streams from 0.0.3 are not read; the format is still a draft). The matches
are the same as 0.0.3's.

## What changed since 0.0.3

- **Ring in slots.** The window ring is an array of chunk-sized slots, each
  allocated when first used, instead of one block grown by doubling with
  `ReAllocMem` (whose peak held the old and the new block, and copied it).
  Comparisons and match copies cross slots; a block stays inside one. The
  chunk (`-b`) must now be a power of two.
- **Compact stream header and end** (format version 3): magic, version,
  log2 of the chunk, varints (window, alignment setting, minimum length)
  and a CRC-32C; the end marker's total is a varint. The fixed cost per
  stream goes from 37–49 bytes to 19–32 (REP's format: ~20).

## Numbers

Whole `TILIN.tar` (1.86 GB), 1 GB window:

| | 0.0.3 | 0.0.4 | REP `rep:1024m` |
|---|---:|---:|---:|
| decoder RSS / time | 2.17 GB / 2.6 s | **1.06 GB / 1.5 s** | 1.06 GB / 1.8 s |
| encoder RSS (`-l512 -s16`) | 2.64 GB | **1.60 GB** | 1.32 GB |

512 MB window, game assets: decoder 1.07 GB / 1.10 s → **533 MB / 0.58 s**
(REP 537 MB / 0.58 s). 96 MB window, silesia: decoder 135 → **107 MB**,
0.21 s (REP 111 MB, 0.22 s). The encoder's remaining difference is its hash
table.

Updated suggestions for PArc's presets (measured against REP, see the
audit):

- **fast** (`rep:96m:256:c256` today): `-w96m -l256 -c1` takes the same
  time as REP (0.67 s vs 0.68 s on tilin_512m, 4 threads) and wins on
  silesia, history and enwik8, ties versions, loses pja (+0.20%) behind a
  fast lzma; `-l128 -c1` wins all five (−0.12% to −1.12%) in 1.6 times the
  time.
- **normal lzma** (`-m3`..`-m5`): the defaults (`-l64`), or `-l32`.
- **`lzma:max`** (`-m6`..`-m9`): `-w<window> -l512 -s8 -a4` (with four
  candidates `-s8` is enough; 0.97 s vs 1.38 s with `-s16`, REP 0.79 s):
  silesia −0.49%, history −0.03%, pja +0.01%, versions +0.04% against REP.

## Tests

`tests/orep.sh` and `tests/orep_api.lpr` (round trips, native ==
reference, ring wrap with 64 KiB windows, the same bytes with 1 to 8
threads and with `-c1`, the API in small pieces, reset, flush, memory
limit, 300 corrupt or truncated streams). 0.0.4 gives the same matches as
0.0.3 (only the header and the end differ).
The six binaries give the same stream with `-t1` and `-t4` (qemu for arm64,
wine, and a real Windows 10 for x64 and x86: three files × three option
sets × two thread counts, round trips).

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.4.tar.gz`, `SHA256SUMS`.

## Limitations

- Format version 3 is a draft.
- `-l64` / `-l32` encode slower than REP (the hash table is memory-bound);
  in the presets where they pay off, lzma takes far longer.

## License

MIT.
