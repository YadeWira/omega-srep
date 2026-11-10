/* OSREP CDC: find the chunk boundaries and the FNV-1a hash of each chunk.

   This is a leaf function: no state, no allocation, no libc. The Pascal
   reference in osrep_dedup.pas must produce the same offsets, lengths and
   hashes; tests/native_cdc.sh compares both builds.

   chunker 0: order-1 CDC (the zpaq parameters)
   chunker 1: fixed-window CDC (48-byte rolling hash)

   Returns the number of chunks, or (size_t)-1 if cap is too small. */
#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint64_t offset;
  uint32_t len;
  uint64_t hash;
} osrep_chunk;

#define DUP_MIN      (64u << 6)
#define DUP_MAX      (8128u << 6)
#define DUP_THRESHOLD (1u << (22 - 6))
#ifndef DUP_AVG
#define DUP_AVG 8192u
#endif
#define FNV_PRIME    UINT64_C(0x100000001B3)
#define FNV_OFFSET   UINT64_C(0xCBF29CE484222325)

static uint64_t fnv1a(const uint8_t *p, size_t n) {
  uint64_t h = FNV_OFFSET;
  size_t i;
  for (i = 0; i < n; i++) {
    h ^= p[i];
    h *= FNV_PRIME;
  }
  return h;
}

size_t osrep_cdc_find(const uint8_t *data, size_t n, int chunker,
                      osrep_chunk *out, size_t cap) {
  size_t count = 0;
  size_t start = 0, len = 0, i;
  uint32_t h32 = 0;
  uint64_t h64 = 0, pow = 1;
  uint8_t o1[256];
  uint8_t c1 = 0;
  int k;

  for (k = 0; k < 256; k++) o1[k] = 0;
  for (k = 0; k < 48; k++) pow *= FNV_PRIME;

  for (i = 0; i < n; i++) {
    int cut = 0;
    uint8_t c = data[i];
    len++;
    if (chunker == 0) {
      uint8_t pred = o1[c1];
      h32 = (h32 + (uint32_t)c + 1u) *
            (c == pred ? 314159265u : 271828182u);
      o1[c1] = c;
      c1 = c;
      cut = (len >= DUP_MIN) && (h32 < DUP_THRESHOLD || len >= DUP_MAX);
    } else {
      h64 = h64 * FNV_PRIME + c;
      if (i - start >= 48)
        h64 -= (uint64_t)data[i - 48] * pow;
      cut = (len >= DUP_MIN) && (h64 < UINT64_MAX / DUP_AVG || len >= DUP_MAX);
    }
    if (cut) {
      if (count >= cap) return (size_t)-1;
      out[count].offset = (uint64_t)start;
      out[count].len = (uint32_t)len;
      out[count].hash = fnv1a(data + start, len);
      count++;
      start = i + 1;
      len = 0;
      if (chunker == 0) {
        h32 = 0;
        c1 = 0;
        for (k = 0; k < 256; k++) o1[k] = 0;
      } else {
        h64 = 0;
      }
    }
  }
  if (len > 0) {
    if (count >= cap) return (size_t)-1;
    out[count].offset = (uint64_t)start;
    out[count].len = (uint32_t)len;
    out[count].hash = fnv1a(data + start, len);
    count++;
  }
  return count;
}
