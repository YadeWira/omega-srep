# External review post — drafts

Three drafts, originally written for the F6.4 task ("post asking for
external review on the new C++ before promoting v1.0a-beta.2 → v1.0").
**F6.4 was discarded as a v1.0 stable gate (2026-07-10, see CHANGELOG
`[Unreleased]`)** — publishing is no longer required before declaring
v1.0 stable. The drafts are kept here as-is in case the user wants to
post for community feedback at their own pace, independent of the
release timeline; pick one venue, copy the corresponding draft, edit
names and links to taste.

---

## Draft 1 — encode.su (compression / FreeArc community)

This is the primary venue. Audience knows SREP, FA, ZPAQ, and the
FreeArc ecosystem deeply. Tone: peer-to-peer, technical, no
hand-holding.

> **Subject:** Omega SREP 1.0a-beta.4 — fork of 3.93a with FA-style `-dup` mode + Windows build, pre-release review wanted
>
> Hi all,
>
> Omega SREP is a fork of Bulat Ziganshin's SREP 3.93a beta (frozen
> Oct 2014). I picked it up to land a few things upstream never
> shipped:
>
>   * **FA 0.11–style `-dup` pre-pass** as a native flag on `osrep`.
>     Streaming end-to-end (per-buffer CDC, seek-based ref expansion
>     on decode); peak RAM independent of input size. On a 128 MiB
>     corpus of repeated 32 MiB blocks, `-m4 -dup` cuts decompress
>     peak RSS by 65.6 % vs `-m4` alone, archive bloat 0.3 %.
>   * **Reproducible archives via `--seed=N`** for content-addressed
>     storage / reproducible builds.
>   * **Windows 10/11 build** end-to-end (ThreadsWin32.{h,c} written;
>     upstream referenced but never shipped them), plus an
>     alternative CMake path that also compiles clean under native
>     MSVC (cl.exe) — not yet hand-verified by me, so this is one of
>     the things I'd most like eyes on.
>   * **AddressSanitizer-clean** under the full test suite. One
>     genuine bug surfaced and fixed (misaligned uint64_t store in
>     VHash::compute).
>   * **Two correctness bugs found during the beta.2 soak window**
>     and fixed in beta.3: a silent >2 GiB output truncation on
>     Windows MinGW (32-bit `off_t` despite `_FILE_OFFSET_BITS=64`),
>     and a `std::bad_alloc` abort on a corrupted `chunk_count` field
>     (found by libFuzzer in 4 execs). Both now have permanent
>     regression coverage via `tests/fuzz_regression.sh`.
>   * **Multi-corpus bench vs upstream SREP 3.92 and FA 0.11**
>     ([`docs/multi-corpus-bench.md`][bench]): `osrep -m4` is
>     byte-identical to `srep64 -m4` on every corpus tested (fork
>     parity confirmed), and `osrep -dup`'s dedup ratio lands within
>     0.5% of FA 0.11's own `-dup` on the same dup-friendly corpus.
>
> What I'm specifically asking review for, in order of impact:
>
>   1. The `-dup` design and implementation
>      ([`Compression/SREP/dedup.cpp`][dedup] +
>      [`Compression/SREP/dup_wrapper.cpp`][wrap]). Streaming
>      encoder trusts the 64-bit chunk hash (collision rate ~1e-7
>      per million chunks); `--dup-paranoid` opts into byte-compare.
>      The on-disk `ODUP` trailer scheme is in
>      [`docs/format-spec.md`][fmt].
>   2. The `ThreadsWin32.{h,c}` port at
>      [`Compression/LZMA2/C/`][threads]. Modeled on Igor Pavlov's
>      modern (26.x) LZMA SDK Threads.h Win32 path but kept
>      ABI-compatible with the 2008-era ThreadsUnix.h shipped in
>      this fork, so the C++ wrapper layer (Thread.h /
>      Synchronization.h) needed no changes.
>   3. The native-MSVC CMake path — compiles clean per source audit,
>      but I only have GCC/clang on Linux to test with. If anyone
>      has a Windows box with Visual Studio 2022, a smoke-test build
>      would close the last untested platform gap before v1.0.
>   4. Empirical upstream parity:
>      [`docs/upstream-comparison.md`][cmp] and
>      [`docs/multi-corpus-bench.md`][bench] — byte-identical
>      compsize between SREP 3.92 and Omega on every corpus tested;
>      downstream zpaqfranz outputs differ by 39 bytes / 0.000005 %
>      at `-m3`.
>
> What I'm explicitly NOT asking for:
>
>   * Style nits in the inherited `srep.cpp` / Common.h / hashes.cpp.
>     Those are upstream code. I touched only what F5/F6 required
>     plus the one ASAN fix.
>   * macOS/BSD ports. Out of scope; declared x86_64 Linux +
>     Windows only.
>
> Pre-release binaries (Linux x86_64 + Windows x86_64): [release page][rel].
> Repo: [github.com/YadeWira/omega-srep][repo].
>
> Concrete things that would help most:
>
>   * Adversarial inputs that break `-dup` round-trip
>     (`tests/dup_corruption_fuzz.sh` already covers 27 trailer-
>     mutation variants — looking for shapes the test misses).
>   * Soak runs with workloads bigger than my ~2 GiB stress.
>   * A hand-verified native MSVC build (see point 3 above) —
>     I can't test cl.exe myself.
>
> Thanks. Aiming to soak 2-4 weeks of feedback before promoting to
> stable v1.0.
>
> [dedup]: https://github.com/YadeWira/omega-srep/blob/main/Compression/SREP/dedup.cpp
> [wrap]:  https://github.com/YadeWira/omega-srep/blob/main/Compression/SREP/dup_wrapper.cpp
> [fmt]:   https://github.com/YadeWira/omega-srep/blob/main/docs/format-spec.md
> [threads]: https://github.com/YadeWira/omega-srep/blob/main/Compression/LZMA2/C/ThreadsWin32.c
> [cmp]:   https://github.com/YadeWira/omega-srep/blob/main/docs/upstream-comparison.md
> [bench]: https://github.com/YadeWira/omega-srep/blob/main/docs/multi-corpus-bench.md
> [rel]:   https://github.com/YadeWira/omega-srep/releases/tag/v1.0a-beta.4
> [repo]:  https://github.com/YadeWira/omega-srep

