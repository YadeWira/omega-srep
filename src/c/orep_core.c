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
  uint64_t *table;       /* nbuck buckets of 4 entries (32-byte
                            aligned): tag << 32 | position + 1, 0 = empty,
                            newest first */
  uint32_t minlen;       /* shortest match found by the search */
  uint32_t gram;         /* bytes hashed per anchor, 4..64 */
  uint32_t smask;        /* anchor when ((h >> sshift) & smask) == 0 */
  uint32_t maxgap;       /* force an anchor after this many positions */
  uint32_t plim;         /* longest period tried at a forced anchor, 0 =
                            none (orep_vselect) */
  uint32_t align;        /* match lengths are a multiple of this */
  uint32_t minkeep;      /* shortest continuation across chunks */
  uint32_t sshift;       /* anchor bits: sshift .. sshift + log2(smask + 1) */
  uint32_t cands;        /* candidates per anchor, 1..4 (1: one entry per
                            gram in the table, the newest) */
  uint32_t score;        /* bytes compared to pick among candidates */
  uint32_t cshift;       /* log2 of the slot (= chunk) size */
  uint32_t nbuck;        /* buckets of the table: bucket = (hash >> 32) * nbuck >> 32 */
  uint32_t runkeep;      /* a match over a run of one byte shorter than
                            this is left to the backend (0 = none) */
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

/* ---- the search, in three phases -----------------------------------------

   A block (ring[cphys .. cphys + clen), absolute position cabs) is searched
   in segments of OREP_SUB positions.  Each segment goes through:

     1. orep_anchors  per segment: the anchors (position, bucket, tag).
        Segment-local: the gear hash restarts at the segment (its bits
        below gram only depend on the last gram bytes) and so does the
        forced-anchor count, so segments are independent.
     2. orep_probe    one segment at a time, in order: up to four
        candidate distances (the earlier copies of the gram in the bucket),
        then the insert, so the table ends the same with any number of
        threads.  It lists the anchors step 3 has to look at: those with a
        candidate, and the forced ones (they try their gram's period).
     3. orep_vselect  one segment at a time, in order, over that list: the
        greedy choice.
        Each anchor not inside a match already chosen is verified first
        (verify1): the best candidate (longest forward match up to
        max(cap, score) bytes) and its lengths, the forward one capped at
        `cap` (= minlen + align) and the backward one at what the sum
        needs to reach cap.  The capped lengths decide exactly whether a
        match reaches minlen (select1); an accepted match is then extended
        in full.  Anchors inside a match are never verified, which is most
        of them in redundant data.

   Phase 1 of later segments runs on any thread at the same time as the
   probe and the select of earlier ones (orep.pas, SearchLoop); 2 and 3
   are sequential.  The result does not depend on how the work is split.
   orep_cont handles the continuation of the previous block's last
   match. */

/* anchors of the segment [s0, s1) (gram start positions, s1 + gram - 1 <=
   clen); returns the count (at most s1 - s0) */
