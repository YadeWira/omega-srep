/* OSREP CRC-32C: reflected polynomial 0x82F63B78, init 0 and no final XOR,
   exactly as the v6 container defines it.

   Uses the x86 crc32 instruction when SSE4.2 is present; otherwise a small
   bitwise fallback. The Pascal table implementation remains the reference
   (build with -dOSREP_NO_NATIVE). No libc, no allocation. */
#include <stddef.h>
#include <stdint.h>

#if (defined(__x86_64__) || defined(__i386__)) && defined(__GNUC__)
#include <nmmintrin.h>
#define OSREP_X86 1
#else
#define OSREP_X86 0
#endif

#define POLY UINT32_C(0x82F63B78)

static uint32_t crc_sw(uint32_t crc, const uint8_t *p, size_t n) {
  size_t i;
  int k;
  for (i = 0; i < n; i++) {
    crc ^= p[i];
    for (k = 0; k < 8; k++)
      crc = (crc >> 1) ^ ((crc & 1u) ? POLY : 0u);
  }
  return crc;
}

#if OSREP_X86
static int has_sse42(void) {
  static int cached = -1;
  uint32_t eax, ebx, ecx, edx;
  if (cached >= 0) return cached;
  eax = 1;
  __asm__ __volatile__("cpuid"
                       : "+a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx));
  cached = (ecx & (UINT32_C(1) << 20)) != 0;
  return cached;
}

__attribute__((target("sse4.2")))
static uint32_t crc_hw(uint32_t crc, const uint8_t *p, size_t n) {
#if defined(__x86_64__)
  uint64_t c = crc;
  while (n >= 8) {
    uint64_t v;
    __builtin_memcpy(&v, p, sizeof v);
    c = _mm_crc32_u64(c, v);
    p += 8;
    n -= 8;
  }
  while (n > 0) {
    c = _mm_crc32_u8((uint32_t)c, *p);
    p++;
    n--;
  }
  return (uint32_t)c;
#else
  uint32_t c = crc;
  while (n >= 4) {
    uint32_t v;
    __builtin_memcpy(&v, p, sizeof v);
    c = _mm_crc32_u32(c, v);
    p += 4;
    n -= 4;
  }
  while (n > 0) {
    c = _mm_crc32_u8(c, *p);
    p++;
    n--;
  }
  return c;
#endif
}
#endif

uint32_t osrep_crc32c(uint32_t crc, const void *data, size_t n) {
  const uint8_t *p = (const uint8_t *)data;
  if (n == 0) return crc;
#if OSREP_X86
  if (has_sse42()) return crc_hw(crc, p, n);
#endif
  return crc_sw(crc, p, n);
}
