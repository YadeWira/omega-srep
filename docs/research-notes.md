# Omega SREP — Research notes

Living document of historical context, references, and ideas inherited
from upstream SREP that have not yet been implemented in the Omega fork.

## The "data reordering" variant Bulat Ziganshin mentioned but never released

### What we know

In old discussions on `encode.su` (the compression community forum
where Bulat Ziganshin was active), Bulat referred to **an unpublished
SREP version that implemented "data reordering" to reduce the RAM cost
of Future-LZ decompression**. The release never made it out — it stayed
in private or experimental state, and the freearc.org Mercurial
repository went offline before any 4.x build was published.

We could not find the original thread quoted verbatim (`encode.su`
returns HTTP 403 to automated fetchers, requiring manual reading or an
`archive.org` snapshot). The reference came up second-hand in search
result excerpts; we did not confirm it from the source post.

### Why it matters

Bulat's own follow-up project, FA 0.11 (October 2016), demonstrates how
much memory can be saved by adjusting the dedup strategy. From the FA
0.11 release notes:

> *"In my experiment with compression of 4.7 GB, `-m4 -dup` produced
> archive 4% larger than `-m4`, but decompression memory was dropped
> from 735 to 179 MB."*

That's a **~75% reduction in decompression-time RAM** for a small
(<5%) cost in archive size. SREP's Future-LZ — which keeps all
upcoming matches in RAM until they are consumed — is exactly the
algorithm this kind of trick targets.

### Plausible implementation directions for Omega

Without Bulat's original prototype, our best guesses (all unverified):

1. **Match-distance-aware reordering.** Sort the LZ match heap so that
   short-lived matches (small `dest - src` gap) are emitted first, and
   long-lived ones (big gap) are batched against a disk-backed heap.
   Today the `VIRTUAL_MEMORY_MANAGER` in `decompress.cpp` already
   spills to disk when memory pressure rises — reordering would change
   *what* gets spilled, not *whether* spilling happens.

2. **Block-permutation at compress time.** Reorder the input blocks so
   that long-distance matches collapse into local ones. The format
   would need to record the permutation; decompression undoes it as a
   final pass. This is closer in spirit to how `bsdiff`/`bzip2` rely
   on data permutations to expose redundancy.

3. **Dedup-first, REP-after.** Run a dedup pass (like FA 0.11's
   `-m4 -dup`) before SREP's REP, leaving SREP to handle only the
   non-deduplicated tail. This matches the FA 0.11 measurement above.

The safest first step before attempting any of these is **measuring**:
instrument the existing decompressor to record peak match-heap
occupancy on the existing corpus, so any future change has a
quantifiable target.

## The `-m5` SIGSEGV (preexisting)

Found by the new fuzz harness on its first run (`tests/fuzz.sh`), 8/30
random seeds trigger a SIGSEGV in `-m5` (exhaustive search) on
near-random inputs of 449 KiB – 4 MiB. Reproducible against the
upstream commit just before the Omega fork point, so this **is not a
regression introduced by Omega**. Tracked in task F4.4. This is also a
plausible explanation for the old `encode.su` thread *"SREP creepy
decompression problem! Can it be an irreversible, lossy bug?"* — though
that thread describes a decompression-side issue, not compress-side.

## Threading `-m3 / -m4 / -m5` (task F3.3 deferred for design)

The upstream `-tN` flag applies only to `-m1 / -m2` because content-defined
chunking is embarrassingly parallel — different chunks can be hashed
independently. `-m3 / -m4 / -m5` are not so kind.

### What's already parallel

`Compression/SREP/io.cpp` defines `BG_COMPRESSION_THREAD`. There's already
a **two-stage pipeline** (one bg thread + one main thread):

  - BG thread: reads next block, computes the per-block hash, runs
    `h.prepare_buffer` and `inmem.prepare_buffer` for the next block's
    hash-table state.
  - Main thread: runs the actual compression (`compress.cpp` inner
    loop) on the current block.

Synchronization: `Event ReadDone, WriteReady, BgThreadFinished`.

So the trivially-overlappable I/O + hash-prep work is already off the
critical path of the main compression thread.

### What's hard to parallelize

The inner loop in `Compression/SREP/compress.cpp` (`compress<ACCELERATOR>`,
around line 97) carries genuine serial dependencies between iterations:

  - `last_match_end` advances as each match is recorded; later iterations
    must not start matches before it.
  - `h.find_match()` returns hits against a hash table that
    `h.add_hash()` mutates as we walk forward — mutation order
    determines which match is found first when multiple candidates
    exist.
  - The output match list must be written in input order to satisfy the
    decoder's Future-LZ / Index-LZ format.

A naive "split block into N sub-blocks, run N threads in parallel, merge
the match lists" loses cross-sub-block matches and degrades compression
ratio. Splitting safely requires explicit conflict detection at the
sub-block boundaries — that's the design work.

### Plausible smaller wins worth measuring before refactoring

  - **`-m3` only:** `-m3` checks matches by VMAC digest comparison only,
    not by re-reading old data. Its hash-check path may be more
    parallel-friendly than `-m4 / -m5` (which re-read from disk and
    serialise on file I/O). Worth profiling.
  - **`-m4 / -m5` re-read parallelism:** disk re-read (under POSIX mmap
    after F3.1) is read-only and thread-safe. Multiple threads could
    verify *candidate* matches in parallel, before the serial
    "select-and-record" step. This is a smaller refactor than full
    inner-loop parallelism.

