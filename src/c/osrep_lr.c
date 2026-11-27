/* Long-range match finder for OSREP (clean-room, MIT).

   Finds repeats of at least `minlen` bytes anywhere earlier in the input,
   not only inside one block.  The input is indexed every `step` bytes: the
   hash of the `win` bytes starting at each multiple of `step` goes into a
   bucketed table.  Every position is looked up: its window's hash is
   checked against a bit filter, then the bucket, then the bytes, and the
   match is extended forward and backward.  A repeat of `win + step - 1`
   bytes or more always contains an indexed window, so with win = step =
   minlen / 2 every repeat of minlen - 1 bytes is seen.

   The length of every match is a multiple of `align`: the bytes after a
   removed match keep their offset modulo align, which backends model
   (LZMA's position bits, x86 code); measured on silesia's mozilla, a tar of
   executables, +1.5 % with xz unaligned and -0.1 % with align 16.

   Three steps, so that the costly part can run on several threads (the
   caller's; this file has none) and the matches do not depend on how many:
   1. osrep_lr_index: the hash of every indexed window, by pieces of the
      input; osrep_lr_filter_add puts them all in the filter.  The table
      gets them later, in order, but the filter is complete from the start.
   2. osrep_lr_scan: the rolling hash at every position of a piece, and the
      positions whose hash passes the filter (or that are indexed): about
      1-10 % of them.  A piece only needs its own bytes and the filter.
   3. osrep_lr_feed: those positions, in order, against the table (inserts
      and lookups, as one sequential scan would do them), the verification
      and the extension.  The filter only skips lookups that cannot find
      anything (equal windows have equal hashes), so a complete filter gives
      the same matches as one that grows with the table.

   In step 3 the input is either all in memory (`mem`) or read by position
   through a callback (`read`), so the encoder does not have to hold it: it
   keeps a window around the cursor and two small caches for the other side
   of a comparison (the source, and the destination ahead of the cursor).
   Both ways give the same matches.

   The caller owns every buffer (no libc): the filter, the table, the I/O
   buffer, the state.  Matches go to `emit` in destination order, never
   overlapping in destination, each with src < dst.  Deterministic: no
   addresses, no threads. */

#include <stddef.h>
#include <stdint.h>

typedef int (*osrep_lr_read_fn)(void *ctx, uint64_t pos, uint8_t *buf,
                                size_t len);
typedef int (*osrep_lr_emit_fn)(void *ctx, uint64_t src, uint64_t dst,
                                uint64_t len);

/* u64 fields first, then pointers, then u32: no padding on 32 or 64 bits */
typedef struct {
  uint64_t n;
  uint64_t buf_cap;
  const uint8_t *mem;     /* the whole input, or NULL to use `read` */
  osrep_lr_read_fn read;  /* returns 0 when it filled all `len` bytes */
  osrep_lr_emit_fn emit;  /* returns 0 to go on */
  void *ctx;
  uint32_t *table;        /* (1 << tbits) buckets of LR_BUCKET u32 */
  uint8_t *filter;        /* unused (osrep_lr_scan takes the filter) */
  uint8_t *buf;           /* buf_cap bytes, only with `read` */
  uint32_t minlen, win, step, align, tbits, fbits;
} osrep_lr_params;

#define OSREP_LR_ERR_READ (-1)
#define OSREP_LR_ERR_EMIT (-2)
#define OSREP_LR_ERR_BUF (-3)
#define OSREP_LR_ERR_ARG (-4)

#define LR_B UINT64_C(0x9E3779B97F4A7C15)
#define LR_WAYS 4u
#define LR_BUCKET 6u   /* u32 words per bucket: 4 tags of 16 bits, 4 idx */
#define LR_CHUNK0 4096u
#define LR_AHEAD 32u    /* osrep_lr_scan: hashes computed ahead (filter prefetch) */
#define LR_RING 64u     /* > LR_AHEAD, a power of two */
#define LR_FAHEAD 8u    /* osrep_lr_feed, osrep_lr_filter_add: prefetch distance */
#if defined(__GNUC__) || defined(__clang__)
#define LR_PREFETCH(p) __builtin_prefetch(p)
#else
#define LR_PREFETCH(p) ((void)0)
#endif

