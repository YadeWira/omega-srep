# OREP 0.0.6 — threads that respect a full thread budget (pre-release)

**2026-11-18.** Follow-up to PArc's measurements with 0.0.5: with a global
thread budget, OREP with threads was slower than OREP inline, because its
workers spun with their token held between jobs and the caller's thread
waited for the search with its own token held. **Same stream format
(version 3) and the same bytes as 0.0.5.**

## What changed since 0.0.5

All new fields are optional; with them unset OREP behaves as in 0.0.5.

- **`P.SpinUs`** (CLI `-y<us>`): how long an idle OREP thread spins (then
  yields) before it calls `OnWorkerIdle` and sleeps, in microseconds.
  Default 2000 (about what 0.0.5 did); 0 = give the token back at once.
- **`P.OnCallerWaitBegin` / `P.OnCallerWaitEnd`**: called by the caller's
  thread around its waits for the search inside `OrepEncRun`,
  `OrepEncReset` and `OrepEncEnd`, only when it would block, so it can give
  its token back meanwhile. **If the caller holds a token and the budget
  can run out, set them (or `OnWorkerTryBusy`)**: otherwise the caller
  waits for a coordinator that waits for the caller's token (reproduced
  with 4 encoders sharing 4 tokens).
- **`P.OnWorkerTryBusy`** (`function(Ctx): Boolean`, never blocks): with it
  no OREP thread ever waits for a token. As each block starts, the
  caller's thread asks for a token for the coordinator, and searches the
  block itself if there is none. As each batch of 8 segments starts, the
  searching thread asks for tokens for its helpers, wakes only those,
  splits the batch into that many shards (the hash table ends the same
  with any split) and gives the tokens back when the batch ends. With a
  full budget the encoder works like `Threads = 1`; with free tokens it
  uses them.
- **Fix:** `OrepEncEnd` freed the
  ring and the hash table before waiting for a search still in flight. It
  now waits first. This affected only callers that ended an encoder in the
  middle of a stream with `Threads >= 2` (0.0.4 and 0.0.5).

## Numbers

`tools/scoreboard/orep_budget_bench.lpr`: N encoders at once on `tilin_512m.tar` (`-w96m -l256`),
sharing 4 tokens, each caller's thread holding one; wall seconds, two runs
on a shared Xeon:

| | 1 thread (inline) | 4 threads, Busy + caller hooks, `SpinUs 2000` | 4 threads, `SpinUs 0` + caller hooks | 4 threads, `TryBusy` + caller hooks, `SpinUs 200` |
|---|---:|---:|---:|---:|
| 4 encoders (full budget) | 1.97–2.12 | 4.72–5.00 | 2.82–2.90 | **2.03–2.08** |
| 1 encoder (free tokens) | 1.66–1.89 | 1.22 | 1.54–1.73 | **1.15–1.24** |

The CLI (no hooks) is as fast as 0.0.5: `-w96m -t4` on `tilin_512m`,
`-l512` 0.60–0.73 s vs 0.60–0.72 s, `-l64` 2.66–2.75 s vs 2.60–2.66 s.

Suggested for PArc: `Threads = 4`, `OnWorkerTryBusy`, both caller hooks,
`SpinUs = 200`.

## Tests

`tests/orep_api.lpr` adds:
- the caller hooks with `SpinUs = 0` and 3 tokens shared by the caller and
  OREP's threads;
- `OnWorkerTryBusy` with 1 token (every block inline) and with 2;
- an encoder ended in the middle of a stream with a search in flight.

Each case checks the same stream, never more threads busy than tokens,
and balanced Busy/Idle and Begin/End calls. The rest is as before:
- round trips, and native == reference;
- ring wrap;
- the same bytes with 1 to 8 threads;
- `-c1`;
- stdin/stdout;
- memory limit;
- 300 corrupt or truncated streams.

On `tilin_512m`, three option sets give the same bytes as 0.0.5.

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.6.tar.gz`, `SHA256SUMS`.

## License

MIT.
