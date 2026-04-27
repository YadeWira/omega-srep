# Sanitizer-clean run record

Pre-release stability check: build the full test suite under
AddressSanitizer (and optionally UBSan) and verify no memory-safety
issues exist in the F5-generation code (`Compression/SREP/dedup.cpp`,
`Compression/SREP/dup_wrapper.cpp`, plus the modifications to
`Compression/SREP/hashes.cpp` and `Compression/Common.cpp`).

## How to run

```bash
make clean
make bin/osrep bin/dedup_test \
  CFLAGS="-O1 -g -fsanitize=address -fno-omit-frame-pointer" \
  LDFLAGS="-lpthread -lstdc++ -fsanitize=address" \
  STATIC=""

ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/roundtrip.sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/fuzz.sh 5
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/dedup_xtest.sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/dup_roundtrip.sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/dup_native_roundtrip.sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/dup_corruption_fuzz.sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 bash tests/dup_concurrency.sh
```

`detect_leaks=0` is on because srep_main upstream allocates a few
buffers via `new[]` and never frees them — it relies on OS
process-cleanup at exit. The leaks are not introduced by F5 work
and are not exploitable; they're an upstream pattern. Disabling
detection just keeps the test runner from treating an exit-time
report as failure.

## Last run (2026-04-27)

| suite                         | result      |
|-------------------------------|-------------|
| roundtrip                     | 30/30 ✓     |
| fuzz (5 seeds × 6 methods)    | 30/30 ✓     |
| dedup_xtest                   | 4/4 ✓       |
| dup_roundtrip (F5.3a wrapper) | 5/5 ✓       |
| dup_native_roundtrip (F5.3b)  | 16/16 ✓     |
| dup_corruption_fuzz           | 27/27 ✓     |
| dup_concurrency               | 8/8 ✓       |
| **total**                     | **120/120** |

Real bug surfaced and fixed during this run:

- `Compression/SREP/hashes.cpp:364-366` — VMAC result writeback used
  `((uint64_t*)result)[0] = res` on a `void*` that callers don't
  guarantee is 8-byte-aligned. UBSAN flagged it as a misaligned
  store. Fixed with `memcpy` (commit `a17cc3c`); compiles to the
  same single MOV on x86_64.

## Known UBSAN noise (NOT fixed)

These trip UBSAN strict mode but are not real bugs on x86_64 (our
only target). Vendored crypto deliberately reads unaligned uint64_t
words for performance:

- `Compression/_Encryption/hashes/vmac/vmac.c:966` — `nh_16_2`
  reads input in 16-byte blocks (two `uint64_t`s) from the user
  buffer. The input pointer offset is determined by the data, not
  alignment.
- `Compression/_Encryption/hashes/siphash/siphash.c` — same
  pattern in `U8TO64_LE`.

x86_64 hardware tolerates unaligned access (the C standard does not).
Patching the vendored crypto to use `memcpy` would slow the inner
hash loops measurably. We accept the UBSAN warnings on the strict
profile; ASAN-only runs are clean.

If a strict-alignment target ever becomes relevant (ARMv7-A
with strict alignment, etc.), this is a real porting issue. We are
declared x86_64-only, so this stays open.

## Memory leaks at exit (NOT fixed)

`srep_main` in `Compression/SREP/srep.cpp` (lines around 541, 649,
725-727) allocates working buffers with `new[]` and never frees
them; the program exits and the OS reclaims the memory. This is
upstream SREP behavior. LeakSanitizer correctly reports them but
they are not exploitable and not introduced by Omega work. Not
worth changing for v1.0 (risk of regression).

## ASAN+UBSAN combined run

When run with `-fsanitize=address,undefined` and
`UBSAN_OPTIONS=halt_on_error=1`, the tests fail because the VMAC
/ SipHash unaligned reads abort. To exercise both sanitizers in one
build, drop `halt_on_error=1` for UBSAN:

```bash
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=0:print_stacktrace=0 \
bash tests/roundtrip.sh
```

This reports UB warnings without aborting on the known crypto noise.
