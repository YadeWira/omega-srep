/* OREP match finder (clean-room, MIT).

   OREP is a one-pass streaming long-range dedup: the input goes through a
   ring buffer in chunks, and each chunk is searched against everything in
   the last `window` bytes.  This file is the hot loop: one chunk in, a list
   of (literal run, length, distance) out.  The framing, the streaming API
   and the decoder are in src/orep/orep.pas, which also holds a Pascal
   reference of this file (-dOREP_NO_NATIVE) that gives the same matches.

   Anchors.  A gear hash (h = 2h + T[byte]) runs over the chunk; its bits
   below `gram` depend only on the last `gram` bytes.  A gram is an anchor
   when bits sshift.. of the hash (all below gram) are zero under `smask`
   (content-defined, about one position in smask + 1), or when
   `maxgap` positions went by without one (so long runs and short periods
   still get anchors, at the same offsets in both copies).  The table key
   and tag come from a hash of the gram's bytes.  Every anchor is looked up
   in the table and then inserted.  The table has buckets of four entries in one cache line, at
   most one per gram (a newer copy of a gram replaces the older), newest
   first.  A hit is verified and extended in both directions; repeats of
   minlen bytes contain an anchor with high probability, longer ones almost
   surely.  Anchors are collected per sub-block and the table slots are
   prefetched a few anchors ahead.

   Ring layout.  The ring has `ring_size` bytes, a multiple of the chunk
   size, so a chunk is always contiguous; positions before it wrap.  The
   table stores the low 32 bits of the absolute position + 1 (0 = empty),
   so `window` must stay below 2^32 - chunk.

   Rules: no libc, caller-owned buffers, no global mutable state,
   deterministic (no addresses, no threads, little-endian loads only decide
   where a comparison stops, which is the same on every target). */

#include <stddef.h>
#include <stdint.h>

/* field order: arrays of u64, then u64, then pointers, then u32; the
   Pascal side declares the same record with {$PACKRECORDS C} */
typedef struct {
  uint64_t T[256];       /* per-byte random values (gear hash) */
  uint64_t window;       /* max distance */
  uint64_t ring_size;    /* bytes in the ring */
  uint64_t mindist;      /* shorter distances are left to the backend */
  uint8_t *ring;
  uint64_t *table;       /* 1 << tbits buckets of 4 entries (32-byte
                            aligned): tag << 32 | position + 1, 0 = empty,
                            newest first */
  uint32_t *scratch;     /* 3 * OREP_SUB u32 */
  uint32_t minlen;       /* shortest match found by the search */
  uint32_t gram;         /* bytes hashed per anchor, 4..64 */
  uint32_t smask;        /* anchor when ((h >> sshift) & smask) == 0 */
  uint32_t maxgap;       /* force an anchor after this many positions */
  uint32_t tbits;
  uint32_t align;        /* match lengths are a multiple of this */
  uint32_t minkeep;      /* shortest continuation across chunks */
  uint32_t sshift;       /* anchor bits: sshift .. sshift + log2(smask + 1) */
} orep_cfg;

#define OREP_SUB 65536u
#define OREP_PF 16u   /* prefetch the table slot this many anchors ahead */
#define OREP_PF2 6u   /* and the candidate's bytes this many ahead */

typedef uint64_t orep_u64u __attribute__((aligned(1), may_alias));

static uint64_t ld64(const uint8_t *p) { return *(const orep_u64u *)p; }

static uint32_t ctz64(uint64_t x) { return (uint32_t)__builtin_ctzll(x); }
static uint32_t clz64(uint64_t x) { return (uint32_t)__builtin_clzll(x); }

static uint64_t mix(uint64_t h) {
  h ^= h >> 29;
  h *= UINT64_C(0xBF58476D1CE4E5B9);
  h ^= h >> 32;
  return h;
}

/* hash of the gram (gram >= 8 bytes): its words, the last one overlapping */
static uint64_t gramhash(const uint8_t *p, uint32_t g) {
  uint64_t k = g;
  uint32_t o = 0;
  while (o + 8 < g) {
    k = (k ^ ld64(p + o)) * UINT64_C(0x9E3779B97F4A7C15);
    k ^= k >> 28;
    o += 8;
  }
  k = (k ^ ld64(p + g - 8)) * UINT64_C(0x9E3779B97F4A7C15);
  return mix(k);
}

/* forward: ring[s..] against ring[d..], at most max bytes; s wraps at the
   end of the ring, d does not (it is inside the chunk) */
