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

## Segment-level parallelism for `-m3 / -m4 / -m5` (task F3.3d, reopens roadmap P2.8)

F3.3b/c above were closed won't-fix for *inner-loop* parallelism against
the single shared hash table — splitting the existing serial scan while
keeping one order-dependent table. This is a structurally different
angle: parallelism at the *segment* level (independent per-segment
state, zstd `--long`/xz `--threads`/lrzip-style), which sidesteps the
hash-table mutation-order dependency instead of trying to synchronize
it.

### What we tested

A standalone Python coverage-measurement harness
(`tests/segment_match_loss.py`, structurally modeled on the real
`hash_table.cpp`/`compress.cpp` grid-indexed greedy matcher — chunk-grid
size = `MIN_MATCH` = 512B, one-slot-per-bucket table unconditionally
overwritten on insert, first-hit-wins matching, no lazy lookahead)
computed, for four corpora already used by
`tests/multi_corpus_bench.sh`, how much exact-duplicate coverage a
whole-buffer match pass finds vs. splitting the same buffer into
fixed-size segments with 0/1MB/4MB of priming overlap copied from the
previous segment's tail:

| corpus | baseline coverage | loss, 4/16MB segment, no overlap | recovered by +1MB | recovered by +4MB |
|---|---|---|---|---|
| mixed.bin (6.25MB) | 67.45% | 0.00% | — | — |
| text.bin (4.00MB) | 99.16% | 0.00% | — | — |
| enwik8 (64MB slice) | 0.00%* | 0.00% | — | — |
| dup_bench_in_32x4.bin (64MB slice) | 50.08% | **99.68%** | 0.0% | 0.0% |

\* enwik8's baseline coverage is 844 bytes out of 64MB — there is
essentially no exact-duplicate redundancy to lose at `MIN_MATCH=512` on
this corpus, so its 0.00% loss figures mean "nothing to lose," not
"segmentation is harmless."

A separate synthetic sanity check (12MB buffer, 600KB duplicate placed
0.78MB into segment 1) confirmed the overlap *mechanism* itself works
correctly: 100% loss with no overlap, 0% loss with a 1MB handoff. This
rules out "the harness is broken" as the explanation for dup_bench's
result — the real duplicate distance in dup_bench (~32MB) is simply far
larger than any handoff window tested (max 4MB), so 0% of that specific
loss is recoverable at the tested sizes.

### What this tells us

