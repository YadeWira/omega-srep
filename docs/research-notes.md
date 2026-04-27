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