---

## Draft 2 — r/cpp (general C++ community)

Audience: C++ developers, may not know SREP at all. Lead with the
C++ angle. Tone: code-review request.

> **Title:** [Pre-release review wanted] Omega SREP — modernized fork of an abandoned LZ77 preprocessor; ~700 lines of new C++ I'd like eyes on
>
> Body:
>
> I've forked SREP 3.93a (a 2014-era huge-dictionary LZ77
> preprocessor by Bulat Ziganshin, frozen at upstream) and added:
> a streaming dedup pre-pass (CDC + content hash + ref table), a
> Windows-port shim that upstream referenced but never shipped, and
> deterministic seeding for reproducible archives.
>
> Total new C++ ≈ 700 lines split across:
>
>   * `Compression/SREP/dedup.cpp` — encoder/decoder for the dedup
>     pre-pass. Streaming via FILE\* + fseek. Trusts a 64-bit FNV-1a
>     hash for dedup decisions; `--dup-paranoid` switches to byte-
>     compare via fseek+fread on every hit.
>   * `Compression/SREP/dup_wrapper.cpp` — outer `int main` that
>     parses Omega-specific flags (`-dup`, `--chunk-{avg,min,max,
>     buf}=N`, `--seed=N`) and wraps the renamed `srep_main`. Uses
>     mkstemp via a Common.cpp helper for cross-platform tempfiles.
>   * `Compression/LZMA2/C/ThreadsWin32.{h,c}` — Win32-API port of
>     the LZMA SDK threading primitives (Thread, Event, Semaphore,
>     CriticalSection). Modeled on Igor Pavlov's modern 26.x SDK
>     but kept ABI-compatible with the 2008-era ThreadsUnix.h
>     shipped in this fork (so the C++ wrapper layer doesn't change).
>
> Verification I've already done:
>
>   * 160+ tests across 10 suites (round-trip, random fuzz incl.
>     `-dup`, format-corruption fuzz, concurrency stress, byte-
>     identity cross-test C++ vs Python prototype, real-world tar
>     of /usr/bin, multi-corpus bench vs upstream SREP 3.92 and FA
>     0.11).
>   * AddressSanitizer/UBSan-clean across the full sanitized suite.
>   * Three libFuzzer harnesses (decode, decode_streaming,
>     encode_split) — two bugs already found and fixed this way: a
>     silent >2 GiB output truncation on Windows (32-bit `off_t`
>     surviving `_FILE_OFFSET_BITS=64`), and a `std::bad_alloc`
>     abort on a corrupted length field. Both are pinned as
>     permanent regression tests now.
>   * Independent benchmark: byte-identical compsize on a 1.79 GiB
>     tar between upstream SREP 3.92 and Omega — confirms the
>     algorithmic core is preserved. Separately, Omega's `-dup`
>     dedup ratio lands within 0.5% of FA 0.11's own `-dup` mode on
>     the same corpus.
>   * Builds clean on Linux gcc 14 / clang 19, and Windows MinGW.
>     A CMake path also compiles clean under native MSVC per source
>     audit, but I haven't hand-verified cl.exe myself yet.
>
> What I'd value most:
>
>   1. Concurrency review of the streaming dedup encoder/decoder:
>      currently single-threaded but called from
>      `BG_COMPRESSION_THREAD` indirectly via the existing pipeline.
>   2. The mkstemp-based tempfile lifetime in `dup_wrapper.cpp` —
>      I `unlink()` early on Linux but rely on the file handle
>      persisting through `srep_main`. Audit for race / leak windows.
>   3. The trust-the-hash trade-off in streaming mode. Documented;
>      `--dup-paranoid` mitigates. Comments welcome on whether I
>      should flip the default.
>   4. Style / idiom — most of the codebase is C-with-classes
>      2008-era; my new files use `std::vector`, `std::string`,
>      `std::unordered_map`. Consistency tradeoffs?
>   5. If anyone has Visual Studio 2022 handy: a smoke-test build
>      via the CMake path would close the one platform I can't test.
>
> Repo: github.com/YadeWira/omega-srep
> Pre-release binaries (Linux + Windows x86_64): [release tag,
> v1.0a-beta.4]
>
> NOT asking for review of the upstream SREP code I inherited.
> Aiming to soak 2-4 weeks before tagging v1.0.

---

## Draft 3 — r/compression (niche)

Audience: compression algorithm enthusiasts. Lead with numbers.

> **Title:** Omega SREP 1.0a-beta.4 — pre-release of the abandoned SREP 3.93a fork, with FA-style `-dup` mode
>
> Body:
>
> SREP (Bulat Ziganshin's huge-dictionary LZ77 preprocessor that
> drove FreeArc) froze at 3.93a beta in October 2014. I've picked
> up the lineage as `osrep` with a few additions:
>
>   * Native `-dup` pre-pass (FA 0.11 design): -65.6 % decompress
>     peak RSS at 0.3 % archive bloat on a 4× duplicate-block
>     corpus.
>   * Windows 10/11 build verified (was declared but never built
>     end-to-end on real Windows).
>   * Reproducible archives via `--seed=N`.
>   * Two correctness bugs (found via libFuzzer + a soak window)
>     fixed since the first pre-release: a silent >2 GiB output
>     truncation on Windows, and a `std::bad_alloc` abort on a
>     corrupted archive field.
>
> Independent user check: 1.79 GiB real tar, `-m5f -a0`. Upstream
> SREP 3.92 vs Omega produced **byte-identical compsize**
> (1,052,227,610 bytes both). Downstream zpaqfranz `-m3` outputs
> differ by 39 bytes (0.000005 %) — pure arithmetic-coder noise
> from the per-run random hash seed.
>
> I've since run a 3-corpus comparative bench against both upstream
> SREP 3.92 *and* FA 0.11 directly (`docs/multi-corpus-bench.md`):
> fork parity holds on every corpus, and Omega's `-dup` dedup ratio
> lands within 0.5 % of FA 0.11's own `-dup` mode on the same
> dup-heavy corpus — so the two independent CDC+dedup
> implementations agree.
>
> Repo + bench numbers + format spec:
> github.com/YadeWira/omega-srep
>
> Pre-release: [release tag, v1.0a-beta.4]
>
> Soaking 2-4 weeks of feedback before tagging v1.0. If anyone has
> SREP 3.92 / FA 0.11 / ZPAQ pipelines on real workloads and wants
> to compare further, the more datapoints the better.

---

## Where to post (recommended order)

1. **encode.su** — primary. Most informed audience. Bulat himself
   has historically posted there; SREP discussion threads exist.
   Use Draft 1.
2. **r/cpp** — code review eyes. Use Draft 2.
3. **r/compression** — niche but engaged. Use Draft 3.

Skip Hacker News (too broad, signal-to-noise low for a niche fork)
and lobste.rs (invite-only, not the right audience anyway).

After posting:

  * Pin the thread URL in `docs/research-notes.md` so feedback is
    discoverable.
  * Triage incoming bug reports as v1.0a-beta.3 candidates if any.
  * Don't promote to v1.0 until at least one calendar week of
    no-major-issues soak.