static uint32_t fwd(const orep_cfg *c, uint64_t s, uint64_t d, uint32_t max) {
  const uint8_t *r = c->ring;
  uint32_t l = 0;
  while (l < max) {
    uint64_t room = c->ring_size - s;
    uint32_t run = max - l, k = 0;
    if (room < run) run = (uint32_t)room;
    while (k + 8 <= run) {
      uint64_t x = ld64(r + s + k) ^ ld64(r + d + k);
      if (x) return l + k + (ctz64(x) >> 3);
      k += 8;
    }
    while (k < run) {
      if (r[s + k] != r[d + k]) return l + k;
      k++;
    }
    l += run;
    s += run;
    d += run;
    if (s == c->ring_size) s = 0;
  }
  return l;
}

/* backward: ring[s-1], ring[s-2].. against ring[d-1].., at most max bytes;
   s wraps below 0 */
static uint32_t bwd(const orep_cfg *c, uint64_t s, uint64_t d, uint32_t max) {
  const uint8_t *r = c->ring;
  uint32_t l = 0;
  while (l < max) {
    uint32_t run = max - l, k = 0;
    if (s == 0) s = c->ring_size;
    if (s < run) run = (uint32_t)s;
    while (k + 8 <= run) {
      uint64_t x = ld64(r + s - k - 8) ^ ld64(r + d - k - 8);
      if (x) return l + k + (clz64(x) >> 3);
      k += 8;
    }
    while (k < run) {
      if (r[s - k - 1] != r[d - k - 1]) return l + k;
      k++;
    }
    l += run;
    s -= run;
    d -= run;
  }
  return l;
}

/* the way of bucket b that holds tag, or -1 */
static int way(const uint64_t *b, uint32_t tag) {
  int w;
  for (w = 0; w < 4; w++)
    if ((uint32_t)(b[w] >> 32) == tag && (uint32_t)b[w]) return w;
  return -1;
}

static void pf(const void *p) { __builtin_prefetch(p, 1, 0); }

/* Search one chunk: ring[cphys .. cphys + clen), absolute position cabs.
   prev_dist is the distance of the previous chunk's last match when it
   ended exactly at cabs (0 otherwise).  Matches go to lit/len/dist in
   order: lit[i] literal bytes, then len[i] bytes copied from dist[i] back.
   Returns the count, or -1 when cap is too small (cap = clen / minkeep + 2
   is always enough). */
int32_t orep_find(orep_cfg *c, uint64_t cabs, uint64_t cphys, uint32_t clen,
                  uint64_t prev_dist, uint32_t *lit, uint32_t *len,
                  uint64_t *dist, uint32_t cap) {
  const uint8_t *p = c->ring + cphys;
  uint32_t *apos = c->scratch, *aidx = c->scratch + OREP_SUB;
  uint32_t *atag = c->scratch + 2 * OREP_SUB;
  uint32_t n = 0, litstart = 0, g = c->gram, tshift = 64u - c->tbits;
  uint32_t lastanchor = 0, pos = 0, i;
  uint64_t h = 0, W = c->window;
  /* locals: the stores to the anchor lists could alias the config */
  const uint64_t *T = c->T;
  uint64_t *table = c->table;
  const uint32_t smask = c->smask, sshift = c->sshift, maxgap = c->maxgap;

  if (prev_dist && prev_dist <= cabs && prev_dist <= W && clen) {
    uint64_t s = cphys >= prev_dist ? cphys - prev_dist
                                    : cphys + c->ring_size - prev_dist;
    uint32_t l = fwd(c, s, cphys, clen);
    l -= l % c->align;
    if (l >= c->minkeep) {
      if (n >= cap) return -1;
      lit[n] = 0;
      len[n] = l;
      dist[n] = prev_dist;
      n++;
      litstart = l;
    }
  }
  if (clen < g) return (int32_t)n;
  for (i = 0; i + 1 < g; i++) h = (h << 1) + T[p[i]];

  while (pos + g <= clen) {
    /* collect the anchors of one sub-block */
    uint32_t end = pos + OREP_SUB, na = 0, j;
    if (end > clen - g + 1) end = clen - g + 1;
    for (; pos < end; pos++) {
      h = (h << 1) + T[p[pos + g - 1]];
      if ((((uint32_t)(h >> sshift)) & smask) == 0 ||
          pos - lastanchor >= maxgap) {
        uint64_t m = gramhash(p + pos, g);
        apos[na] = pos;
        aidx[na] = (uint32_t)(m >> tshift);
        atag[na] = (uint32_t)m;
        na++;
        lastanchor = pos;
      }
    }
    for (j = 0; j < na && j < OREP_PF; j++) pf(table + 4u * aidx[j]);
    for (j = 0; j < na; j++) {
      uint32_t a = apos[j], tag = atag[j], cur32 = (uint32_t)(cabs + a);
      uint64_t *b = table + 4u * aidx[j], ne;
      int w = way(b, tag);
      if (j + OREP_PF < na) pf(table + 4u * aidx[j + OREP_PF]);
      if (j + OREP_PF2 < na) {
        /* the candidate of a later anchor: fetch its bytes */
        const uint64_t *b2 = table + 4u * aidx[j + OREP_PF2];
        int w2 = way(b2, atag[j + OREP_PF2]);
        if (w2 >= 0) {
          uint32_t a2 = apos[j + OREP_PF2];
          uint64_t d2 =
              (uint32_t)((uint32_t)(cabs + a2) - ((uint32_t)b2[w2] - 1u));
          if (d2 && d2 <= W && d2 <= cabs + a2) {
            uint64_t dp2 = cphys + a2;
            pf(c->ring + (dp2 >= d2 ? dp2 - d2 : dp2 + c->ring_size - d2));
          }
        }
      }
      if (a >= litstart && w >= 0) {
        uint64_t d = (uint32_t)(cur32 - ((uint32_t)b[w] - 1u));
        if (d >= c->mindist && d && d <= W && d <= cabs + a) {
          uint64_t dp = cphys + a;
          uint64_t s = dp >= d ? dp - d : dp + c->ring_size - d;
          uint32_t fl = fwd(c, s, dp, clen - a);
          if (fl >= g) {
            uint32_t maxb = a - litstart, bl, tot;
            if ((uint64_t)maxb > cabs + a - d) maxb = (uint32_t)(cabs + a - d);
            bl = bwd(c, s, dp, maxb);
            tot = bl + fl;
            tot -= tot % c->align;
            if (tot >= c->minlen) {
              if (n >= cap) return -1;
              lit[n] = a - bl - litstart;
              len[n] = tot;
              dist[n] = d;
              n++;
              litstart = a - bl + tot;
            }
          }
        }
      }
      /* newest first; the same gram replaces its older entry */
      ne = ((uint64_t)tag << 32) | (uint32_t)(cur32 + 1u);
      if (w < 0) w = 3;
      for (; w > 0; w--) b[w] = b[w - 1];
      b[0] = ne;
    }
  }
  return (int32_t)n;
}

