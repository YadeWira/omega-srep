# OREP 0.0.3 — more candidates per anchor, alignment per block (pre-release)

**2026-11-18.** Better compression at about the same speed. **Stream format
version 2**: version 1 streams (0.0.1, 0.0.2) are not read; the format is
still a draft.

## What changed since 0.0.2

- **Up to four candidates per anchor (`-c`, default 4).** The hash table
  keeps several copies of a gram; the verification (parallel) compares each
  candidate's forward match up to 256 bytes and keeps the longest (the
  newest on a tie). `-c1` keeps one entry per gram and gives 0.0.2's
  matches.
- **Alignment per block (`-a0`, the new default).** Each block is aligned
  to 1 when ~4096 bytes spread over it are 90% printable ASCII/tab/CR/LF
  (text) and to 4 otherwise (lzma's pb2); the value goes in the block
  header (format version 2). A fixed `-a<n>` still works.
- **`OrepEncReset`**: a new stream with the same parameters, keeping the
  memory and the threads (the same bytes as a new state).
- **`tests/orep_api.lpr`**: the API with input in small pieces and tiny
  output buffers, `OrepEncReset`, `OREP_FLUSH`, whole buffers and the
  decoder's memory limit, native and reference, 1 to 3 threads.

## Numbers

Against REP (`-mrep:96m`), each output followed by the lzma of `parc -m4`
(`lzma:96m:normal:16:mc8:lc4`, run as
`xz --format=raw --lzma1=dict=96MiB,lc=4,lp=0,pb=2,mode=normal,nice=16,mf=hc4,depth=8`),
OREP with `-w96m`:

| corpus | REP | OREP 0.0.3 (defaults, `-l64`) | OREP 0.0.3 `-l32` |
|---|---:|---:|---:|
| zpaqstd-history.tar | 6,330,866 | 6,196,536 (**−2.12%**) | 6,130,784 (**−3.16%**) |
| versions.tar | 5,440,237 | 5,367,412 (**−1.34%**) | 5,317,780 (**−2.25%**) |
| silesia.tar | 54,769,356 | 54,158,366 (**−1.12%**) | 53,963,072 (**−1.47%**) |
| enwik8 | 30,338,496 | 30,232,499 (**−0.35%**) | 29,997,573 (**−1.12%**) |
| game-assets.tar | 303,520,426 | 303,280,014 (**−0.08%**) | 303,508,638 (−0.00%) |
| tilin_512m.tar | 255,185,911 | 254,908,393 (**−0.11%**) | 255,183,951 (−0.00%) |

0.0.2 with its defaults: −1.31%, −0.85%, −0.80%, −0.25%, −0.05%, −0.03%.

- More candidates beat more anchors: `-s16` (four times the anchors and
  the table) gave −0.30% / −0.30% / −0.17% / −0.02% on silesia / history /
  versions / enwik8, four candidates −0.27% / −0.41% / −0.25% / −0.03% with
  the same anchors.
- With the alignment per block `-l32` no longer loses on binaries (0.0.2's
  `-l32 -a1` was +0.55% on silesia).

Speed, 4 threads, best of 5 interleaved runs on a shared machine,
`tilin_512m`, `-l512`: 0.0.2 0.55 s, 0.0.3 0.65 s (`-c1 -a4`: 0.59 s),
REP 0.77–0.83 s. `-l64` costs about 4 times `-l512` and `-l32` about 8
times, mostly in the hash table.

Suggested settings for PArc: `-l256 -c1` or `-l512` for its fast presets;
the defaults (`-l64`) in front of a normal-mode lzma, or `-l32` when there
is time (text-heavy data gains the most); `-l512 -s16` in front of
`lzma:max` with a dictionary smaller than the window.

## Tests

`tests/orep.sh` (round trips, native == reference, ring wrap, the same
bytes with 1 to 8 threads and with `-c1`, stdin/stdout, memory limit, 300
corrupt or truncated streams) and `tests/orep_api.lpr`.
The six binaries give the same stream with `-t1` and `-t4` (qemu for arm64,
wine, and a real Windows 10 for x64 and x86: three files × three option
sets × two thread counts, round trips).

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.3.tar.gz` (the Pascal unit, the C core and its object per
Linux/Windows target), `SHA256SUMS`.

## Limitations

- Format version 2 is a draft; it can still change.
- `-l64` and `-l32` are slower than REP in wall time (the hash table is
  memory-bound); in the presets where they pay off, lzma takes far longer.

## License

MIT.
