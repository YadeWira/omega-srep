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
   in the table and then inserted.  The table has buckets of four entries
   in one cache line, newest first; several copies of a gram can be there,
   and the one that matches longest is taken.  A hit is verified and extended in both directions; repeats of
   minlen bytes contain an anchor with high probability, longer ones almost
   surely.  Anchors are collected per sub-block and the table slots are
   prefetched a few anchors ahead.

   Ring layout.  The ring has `ring_size` bytes in slots of one chunk
   (a power of two), each its own allocation, so a block is always
   contiguous; a comparison crosses slots and wraps.  The
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
  uint8_t **slots;       /* ring_size >> cshift slots of 1 << cshift bytes */
  uint64_t *table;       /* 1 << tbits buckets of 4 entries (32-byte
                            aligned): tag << 32 | position + 1, 0 = empty,
                            newest first */
  uint32_t minlen;       /* shortest match found by the search */
  uint32_t gram;         /* bytes hashed per anchor, 4..64 */
  uint32_t smask;        /* anchor when ((h >> sshift) & smask) == 0 */
  uint32_t maxgap;       /* force an anchor after this many positions */
  uint32_t tbits;
  uint32_t align;        /* match lengths are a multiple of this */
  uint32_t minkeep;      /* shortest continuation across chunks */
  uint32_t sshift;       /* anchor bits: sshift .. sshift + log2(smask + 1) */
  uint32_t cands;        /* candidates per anchor, 1..4 (1: one entry per
                            gram in the table, the newest) */
  uint32_t score;        /* bytes compared to pick among candidates */
  uint32_t cshift;       /* log2 of the slot (= chunk) size */
  uint32_t pad;
} orep_cfg;

/* the byte at ring offset p */
static const uint8_t *sp(const orep_cfg *c, uint64_t p) {
  return c->slots[p >> c->cshift] + (p & ((UINT64_C(1) << c->cshift) - 1u));
}

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

/* forward: ring[s..] against ring[d..], at most max bytes; s crosses slots
   and wraps at the end of the ring, d does not (it is inside the block,
   which is inside one slot) */
static uint32_t fwd(const orep_cfg *c, uint64_t s, uint64_t d, uint32_t max) {
  const uint8_t *dp = sp(c, d);
  const uint64_t cs = UINT64_C(1) << c->cshift;
  uint32_t l = 0;
  while (l < max) {
    uint64_t off = s & (cs - 1u);
    const uint8_t *r = c->slots[s >> c->cshift] + off;
    uint32_t run = max - l, k = 0;
    if (cs - off < run) run = (uint32_t)(cs - off);
    while (k + 8 <= run) {
      uint64_t x = ld64(r + k) ^ ld64(dp + l + k);
      if (x) return l + k + (ctz64(x) >> 3);
      k += 8;
    }
    while (k < run) {
      if (r[k] != dp[l + k]) return l + k;
      k++;
    }
    l += run;
    s += run;
    if (s == c->ring_size) s = 0;
  }
  return l;
}

/* backward: ring[s-1], ring[s-2].. against ring[d-1].., at most max bytes;
   s crosses slots and wraps below 0 */
static uint32_t bwd(const orep_cfg *c, uint64_t s, uint64_t d, uint32_t max) {
  const uint8_t *dp = sp(c, d);
  const uint64_t cs = UINT64_C(1) << c->cshift;
  uint32_t l = 0;
  while (l < max) {
    uint64_t last, off;
    const uint8_t *r;
    uint32_t run = max - l, k = 0;
    if (s == 0) s = c->ring_size;
    last = s - 1;
    off = last & (cs - 1u);
    r = c->slots[last >> c->cshift] + off + 1;   /* just past ring[s-1] */
    if (off + 1 < run) run = (uint32_t)(off + 1);
    while (k + 8 <= run) {
      uint64_t x = ld64(r - k - 8) ^ ld64(dp - l - k - 8);
      if (x) return l + k + (clz64(x) >> 3);
      k += 8;
    }
    while (k < run) {
      if (r[-(int64_t)k - 1] != dp[-(int64_t)(l + k) - 1]) return l + k;
      k++;
    }
    l += run;
    s -= run;
  }
  return l;
}