Segment-boundary ratio loss, which F3.3 flagged qualitatively but never
quantified ("a naive split... loses cross-sub-block matches and
degrades compression ratio"), is now measured and corpus-dependent
rather than uniform: **zero loss on general-purpose corpora, catastrophic
(99.68%) loss on the exact workload class SREP differentiates itself
on** — long-range periodic duplicates, the same class the F6.10 bench
uses to claim `-dup` cuts decompress RSS by 66% on long-range-dup
corpora. Any segment-based parallel design trades away some fraction of
that unbounded-whole-file advantage; how much, for real (not synthetic)
corpora, is now measured for the tested sizes — only the mechanism
(works when handoff ≥ true duplicate distance) and the failure mode
(recovers 0% when it doesn't) are confirmed, not the exact recovery
curve at larger handoff sizes.

### Three candidate designs considered, none ready to ship

  - **Fully-independent zero-handoff segments** (xz `-T0` clone):
    rejected as a default. Its numbers are literally the "no overlap"
    rows above — 99.68% loss on dup_bench, i.e. it guts the F6.10
    headline result. It also implies a new on-disk container format
    (independently-decodable segments) with real migration cost, not
    just a ratio tradeoff. Only defensible as a loudly-gated, explicit
    opt-in "fast lane" for content already known to have no long-range
    structure — never as the shipped `-dup` default.

  - **Segmented Pipeline Compression** (per-segment hash tables +
    64MB handoff, sized to just clear the 32MB gap measured above): the
    design that motivated the measurement above, but as first scoped it
    has a fatal contradiction — it gates "worker N+1 starts once worker
    N's segment is done," which means at most one segment is ever
    compressing at a time. As scoped, it would cost ~1-2 engineer-weeks
    (chunk-number rebasing across `chunkarr_value`/`get_chunk`/
    `digestarr`, per-segment table lifecycle, ordered `statbuf` merge —
    the rebasing risk is "silent wrong-offset matches, not just ratio
    loss") for **zero wall-clock parallelism**. Its 256MB/64MB sizing is
    also an extrapolation from the 4MB-handoff experiment, never itself
    measured. It additionally never addresses that `-m5` needs
    `L`-aligned segment boundaries in a size range that overlaps the
    known F4.4 SIGSEGV trigger window (449KiB–4MiB) — nobody has checked
    whether segmenting changes that bug's trigger rate.

  - **BG-thread stripe-parallel `prepare_buffer`**: the one candidate
    that changes zero lines in `compress.cpp`/`hash_table.cpp`'s serial
    match logic. `SliceHash::hash()` (hash_table.cpp:50-56) is a pure
    per-chunk function of pointer+size, and the existing `MainDigest`/
    `PrepDigest` per-thread-copy pattern (hash_table.cpp:124/138,
    comment: *"we need two equal digests since they are used in 2
    threads..."*) is already the exact template needed to stripe
    `prepare_buffer`'s two independent, disjoint-index loops
    (hash_table.cpp:64-75, 171-179) across N workers inside the existing
    `BG_COMPRESSION_THREAD`, joined before `io.cpp`'s `ReadDone.Signal()`.
    Zero ratio risk, zero format risk, zero F4.4 interaction — but **no
    measured payoff**: this only helps `-m3`/`-m5` (the loops it strips
    are no-ops for `-m4`), and F3.3a already showed the BG/main pipeline
    hides 97-171% of the relevant cost, so the win could easily be
    marginal.

### Recommendation

Do not pick a "winner" yet — none of the three clears the bar of
"measured design ready for engineering investment," consistent with
F3.3's own "we will not ship half-implemented threading."

  1. **Reject fully-independent segments as any default** — the 99.68%
     loss number is disqualifying for `-dup`'s core selling point. May
     only ship as an explicit opt-in with a hard product sign-off that
     it can silently regress long-range dedup.
  2. **Do not build Segmented Pipeline Compression's MVP as scoped.**
     Rework it so segment N+1's priming can start without waiting for
     segment N's `compress()` to finish (priming-table fill is a pure
     function of already-available mmap'd bytes, not of N's
     match-search progress — it doesn't need the "progress cursor" the
     original design assumed). Size and risk-assess *that* version.
     Separately, rerun `tests/segment_match_loss.py` at the actual
     proposed 256MB/64MB sizes against `dup_bench` (not extrapolated
     from 4MB) before trusting the defaults, and resolve the F4.4/`-m5`
     boundary-rounding interaction first (recommend excluding `-m5`
     from segment-parallel work entirely until F4.4 is fixed).
  3. **Stripe-parallel `prepare_buffer` can proceed to a profiling
     spike now** (extend `tests/profile.sh`, same discipline as F3.3a)
     to measure `prepare_buffer`'s actual share of BG-thread wall-clock
     on real corpora at both 64MB and 1GiB scale, before committing the
     1-2 engineer-days of implementation. If the spike shows it's a
     small fraction of BG-thread time, close it won't-fix alongside
     F3.3b/c for the same reason; if there's real idle-core time, it's a
     safe, self-contained win worth taking.

Filed as **F3.3d** (open — this session's contribution is the quantified
segment-boundary loss curve above; no C++ implementation has started
for any of the three candidates).

## Stripe-parallel `prepare_buffer`, implemented (task F3.3e, closes the F3.3d spike)

F3.3d's recommendation #3 was a profiling spike before committing to the
implementation: measure `prepare_buffer`'s actual share of BG-thread
wall-clock. That spike ran first.

### Profiling spike result

Real `-pc`-gated timing (reusing the existing gated-diagnostic-counter
pattern already used by `pc.max_offset`, not a new mechanism), on
64 MiB and 1 GiB corpora, `-m3` (digest precompute) and `-m5`
(SliceHash):

| mode | corpus | % of BG-thread active time | % of wall-clock |
|---|---|---|---|
| -m3 | 64MiB incompressible | 25–27% | 12–15% |
| -m3 | 64MiB repetitive text | 44–47% | 30–36% |
| -m5 | 64MiB incompressible | 36–41% | 24–30% |
| -m5 | 64MiB repetitive text | 59–64% | 50–55% |
| -m3 | 1GiB compressible text | 50–55% | 46% |
| -m5 | 1GiB compressible text | 62–69% | 60–65% |

Not a marginal fraction — up to 69% of the BG thread's own active time,
worst on `-m5`/compressible-text and *increasing* at 1 GiB scale (this
host, 56 cores, has more headroom than the original 4-core F3.3a box).
Well above the bar for spending 1-2 engineer-days on the implementation,
so the workflow proceeded to build it rather than closing won't-fix.

### Implementation

Striped `HashTable::prepare_buffer`'s two independent, disjoint-index
loops (digest precompute for `-m3`, SliceHash for `-m5`) across worker
threads inside `BG_COMPRESSION_THREAD`, reusing the exact
`MultipleProcessingThreads<Job>` template already proven for `-m1/-m2`
in `compress_cdc.cpp`, and the exact `MainDigest`/`PrepDigest`
per-thread-VDigest-copy pattern already at `hash_table.cpp:124/138`
(extended from 2 copies to N). Zero lines changed in `compress.cpp` or
`add_hash0`/`find_match0`. Falls back to the original inline call
whenever there's nothing to parallelize.

**Overhead regression found and fixed before commit.** The first pass
created and started the thread pool whenever `NumThreads>1` — true by
default on any multi-core host — regardless of whether the current mode
actually uses `prepare_buffer` for anything. Since `BG_COMPRESSION_THREAD`
is constructed on every invocation (all methods, including `-m0/-m1/-m2/-m4`
which never touch these loops), this meant every single run paid a fixed
thread-pool create/destroy cost for a pool it would never use. Fixed by
gating pool creation on `h.PRECOMPUTE_DIGESTS || h.slicehash.h != NULL` in
addition to `NumThreads>1` — confirmed by direct measurement (50 back-to-back
`-m4` invocations on a 64KiB file: 0.102s baseline vs 0.103s after the whole
F3.3e change, i.e. no measurable regression) that this closed the gap.

### Independent verification

Re-verified directly, not just from the implementing/reviewing agents'
own reports, because of a methodology trap worth naming: **without
`--seed=N`, `osrep`'s output is intentionally non-deterministic between
runs** (the `--seed` feature exists precisely to make archives
reproducible), so naive before/after `cmp` on default invocations
shows spurious byte differences that have nothing to do with the code
change. With `--seed` fixed, output from the striped build and from
unmodified HEAD is **byte-for-byte identical** across `-m3`/`-m5` ×
`-t1`/`-t4`/`-t8`, on both a 5 MiB random buffer and a doubled-corpus
compressible buffer — confirming the striping changes timing only, not
any compression decision. Full existing suite re-run clean on the final
tree: `roundtrip.sh` 30/30, `fuzz.sh` 105/105, `dedup_xtest.sh` PASS,
`dup_native_roundtrip.sh` 17/17, `dup_concurrency.sh` 8/8,
`fuzz_regression.sh` 1/1.

**Real speedup, but modest and noisy at very high thread counts.** On a
512 MiB compressible-text buffer on this 56-core host, comparing 3-rep
medians: `-m3` `-t1` ≈0.56s vs `-t8` ≈0.47s (~16% faster); `-m5` `-t1`
≈0.69s vs `-t8` ≈0.60s (~13% faster). At the *default* thread count
(`NumThreads` = all 56 cores on this host), results were noisier and a
single early sample even showed a net slowdown vs `-t1` — plausible
given a 512 MiB file only has 64 buffers total and the one-time,
56-real-OS-thread pool startup cost doesn't obviously pay for itself at
that scale. Not tuned further this session (would need a size-aware or
independently-capped worker count, separate from `-tN`, to reliably beat
`-t1` at very high core counts) — worth a follow-up measurement pass on
larger inputs and/or a lower worker-count cap before trusting the
default on many-core hardware.

### Verdict

**Shipped.** Thread-safety independently re-derived (FIFO
`Get()`-then-`Event::Wait()` barrier, credit/window slot-reuse ordering,
POD `VDigest` copy semantics) — no defect found. Correctness independently
confirmed bit-for-bit with `--seed` fixed. The overhead regression found
during review was fixed before commit, not left as a follow-up. The
speedup is real at moderate thread counts and roughly a wash at this
host's full 56-core default — good enough to ship given zero downside
risk (falls back to the unmodified path whenever there's nothing to
gain), with thread-count tuning flagged as a real, separate follow-up.

## CDC rolling hash: FNV lacks a fixed window, so `-dup` needs buffer-aligned duplicates (task F5.6)

### What we tested

The `-dup` CDC boundary hash (`Compression/SREP/dedup.cpp`, mirrored in
`tests/dup_prototype.py`'s `cdc_split`) is `h = h*PRIME + byte`, reset to
`0` only when a cut fires. A pure-Python prototype
(`gear_cdc_split`, not committed — see below) swapped in a Gear-hash
(`h = (h << 1) + GEAR[byte]`, FastCDC-style) with the same min/max
bounds, to see whether the choice of rolling hash actually matters for
Omega, or whether it's a theoretical nit.

Compared on real corpora already used by `tests/multi_corpus_bench.sh`
(`enwik8`, the `dup_bench_in_32x4.bin` synthetic duplicate corpus) plus
`tests/corpus/*.bin`:

  1. Chunk-size distribution (stdev, % clamped at `max_chunk`).
  2. Dedup ratio on a corpus built from two identical 32 MiB blocks.
  3. Edit locality: insert a few random bytes near the start of a
     buffer, measure how far downstream chunk boundaries stay
     disrupted before re-syncing with the un-edited version.
  4. Throughput (pure Python — not representative of C++/SIMD, included
     only to confirm no accidental regression in the toy chunker).

### What we found

**The current hash has no fixed window.** `h = h*PRIME + byte` accumulates
the *entire* prefix since the last cut — it never "forgets" earlier
bytes in the current chunk. Gear-hash's `h = (h << 1) + GEAR[byte]`
naturally forgets bytes older than ~64 shifts (they fall off the top of
the 64-bit register), giving it an implicit fixed window without any
explicit removal step.

This is not just a theoretical purity concern — it breaks dedup on
non-buffer-aligned duplicates:

| test | fnv (current) | gear-hash |
|---|---|---|
| dedup ratio, 2× identical 32 MiB blocks, **no buffer reset** (`buf_size=0`) | 100% unique (**found nothing**) | 50.1% unique (correct) |
| edit-locality: resync distance after a 1-byte insert | +6,291,456 B (never resynced within an 8 MiB buffer) | +2,487 B |

Production `-dup` survives this today only because `--chunk-buf`
(default 8 MiB) resets the hash to `0` at a fixed grid, and the
existing benchmark corpus (`dup_bench_in_32x4.bin`) was built with
32 MiB blocks — an exact multiple of 8 MiB, so the reset grid happens
to realign with the duplicate boundaries. A real-world duplicate that
does **not** start at an 8 MiB-aligned offset (e.g. an identical file
embedded at an arbitrary offset inside a tar archive) would not be
found at all, because the FNV hash's cut-point sequence after the
buffer reset depends on the *distance since the reset*, not just on
local content — so two occurrences of the same bytes starting at
different offsets-mod-8MiB diverge immediately.

Gear-hash removes this dependency entirely: the `buf_size=0` (no reset)
run above already outperforms FNV's buffer-aligned best case, because
its window is short enough (~64 bytes) to resync locally regardless of
absolute position.

### Secondary finding: FastCDC's "normalized chunking" needs care

A true FastCDC implementation also uses a stricter mask below the
target average size and a laxer mask above it (not a single mask), to
concentrate cut points around the average rather than let them drift.
Implementing that dual-mask scheme measurably tightened the size
distribution on `enwik8` (max-clamp rate 12.9% → 0.4%, stdev 5089 →
2117) and `dup_bench_in_32x4` (max-clamp 3.6% → 0.1%).

But it is **not universally better without tuning**: on
`tests/corpus/mixed.bin` the normalized variant produced a *larger*
average chunk (9362 B vs FNV's 4127 B target-4096) and higher max-clamp
(38.9%) than FNV, and on the deliberately low-entropy
`tests/corpus/text.bin` (28 distinct byte values) the naive Gear-hash
degenerated completely — every single chunk hit the max-size clamp,
zero natural cut points found at all, because the shift-based hash's
low bits enter a short LCG-style cycle on highly periodic input and
never land on the boundary condition. This is a real robustness gap
that any Gear-hash port would need to guard against (e.g. mixing in
position-dependent entropy, or accepting that already-repetitive
low-entropy input doesn't need fine-grained CDC anyway since it
compresses well downstream regardless).

### Recommendation

Worth porting to C++ (a real F5.x-follow-on task), because the
alignment-independence is a genuine correctness/coverage improvement
for `-dup`, not just a performance tweak — but only after:

  1. Tuning the normalized-chunking mask widths against the *full*
     multi-corpus-bench suite (`data.tar`, full `enwik8`, not the
     8 MB / 16 MB slices used in this prototype).
  2. Adding a degenerate-input safeguard so low-entropy stretches don't
     silently fall back to always-max-size chunks (harmless for
     correctness, since min/max bounds still hold, but it means CDC is
     doing no useful work in that region).
  3. Re-validating round-trip correctness end-to-end — this research
     only touched chunk *boundaries*, not the on-disk `.dupref`/`ODUP`
     format, so no format change is implied by adopting a different
     internal hash.

Filed as **F5.6** (open — prototype only, no C++ work started).

## Gear-hash CDC ported to C++, shipped opt-in as `--chunk-hash=gear` (closes F5.6)

The three prerequisites above are done; this is the real C++ port.

### Mask tuning and the degenerate-input safeguard

A standalone C++ harness (faster than the Python prototype at these
sizes) swept normalized-chunking mask widths against full-file
corpora (all of `tests/corpus/*.bin`, full 100 MB `enwik8`, full
128 MB `dup_bench_in_32x4.bin`):

| delta_s,delta_l | text.bin avg | mixed.bin avg | random.bin avg | enwik8 avg | resync (5B insert, enwik8) |
|---|---|---|---|---|---|
| 0,0 (flat mask) | 12264 | 8669 | 5323 | 6611 | — |
| 2,2 (FastCDC-typical) | 12264 | 8285 | 4900 | 5577 | — |
| 4,4 | 12264 | 7737 | 4333 | 4513 | 2360 |
| **5,5 (chosen)** | **4136** | **4278** | **4220** | **4274** | **2280** |
| 6,6 | 4136 | 4250 | 4136 | 4188 | 7413 (one 55KB outlier) |

Below delta=5, text.bin/mixed.bin get essentially no natural cuts under
the tuned mask at all (avg stuck near 8-12KB, resolved entirely by the
escape safety net) — delta=5 is the minimum width where the tuned mask
itself starts finding genuine content-defined cuts, not just distribution
tightness. **Chosen: delta_s = delta_l = 5.**

Two false starts changed the final safeguard design and are worth
recording: (1) a period-256 salt lookup table fixed `text.bin` but not
an all-zero input — Gear-hash's `h=(h<<1)+K` recurrence provably
converges to an exact fixed point on constant bytes, and a short-period
salt just replays the same outcomes against that fixed point forever.
Switched to a full 64-bit avalanche mix (splitmix64-style) with no
short period. (2) Applying that mix unconditionally on every byte fixed
every degenerate corpus but made ordinary content's edit-locality
resync ~380x worse (2.5KB → ~864KB average on enwik8) — reproducing the
exact "never resyncs" FNV failure this port exists to fix, because the
cut decision now depended on `span` (chunk-relative, position-like),
not the ~64-byte content window. Fixed by **gating** the safeguard
behind `span >= 0.75*max_chunk` so it only activates on chunks that
have gone abnormally long without a natural cut, restoring ~2.3KB
average resync while still fixing every degenerate corpus tested (a
200-random-GEAR-table sweep found the naive bug on 191-200/200 tables
— not a fluke of one table — and 0/200 with the safeguard).

### What shipped

`Compression/SREP/dedup.cpp` gained `CDC_HASH_FNV` (default, byte-for-byte
unchanged) / `CDC_HASH_GEAR` (opt-in), a fixed compile-time 256-entry
`GEAR_TABLE`, and `cdc_split_buffer_gear` implementing the tuned dual-mask
Gear-hash chunker with the gated safeguard above. Threaded through
`cdc_split`/`cdc_split_buffer`/`encode`/`encode_split`/`encode_streaming`
(both call sites — the direct `cdc_split_buffer` call in the streaming
path, and the `cdc_split` call in `encode`). Exposed as `--chunk-hash=fnv|gear`
in `Compression/SREP/dup_wrapper.cpp`, documented in its `--help` and
`srep.cpp`'s synopsis. `decode()`/`decode_streaming()`/`decode_split()`
are untouched — confirmed by direct inspection, no `hash_algo`/`CDC_HASH`
token appears anywhere near them. This is purely an encoder-side chunking
choice: it changes where boundaries fall, never the `.dupref` wire
format, so old and new archives keep interoperating with no version bump.

### Independent verification

Re-verified with the same discipline F3.3e's review used, since the same
trap applies here: `osrep`'s output is intentionally non-deterministic
without `--seed`, so before/after comparisons controlled for it explicitly.

**Default path unchanged.** `osrep -dup -m3/-m4/-m5 --seed=N` (no
`--chunk-hash` flag) produces byte-for-byte identical archives before/after
this change, confirmed on corpora the implementer didn't touch (a 113 MB
tar of system `.so` libraries, real text/log/dictionary corpora, plus the
synthetic fixtures) — round-trip verified separately.

**Headline finding replicated with real numbers, not just asserted.** A
20,475,140-byte input with one 8 MiB duplicate block at two non-buffer-
-aligned offsets (777 and 11,530,977 — not congruent mod the 8 MiB
`--chunk-buf` default): `--chunk-hash=fnv` (default) dedup-body ratio =
1.0000 (found nothing); `--chunk-hash=gear` = 0.6064 (recovered 96.1% of
the duplicate). Matches the original Python prototype's finding, now with
a real C++ measurement.

**Important caveat found during validation: final archive size hides this
entirely.** Running `osrep -dup -mN --chunk-hash=fnv` vs `=gear` end-to-end
on the same input produced nearly identical final archive sizes at every
method, because SREP's own long-range match finder independently
rediscovers the duplicate once it's sitting in the dedup body, regardless
of which hash found it first. The actual value of this feature isn't
"smaller archives" — it's `-dup` actually delivering its bounded-RAM
purpose (FA 0.11's `-dup` finding, referenced above) for non-buffer-aligned
duplicates: content the FNV chunker misses flows through to SREP's own
unbounded-dictionary Future-LZ pass, which is exactly the RAM cost `-dup`
exists to avoid. A test that only compares final archive size would not
catch this feature silently regressing — `tests/dup_gear_hash_test.sh`
(new, 11 cases) measures the dedup-body ratio directly for this reason.

Full existing suite re-run clean throughout (`roundtrip.sh` 30/30,
`fuzz.sh` 105/105, `dedup_xtest.sh` PASS, `dup_roundtrip.sh` 5/5,
`dup_native_roundtrip.sh` 17/17, `dup_corruption_fuzz.sh` 27/27,
`dup_concurrency.sh` 8/8, `fuzz_regression.sh` 1/1,
`dup_gear_hash_test.sh` 11/11).

### Two real limitations found by adversarial review — one fixed, one deferred

**Fixed before commit: `--chunk-avg` below 64 silently collapsed to
near-fixed-size chunking.** `mask_l` is built from
`lb = floor(log2(avg)) - GEAR_DELTA_L`; for `avg < 64`, `lb <= 0`, and an
unclamped 0-bit mask makes the `span >= avg` cut test unconditionally
true. Confirmed on genuinely high-entropy `tests/corpus/random.bin` at
`--chunk-avg=32`: gear's stdev collapsed to 2.2 around mean 32.7 (vs
fnv's stdev 31.4 around mean 40.2) — not content-defined at all.
Fixed by clamping `lb >= 1`: re-measured at the same `--chunk-avg=32`,
mean chunk size is now 33.7, matching fnv's 39.2 — genuinely
content-defined again. Default `--chunk-avg` (4096) was never affected.

**Deferred as a follow-up, not fixed here: the escape safeguard
reintroduces history-dependence for periodic/low-local-entropy content.**
The escape path's cut test mixes in `gear_mix_span(span)`, where `span`
is bytes-since-*this*-chunk's-own-start — a chunk-history-dependent
quantity, not an absolute-content-position one. For content whose
*natural* cuts never fire (verified this is a realistic content class,
not a contrived one: an all-zero run, a period-2 pattern, a period-64
pseudo-random block, and even a real English sentence repeated ~65,000
times — period 45 bytes, nowhere near "constant") escape fires on 100%
of cuts. Measuring actual chunk-boundary offsets relative to each copy's
own start, for two placements of the same duplicated content: when
natural cuts do the work (the implementer's own 8 MiB random-duplicate
case), 92.7% of relative boundary positions matched between the two
copies — alignment-independence genuinely holds. But for a 3,000,000-byte
repeated-sentence duplicate (period 45B) placed behind two
different-length paddings so the two copies enter the periodic content
at different chunk-history phase, escape fires on 100% of cuts and
**zero** of 243/244 boundary points matched between the copies — silently
reintroducing the exact history/offset-dependent miss that motivated
this port, for that specific content class (padding blocks, templated
records, sparse binary structures — realistic, not just adversarial).
Round-trip correctness is unaffected in every case tried (verified
byte-identical); this is a dedup-effectiveness gap in the CDC pre-pass
itself, invisible in final archive size for the same reason noted above,
so nobody had seen it. Proper fix needs the safeguard's extra entropy
source to depend on something other than chunk-relative position without
reintroducing absolute-offset-dependence — a real redesign, not a quick
patch. **Filed as F5.6a** (open).

### Verdict

**Shipped as opt-in** (`--chunk-hash=gear`, default `fnv` unaffected).
Thread-/data-safety and format-compatibility hold: default path is
byte-for-byte unchanged, no `.dupref` version bump, the GEAR table is a
build-to-build-reproducible compile-time constant (md5-verified identical
across a from-scratch clean rebuild). The headline claim — Gear-hash finds
non-buffer-aligned duplicates of realistic/random content that FNV misses
— is independently reconfirmed with real numbers. Two real limitations
were found by adversarial review rather than shipped silently: the
`--chunk-avg<64` collapse is fixed in this same commit; the periodic-content
escape-safeguard gap is documented and filed as F5.6a rather than blocking
this commit, since it doesn't affect round-trip correctness or the default
path, and the feature's core case (realistic, non-periodic duplicate content)
works as intended.

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
