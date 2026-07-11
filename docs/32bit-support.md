# 32-bit (i686) build support (task F6.12)

Omega SREP's primary, tested target remains x86_64 (Windows 10/11 x64,
Linux x64). This document covers the **opt-in** 32-bit x86 (i686)
target: what changed to enable it, two real bugs found and fixed by
actually building and running it for the first time, one real bug
found and left open, and the evidence this is based on -- including a
run on a real Windows 7 x64 VM, not just Wine emulation.

## Why 32-bit at all

The `_32_or_64`/`_32_only` macro hooks and the `NUMBER` (loop-index)
typedef already existed in `Compression/SREP/srep.cpp`, hardcoded to
always take the 64-bit branch, alongside an explicit `#error` guard
rejecting anything but x86_64. These are vestiges of upstream SREP
(Bulat Ziganshin's FreeArc-derived codebase), which historically
supported 32-bit targets -- Omega's fork simplified to x86_64-only.
Re-enabling 32-bit surfaced two real, previously-latent bugs that had
never been exercised because this code had never actually been
compiled and run for i686 before.

## What changed

- `Compression/Common.h` and `Compression/SREP/srep.cpp`: the `#error`
  guards now accept `_M_IX86`/`__i386__`/`__i686__` alongside the
  x86_64 macros. Anything that isn't 32- or 64-bit x86 is still
  rejected -- genuinely untested.
- `Compression/Common.h`: the non-Windows `BigAlloc`/`BigAllocZero`
  (used on Linux) gained the same `size > size_t(-1)` overflow guard
  the Windows `BigAlloc` already had. Without it, an oversized `int64`
  allocation request on 32-bit Linux would silently narrow to `size_t`
  at the `malloc()` call boundary, succeeding with a far-too-small
  buffer instead of failing cleanly.
- `Compression/SREP/srep.cpp`: `_32_or_64`/`_32_only` are now real
  `#if`/`#else` conditionals instead of being hardcoded to the 64-bit
  branch, so the one real call site (`_32_only(vm_mem = 1536*mb)`)
  actually caps `vm_mem` on 32-bit builds. A new `dictsize` clamp
  mirrors the existing `vm_mem` one.
- `CMakeLists.txt`: the `CMAKE_SIZEOF_VOID_P EQUAL 8`-only gate now
  also accepts 4-byte pointers.

None of this touches the x86_64 path: confirmed on every iteration of
this work via a from-scratch `make clean && make bin/osrep bin/dedup_test`
and `tests/roundtrip.sh` (30/30 clean, zero new warnings). The `#error`
guard changes and the `_32_or_64`/`_32_only` conditionals are the only
things that could plausibly affect x86_64, and both are gated on
`_M_X64`/`_M_AMD64`/`__x86_64__` exactly as before.

## Bug #1 (fixed): `-d`/`-mem=` values >= 4 GiB silently wrapped

The first pass added a `dictsize` clamp mirroring the existing
`vm_mem` one, but it didn't fire on the path it was written for:
`parse_mem_option()` (which backs both `-d` and `-mem=`) called
`parseMem()`, whose return type is `MemSize == size_t` -- 32-bit on
i686 -- rather than the already-existing, already-correct
`parseMem64()`/`LongMemSize` (already used elsewhere, e.g. the `-a`
option). The narrowing happened *before* either clamp ever saw the
value.

Confirmed on real 32-bit Windows hardware: `-d8gb` silently became the
unrelated 512 MiB *default* (exit 0, no warning); `-d5gb` silently
became `-d1gb`; a control `-d3gb` (below the 4 GiB wrap boundary)
correctly failed loudly with `ERROR! Can't allocate memory`.

**Fix**: `parse_mem_option()`'s two internal calls now use `parseMem64`
instead of `parseMem` (`srep.cpp` ~line 198/212). Re-verified on real
hardware post-fix: `-d8gb` and `-d5gb` now correctly report
`-d4294967295b` (i.e. `size_t(-1)`, the existing clamp) instead of
silently wrapping to a smaller value.

## Bug #2 (fixed): VMAC crashes on every 32-bit build with the default hash

The bigger finding. `-hash=vmac` (the default) crashed reliably on
32-bit -- and since `-m0`/`-m1`/`-m2`/`-m3` internally hardcode VMAC
for CDC/digest verification *regardless* of the user's `-hash=`
selection (the flag only controls the separate whole-archive integrity
checksum), those four modes were completely unusable on 32-bit no
matter what hash the user picked.

### Root cause

`Compression/_Encryption/hashes/vmac/vmac.c` is Ted Krovetz's
public-domain VMAC reference implementation (imported once, in the
2014 fork, never modified since). Its 32-bit MMX-optimized inner loop
(`nh_16_func`, the `VMAC_USE_SSE2` branch) is hand-written GCC extended
inline assembly. The asm body genuinely uses ESI/EDI/ECX as live
loop-control registers -- advancing `esi`/`edi` by 16 bytes per
iteration and decrementing `ecx` as the loop counter -- but the operand
list declared all three as plain **read-only** inputs (`"S"`/`"D"`/`"c"`).

GCC's extended-asm contract requires any register an asm modifies to
be declared output or read-write (`"+"`); violating it let `-O2`/`-O3`'s
`-fipa-ra` (interprocedural register allocation) assume ECX survives a
call to `nh_16_func` unchanged. Since ECX is *caller-saved* under the
x86 cdecl ABI, the caller sometimes skipped reloading it before the
second of two back-to-back `nh_16_func` calls (`nh_vmac_nhbytes_2`,
which fires whenever `VMAC_TAG_LEN==128`, this project's configured
default). The callee then entered with ECX==0, `sub ecx,2` underflowed
to ~0xFFFFFFFE, and the MMX copy loop ran unbounded off the end of the
message buffer -- a page fault.

Confirmed empirically, not just theorized: a minimal standalone repro
reproduced the exact crash; the bug is present at `VMAC_NHBYTES=128`
(the library's own default) as well as this project's `4096` override,
so the override is *not* the trigger; it reproduces only when
`VMAC_TAG_LEN==128` (the double-call path), not at `64`; `-O1` doesn't
crash, `-O2`/`-O3` do (matches `-fipa-ra` being an `-O2+` pass); adding
`-fno-ipa-ra` to the command line makes it disappear with zero source
changes. A from-scratch negative control (same flags, unmodified
`vmac.c`) reproduces the identical crash signature every time; the
same build with the fix applied does not, across every test run.

### Fix

Route `mp`/`kp`/`nw` through local scratch variables declared as
GCC-visible read-write (`"+S"`/`"+D"`/`"+c"`) operands instead of plain
inputs, so GCC's dataflow model correctly reflects that the asm
modifies them. (A bare `esi`/`edi`/`ecx` clobber is rejected by GCC --
"asm operand has impossible constraints" -- since they're simultaneously
fixed hard-register inputs; `"+"`-operands are the only accepted route.)
Scoped to the `#ifdef __GNUC__` branch of `nh_16_func` only; +25/-2
lines; nothing else in the file touched by this part of the fix.

Verified against Ted Krovetz's own published VMAC-64 and VMAC-128
known-answer vectors (lengths 0, 3, 48, 300, 3,000,000) -- all pass,
byte-identical to the native x86_64 build's output, both with the
library's default `VMAC_NHBYTES=128` and this project's `4096`.

### Bonus hardening: `poly_step_func` had the same undeclared-register-modification pattern

Adversarial review of the `nh_16_func` fix found a second instance of
the same bug *class* ~100 lines below it, in `poly_step_func` (also
`VMAC_USE_SSE2`): its asm loads `mh` into ESI, then reuses ESI as pure
scratch mid-computation (`movd esi,mm0` ... later `movd mm7,esi`)
without ever dereferencing `[esi]` again -- while the operand list
still declares it a plain read-only input. `poly_step_func` is also
called twice back-to-back for `VMAC_TAG_LEN==128`
(`poly_step(ch,...)` then `poly_step(ch2,...)`), the same shape that
broke `nh_16_func`.

No failure from this was observed in any test run -- direct disassembly
confirms `poly_step_func` is never inlined at any optimization level
this project uses (`-O2`/`-Os`/`-O3 -funroll-all-loops`), and ESI/EDI
are *callee-saved* under cdecl (unlike ECX), so the function's own
prologue/epilogue currently protects the caller regardless of the
operand-list bug. This is a latent, currently-dormant risk (a future
compiler, `-flto`, or a refactor of the calling code could change
that), not an active one -- but since the fix pattern was already
understood and verified safe, it was applied here too rather than left
as a "someday" item: same `"+S"` treatment, same scratch-variable
approach, verified with the same known-answer-vector suite plus a full
30-cell round-trip re-test (`-m0`..`-m5` x 5 hashes x 5 corpus files,
under Wine) with zero regressions.

### Validation

Full matrix, i686 build under Wine, `-m0`..`-m5` x
`{vmac(default), md5, sha1, siphash, sha512}` x 5 corpus files
(tiny/zeros/random/mixed/text.bin), each cell compress -> decompress ->
byte-compare:

| hash | result |
|---|---|
| vmac (default) | **PASS** on every mode/file combination tested |
| md5 | PASS on every combination |
| siphash | PASS on every combination |
| sha512 | PASS on every combination |
| sha1 | **FAIL on every combination** -- see below |

(`-m0`'s ~595 MB in-memory dictionary allocation intermittently fails
under Wine with an out-of-memory error, hit at random across different
hash choices, always succeeding on retry -- confirmed as Wine/32-bit
address-space flakiness unrelated to hash choice or this fix, not a
correctness regression.)

**Re-confirmed on a real Windows 7 Ultimate SP1 x64 VM** (build
6.1.7601, `dockurr/windows`, real WOW64 -- not Wine, not a Linux cross-
compile check): the exact four mode/hash combinations that were broken
before this fix (`-m0`/`-m1`/`-m2`/`-m3` with the default `vmac` hash)
are now 12/12 PASS with byte-identical round trips (`fc /b`) across
three files, clean `0`/`0`/`0` exit codes. This is meaningfully
stronger evidence than Wine alone: WOW64 is Windows' own real 32-bit
compatibility subsystem, not an independent reimplementation.

## Bug #3 (open, not fixed): `-hash=sha1` fails decompression checksum verification on 32-bit

`-hash=sha1` compresses successfully but fails at decompression time:
`ERROR! Decompression problem: checksum of decompressed data is not the
same as checksum of original data`. Deterministic, 100% reproducible,
every mode, every corpus file tested, on both Wine and the real Win7
VM. Confirmed unrelated to the VMAC fix above (`git diff --stat` shows
zero lines touched in `sha1.c` or anything sha1-related). Root cause
not investigated -- filed as a follow-up. **Avoid `-hash=sha1` on
32-bit builds until this is fixed**; every other hash (`vmac` default,
`md5`, `siphash`, `sha512`) is confirmed working.

## Bug #4 (fixed): SSE4.2 hardware CRC32 asm had the same undeclared-register-modification risk as VMAC

Flagged by a cross-project code review (a different fork of upstream
SREP shares this exact function) and independently confirmed here.
`Compression/SREP/hashes.cpp`'s `a_mm_crc32_u8` -- the hardware CRC32C
instruction wrapper used by `CrcRollingHash` for `-m1`/`-m2`'s
content-defined chunking, on any CPU with SSE4.2 (32-bit or 64-bit;
this is a live, actively-used path, not dead code) -- declared its
byte-sized `value` parameter with a `"rm"` constraint:

```c
asm("crc32b %[value], %[crc]\n" : [crc] "+r" (crc) : [value] "rm" (value));
```

`"rm"`'s register alternative allows *any* general-purpose register,
but on i386 only eax/ebx/ecx/edx have an 8-bit sub-register (esi/edi/
ebp/esp don't) -- if the allocator ever picks one of those for an
inlined call site under real register pressure, the build fails
("unsupported size for integer register"). Confirmed this didn't fire
in this project's own build only because GCC happened to pick a memory
operand instead of a register at `-O3` (verified via `objdump`) --
the same "safe by accident of the current compiler's choices" shape as
the VMAC bug above, not a guarantee.

**Fix**: `"rm"` → `"qm"`, restricting the register alternative to the
byte-addressable class (a/b/c/d), valid on both i386 and x86_64.
Also added an explicit `"cc"` clobber for documentation/defense-in-depth,
even though CRC32's Intel-documented flags-affected is "None" -- costs
nothing, removes any doubt, matches the same defensive reasoning applied
to `poly_step_func` above. Verified byte-for-byte identical output vs.
unmodified code (`--seed` fixed) on x86_64, and a real 10/10 `-m1`/`-m2`
round-trip pass on the 32-bit build under Wine (this host has SSE4.2,
so the hardware path is genuinely exercised, not silently skipped).

## Bug #5 (fixed): VMAC's generic 128-bit ADD128/PMUL64 fallback was miscompiled by GCC's strict-aliasing optimizer on i686

Found via real cross-project collaboration: another AI working on a
separate SREP-derived project (ytool) migrated to omega-srep, hit a
genuine cross-arch decode failure, and helped isolate it down to real
hardware (Windows 7/10, not Wine — this bug did not reproduce under
Wine at all, only on real WOW64).

**Symptom**: `osrep -d` on a real Windows 32-bit build failed with
`ERROR! Decompression problem: checksum of decompressed data is not
the same as checksum of original data` on archives that decoded
perfectly on the same-source x86_64 build. Reproduced with `-m0`
through `-m5`, with and without any LZ matches at all (a 186483-byte
file compressed with `-m1`, zero matches, pure literal content, still
failed) — ruling out the match-finding/CDC/Future-LZ code entirely.
Switching to any non-VMAC hash (`-hash=md5`) made it pass, isolating
the bug to VMAC specifically (the default hash, and the one
`-m0`-`-m3` use internally regardless of `-hash=`).

**Root cause**: `Compression/_Encryption/hashes/vmac/vmac.c`'s
`__GNUC__ && __i386__` architecture branch only defines
`GET_REVERSED_64` — it does **not** provide its own `ADD128`/`MUL64`/
`PMUL64` (unlike the `__x86_64__` branch, which has hand-written
`addq`/`adcq` asm for `ADD128`). This means i386+GCC silently falls
through to the file's generic, portable-C fallback implementations of
these macros. Bisected with the same technique used for Bug #2 above:
instrumented `vhash()` to print its internal 128-bit accumulator
(`ch`/`cl`/`ch2`/`cl2`) right before the final `l3hash()` reduction —
on the failing input, win32's values differed from win64's (one word
was off by exactly 1, a classic missed/extra-carry signature; the
other differed completely). Recompiling win32 at `-O1` instead of
`-O3` made the values match and the decode succeed; recompiling at
`-O3 -fno-strict-aliasing` (leaving every other optimization on) also
fixed it. This is the same **bug class** as the `poly_step_func`
strict-aliasing issue already documented in this file's "F5.6"-era
research (a different macro this time — `ADD128`/`PMUL64`'s generic
fallback, not `poly_step_func`'s pointer type-punning) — GCC's
strict-aliasing-based optimizations at `-O2`+ miscompile code derived
from pointer-cast buffers (`m`/`mptr`/`kptr` are repeatedly cast
between `unsigned char*` and `uint64_t*` throughout this file) in a
way that corrupts the plain-`uint64_t` carry arithmetic nearby, even
though `ADD128`/`PMUL64` themselves don't do any pointer casting.

**Fix**: added `#pragma GCC optimize ("no-strict-aliasing")` gated on
`defined(__GNUC__) && defined(__i386__)`, right after `vmac.c`'s own
architecture-detection macros (before any function bodies), so it
applies to every function in the translation unit when targeting
i386 with GCC and has zero effect on x86_64 (which never reaches the
generic fallback — it has its own asm `ADD128`/`MUL64`). This is
source-level, not a build-flag requirement someone could forget to
pass. Verified: byte-for-byte identical x86_64 output (unaffected, as
expected), the real failing 186KB archive now decodes correctly on
i686 with a byte-identical hash to x86_64, and a full 120-cell matrix
(`-m0`-`-m5` × `{vmac,md5,siphash,sha512}` × 5 corpus files) passes
clean under Wine (the known `-m0` Wine memory-allocation flake — see
Bug #2 — accounted for 5 of the first 120 attempts, all confirmed
passing on retry).

## Building a 32-bit binary

Not yet wired into the Makefile as a named target (the host-arch-vs-
target-arch detection in the Makefile's Windows/Unix branch selection
would need adjusting first). Cross-compile directly:

```bash
i686-w64-mingw32-g++ -DFREEARC_WIN -DUNICODE -D_UNICODE \
  -DFREEARC_INTEL_BYTE_ORDER -D_FILE_OFFSET_BITS=64 \
  -ICompression -ICompression/_Encryption \
  -ICompression/_Encryption/headers -ICompression/_Encryption/hashes \
  -O3 -mtune=generic -funroll-all-loops -msse2 \
  -Wno-write-strings -Wno-unused-result \
  Compression/Common.cpp Compression/SREP/srep.cpp \
  -lstdc++ -lole32 -luuid -lshell32 -ladvapi32 -static \
  -o osrep32.exe
```

(On a case-sensitive filesystem you'll also need the same lowercase
`ShObjIdl.h` shim `tests/local_hardening.sh`'s mingw stage already
documents, for `Compression/Common.cpp:1052`'s mixed-case include.)

`-funroll-all-loops` is required alongside `-O3`/`-msse2` -- without it,
`Compression/SREP/compress_cdc.cpp` fails to compile on i686 at all
(`error: unsupported size for integer register`). The Makefile always
bundles these two flags together, so this is not live in the real
build; noted here only for anyone compiling by hand with a different
flag subset.

## Summary: what works today

| mode | default hash (vmac) | md5 / siphash / sha512 | sha1 |
|---|---|---|---|
| -m0 | ✅ | ✅ | ❌ (known bug, above) |
| -m1 | ✅ | ✅ | ❌ |
| -m2 | ✅ | ✅ | ❌ |
| -m3 | ✅ | ✅ | ❌ |
| -m4 | ✅ | ✅ | ❌ |
| -m5 | ✅ | ✅ | ❌ |

32-bit support is real and usable for every mode with any hash except
`-hash=sha1`. Not yet covered by automated CI/local hardening (this is
a manually cross-compiled, manually tested target, unlike the primary
x86_64 path) -- a `tests/local_hardening.sh` stage for this is a
reasonable follow-up.

(This table originally said ✅ for `vmac` before Bug #5 above was
found and fixed -- the earlier testing that produced it didn't happen
to exercise the exact "remaining tail" carry pattern Bug #5 needed to
manifest. It's accurate now, but worth remembering that a "passing"
matrix on the corpora tested at the time doesn't guarantee every code
path was exercised -- this bug specifically needed real cross-project
testing with different content to surface.)