static void pf(const void *p) { __builtin_prefetch(p, 1, 0); }

/* ---- the search, in four phases ------------------------------------------

   A block (ring[cphys .. cphys + clen), absolute position cabs) is searched
   in batches of segments of OREP_SUB positions.  For each batch:

     1. orep_anchors  per segment: the anchors (position, bucket, tag).
        Segment-local: the gear hash restarts at the segment (its bits
        below gram only depend on the last gram bytes) and so does the
        forced-anchor count, so segments are independent.
     2. orep_probe    per shard of buckets (its anchors, in order): up
        to four candidate distances (the earlier copies of the gram in the
        bucket), then the insert.  A bucket belongs to one shard,
        so the table ends the same whatever the number of shards.
     3. orep_verify   per segment: the best candidate of each anchor
        (longest forward match up to 256 bytes) and its lengths, the
        forward one capped at `cap` (= minlen +
        align) and the backward one at what the sum needs to reach cap.
     4. orep_select   in order: the greedy choice.  The capped lengths
        decide exactly whether a match reaches minlen; an accepted match is
        then extended in full.

   Phases 1-3 can run on several threads; phase 4 is sequential.  The
   result does not depend on how the work is split.  orep_cont handles the
   continuation of the previous block's last match. */

/* anchors of the segment [s0, s1) (gram start positions, s1 + gram - 1 <=
   clen); returns the count (at most s1 - s0) */
uint32_t orep_anchors(const orep_cfg *c, const uint8_t *p, uint32_t s0,
                      uint32_t s1, uint32_t *apos, uint32_t *aidx,
                      uint32_t *atag) {
  const uint64_t *T = c->T;
  const uint32_t g = c->gram, smask = c->smask, sshift = c->sshift,
                 maxgap = c->maxgap, tshift = 64u - c->tbits;
  uint32_t na = 0, nn = 0, last = s0, pos, i;
  uint64_t h = 0;
  if (s1 <= s0) return 0;
  for (i = 0; i + 1 < g; i++) h = (h << 1) + T[p[s0 + i]];
  /* pass 1, without branches: the content-defined anchors (into aidx) */
  {
    const uint64_t am = (uint64_t)smask << sshift;
    const uint8_t *q = p + g - 1;
    for (pos = s0; pos < s1; pos++) {
      h = (h << 1) + T[q[pos]];
      aidx[nn] = pos;
      nn += (h & am) == 0;
    }
  }
  /* merge in the forced ones: after maxgap positions without an anchor
     (counted from s0), one every maxgap until the next natural one */
  for (i = 0; i <= nn; i++) {
    uint32_t next = i < nn ? aidx[i] : s1;
    while (next - last > maxgap) {
      last += maxgap;
      apos[na++] = last;
    }
    if (i < nn) {
      apos[na++] = next;
      last = next;
    }
  }
  /* pass 2: their hashes (independent of each other) */
  for (i = 0; i < na; i++) {
    uint64_t m = gramhash(p + apos[i], g);
    aidx[i] = (uint32_t)(m >> tshift);
    atag[i] = (uint32_t)m;
  }
  return na;
}

/* group anchors [0, n) by the shard that owns their bucket (shard t owns
   the buckets k with (k * ns) >> tbits = t), keeping their order: list
   gets the indexes, ofs[t] the end of shard t (its start is ofs[t - 1], or
   0 for t = 0); ofs has ns + 1 entries */
