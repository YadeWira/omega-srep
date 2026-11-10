/* OSREP match finder: the exact greedy/lazy hash-chain parse of -m3/-m4/-m5.

   Pure leaf function: the caller owns head/prev and the output array. The
   Pascal reference in osrep_encoder.pas must produce the same matches;
   tests/native_match.sh compares the two builds byte for byte. */
#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint32_t source;
  uint32_t dest;
  uint32_t len;
} osrep_match;

typedef struct {
  const uint8_t *data;
  size_t n;
  uint32_t min_match;
  uint32_t depth;
  uint32_t stride;
  int method;
  int32_t *head;
  uint32_t mask;
  int32_t *prev;
} match_ctx;

static uint32_t hash4(const uint8_t *p) {
  uint32_t h = (uint32_t)p[0] * UINT32_C(0x9E3779B1);
  h ^= (uint32_t)p[1] * UINT32_C(0x85EBCA77);
  h ^= (uint32_t)p[2] * UINT32_C(0xC2B2AE3D);
  h ^= (uint32_t)p[3] * UINT32_C(0x27D4EB2F);
  h ^= h >> 15;
  return h;
}

static uint64_t load64(const void *p) {
  uint64_t v;
  __builtin_memcpy(&v, p, sizeof v);
  return v;
}

static uint32_t match_len(const uint8_t *a, const uint8_t *b, size_t max) {
  size_t i = 0;
  while (i + 8 <= max) {
    if (load64(a + i) != load64(b + i)) break;
    i += 8;
  }
  while (i < max && a[i] == b[i]) i++;
  return (uint32_t)i;
}

static void insert_pos(match_ctx *c, size_t p) {
  uint32_t h;
  if (p + 4 > c->n) return;
  if (c->stride > 1 && (p % c->stride) != 0) return;
  h = hash4(c->data + p) & c->mask;
  c->prev[p] = c->head[h];
  c->head[h] = (int32_t)p;
}

static void find_best(match_ctx *c, size_t p, uint32_t *blen, int32_t *bsrc) {
  size_t max = c->n - p;
  uint32_t h, d, l;
  int32_t cand;
  *blen = 0;
  *bsrc = -1;
  if (max < 4) return;
  h = hash4(c->data + p) & c->mask;
  cand = c->head[h];
  d = c->depth;
  if (c->method >= 5) {
    d *= 2;
    if (d > 256) d = 256;
  }
  while (cand >= 0 && d > 0) {
    l = match_len(c->data + (size_t)cand, c->data + p, max);
    if (l > *blen) {
      *blen = l;
      *bsrc = cand;
      if (l == max) break;
    }
    cand = c->prev[cand];
    d--;
  }
}

size_t osrep_match_find(const uint8_t *data, size_t n, uint32_t min_match,
                        uint32_t chain_depth, uint32_t stride, int method,
                        int32_t *head, uint32_t mask, int32_t *prev,
                        osrep_match *out, size_t cap) {
  match_ctx c;
  size_t p = 0, count = 0;
  c.data = data;
  c.n = n;
  c.min_match = min_match;
  c.depth = chain_depth;
  c.stride = stride;
  c.method = method;
  c.head = head;
  c.mask = mask;
  c.prev = prev;

  while (p < n) {
    uint32_t blen, nlen;
    int32_t bsrc, nsrc;
    find_best(&c, p, &blen, &bsrc);
    if (bsrc >= 0 && blen >= min_match) {
      if (method >= 4 && p + 1 < n && blen < n - p) {
        size_t k;
        insert_pos(&c, p);
        find_best(&c, p + 1, &nlen, &nsrc);
        if (nlen > blen + 1) {
          p++;
          continue;
        }
        for (k = p + 1; k < p + blen; k++) insert_pos(&c, k);
      } else {
        size_t k;
        for (k = p; k < p + blen; k++) insert_pos(&c, k);
      }
      if (count >= cap) return (size_t)-1;
      out[count].source = (uint32_t)bsrc;
      out[count].dest = (uint32_t)p;
      out[count].len = blen;
      count++;
      p += blen;
    } else {
      insert_pos(&c, p);
      p++;
    }
  }
  return count;
}