/* word-at-a-time access (little-endian GCC and Clang; byte loops elsewhere) */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && \
    (defined(__GNUC__) || defined(__clang__))
#if UINTPTR_MAX > 0xFFFFFFFFu
typedef uint64_t lr_word;
#define LR_CTZ(x) __builtin_ctzll(x)
#define LR_CLZ(x) __builtin_clzll(x)
#else
typedef uint32_t lr_word;
#define LR_CTZ(x) __builtin_ctz(x)
#define LR_CLZ(x) __builtin_clz(x)
#endif
typedef lr_word __attribute__((aligned(1), may_alias)) lr_uword;
typedef uint64_t __attribute__((aligned(1), may_alias)) lr_u64u;
#define LR_WORDS 1
#endif

/* sum of (p[i] + 1) * LR_B^(win - 1 - i), in four interleaved lanes (the
   same value as the plain loop, which is one long dependency chain) */
static uint64_t lr_hash(const uint8_t *p, uint32_t win) {
  const uint64_t b2 = LR_B * LR_B, b4 = b2 * b2;
  uint64_t h0 = 0, h1 = 0, h2 = 0, h3 = 0, h;
  uint32_t i = 0, w4 = win & ~3u;
  for (; i < w4; i += 4) {
    h0 = h0 * b4 + p[i] + 1u;
    h1 = h1 * b4 + p[i + 1u] + 1u;
    h2 = h2 * b4 + p[i + 2u] + 1u;
    h3 = h3 * b4 + p[i + 3u] + 1u;
  }
  h = ((h0 * LR_B + h1) * LR_B + h2) * LR_B + h3;
  for (; i < win; i++) h = h * LR_B + p[i] + 1u;
  return h;
}

static uint64_t lr_mix(uint64_t h) {
  h ^= h >> 31;
  h *= UINT64_C(0xD6E8FEB86659FD93);
  h ^= h >> 32;
  return h;
}

/* table: (1 << tbits) buckets of LR_WAYS entries, 24 bytes each: words 0
   and 1 hold the four 16-bit tags (way w in bits 16 * (w % 2) of word
   w / 2), words 2..5 the index + 1 of each window (position = index *
   step); index 0 = empty.  The tag only decides which entries are verified:
   two equal windows have the same hash, so a shorter tag adds failed
   verifications and never changes a match (it was 32 bits, 8 bytes per
   entry).  The bucket is the top tbits bits of the mixed hash.  (Sizing
   the table exactly instead of to a power of two, 27-50 % full, saves up
   to 70 % of it but remaps the buckets: -0.01 to +0.08 % after the
   backends, measured 2026-11-16, enough to undo the versions/xz margin.) */
static uint32_t *lr_bucket(uint32_t *table, uint32_t tbits, uint64_t m) {
  return table + (m >> (64 - tbits)) * LR_BUCKET;
}

static uint32_t lr_tag(const uint32_t *b, uint32_t w) {
  return (b[w >> 1] >> (16u * (w & 1u))) & 0xFFFFu;
}

static void lr_insert(uint32_t *table, uint32_t tbits, uint64_t m,
                      uint32_t idx1) {
  uint32_t *b = lr_bucket(table, tbits, m);
  /* newest first: shift the others down, the oldest falls out */
  b[1] = (b[1] << 16) | (b[0] >> 16);
  b[0] = (b[0] << 16) | ((uint32_t)m & 0xFFFFu);
  b[5] = b[4];
  b[4] = b[3];
  b[3] = b[2];
  b[2] = idx1;
}

/* filter: (1 << fbits) bits, fbits >= 6, a blocked Bloom filter: three
   bits of the mixed hash, all in the same 64-bit group (one cache line).
   It only skips lookups, never changes a match.  Sized at 16 bits or more
   per indexed window, it lets 0.2-0.5 % of the positions without a repeat
   through (one bit at 8 bits per window: 6 %). */
static void lr_fbits(uint64_t m, uint64_t fmask, uint64_t *f, uint64_t *g,
                     uint64_t *h) {
  uint64_t w;
  *f = m & fmask;
  w = *f & ~UINT64_C(63);
  *g = w | (m >> 58);
  *h = w | ((m >> 52) & 63u);
}

