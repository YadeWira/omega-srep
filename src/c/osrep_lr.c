/* Long-range match finder for OSREP (clean-room, MIT).

   Finds repeats of at least `minlen` bytes anywhere earlier in the input,
   not only inside one block.  The input is indexed every `step` bytes: the
   hash of the `win` bytes starting at each multiple of `step` goes into a
   bucketed table.  The scan computes a rolling hash of `win` bytes at every
   position, checks a bit filter, looks up the bucket, verifies the bytes and
   extends the match forward and backward.  A repeat of `win + step - 1`
   bytes or more always contains an indexed window, so with win = step =
   minlen / 2 every repeat of minlen - 1 bytes is seen.

   The caller owns every buffer (no libc): the filter, the table and the
   output.  Matches come out in destination order, never overlapping in
   destination, each with src < dst.  Deterministic: no addresses, no
   threads. */

#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint64_t src;
  uint64_t dst;
  uint64_t len;
} osrep_lr_match;

#define LR_B UINT64_C(0x9E3779B97F4A7C15)
#define LR_WAYS 4u

static uint64_t lr_hash(const uint8_t *p, uint32_t win) {
  uint64_t h = 0;
  uint32_t i;
  for (i = 0; i < win; i++) h = h * LR_B + p[i] + 1u;
  return h;
}

static uint64_t lr_mix(uint64_t h) {
  h ^= h >> 31;
  h *= UINT64_C(0xD6E8FEB86659FD93);
  h ^= h >> 32;
  return h;
}

/* table: (1 << tbits) buckets of LR_WAYS entries, each entry two u32:
   tag and index + 1 of the window (position = index * step); 0 = empty.
   filter: (1 << fbits) bits. */
static void lr_insert(uint32_t *table, uint32_t tbits, uint8_t *filter,
                      uint32_t fbits, uint64_t h, uint32_t idx1) {
  uint64_t m = lr_mix(h);
  uint32_t *b = table + ((m >> (64 - tbits)) * LR_WAYS * 2u);
  uint32_t tag = (uint32_t)m;
  uint64_t f = m & ((UINT64_C(1) << fbits) - 1u);
  uint32_t i;
  filter[f >> 3] |= (uint8_t)(1u << (f & 7u));
  /* newest first: shift the others down, the oldest falls out */
  for (i = LR_WAYS - 1u; i > 0; i--) {
    b[2u * i] = b[2u * (i - 1u)];
    b[2u * i + 1u] = b[2u * (i - 1u) + 1u];
  }
  b[0] = tag;
  b[1] = idx1;
}

static uint64_t lr_fwd(const uint8_t *d, uint64_t a, uint64_t b, uint64_t n) {
  uint64_t l = 0;
  while (b + l < n && d[a + l] == d[b + l]) l++;
  return l;
}

static int lr_same(const uint8_t *a, const uint8_t *b, uint32_t n) {
  uint32_t i;
  for (i = 0; i < n; i++)
    if (a[i] != b[i]) return 0;
  return 1;
}

/* Returns the number of matches written, or SIZE_MAX if `cap` is too
   small.  mindist: matches with dst - src < mindist are not emitted
   (0 = all). */
size_t osrep_lr_find(const uint8_t *d, uint64_t n, uint32_t minlen,
                     uint32_t win, uint32_t step, uint64_t mindist,
                     uint32_t *table, uint32_t tbits, uint8_t *filter,
                     uint32_t fbits, osrep_lr_match *out, size_t cap) {
  uint64_t bw1 = 1, h, q, last_end = 0, next_ins = 0;
  size_t count = 0;
  uint32_t i;
  if (win == 0 || step == 0 || n < (uint64_t)win || minlen < win) return 0;
  for (i = 1; i < win; i++) bw1 *= LR_B;
  h = lr_hash(d, win);
  q = 0;
  while (q + win <= n) {
    uint64_t m = lr_mix(h);
    uint64_t f = m & ((UINT64_C(1) << fbits) - 1u);
    if (filter[f >> 3] & (1u << (f & 7u))) {
      uint32_t *b = table + ((m >> (64 - tbits)) * LR_WAYS * 2u);
      uint32_t tag = (uint32_t)m;
      uint64_t best_len = 0, best_src = 0, best_back = 0;
      uint32_t w;
      for (w = 0; w < LR_WAYS; w++) {
        uint64_t p, fl, bl;
        if (b[2u * w + 1u] == 0) break;
        if (b[2u * w] != tag) continue;
        p = (uint64_t)(b[2u * w + 1u] - 1u) * step;
        if (p >= q || !lr_same(d + p, d + q, win)) continue;
        fl = win + lr_fwd(d, p + win, q + win, n);
        bl = 0;
        while (bl < p && q - bl > last_end && d[p - bl - 1u] == d[q - bl - 1u])
          bl++;
        if (fl + bl > best_len) {
          best_len = fl + bl;
          best_src = p - bl;
          best_back = bl;
        }
      }
      if (best_len >= minlen && (q - best_back) - best_src >= mindist) {
        uint64_t dst = q - best_back, end = dst + best_len;
        if (count >= cap) return (size_t)-1;
        out[count].src = best_src;
        out[count].dst = dst;
        out[count].len = best_len;
        count++;
        last_end = end;
        /* index the windows the match skips over */
        while (next_ins * step < end) {
          if (next_ins * step + win <= n)
            lr_insert(table, tbits, filter, fbits,
                      lr_hash(d + next_ins * step, win),
                      (uint32_t)(next_ins + 1u));
          next_ins++;
        }
        q = end;
        if (q + win > n) break;
        h = lr_hash(d + q, win);
        continue;
      }
    }
    if (q == next_ins * step) {
      lr_insert(table, tbits, filter, fbits, h, (uint32_t)(next_ins + 1u));
      next_ins++;
    }
    if (q + win >= n) break;
    h = (h - (uint64_t)(d[q] + 1u) * bw1) * LR_B + d[q + win] + 1u;
    q++;
  }
  return count;
}