/* CRC-32C (Castagnoli), reflected, init ~0, final xor ~0 (the usual one).
   x86 with SSE4.2: the crc32 instruction (checked with cpuid on every call,
   which is once per block: no cached global); otherwise slice-by-8 with the
   caller's 8 x 256 table.  Same value either way. */
#if (defined(__x86_64__) || defined(__i386__)) && defined(__GNUC__)
#define OREP_X86 1
static int has_sse42(void) {
  uint32_t eax = 1, ebx, ecx, edx;
#if defined(__i386__) && defined(__PIC__)
  __asm__ __volatile__("xchgl %%ebx, %1; cpuid; xchgl %%ebx, %1"
                       : "+a"(eax), "=r"(ebx), "=c"(ecx), "=d"(edx));
#else
  __asm__ __volatile__("cpuid" : "+a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx));
#endif
  (void)ebx;
  return (ecx >> 20) & 1u;
}

__attribute__((target("sse4.2")))
static uint32_t crc_hw(uint32_t crc, const uint8_t *p, size_t n) {
#if defined(__x86_64__)
  uint64_t c = crc;
  while (n >= 8) {
    c = __builtin_ia32_crc32di(c, ld64(p));
    p += 8;
    n -= 8;
  }
  crc = (uint32_t)c;
#else
  while (n >= 4) {
    uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                 ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    crc = __builtin_ia32_crc32si(crc, v);
    p += 4;
    n -= 4;
  }
#endif
  while (n--) crc = __builtin_ia32_crc32qi(crc, *p++);
  return crc;
}
#else
#define OREP_X86 0
#endif

uint32_t orep_crc32c(const uint32_t *t, uint32_t crc, const uint8_t *p,
                     size_t n) {
  crc = ~crc;
#if OREP_X86
  if (n >= 256 && has_sse42()) return ~crc_hw(crc, p, n);
#endif
  while (n && ((uintptr_t)p & 7u)) {
    crc = t[(crc ^ *p++) & 0xFFu] ^ (crc >> 8);
    n--;
  }
  while (n >= 8) {
    uint64_t v = ld64(p) ^ crc;
    crc = t[7 * 256 + (v & 0xFF)] ^ t[6 * 256 + ((v >> 8) & 0xFF)] ^
          t[5 * 256 + ((v >> 16) & 0xFF)] ^ t[4 * 256 + ((v >> 24) & 0xFF)] ^
          t[3 * 256 + ((v >> 32) & 0xFF)] ^ t[2 * 256 + ((v >> 40) & 0xFF)] ^
          t[1 * 256 + ((v >> 48) & 0xFF)] ^ t[(v >> 56) & 0xFF];
    p += 8;
    n -= 8;
  }
  while (n--) crc = t[(crc ^ *p++) & 0xFFu] ^ (crc >> 8);
  return ~crc;
}