static int lr_ftest(const uint8_t *filter, uint64_t fmask, uint64_t m) {
#ifdef LR_WORDS
  uint64_t f = m & fmask;
  uint64_t x = *(const lr_u64u *)(filter + ((f >> 3) & ~(uint64_t)7u));
  uint64_t k = (UINT64_C(1) << (f & 63u)) | (UINT64_C(1) << (m >> 58)) |
               (UINT64_C(1) << ((m >> 52) & 63u));
  return (x & k) == k;
#else
  uint64_t f, g, h;
  lr_fbits(m, fmask, &f, &g, &h);
  return (filter[f >> 3] >> (f & 7u)) & (filter[g >> 3] >> (g & 7u)) &
         (filter[h >> 3] >> (h & 7u)) & 1u;
#endif
}

/* a % b without a 64-bit division (32-bit targets would need libgcc) */
static uint64_t lr_mod(uint64_t a, uint32_t b) {
  uint64_t r = 0;
  int i;
  if (b == 1u) return 0;
  if ((b & (b - 1u)) == 0) return a & (b - 1u);
  for (i = 63; i >= 0; i--) {
    r = (r << 1) | ((a >> i) & 1u);
    if (r >= b) r -= b;
  }
  return r;
}

/* equal bytes going forward from x and y, at most len */
static size_t lr_eq_fwd(const uint8_t *x, const uint8_t *y, size_t len) {
  size_t k = 0;
#ifdef LR_WORDS
  while (k + sizeof(lr_word) <= len) {
    lr_word d = *(const lr_uword *)(x + k) ^ *(const lr_uword *)(y + k);
    if (d) return k + (size_t)(LR_CTZ(d) >> 3);
    k += sizeof(lr_word);
  }
#endif
  while (k < len && x[k] == y[k]) k++;
  return k;
}

/* equal bytes going backward from x - 1 and y - 1, at most len */
static size_t lr_eq_back(const uint8_t *x, const uint8_t *y, size_t len) {
  size_t k = 0;
#ifdef LR_WORDS
  while (k + sizeof(lr_word) <= len) {
    lr_word d = *(const lr_uword *)(x - k - sizeof(lr_word)) ^
                *(const lr_uword *)(y - k - sizeof(lr_word));
    if (d) return k + (size_t)(LR_CLZ(d) >> 3);
    k += sizeof(lr_word);
  }
#endif
  while (k < len && x[-1 - (ptrdiff_t)k] == y[-1 - (ptrdiff_t)k]) k++;
  return k;
}

/* ---- input access ---------------------------------------------------- */

typedef struct {
  uint8_t *p;
  uint64_t base;
  size_t len, cap;
} lr_cache;

/* small direct-mapped cache for the start of a source: slot k holds
   [blk * half, blk * half + 2 * half) for some blk with blk % nslots = k,
   so any range of up to `half` bytes that starts in block blk fits */
typedef struct {
  uint8_t *p;
  uint64_t *tag;   /* blk + 1, 0 = empty */
  size_t half, nslots;   /* both powers of two (no 64-bit division: */
  uint32_t shift;        /* 32-bit targets would need libgcc for it) */
} lr_slots;

typedef struct {
  const osrep_lr_params *pr;
  lr_cache cur;  /* the window around the scan cursor, with history */
  lr_cache a;    /* the source side of a long comparison */
  lr_cache b;    /* the destination side ahead of the cursor */
  lr_slots s;    /* the source side of the first chunk */
  int err;
} lr_io;

static int lr_in(const lr_cache *c, uint64_t pos, size_t len) {
  return c->len > 0 && pos >= c->base && pos + len <= c->base + c->len;
}

/* `len` bytes at `pos` (len <= cache cap, pos + len <= n): from memory,
   from the cursor window, from cache `c`, or read into `c` (at least
   `ahead` bytes when the input has them). */
