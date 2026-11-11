/* SHA-1 for the zpaq-std fragmenter integration.

   Scalar portable implementation (FIPS 180-4). A SHA-NI path can be added
   later without changing this API; the host used for the current benchmarks
   has no SHA-NI. */
#include <stddef.h>
#include <stdint.h>

static uint32_t rol(uint32_t x, unsigned n) {
  return (x << n) | (x >> (32 - n));
}

static void sha1_block(uint32_t h[5], const uint8_t *p) {
  uint32_t w[80], a, b, c, d, e, t;
  int i;
  for (i = 0; i < 16; i++)
    w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
           ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
  for (i = 16; i < 80; i++)
    w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  a = h[0];
  b = h[1];
  c = h[2];
  d = h[3];
  e = h[4];
  for (i = 0; i < 80; i++) {
    uint32_t f, k;
    if (i < 20) {
      f = (b & c) | ((~b) & d);
      k = UINT32_C(0x5A827999);
    } else if (i < 40) {
      f = b ^ c ^ d;
      k = UINT32_C(0x6ED9EBA1);
    } else if (i < 60) {
      f = (b & c) | (b & d) | (c & d);
      k = UINT32_C(0x8F1BBCDC);
    } else {
      f = b ^ c ^ d;
      k = UINT32_C(0xCA62C1D6);
    }
    t = rol(a, 5) + f + e + k + w[i];
    e = d;
    d = c;
    c = rol(b, 30);
    b = a;
    a = t;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
}

void osrep_sha1(const uint8_t *data, size_t len, uint8_t out[20]) {
  uint32_t h[5] = {UINT32_C(0x67452301), UINT32_C(0xEFCDAB89),
                   UINT32_C(0x98BADCFE), UINT32_C(0x10325476),
                   UINT32_C(0xC3D2E1F0)};
  uint8_t tail[128];
  size_t full = len / 64;
  size_t rem = len % 64;
  size_t i;
  uint64_t bits = (uint64_t)len * 8;
  for (i = 0; i < full; i++)
    sha1_block(h, data + i * 64);
  /* Padding: data, 0x80, zeros, then the 64-bit big-endian bit length. */
  for (i = 0; i < 128; i++)
    tail[i] = 0;
  if (rem > 0)
    for (i = 0; i < rem; i++)
      tail[i] = data[full * 64 + i];
  tail[rem] = 0x80;
  if (rem < 56) {
    for (i = 0; i < 8; i++)
      tail[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
    sha1_block(h, tail);
  } else {
    for (i = 0; i < 8; i++)
      tail[120 + i] = (uint8_t)(bits >> (56 - 8 * i));
    sha1_block(h, tail);
    sha1_block(h, tail + 64);
  }
  for (i = 0; i < 5; i++) {
    out[i * 4] = (uint8_t)(h[i] >> 24);
    out[i * 4 + 1] = (uint8_t)(h[i] >> 16);
    out[i * 4 + 2] = (uint8_t)(h[i] >> 8);
    out[i * 4 + 3] = (uint8_t)h[i];
  }
}