void orep_shard(const uint32_t *aidx, uint32_t n, uint32_t ns, uint32_t tbits,
                uint32_t *list, uint32_t *ofs) {
  uint32_t cnt[257], j, t, sh = 32u - tbits;  /* ns <= 256 */
  for (t = 0; t <= ns; t++) cnt[t] = 0;
  /* owner = (k * ns) >> tbits, with k < 2^tbits: as a 32-bit product
     shifted up first it needs no 64-bit multiply */
  for (j = 0; j < n; j++) cnt[((uint64_t)(aidx[j] << sh) * ns >> 32) + 1]++;
  for (t = 1; t <= ns; t++) cnt[t] += cnt[t - 1];
  for (j = 0; j < n; j++) {
    t = (uint32_t)((uint64_t)(aidx[j] << sh) * ns >> 32);
    list[cnt[t]++] = j;
  }
  for (t = 0; t <= ns; t++) ofs[t] = cnt[t];
}

/* table pass over the anchors list[0..nl) (indexes into the segment's
   anchors, in order; list NULL = all of 0..nl): cand4[4i..4i+3] = the
   distances of the (up to four) earlier copies of the gram of anchor
   list[i], newest first, 0 after the last; then insert, newest first
   (copies of the same gram are kept: verify picks the best).  The caller
   gives each thread the anchors of its own buckets, and cand4 in list
   order keeps the threads' writes apart. */
void orep_probe(orep_cfg *c, uint64_t cabs, const uint32_t *apos,
                const uint32_t *aidx, const uint32_t *atag,
                const uint32_t *list, uint32_t nl, uint32_t *cand4) {
  uint64_t *table = c->table;
  const uint64_t W = c->window, md = c->mindist;
  uint32_t i;
#define OREP_AT(i) (list ? list[i] : (i))
  for (i = 0; i < nl && i < OREP_PF; i++) pf(table + 4u * aidx[OREP_AT(i)]);
  for (i = 0; i < nl; i++) {
    uint32_t j = OREP_AT(i);
    uint64_t *b = table + 4u * aidx[j];
    uint32_t a = apos[j], tag = atag[j], cur32 = (uint32_t)(cabs + a);
    uint32_t *o = cand4 + 4u * i, k = 0, w;
    if (i + OREP_PF < nl) pf(table + 4u * aidx[OREP_AT(i + OREP_PF)]);
    for (w = 0; w < 4; w++)
      if ((uint32_t)(b[w] >> 32) == tag && (uint32_t)b[w]) {
        uint64_t dd = (uint32_t)(cur32 - ((uint32_t)b[w] - 1u));
        if (dd && dd >= md && dd <= W && dd <= cabs + a) o[k++] = (uint32_t)dd;
      }
    for (; k < 4; k++) o[k] = 0;
    if (c->cands == 1) {
      /* one entry per gram: the newer copy replaces the older */
      for (w = 0; w < 3; w++)
        if ((uint32_t)(b[w] >> 32) == tag && (uint32_t)b[w]) break;
    } else
      w = 3;
    for (; w > 0; w--) b[w] = b[w - 1];
    b[0] = ((uint64_t)tag << 32) | (uint32_t)(cur32 + 1u);
  }
#undef OREP_AT
}

static uint64_t srcpos(const orep_cfg *c, uint64_t dp, uint64_t d) {
  return dp >= d ? dp - d : dp + c->ring_size - d;
}

/* for anchors [0, n) of one segment: the best of their first `cands`
   candidates (the longest forward match, compared up to max(cap, score)
   bytes; the newest wins a tie) into cand[j], and its capped lengths */
