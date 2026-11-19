# OREP 0.0.8 — verify only the anchors select looks at (pre-release)

**2026-11-19.** For PArc's remaining gap with `-m1`/`-m2`: when the thread
budget is full, OREP runs inline with one thread, so its one-thread speed
is what counts. **Same stream format (version 3) and the same bytes as
0.0.7.**

## What changed since 0.0.7

- **Verify inside select.** Until 0.0.7, verify was a stage of its own:
  - it checked every anchor's candidates, in parallel;
  - select then skipped the anchors inside a match it had already chosen.

  In redundant data most anchors are inside such a match. Now select
  verifies each anchor just before it looks at it (`orep_vselect`), so
  those anchors are never verified. The choice is the same, so the
  stream is the same.
- **The pipeline has three stages:**
  - anchors, on any thread;
  - probe, in order on the driving thread;
  - verify + select, in order.

  The memory per segment slot drops from 40 to 28 bytes per position.
- **No lock with no helpers.** With one thread, or with
  `OnWorkerTryBusy` and no free token, `SearchBlock` runs the three stages
  in turn without the lock.
- `orep_verify` and `orep_select` are no longer exported by `orep_core.c`;
  `orep_vselect` replaces them. The Pascal reference keeps them as
  helpers.

## Numbers

Encoder, `TILIN.tar` (1.8 GB), `-w96m`, CLI, best of 3, interleaved;
wall / CPU seconds:

| | 0.0.7 | 0.0.8 |
|---|---:|---:|
| `-l256 -c1 -t1` | 5.15 / 5.10 | **4.21 / 4.15** |
| `-l256 -t1` | 5.80 / 5.74 | **4.44 / 4.38** |
| `-l64 -t1` | 16.76 / 16.70 | **8.94 / 8.90** |
| `-l256 -c1 -t4` | 1.99 / 8.64 | **1.80 / 7.85** |
| `-l256 -t4` | 2.17 / 9.56 | **1.96 / 8.59** |
| `-l64 -t4` | 8.17 / 33.60 | **6.52 / 27.14** |

With a thread budget (`tools/scoreboard/orep_budget_bench.lpr`,
`tilin_512m.tar`, `-l256`, 4 tokens, `TryBusy` + caller hooks +
`SpinUs 200`), wall seconds:

| | 0.0.7 | 0.0.8 |
|---|---:|---:|
| 4 encoders on a full budget | 2.09–2.17 | **1.62–1.67** |
| 4 encoders, inline (`Threads = 1`) | 2.02–2.16 | **1.67–1.69** |
| 1 encoder with free tokens | 0.72–0.81 | **0.71** |

The decoder is unchanged.

## Tests

`tests/orep.sh` passes, as before:
- round trips, and native == reference;
- ring wrap;
- the same bytes with 1 to 8 threads;
- `-c1`;
- the API with threads, hooks and `TryBusy`;
- stdin/stdout;
- memory limit;
- 300 corrupt or truncated streams.

On `tilin_512m`, the bytes are the same as 0.0.7's with
`-l256`, `-c1`, `-l64`, `-l32 -b64k -w1m` and `-l512 -c2 -s8`, each with
`-t1`, `-t3` and `-t4`.
The six binaries give the same stream as 0.0.7 with `-t1`, `-t4 -y0`
and `-l32 -b64k -w1m -t3`, with round trips. They were run on the host
(x86_64 and x86), under qemu (arm64), under wine, on a real Windows 10
(x64 and x86), and in the macOS CI (the whole test suite).

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.8.tar.gz`, `SHA256SUMS`.

## License

MIT.