static const uint8_t *lr_fetch(lr_io *io, lr_cache *c, uint64_t pos,
                               size_t len, size_t ahead) {
  uint64_t rl;
  if (io->pr->mem) return io->pr->mem + pos;
  if (lr_in(&io->cur, pos, len)) return io->cur.p + (pos - io->cur.base);
  if (lr_in(c, pos, len)) return c->p + (pos - c->base);
  rl = ahead > len ? ahead : len;
  if (rl > c->cap) rl = c->cap;
  if (rl > io->pr->n - pos) rl = io->pr->n - pos;
  c->len = 0;
  if (io->pr->read(io->pr->ctx, pos, c->p, (size_t)rl) != 0) {
    io->err = OSREP_LR_ERR_READ;
    return NULL;
  }
  c->base = pos;
  c->len = (size_t)rl;
  return c->p;
}

/* `len` (<= half) bytes at `pos` for the source side: memory, cursor
   window, or a slot */
static const uint8_t *lr_src(lr_io *io, uint64_t pos, size_t len) {
  lr_slots *s = &io->s;
  uint64_t blk, at, rl;
  size_t k;
  uint8_t *sp;
  if (io->pr->mem) return io->pr->mem + pos;
  if (lr_in(&io->cur, pos, len)) return io->cur.p + (pos - io->cur.base);
  if (s->nslots == 0 || len > s->half) return lr_fetch(io, &io->a, pos, len, len);
  blk = pos >> s->shift;
  k = (size_t)blk & (s->nslots - 1u);
  sp = s->p + k * 2u * s->half;
  at = blk * s->half;
  if (s->tag[k] != blk + 1u) {
    rl = 2u * s->half;
    if (rl > io->pr->n - at) rl = io->pr->n - at;
    s->tag[k] = 0;
    if (io->pr->read(io->pr->ctx, at, sp, (size_t)rl) != 0) {
      io->err = OSREP_LR_ERR_READ;
      return NULL;
    }
    s->tag[k] = blk + 1u;
  }
  return sp + (pos - at);
}

/* the cursor window holds [q, q + need) and up to half its size of history
   before q; keeps what it already has */
static const uint8_t *lr_cursor(lr_io *io, uint64_t q, size_t need) {
  lr_cache *c = &io->cur;
  size_t keep = 0, i, off;
  uint64_t rl, nb, from;
  if (io->pr->mem) return io->pr->mem + q;
  if (lr_in(c, q, need)) return c->p + (q - c->base);
  nb = q > c->cap / 2u ? q - c->cap / 2u : 0;
  if (c->len > 0 && nb >= c->base && nb < c->base + c->len) {
    off = (size_t)(nb - c->base);
    keep = c->len - off;
    i = 0;
#ifdef LR_WORDS
    /* forward, dst < src: each word is read before it is overwritten */
    for (; i + sizeof(lr_word) <= keep; i += sizeof(lr_word))
      *(lr_uword *)(c->p + i) = *(const lr_uword *)(c->p + off + i);
#endif
    for (; i < keep; i++) c->p[i] = c->p[off + i];
  }
  from = nb + keep;
  rl = c->cap - keep;
  if (rl > io->pr->n - from) rl = io->pr->n - from;
  c->len = 0;
  if (rl > 0 && io->pr->read(io->pr->ctx, from, c->p + keep, (size_t)rl) != 0) {
    io->err = OSREP_LR_ERR_READ;
    return NULL;
  }
  c->base = nb;
  c->len = keep + (size_t)rl;
  return c->p + (q - nb);
}

/* the number of equal bytes going forward from p and q, at most lim */
static uint64_t lr_fwd(lr_io *io, uint64_t p, uint64_t q, uint64_t lim) {
  uint64_t fl = 0, chunk = LR_CHUNK0;
  if (io->pr->mem) {
    return lr_eq_fwd(io->pr->mem + p, io->pr->mem + q, (size_t)lim);
  }
  /* both in the cursor window (p < q, so q runs out first) */
  if (lr_in(&io->cur, p, 1) && lr_in(&io->cur, q, 1)) {
    const uint8_t *x = io->cur.p + (p - io->cur.base);
    const uint8_t *y = io->cur.p + (q - io->cur.base);
    uint64_t l2 = io->cur.base + io->cur.len - q;
    if (l2 > lim) l2 = lim;
    fl = lr_eq_fwd(x, y, (size_t)l2);
    if (fl < l2 || fl == lim) return fl;
  }
  while (fl < lim) {
    const uint8_t *x, *y;
    size_t c = (size_t)(lim - fl < chunk ? lim - fl : chunk), k;
    if (c > io->a.cap) c = io->a.cap;
    if (fl == 0 && c > io->s.half && io->s.nslots) c = io->s.half;
    x = fl == 0 ? lr_src(io, p, c) : lr_fetch(io, &io->a, p + fl, c, c);
    if (!x) return 0;
    y = lr_fetch(io, &io->b, q + fl, c, c);
    if (!y) return 0;
    k = lr_eq_fwd(x, y, c);
    fl += k;
    if (k < c) break;
    if (chunk < io->a.cap) chunk *= 2;
  }
  return fl;
}

