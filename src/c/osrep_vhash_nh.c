/* VHASH NH layer for OSREP (clean-room, MIT): the inner loop of the block
   digest (hash_id 4, spec/format-v6.md §2.6), the hot part of VHASH.

   For `nw` 64-bit words of `m` (nw even, little-endian), with key words
   k[0 .. nw + 1]:
     r1 = sum over even i of (m[i] + k[i])     * (m[i+1] + k[i+1])
     r2 = sum over even i of (m[i] + k[i + 2]) * (m[i+1] + k[i+3])
   each product 64 x 64 -> 128 bits, sums mod 2^128.  out = {r1 high,
   r1 low, r2 high, r2 low}.  Same results as NhFull2 in osrep_vhash.pas
   (its Pascal reference).  No libc. */

#include <stdint.h>

static uint64_t nh_get64(const uint8_t *p) {
  return (uint64_t)p[0] | ((uint64_t)p[1] << 8) | ((uint64_t)p[2] << 16) |
         ((uint64_t)p[3] << 24) | ((uint64_t)p[4] << 32) |
         ((uint64_t)p[5] << 40) | ((uint64_t)p[6] << 48) |
         ((uint64_t)p[7] << 56);
}

#ifdef __SIZEOF_INT128__
void osrep_vhash_nh2(const uint8_t *m, const uint64_t *k, uint32_t nw,
                     uint64_t *out) {
  unsigned __int128 r1 = 0, r2 = 0;
  uint32_t i;
  for (i = 0; i < nw; i += 2) {
    uint64_t v0 = nh_get64(m + 8u * i), v1 = nh_get64(m + 8u * i + 8u);
    r1 += (unsigned __int128)(v0 + k[i]) * (v1 + k[i + 1u]);
    r2 += (unsigned __int128)(v0 + k[i + 2u]) * (v1 + k[i + 3u]);
  }
  out[0] = (uint64_t)(r1 >> 64);
  out[1] = (uint64_t)r1;
  out[2] = (uint64_t)(r2 >> 64);
  out[3] = (uint64_t)r2;
}
#else
/* 32-bit targets: the product from four 32 x 32 -> 64 multiplications */
static void nh_mul_add(uint64_t a, uint64_t b, uint64_t *h, uint64_t *l) {
  uint64_t a0 = a & 0xFFFFFFFFu, a1 = a >> 32, b0 = b & 0xFFFFFFFFu,
           b1 = b >> 32;
  uint64_t lo = a0 * b0, m1 = a0 * b1, m2 = a1 * b0, hi = a1 * b1;
  uint64_t t = lo + (m1 << 32);
  hi += (m1 >> 32) + (t < lo);
  lo = t + (m2 << 32);
  hi += (m2 >> 32) + (lo < t);
  *l += lo;
  *h += hi + (*l < lo);
}

void osrep_vhash_nh2(const uint8_t *m, const uint64_t *k, uint32_t nw,
                     uint64_t *out) {
  uint64_t h1 = 0, l1 = 0, h2 = 0, l2 = 0;
  uint32_t i;
  for (i = 0; i < nw; i += 2) {
    uint64_t v0 = nh_get64(m + 8u * i), v1 = nh_get64(m + 8u * i + 8u);
    nh_mul_add(v0 + k[i], v1 + k[i + 1u], &h1, &l1);
    nh_mul_add(v0 + k[i + 2u], v1 + k[i + 3u], &h2, &l2);
  }
  out[0] = h1;
  out[1] = l1;
  out[2] = h2;
  out[3] = l2;
}
#endif