void orep_verify(const orep_cfg *c, uint64_t cabs, uint64_t cphys,
                 uint32_t clen, const uint32_t *apos, const uint32_t *cand4,
                 uint32_t n, uint32_t cap, uint32_t *cand, uint32_t *fl,
                 uint32_t *bl) {
  const uint32_t sc = cap > c->score ? cap : c->score, nc = c->cands;
  uint32_t j, k;
  for (j = 0; j < n; j++) {
    const uint32_t *c4 = cand4 + 4u * j;
    uint32_t a = apos[j], best = 0, bf = 0;
    uint64_t dp = cphys + a;
    if (j + OREP_PF2 < n) {
      const uint32_t *p4 = cand4 + 4u * (j + OREP_PF2);
      uint64_t dp2 = cphys + apos[j + OREP_PF2];
      for (k = 0; k < nc && p4[k]; k++) pf(sp(c, srcpos(c, dp2, p4[k])));
    }
    for (k = 0; k < nc && c4[k]; k++) {
      uint32_t mf = clen - a, f;
      if (mf > sc) mf = sc;
      f = fwd(c, srcpos(c, dp, c4[k]), dp, mf);
      if (!best || f > bf) {
        best = c4[k];
        bf = f;
      }
    }
    cand[j] = best;
    if (best) {
      uint32_t mb = a;
      uint64_t s = srcpos(c, dp, best);
      if ((uint64_t)mb > cabs + a - best) mb = (uint32_t)(cabs + a - best);
      fl[j] = bf < cap ? bf : cap;
      /* backward only as far as the total needs to reach cap */
      if (mb > cap - fl[j]) mb = cap - fl[j];
      bl[j] = fl[j] >= c->gram ? bwd(c, s, dp, mb) : 0;
    }
  }
}

/* greedy choice over anchors [0, n) of one segment, in order.  *litstart
   (block offset of the first byte not yet in a match) and *nm carry over
   between calls.  Returns 0, or -1 when mcap is too small. */
int32_t orep_select(const orep_cfg *c, uint64_t cabs, uint64_t cphys,
                    uint32_t clen, const uint32_t *apos, const uint32_t *cand,
                    const uint32_t *fl, const uint32_t *bl, uint32_t n,
                    uint32_t cap, uint32_t *litstart, uint32_t *nm,
                    uint32_t *lit, uint32_t *len, uint64_t *dist,
                    uint32_t mcap) {
  uint32_t j, ls = *litstart, k = *nm;
  for (j = 0; j < n; j++) {
    uint32_t a = apos[j], d = cand[j], f, b, lim, tot, bc;
    if (!d || a < ls) continue;
    f = fl[j];
    if (f < c->gram) continue;
    lim = a - ls;
    if ((uint64_t)lim > cabs + a - d) lim = (uint32_t)(cabs + a - d);
    b = bl[j];
    bc = b >= cap - f;            /* the backward length may be capped */
    if (b > lim) b = lim;
    if (f < cap && (!bc || lim <= bl[j])) {
      /* the exact lengths: decide now */
      tot = b + f;
      tot -= tot % c->align;
      if (tot < c->minlen) continue;
    } else {
      /* a capped length means the sum reaches cap = minlen + align:
         accepted; extend in full */
      uint64_t dp = cphys + a, s = srcpos(c, dp, d);
      if (f >= cap) f = fwd(c, s, dp, clen - a);
      if (bc && lim > bl[j]) b = bwd(c, s, dp, lim);
      tot = b + f;
      tot -= tot % c->align;
      if (tot < c->minlen) continue;
    }
    if (k >= mcap) return -1;
    lit[k] = a - b - ls;
    len[k] = tot;
    dist[k] = d;
    k++;
    ls = a - b + tot;
  }
  *litstart = ls;
  *nm = k;
  return 0;
}

/* the previous block's last match continued at the start of this one:
   its length (a multiple of align, >= minkeep) or 0 */
uint32_t orep_cont(const orep_cfg *c, uint64_t cabs, uint64_t cphys,
                   uint32_t clen, uint64_t prev_dist) {
  uint32_t l;
  if (!prev_dist || prev_dist > cabs || prev_dist > c->window || !clen)
    return 0;
  l = fwd(c, srcpos(c, cphys, prev_dist), cphys, clen);
  l -= l % c->align;
  return l >= c->minkeep ? l : 0;
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