/* the number of equal bytes going backward from p and q, at most lim */
static uint64_t lr_back(lr_io *io, uint64_t p, uint64_t q, uint64_t lim) {
  uint64_t bl = 0, chunk = LR_CHUNK0;
  if (io->pr->mem) {
    return lr_eq_back(io->pr->mem + p, io->pr->mem + q, (size_t)lim);
  }
  /* both in the cursor window (p < q, so p runs out first) */
  if (p > io->cur.base && lr_in(&io->cur, p - 1u, 1) &&
      lr_in(&io->cur, q - 1u, 1)) {
    const uint8_t *x = io->cur.p + (p - io->cur.base);
    const uint8_t *y = io->cur.p + (q - io->cur.base);
    uint64_t l2 = p - io->cur.base;
    if (l2 > lim) l2 = lim;
    bl = lr_eq_back(x, y, (size_t)l2);
    if (bl < l2 || bl == lim) return bl;
  }
  while (bl < lim) {
    const uint8_t *x, *y;
    size_t c = (size_t)(lim - bl < chunk ? lim - bl : chunk), k;
    if (c > io->a.cap) c = io->a.cap;
    if (bl == 0 && c > io->s.half && io->s.nslots) c = io->s.half;
    x = bl == 0 ? lr_src(io, p - c, c) : lr_fetch(io, &io->a, p - bl - c, c, c);
    if (!x) return 0;
    y = lr_fetch(io, &io->b, q - bl - c, c, c);
    if (!y) return 0;
    k = lr_eq_back(x + c, y + c, c);
    bl += k;
    if (k < c) break;
    if (chunk < io->a.cap) chunk *= 2;
  }
  return bl;
}


/* ---- step 1: the indexed windows -------------------------------------- */

/* The mixed hash of the windows at d, d + step, d + 2 step... that fit in
   len bytes, into out (as many as fit).  Returns how many. */
uint64_t osrep_lr_index(const uint8_t *d, uint64_t len, uint32_t win,
                        uint32_t step, uint64_t *out) {
  uint64_t off = 0, k = 0;
  if (win == 0 || step == 0) return 0;
  while (off + win <= len) {
    out[k++] = lr_mix(lr_hash(d + off, win));
    off += step;
  }
  return k;
}

/* Sets the filter bits of `count` mixed hashes. */
void osrep_lr_filter_add(uint8_t *filter, uint32_t fbits, const uint64_t *m,
                         uint64_t count) {
  const uint64_t fmask = (UINT64_C(1) << fbits) - 1u;
  uint64_t i, f, g, h;
  for (i = 0; i < count; i++) {
    if (i + LR_FAHEAD < count)
      LR_PREFETCH(&filter[(m[i + LR_FAHEAD] & fmask) >> 3]);
    lr_fbits(m[i], fmask, &f, &g, &h);
    filter[f >> 3] |= (uint8_t)(1u << (f & 7u));
    filter[g >> 3] |= (uint8_t)(1u << (g & 7u));
    filter[h >> 3] |= (uint8_t)(1u << (h & 7u));
  }
}

/* ---- step 2: the positions worth a lookup ----------------------------- */

/* The positions q in [lo, hi) whose window passes the filter or that are
   indexed (q a multiple of step; `ns` is the first one >= lo), in order,
   as pairs out[2 i] = q, plus 2^63 when it passed, and out[2 i + 1] = the
   mixed hash.  d points at the byte of position lo; the bytes up to
   hi - 1 + win must be there.  Writes at most `cap` pairs; returns how
   many, and in *next the position it stopped at (hi when it is done; the
   next call starts there, with the indexed position after it). */
