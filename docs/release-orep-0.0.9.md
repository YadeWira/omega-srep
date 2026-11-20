# OREP 0.0.9 — a faster single thread, and no remaining losses against REP (pre-release)

**2026-11-20.** For the last gaps in PArc's matrix against REP with 0.0.8:
- 36 cases where the output was larger than REP's, all under 0.1 % and most
  of them at `-m1`/`-m2`;
- TILIN.tar `-m1` with 4 threads, 8 % slower than REP. OREP runs inline
  when PArc's thread budget is full;
- more memory.

**Same stream format (version 3).** The bytes change: the encoder finds
more matches (the period candidate) and the anchor table has another size.

## What changed since 0.0.8

- **Faster single-thread search, same bytes as 0.0.8:**
  - Anchor pass 1 builds a 64-position mask with `cmp`/`adc` and then
    takes its set bits in order. This is x86_64 inline asm, used only with
    sparse anchors (one in 16 or fewer); with `-l16` the plain loop is
    faster.
  - The probe has a fast path for the common case: no entry in the bucket
    has the anchor's tag.
  - The probe lists the anchors that select must look at, so select (with
    its verification) walks only that list.
- **The period at forced anchors.** A forced anchor (`4s` positions with no
  content-defined one) is placed by position. In a run or a short period
  the table can only offer it a multiple of `4s`, or nothing, so repeats
  of 256–384 bytes were lost. It now tries the period of its gram first
  (the smallest `p` from 1 to 16 with the same gram `p` bytes before), and
  the period wins a tie. This is encoder-only; the decoder already handles
  overlapping copies.
- **`P.RunKeep` (CLI `-r<n>`, default 0):** a match that only covers a run
  of one byte and is shorter than `n` is left as literals. tor or lz4 code
  such a run almost for free, and the match costs more. With lzma behind it
  does not help, so it is off by default. PArc uses `r512` at `-m1`/`-m2`.
- **Memory:**
  - The anchor table has one bucket per four expected anchors, rounded up
    to a multiple of 64 instead of to a power of two; the bucket comes from
    a multiply.
  - The encoder ring keeps its spare slot only with `Threads >= 2`.
    `OrepEncMemory` still counts the slot, since a caller may estimate with
    one thread and start with more.
- A verification stops at the first candidate that reaches the compared
  length: later candidates can only tie, and a tie keeps the earlier one.
  This gives the same output.
- `orep_core.c` exports `orep_probe` (now it also returns the list) and
  `orep_vselect` (now it takes the list); the old forms are gone.

## Numbers

OREP CLI, `tilin_512m.tar`, `-w96m -t1`, best of 5 interleaved, CPU seconds
(same bytes as 0.0.8):

| | 0.0.8 | 0.0.9 |
|---|---:|---:|
| `-l256 -c1` | 1.17 | **0.94** |
| `-l256` | 1.30 | **1.08** |
| `-l512` | 1.02 | **0.81** |
| `-l64` | 2.67 | **2.47** |

Inside PArc, with presets `orep:96m:l256:c2:r512` at `-m1`,
`orep:96m:l256:r512` at `-m2` and the others unchanged.

Sizes over PArc's matrix: 10 sets plus `tilin_512m.tar`, `-m1`…`-m9`, 1 and
4 threads, 198 cases (TILIN.tar not included):
- **13 cases** are larger than with REP (0.0.8: 36), all under 0.05 %;
- the total of every level is smaller than REP's (−0.02 to −0.19 %) and
  than 0.0.8's (−0.00 to −0.02 %).

TILIN.tar `-m1`, 4 threads, best of 3 interleaved:

| | REP | OREP 0.0.8 | OREP 0.0.9 |
|---|---:|---:|---:|
| size | 1,091,769,654 | 1,091,594,474 | **1,091,576,066** |
| compression wall / CPU, s | 5.71 / 21.85 | 6.05 / 21.64 | **5.71 / 20.69** |
| decompression wall, s | 3.22 | 3.39 | 3.35 |

Other cases at 4 threads (compression wall, REP → 0.0.9):
- `tilin_512m` `-m2`: 4.48 → 4.43 s;
- `large` `-m1`: 0.68 → 0.63 s;
- `document` `-m3`: 5.82 → 3.68 s;
- `text` `-m5`: 12.71 → 8.94 s.

With one thread, `tilin_512m` `-m1` takes 7.38 s with REP and 6.66 s with
0.0.9. The OREP stage alone uses less memory than REP. PArc's peak RSS with
4 threads is still higher, because PArc keeps the stage until the chain ends
and runs more 4x4 jobs at once while OREP finishes early. Those are PArc
changes, proposed to PArc.

## Tests

`tests/orep.sh` passes. It adds a generated file of runs and short periods
(round trips with `-r`, native == reference, same bytes with 1 to 8
threads). The rest is as before:
- round trips, and native == reference;
- ring wrap;
- the API with threads, hooks and `TryBusy`;
- stdin/stdout;
- memory limit;
- 300 corrupt or truncated streams.

The six binaries give the same stream as the Linux x86_64 one with `-t1`,
`-t4 -y0`, `-l32 -b64k -w1m -t3` and `-l256 -c2 -r512 -t2`, with round
trips. They were run on the host (x86_64 and x86), under qemu (arm64),
under wine, on a real Windows 10 (x64 and x86), and in the macOS CI (the
whole test suite).

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.9.tar.gz`, `SHA256SUMS`.

## License

MIT.
