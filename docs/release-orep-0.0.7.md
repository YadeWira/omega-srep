# OREP 0.0.7 — a search pipeline without barriers, a faster decoder path (pre-release)

**2026-11-18.** For PArc's two remaining gaps against REP: CPU with threads
in the fast presets, and decoder speed. **Same stream format (version 3)
and the same bytes as 0.0.6.**

## What changed since 0.0.6

- **Encoder: a pipeline of segments instead of barriers.** Until 0.0.6, a
  block was searched in batches of 8 segments of 64 KiB:
  - anchors, table and verify each ran with a barrier between them, the
    table split into shards of buckets;
  - select came after.
  With 8 items per phase the threads waited for each other, and with 4
  threads the CPU was 2.3 times that of one.

  Now up to `2 × threads + 2` segments are in flight, and each thread takes
  the most urgent task under a lock:
  - the next segment's probe (only the thread driving the search does it,
    so the hash table stays in its caches and near its memory; probing
    from every thread took twice as long);
  - the next select;
  - a verify;
  - or the anchors of a new segment.

  The probes and the selects run in segment order, so the table and the
  stream are the same as with one thread. An idle thread spins `SpinUs`,
  then sleeps until a task ends. Less memory too: no shard lists.
- **`OnWorkerTryBusy`**: the helpers' tokens are now asked for once per
  block, not per batch.
- **CRC-32C** with SSE4.2 runs three streams at once (2.5 times faster).
  The decoder checks each block with it and the encoder computes it.
- **Decoder without the output copy**:
  - `OrepDecPeek(D, NextIn, AvailIn, Data, Count)` decodes until checked
    output is ready and points `Data` at it, in the decoder's memory;
  - `OrepDecSkip(D, N)` marks `N` bytes as used.
- **`OrepDecReset(D)`**: a new stream that keeps the memory when the chunk
  and the ring size are the same, so no page faults to fill a new ring.
- Fix: after `OrepDecReset` to a stream with another window, the column
  buffer was used after being freed. This never shipped; the API test
  found it.

## Numbers

Encoder, `tilin_512m.tar`, `-w96m`, CLI (`SpinUs` 2000), best of 3,
interleaved; wall / CPU seconds:

| | 0.0.6 | 0.0.7 |
|---|---:|---:|
| `-l256 -c1 -t1` | 1.44 / 1.43 | 1.48 / 1.47 |
| `-l256 -c1 -t2` | 0.90 / 2.05 | **0.78 / 1.90** |
| `-l256 -c1 -t4` | 0.86 / 3.68 | **0.64 / 2.78** |
| `-l256 -t4` | 0.92 / 3.95 | **0.63 / 2.76** |
| `-l512 -t4` | 0.66 / 2.92 | **0.47 / 2.13** |
| `-l64 -t4` | 2.48 / 10.04 | **2.16 / 8.91** |

With a thread budget (`tools/scoreboard/orep_budget_bench.lpr`, `-l256`,
4 tokens, `TryBusy` + caller hooks + `SpinUs 200`):
- 1 encoder with free tokens: 0.84 s (0.0.6: 1.15–1.24; inline 1.7);
- 4 encoders on a full budget: the same time as inline (2.02–2.07 vs
  1.96–2.05).

Decoder, in memory, `tilin_512m` `-l256 -c1` (best of 5, ms):

| 0.0.6 `Run` | 0.0.7 `Run` | 0.0.7 `Peek` | 0.0.7 `Peek` + `Reset` |
|---:|---:|---:|---:|
| 258–280 | 269–286 | 191–205 | **145–165** |

The CRC gain with `Run` is within the noise of a shared machine.

## Tests

`tests/orep_api.lpr` adds the decoder with `Peek`/`Skip` in uneven pieces,
and `OrepDecReset` to a stream with the same window and then another.
The rest is as before:
- round trips, and native == reference;
- ring wrap;
- the same bytes with 1 to 8 threads;
- `-c1`;
- the API with threads and hooks;
- stdin/stdout;
- memory limit;
- 300 corrupt or truncated streams.

The bytes on `tilin_512m` are the same as 0.0.6's.

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.7.tar.gz`, `SHA256SUMS`.

## License

MIT.