uint64_t osrep_lr_scan(const uint8_t *d, uint64_t lo, uint64_t hi,
                       uint64_t ns, uint32_t win, uint32_t step,
                       const uint8_t *filter, uint32_t fbits, uint64_t *out,
                       uint64_t cap, uint64_t *next) {
  const uint64_t fmask = (UINT64_C(1) << fbits) - 1u;
  uint64_t ring[LR_RING], bwb = 1, h, q, a, cnt = 0;
  const uint8_t *ca;
  uint32_t i;
  *next = lo;
  if (lo >= hi || win == 0 || step == 0) {
    *next = hi > lo ? hi : lo;
    return 0;
  }
  for (i = 0; i < win; i++) bwb *= LR_B;  /* LR_B^win */
  /* the hashes run up to LR_AHEAD positions ahead, so the filter's word
     for a position is fetched before the position is tested */
  h = lr_hash(d, win);
  ca = d;
  a = lo;
  for (q = lo; q < hi; q++) {
    uint64_t m;
    int pass;
    while (a < hi && a <= q + LR_AHEAD) {
      uint64_t ma = lr_mix(h);
      ring[a & (LR_RING - 1u)] = ma;
      LR_PREFETCH(&filter[(ma & fmask) >> 3]);
      if (a + 1u < hi) {
        h = h * LR_B + (uint64_t)(ca[win] + 1u) - (uint64_t)(ca[0] + 1u) * bwb;
        ca++;
      }
      a++;
    }
    m = ring[q & (LR_RING - 1u)];
    pass = lr_ftest(filter, fmask, m);
    if (pass || q == ns) {
      if (cnt == cap) {
        *next = q;
        return cnt;
      }
      out[2u * cnt] = q | ((uint64_t)pass << 63);
      out[2u * cnt + 1u] = m;
      cnt++;
      if (q == ns) ns += step;
    }
  }
  *next = hi;
  return cnt;
}

/* ---- step 3: the table and the matches -------------------------------- */

typedef struct {
  lr_io io;
  uint64_t last_end, next_ins, skip_to, count;
} lr_state;

/* the size of the state that osrep_lr_begin and osrep_lr_feed take */
uint64_t osrep_lr_state_size(void) { return sizeof(lr_state) + 16u; }

static lr_state *lr_st(void *st) {
  uintptr_t t = ((uintptr_t)st + 15u) & ~(uintptr_t)15u;
  return (lr_state *)t;
}

/* Starts step 3 on an empty table.  pr (n, mem or read and buf, emit, ctx,
   table, tbits, minlen, win, step, align) has to stay there until the end.
   With `read`, buf_cap must be at least 8 * (win + 1); it is split into the
   cursor window (1/2), the source slots and their tags (1/4), and the two
   caches (1/8 each).  Returns 0 or a negative OSREP_LR_ERR_*. */
