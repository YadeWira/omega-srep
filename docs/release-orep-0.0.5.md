# OREP 0.0.5 — thread budget hooks (pre-release)

**2026-11-18.** For programs with a global thread budget (PArc's
`PARC_THREADS`). **Same stream format as 0.0.4 (version 3)** and the same
bytes.

## What changed since 0.0.4

- **`P.OnWorkerBusy` / `P.OnWorkerIdle` / `P.HookCtx`** (optional, nil by
  default). OREP's own threads (the workers and the coordinator) call
  `OnWorkerBusy(HookCtx)` when they start working and `OnWorkerIdle(HookCtx)`
  before they block waiting, so the caller can take and give back one token
  per thread. The short spin between the jobs of a block counts as busy.
  `OnWorkerBusy` may block until a token is free: a worker joins a job only
  while the job still has items, so the search never waits for a thread
  that has not joined, and the output stays the same.
- The worker pool hands jobs out under a lock (join while open, close when
  every item is taken); no measurable change in speed.
- The unit package (`orep-unit-0.0.5.tar.gz`) now includes `orep.md`
  (design, API, measurements, suggested settings) and `orep_api.lpr` (an
  API test that shows every call: threads, hooks, reset, flush).

## Tests

`tests/orep_api.lpr` adds a token budget: 5 threads and 2 tokens, with
`OnWorkerBusy` waiting for a free token. It checks that the stream is the
same, that no more than 2 threads are ever busy, and that every Busy has its
Idle. It runs with 1, 3 and 5 threads, native and reference, in
`tests/orep.sh` and in the macOS workflow, together with the rest (round
trips, native == reference, ring wrap, the same bytes with 1 to 8 threads,
`-c1`, stdin/stdout, memory limit, 300 corrupt or truncated streams).
WINDOWS_LINE

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.5.tar.gz`, `SHA256SUMS`.

## License

MIT.