uint32_t orep_anchors(const orep_cfg *c, const uint8_t *p, uint32_t s0,
                      uint32_t s1, uint32_t *apos, uint32_t *aidx,
                      uint32_t *atag) {
  const uint64_t *T = c->T;
  const uint32_t g = c->gram, sshift = c->sshift, maxgap = c->maxgap;
  const uint64_t nb = c->nbuck;
  uint32_t na = 0, nn = 0, last = s0, pos, i;
  uint64_t h = 0;
  if (s1 <= s0) return 0;
  for (i = 0; i + 1 < g; i++) h = (h << 1) + T[p[s0 + i]];
  /* pass 1: the content-defined anchors (into aidx).  With the table
     shifted left by 64 - g, the anchor bits sshift..g-1 of h are the top
     bits of h2 = h << (64 - g), and the test is h2 < lim. */
  {
    const uint8_t *q = p + g - 1;
    const uint64_t lim = UINT64_C(1) << ((sshift + 64u - g) & 63u);
    uint64_t T2[256], h2 = h << (64u - g);
    for (i = 0; i < 256; i++) T2[i] = T[i] << (64u - g);
    pos = s0;
    if (sshift >= g) {
      /* no anchor bits (smask 0): every position */
      for (; pos < s1; pos++) aidx[nn++] = pos;
    }
#if defined(__x86_64__) && defined(__GNUC__)
    /* 64 positions at a time into a bit mask (cmp / adc, no store per
       position: the first one ends in the top bit), then its set bits in
       order.  t0 is rax: a base of rbp or r13 would make the lea a slow
       three-operand one. */
    /* only with sparse anchors (one in 16 or fewer): with denser ones
       most blocks hold more than four and the bit loop is slower than
       the plain one below */
    while (c->smask >= 15u && pos + 64u <= s1) {
      const uint8_t *r = q + pos;
      uint64_t m = 0, t0;
      uint32_t k;
      for (k = 0; k < 64u; k += 8u) {
#define OREP_STEP(o)                                                         \
  "movzbl " #o "(%[r]), %k[t0]\n\t"                                         \
  "movq (%[T], %[t0], 8), %[t0]\n\t"                                         \
  "leaq (%[t0], %[h], 2), %[h]\n\t"                                          \
  "cmpq %[lim], %[h]\n\t"                                                    \
  "adcq %[m], %[m]\n\t"
        __asm__(OREP_STEP(0) OREP_STEP(1) OREP_STEP(2) OREP_STEP(3)
                OREP_STEP(4) OREP_STEP(5) OREP_STEP(6) OREP_STEP(7)
                : [h] "+r"(h2), [m] "+r"(m), [t0] "=&a"(t0)
                : [r] "r"(r + k), [T] "r"(T2), [lim] "r"(lim),
                  "m"(*(const uint8_t(*)[8])(r + k)),
                  "m"(*(const uint64_t(*)[256])T2)
                : "cc");
#undef OREP_STEP
      }
      /* usually at most four: those without a branch per bit */
      for (k = 0; k < 4u; k++) {
        uint32_t b = clz64(m | 1u);
        aidx[nn] = pos + b;
        nn += m != 0;
        m &= ~(UINT64_C(0x8000000000000000) >> b);
      }
      while (m) {
        uint32_t b = clz64(m);
        aidx[nn++] = pos + b;
        m &= ~(UINT64_C(0x8000000000000000) >> b);
      }
      pos += 64u;
    }
#endif
    /* without branches: store every position, keep the anchors */
    for (; pos < s1; pos++) {
      h2 = (h2 << 1) + T2[q[pos]];
      aidx[nn] = pos;
      nn += h2 < lim;
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
    aidx[i] = (uint32_t)(((m >> 32) * nb) >> 32);
    atag[i] = (uint32_t)m;
  }
  return na;
}

/* one table step for the anchor at block offset a with bucket b and tag:
   its candidates into o[0..3] (0 after the last), then the insert.
   Returns 1 when there is a candidate. */
static inline __attribute__((always_inline)) uint32_t
probe1(orep_cfg *c, uint64_t cabs, uint32_t a, uint64_t *b, uint32_t tag,
       uint32_t *o) {
  const uint64_t W = c->window, md = c->mindist;
  const uint32_t cur32 = (uint32_t)(cabs + a);
  const uint64_t e0 = b[0], e1 = b[1], e2 = b[2], e3 = b[3];
  uint32_t got = 0;
  o[0] = o[1] = o[2] = o[3] = 0;
  if (__builtin_expect(((uint32_t)(e0 >> 32) == tag) |
                           ((uint32_t)(e1 >> 32) == tag) |
                           ((uint32_t)(e2 >> 32) == tag) |
                           ((uint32_t)(e3 >> 32) == tag),
                       0)) {
    uint32_t k = 0, w, ins = 3;
    for (w = 0; w < 4; w++) {
      uint64_t e = b[w];
      if ((uint32_t)(e >> 32) == tag && (uint32_t)e) {
        uint64_t dd = (uint32_t)(cur32 - ((uint32_t)e - 1u));
        if (dd && dd >= md && dd <= W && dd <= cabs + a) o[k++] = (uint32_t)dd;
        if (w < ins) ins = w;
      }
    }
    /* cands 1, one entry per gram: the newer copy replaces the older one
       if that is among the first three (else the last entry goes, as
       always) */
    if (c->cands != 1) ins = 3;
    for (w = ins; w > 0; w--) b[w] = b[w - 1];
    got = k != 0;
  } else {
    /* the common case, no entry with this tag: no candidate, and the
       new entry goes in front */
    b[3] = e2;
    b[2] = e1;
    b[1] = e0;
  }
  b[0] = ((uint64_t)tag << 32) | (uint32_t)(cur32 + 1u);
  return got;
}

/* table pass over the anchors [0, nl) of a segment, in order:
   cand4[4i..4i+3] = the distances of the (up to four) earlier copies of
   the gram of anchor i, newest first, 0 after the last; then the insert,
   newest first (copies of the same gram are kept: verify picks the best).
   It also lists, in order, into aidx (entry i is written after it is
   read) the anchors orep_vselect has to look at: those with a candidate
   and, with plim, the forced ones (maxgap after the anchor before, or
   after the segment start, where orep_anchors restarts the count),
   flagged OREP_FORCED.  Returns their count. */
#define OREP_FORCED 0x80000000u
uint32_t orep_probe(orep_cfg *c, uint64_t cabs, const uint32_t *apos,
                    uint32_t *aidx, const uint32_t *atag, uint32_t nl,
                    uint32_t *cand4) {
  uint64_t *table = c->table;
  const uint32_t mg = c->maxgap, per = c->plim != 0;
  uint32_t i, nc = 0, prev = nl ? apos[0] & ~(OREP_SUB - 1u) : 0;
  for (i = 0; i < nl && i < OREP_PF; i++) pf(table + 4u * aidx[i]);
  for (i = 0; i < nl; i++) {
    const uint32_t a = apos[i];
    uint32_t got, fo;
    if (i + OREP_PF < nl) pf(table + 4u * aidx[i + OREP_PF]);
    got = probe1(c, cabs, a, table + 4u * aidx[i], atag[i], cand4 + 4u * i);
    fo = per & (a - prev == mg);
    prev = a;
    aidx[nc] = i | (fo ? OREP_FORCED : 0u);
    nc += got | fo;
  }
  return nc;
}

static uint64_t srcpos(const orep_cfg *c, uint64_t dp, uint64_t d) {
  return dp >= d ? dp - d : dp + c->ring_size - d;
}

/* verify one anchor at block offset a, candidates c4 (0 after the last):
   the best of the first nc (the longest forward match, compared up to
   sc = max(cap, score) bytes; the newest wins a tie) into *cand, and its
   capped lengths */
static void verify1(const orep_cfg *c, uint64_t cabs, uint64_t cphys,
                    uint32_t clen, uint32_t a, const uint32_t *c4,
                    uint32_t nc, uint32_t cap, uint32_t sc, uint32_t *cand,
                    uint32_t *fl, uint32_t *bl) {
  uint32_t best = 0, bf = 0, k;
  uint64_t dp = cphys + a;
  for (k = 0; k < nc && c4[k]; k++) {
    uint32_t mf = clen - a, f;
    if (mf > sc) mf = sc;
    f = fwd(c, srcpos(c, dp, c4[k]), dp, mf);
    if (!best || f > bf) {
      best = c4[k];
      bf = f;
      if (bf >= sc) break; /* the later ones can only tie: this one wins */
    }
  }
  *cand = best;
  if (best) {
    uint32_t mb = a;
    uint64_t s = srcpos(c, dp, best);
    if ((uint64_t)mb > cabs + a - best) mb = (uint32_t)(cabs + a - best);
    *fl = bf < cap ? bf : cap;
    /* backward only as far as the total needs to reach cap */
    if (mb > cap - *fl) mb = cap - *fl;
    *bl = *fl >= c->gram ? bwd(c, s, dp, mb) : 0;
  }
}

/* prefetch the candidates' bytes of an anchor */
static void pfcand(const orep_cfg *c, uint64_t cphys, uint32_t a,
                   const uint32_t *c4) {
  uint32_t k;
  for (k = 0; k < c->cands && c4[k]; k++)
    pf(sp(c, srcpos(c, cphys + a, c4[k])));
}

/* the greedy choice for one anchor at a >= *ls with candidate d (nonzero)
   and capped lengths f, bl0: appends the match, if any, and moves *ls.
   Returns 0, or -1 when mcap is too small. */
static int32_t select1(const orep_cfg *c, uint64_t cabs, uint64_t cphys,
                       uint32_t clen, uint32_t a, uint32_t d, uint32_t f,
                       uint32_t bl0, uint32_t cap, uint32_t *ls,
                       uint32_t *nm, uint32_t *lit, uint32_t *len,
                       uint64_t *dist, uint32_t mcap) {
  uint32_t b, lim, tot, bc;
  if (f < c->gram) return 0;
  lim = a - *ls;
  if ((uint64_t)lim > cabs + a - d) lim = (uint32_t)(cabs + a - d);
  b = bl0;
  bc = b >= cap - f;            /* the backward length may be capped */
  if (b > lim) b = lim;
  if (f < cap && (!bc || lim <= bl0)) {
    /* the exact lengths: decide now */
    tot = b + f;
    tot -= tot % c->align;
    if (tot < c->minlen) return 0;
  } else {
    /* a capped length means the sum reaches cap = minlen + align:
       accepted; extend in full */
    uint64_t dp = cphys + a, s = srcpos(c, dp, d);
    if (f >= cap) f = fwd(c, s, dp, clen - a);
    if (bc && lim > bl0) b = bwd(c, s, dp, lim);
    tot = b + f;
    tot -= tot % c->align;
    if (tot < c->minlen) return 0;
  }
  if (tot < c->runkeep) {
    /* a short run of one byte costs the backend less than a match */
    const uint8_t *q = sp(c, cphys + a - b);
    uint32_t i = 1;
    while (i < tot && q[i] == q[0]) i++;
    if (i == tot) return 0;
  }
  if (*nm >= mcap) return -1;
  lit[*nm] = a - b - *ls;
  len[*nm] = tot;
  dist[*nm] = d;
  (*nm)++;
  *ls = a - b + tot;
  return 0;
}

/* the shortest period p (max(1, mindist) <= p <= lim) of the data at
   block offset a: the gram at a equals the gram p bytes before it; 0 if
   none.  p <= a: both grams are inside the block. */
static uint32_t period(const orep_cfg *c, uint64_t cphys, uint32_t a,
                       uint32_t lim) {
  const uint8_t *q = sp(c, cphys + a);
  const uint32_t g = c->gram;
  uint32_t p, o;
  uint64_t x;
  if (lim > a) lim = a;
  if (c->mindist > lim) return 0;
  x = ld64(q);
  for (p = c->mindist > 1 ? (uint32_t)c->mindist : 1; p <= lim; p++) {
    if (ld64(q - p) != x) continue;
    for (o = 8; o + 8 <= g; o += 8)
      if (ld64(q - p + o) != ld64(q + o)) break;
    if (o + 8 > g && ld64(q - p + g - 8) == ld64(q + g - 8)) return p;
  }
  return 0;
}

/* verify and select, over the listed anchors clist[0..nc) of one segment
   (from orep_probe), in order.  *litstart (block offset of the first byte
   not yet in a match) and *nm carry over between calls.  An anchor inside
   a match already chosen is skipped before it is verified.  A forced
   anchor does not follow the content: in a run or a short period the
   table can only offer a multiple of maxgap, or nothing, so the period of
   its gram (up to plim) is tried first, and wins a tie.  Returns 0, or -1
   when mcap is too small. */
int32_t orep_vselect(const orep_cfg *c, uint64_t cabs, uint64_t cphys,
                     uint32_t clen, const uint32_t *apos,
                     const uint32_t *cand4, const uint32_t *clist,
                     uint32_t nc, uint32_t cap, uint32_t *litstart,
                     uint32_t *nm, uint32_t *lit, uint32_t *len,
                     uint64_t *dist, uint32_t mcap) {
  const uint32_t sc = cap > c->score ? cap : c->score;
  const uint32_t plim = c->plim < c->maxgap ? c->plim : c->maxgap - 1u;
  uint32_t i, ls = *litstart, k = *nm, d, f, b;
  for (i = 0; i < nc && i < OREP_PF2; i++) {
    const uint32_t j = clist[i] & ~OREP_FORCED;
    if (apos[j] >= ls) pfcand(c, cphys, apos[j], cand4 + 4u * j);
  }
  for (i = 0; i < nc; i++) {
    const uint32_t j = clist[i] & ~OREP_FORCED, a = apos[j];
    const uint32_t *c4 = cand4 + 4u * j;
    uint32_t p;
    if (i + OREP_PF2 < nc) {
      const uint32_t jn = clist[i + OREP_PF2] & ~OREP_FORCED;
      if (apos[jn] >= ls) pfcand(c, cphys, apos[jn], cand4 + 4u * jn);
    }
    if (a < ls) continue;
    if ((clist[i] & OREP_FORCED) && (p = period(c, cphys, a, plim)) != 0) {
      uint32_t c5[5];
      c5[0] = p;
      c5[1] = c4[0];
      c5[2] = c4[1];
      c5[3] = c4[2];
      c5[4] = c4[3];
      verify1(c, cabs, cphys, clen, a, c5, c->cands + 1u, cap, sc, &d, &f,
              &b);
    } else {
      if (!c4[0]) continue;
      verify1(c, cabs, cphys, clen, a, c4, c->cands, cap, sc, &d, &f, &b);
    }
    if (select1(c, cabs, cphys, clen, a, d, f, b, cap, &ls, &k, lit, len,
                dist, mcap) < 0)
      return -1;
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
   caller's 8 x 256 table.  Same value either way.  The caller's table has
   two more 4 x 256 parts after those: the shift of the raw state over
   OREP_CRC_L zero bytes (at 2048) and over 2 * OREP_CRC_L (at 3072). */
#define OREP_CRC_L 2048u
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

/* the raw CRC state x moved over n zero bytes, with the 4 x 256 table of
   that shift (n = OREP_CRC_L or 2 * OREP_CRC_L, built by the caller) */
static uint32_t crc_shift(const uint32_t *s, uint32_t x) {
  return s[x & 0xFFu] ^ s[256 + ((x >> 8) & 0xFFu)] ^
         s[512 + ((x >> 16) & 0xFFu)] ^ s[768 + (x >> 24)];
}

__attribute__((target("sse4.2")))
static uint32_t crc_hw(const uint32_t *t, uint32_t crc, const uint8_t *p,
                       size_t n) {
#if defined(__x86_64__)
  uint64_t c = crc;
  /* three streams of OREP_CRC_L bytes at once (the instruction's latency
     is three times its throughput), joined with the shift tables */
  while (n >= 3 * OREP_CRC_L) {
    uint64_t c1 = 0, c2 = 0;
    size_t i;
    for (i = 0; i < OREP_CRC_L; i += 8) {
      c = __builtin_ia32_crc32di(c, ld64(p + i));
      c1 = __builtin_ia32_crc32di(c1, ld64(p + OREP_CRC_L + i));
      c2 = __builtin_ia32_crc32di(c2, ld64(p + 2 * OREP_CRC_L + i));
    }
    c = crc_shift(t + 3072, (uint32_t)c) ^ crc_shift(t + 2048, (uint32_t)c1) ^
        (uint32_t)c2;
    p += 3 * OREP_CRC_L;
    n -= 3 * OREP_CRC_L;
  }
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
  if (n >= 256 && has_sse42()) return ~crc_hw(t, crc, p, n);
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