### Recommended decomposition (separate tasks)

  - F3.3a: Profile-driven measurement: add timing to the BG-vs-main
    pipeline to confirm where the wall-clock time is actually spent on
    each `-mN`. This is the prerequisite — speculation about which
    threading change matters is cheap; data isn't.
  - F3.3b: `-m3` threading on the digest-comparison path (lower risk).
  - F3.3c: `-m4 / -m5` parallel candidate verification (higher risk).

For now, F3.3 stays open. We will not ship half-implemented threading.

### F3.3a: actual measurement (2026-04-26)

`tests/profile.sh` parses the `Cpu X mb/s, real Y mb/s = N%` banner
that osrep prints at the end of every run. `parallel_pct = real / cpu`,
so values >100% mean multiple threads are doing real work in parallel
(CPU-time exceeds wall-clock).

64 MiB pseudo-random input (worst case for compression):

| method | real_s | cpu_s | parallel_pct |
|--------|--------|-------|--------------|
| -m0    | 0.507  | 0.320 |  63%  |
| -m1    | 0.164  | 0.149 |  91%  |
| -m2    | 0.138  | 0.179 | 130%  |
| -m3    | 0.312  | 0.344 | 110%  |
| -m4    | 0.307  | 0.299 |  97%  |
| -m5    | 0.360  | 0.413 | 115%  |

64 MiB repetitive text (best case for REP):

| method | real_s | cpu_s | parallel_pct |
|--------|--------|-------|--------------|
| -m0    | 0.409  | 0.301 |  74%  |
| -m1    | 0.148  | 0.163 | 110%  |
| -m2    | 0.130  | 0.198 | 152%  |
| -m3    | 0.144  | 0.177 | 123%  |
| -m4    | 0.148  | 0.154 | 104%  |
| -m5    | 0.166  | 0.220 | 132%  |

**What the data tells us:**

  - `-m1` / `-m2` (CDC) are already well-threaded via the existing
    `-tN` machinery — peaking at 152% parallelism, which is roughly 1.5
    cores active on average.
  - `-m3` / `-m4` / `-m5` are running at **97% – 132%** parallelism on
    these workloads, **purely through the existing BG_COMPRESSION_THREAD
    pipeline**. The two-stage I/O-vs-compute pipeline is already hiding
    most of the I/O + hash-prep cost.
  - `-m4` on incompressible data is the only entry below 100% (97%) —
    that's the single place where some headroom remains, and even there
    it's marginal.
  - `-m0` (REP) is the most single-thread-bound (63 – 74%) but it's the
    algorithm itself that's sequential, not a missing pipeline stage.

**Implication for F3.3b / F3.3c:**

The expected benefit of full inner-loop parallelism for `-m3 / -m4 /
-m5` is **smaller than initially assumed** — the BG-thread pipeline is
already doing most of the easy parallelism. Before investing in the
risky inner-loop split (which could break correctness and complicate
maintenance), the ROI question is honestly: *is there a real workload
where this matters?*

Two possibilities worth measuring before any code change:
  - Larger inputs (multi-GB) where bufsize-bounded BG-thread overlap
    saturates and the main thread becomes the bottleneck.
  - More cores (8+) where Amdahl's law makes the remaining ~30% of
    serial work expensive.

F3.3b and F3.3c are kept open but de-prioritised given this data.

### F3.3a re-run at 1 GiB scale (2026-04-27)

To test the "main thread saturates at scale" hypothesis from the
recommendation block above, `tests/profile.sh` was re-run on a 1 GiB
compressible-text corpus (`yes "..." | head -c 1G`) on the same
4-core / 7 GiB host:

| method | real_s | cpu_s | parallel_pct |
|--------|--------|-------|--------------|
| -m0    | 4.404  | 4.449 | 101% |
| -m1    | 1.964  | 2.599 | 132% |
| -m2    | 1.838  | 3.150 | 171% |
| -m3    | 2.329  | 3.161 | 136% |
| -m4    | 2.253  | 2.558 | 114% |
| -m5    | 2.557  | 3.741 | 146% |

**Every method's parallelism `%` went UP at 1 GiB vs 64 MiB**,
including -m0 (74% → 101%) which is single-threaded by design.
The existing BG_COMPRESSION_THREAD overlap *improves* with input
size on this host — the I/O + hash-prep stage has more useful work
to hide.

This empirically rules out the "main thread saturates at scale"
hypothesis. Combined with the 64 MiB data, **F3.3b and F3.3c are
closed as won't-fix on 4-core / ≤2 GiB workloads**. The remaining
theoretical justification is 8+ core hardware where Amdahl's law on
the inner-loop's serial fraction would matter; if such hardware
becomes available the tasks can be re-opened and the analysis
re-run on it. Until then, adding parallel paths to the inner loop
of `compress.cpp` would add risk and maintenance cost without a
measurable win.

## References

- [Intensity/srep](https://github.com/Intensity/srep) — upstream
  repackage of the last Mercurial commit (3.93a beta, 11 Oct 2014).
- [Bulat-Ziganshin/FA](https://github.com/Bulat-Ziganshin/FA) —
  successor project ("FreeArc'Next") that absorbed SREP's Future-LZ.
- [FA 0.11 release notes](https://github.com/Bulat-Ziganshin/FA/wiki/FA-0.11-release-notes)
  — quantified dedup-vs-future-LZ memory tradeoff.
- [Bulat-Ziganshin/MT-LZ](https://github.com/Bulat-Ziganshin/MT-LZ) —
  Bulat's later experiments with multi-threaded and GPU LZ; `srep.rc`
  there still pins the version at `3.9.3.1, 11-Oct-2014`.
- [Original SREP description (web archive)](https://web.archive.org/web/20161223135216/http://freearc.org/research/SREP.aspx).
