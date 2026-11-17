# OREP 0.0.2 — encoder threads, the same bytes with any number (pre-release)

**2026-11-17.** OREP now uses several threads in the encoder and gives
**exactly the same stream with any number of threads** (and the same as
0.0.1's format; the matches differ slightly from 0.0.1 because anchors are
now local to 64 KiB segments). Asked by PArc: "like REP but better, making
better use of 4 threads".

## What changed since 0.0.1

- **`P.Threads` / `-t<n>`.** With 2 or more, a coordinator thread runs the
  search with `Threads - 1` workers, while the caller's thread copies the
  input of the next block and writes the output of the previous one. If a
  thread cannot be created OREP goes on with fewer; without a thread
  manager (a Unix program without `cthreads`) it uses the caller's thread
  only. The encoder state must stay at the same address while threads run.
- **The search in four phases**, per batch of 8 segments of 64 KiB:
  anchors per segment (parallel, branch-free), the hash table per shard of
  buckets (parallel; each bucket belongs to one thread and is visited in
  order, so the table ends the same with any split), capped verification
  of the candidates (parallel), and the greedy choice (sequential, cheap;
  full extensions only for accepted matches).
- **Faster single thread too:** the anchor pass has no branches (natural
  anchors first, forced ones merged afterwards) and tests one mask.
- The encoder ring has one slot more than a decoder needs (the caller's
  thread fills the next slot while the search may still read the oldest).

## Numbers

Wall time, Xeon E5 v4 shared with other jobs, best of 3, `tilin_512m.tar`
(PArc's corpus), `-w96m`:

| | 1 thread | 4 threads | 8 threads | REP (FreeArc'Next, ~5 threads) |
|---|---:|---:|---:|---:|
| `-l512` | 1.5 s | **0.57 s** | 0.53 s | 0.77–0.81 s (`rep:96m`) |
| `-l256` | 1.7 s | **0.70 s** | 0.62 s | 0.73 s (`rep:96m:256:c256`) |
| `-l64` | 3.2 s | 1.46 s | 1.4 s | — |

Whole `TILIN.tar` (1.86 GB), `-l512 -t4`: 2.33 s and 1,343,009,625 bytes
out, vs 2.54 s and 1,415,525,869 for REP 96m, with 155 MB of RSS vs 245 MB.

And the size is not given back: whole `TILIN.tar` followed by the lzma of
`parc -m4` (`lzma:96m:normal:16:mc8:lc4`, run as `xz --format=raw --lzma1=...`):

| | before lzma | after lzma | vs REP |
|---|---:|---:|---:|
| REP `rep:96m` | 1,415,525,869 | 1,017,365,357 | |
| OREP `-l512` | 1,343,009,625 | 1,014,676,387 | **−0.26%** |
| OREP `-l256` | 1,324,284,629 | 1,014,652,985 | **−0.27%** |
| OREP `-l64` | 1,270,940,001 | 1,012,323,242 | **−0.50%** |

`-l64` (the default, best ratio in front of a normal-mode lzma) is slower:
its table has an entry every ~8 bytes and scales poorly across the two
sockets of this machine; in those presets lzma takes about a hundred times
longer than OREP anyway.

## Tests

`tests/orep.sh` adds: the same bytes with `-t2`, `-t3`, `-t4`, `-t8` and the
reference build with `-t3`, against `-t1`, on three inputs and three option
sets. The rest as in 0.0.1 (round trips, native == reference, ring wrap,
stdin/stdout, memory limit, 300 corrupt or truncated streams).
WINDOWS_LINE

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.2.tar.gz` (the Pascal unit, the C core and its object per
Linux/Windows target), `SHA256SUMS`.

## Limitations

- Format version 1 is still a draft.
- Thread placement is left to the OS; on a two-socket machine `-l64`
  scales less than `-l256`/`-l512`.

## License

MIT.