int osrep_lr_begin(void *state, const osrep_lr_params *pr) {
  lr_state *s = lr_st(state);
  lr_io *io = &s->io;
  if (pr->win == 0 || pr->step == 0 || pr->align == 0 ||
      pr->minlen < pr->win || pr->tbits == 0 || pr->tbits > 32)
    return OSREP_LR_ERR_ARG;
  s->last_end = s->next_ins = s->skip_to = s->count = 0;
  io->pr = pr;
  io->err = 0;
  io->cur.len = io->a.len = io->b.len = 0;
  io->cur.base = io->a.base = io->b.base = 0;
  io->s.nslots = 0;
  io->s.half = 0;
  io->s.shift = 0;
  io->s.p = 0;
  io->s.tag = 0;
  if (!pr->mem) {
    size_t eighth = (size_t)(pr->buf_cap / 8u), region = 2u * eighth, i;
    uintptr_t t;
    if (eighth < (size_t)pr->win + 1u) return OSREP_LR_ERR_BUF;
    io->cur.p = pr->buf;
    io->cur.cap = 4u * eighth;
    io->a.p = pr->buf + 4u * eighth;
    io->a.cap = eighth;
    io->b.p = pr->buf + 5u * eighth;
    io->b.cap = eighth;
    /* slots of 2 * half bytes plus an 8-byte tag each, tags 8-aligned */
    io->s.half = 4096u;
    io->s.shift = 12u;
    while (io->s.half > 1u && region / (2u * io->s.half + 8u) < 16u) {
      io->s.half /= 2u;
      io->s.shift--;
    }
    io->s.nslots = 1u;
    while (2u * io->s.nslots * (2u * io->s.half + 8u) + 8u <= region)
      io->s.nslots *= 2u;
    if (io->s.nslots * (2u * io->s.half + 8u) + 8u > region) io->s.nslots = 0;
    if (io->s.nslots > 0) {
      t = (uintptr_t)(pr->buf + 6u * eighth);
      t = (t + 7u) & ~(uintptr_t)7u;
      io->s.tag = (uint64_t *)t;
      io->s.p = (uint8_t *)(io->s.tag + io->s.nslots);
      for (i = 0; i < io->s.nslots; i++) io->s.tag[i] = 0;
    }
  } else {
    io->cur.p = io->a.p = io->b.p = 0;
    io->cur.cap = io->a.cap = io->b.cap = (size_t)-1;
  }
  return 0;
}

/* Takes the next `count` pairs of osrep_lr_scan, in position order (all of
   them, from every piece, with nothing left out or repeated).  Returns 0 or
   a negative OSREP_LR_ERR_*. */
int osrep_lr_feed(void *state, const uint64_t *rec, uint64_t count) {
  lr_state *s = lr_st(state);
  lr_io *io = &s->io;
  const osrep_lr_params *pr = io->pr;
  const uint64_t n = pr->n, step = pr->step;
  const uint32_t win = pr->win;
  uint64_t r;
  for (r = 0; r < count; r++) {
    uint64_t q = rec[2u * r] & ~(UINT64_C(1) << 63), m = rec[2u * r + 1u];
    int pass = (int)(rec[2u * r] >> 63);
    if (r + LR_FAHEAD < count && (rec[2u * (r + LR_FAHEAD)] >> 63))
      LR_PREFETCH(lr_bucket(pr->table, pr->tbits, rec[2u * (r + LR_FAHEAD) + 1u]));
    if (pass && q >= s->skip_to) {
      uint32_t *b = lr_bucket(pr->table, pr->tbits, m);
      uint32_t tag = (uint32_t)m & 0xFFFFu;
      uint64_t best_len = 0, best_src = 0, best_back = 0;
      uint32_t w;
      for (w = 0; w < LR_WAYS; w++) {
        uint64_t p, fl, bl, blim;
        if (b[2u + w] == 0) break;
        if (lr_tag(b, w) != tag) continue;
        p = (uint64_t)(b[2u + w] - 1u) * step;
        if (p >= q) continue;
        /* keep the cursor window on q: most sources are near it */
        if (!pr->mem && !lr_cursor(io, q, win)) return io->err;
        fl = lr_fwd(io, p, q, n - q);
        if (io->err) return io->err;
        if (fl < win) continue;
        blim = q - s->last_end < p ? q - s->last_end : p;
        bl = lr_back(io, p, q, blim);
        if (io->err) return io->err;
        if (fl + bl > best_len) {
          best_len = fl + bl;
          best_src = p - bl;
          best_back = bl;
        }
      }
      best_len -= lr_mod(best_len, pr->align);
      if (best_len >= pr->minlen) {
        uint64_t dst = q - best_back, end = dst + best_len;
        if (pr->emit(pr->ctx, best_src, dst, best_len) != 0)
          return OSREP_LR_ERR_EMIT;
        s->count++;
        s->last_end = end;
        /* no lookups until the end of the match; the windows it covers
           still go into the table, as they come */
        s->skip_to = end;
      }
    }
    if (q == s->next_ins * step) {
      lr_insert(pr->table, pr->tbits, m, (uint32_t)(s->next_ins + 1u));
      s->next_ins++;
    }
  }
  return 0;
}

/* the number of matches emitted so far */
int64_t osrep_lr_count(void *state) { return (int64_t)lr_st(state)->count; }
