/* Long-range match finder for OSREP (clean-room, MIT).

   Finds repeats of at least `minlen` bytes anywhere earlier in the input,
   not only inside one block.  The input is indexed every `step` bytes: the
   hash of the `win` bytes starting at each multiple of `step` goes into a
   bucketed table.  The scan computes a rolling hash of `win` bytes at every
   position, checks a bit filter, looks up the bucket, verifies the bytes and
   extends the match forward and backward.  A repeat of `win + step - 1`
   bytes or more always contains an indexed window, so with win = step =
   minlen / 2 every repeat of minlen - 1 bytes is seen.

   The length of every match is a multiple of `align`: the bytes after a
   removed match keep their offset modulo align, which backends model
   (LZMA's position bits, x86 code); measured on silesia's mozilla, a tar of
   executables, +1.5 % with xz unaligned and -0.1 % with align 16.

   The input is either all in memory (`mem`) or read by position through a
   callback (`read`), so the encoder does not have to hold it: the scan keeps
   a window around the cursor and two small caches for the other side of a
   comparison (the source, and the destination ahead of the cursor).  Both
   ways give the same matches.

   The caller owns every buffer (no libc): the filter, the table, the I/O
   buffer.  Matches go to `emit` in destination order, never overlapping in
   destination, each with src < dst.  Deterministic: no addresses, no
   threads. */

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
  uint8_t *filter;        /* (1 << fbits) bits */
  uint8_t *buf;           /* buf_cap bytes, only with `read` */
  uint32_t minlen, win, step, align, tbits, fbits;
} osrep_lr_params;

#define OSREP_LR_ERR_READ (-1)
#define OSREP_LR_ERR_EMIT (-2)
#define OSREP_LR_ERR_BUF (-3)

#define LR_B UINT64_C(0x9E3779B97F4A7C15)
#define LR_WAYS 4u
#define LR_BUCKET 6u   /* u32 words per bucket: 4 tags of 16 bits, 4 idx */
#define LR_CHUNK0 4096u

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

/* table: (1 << tbits) buckets of LR_WAYS entries, 24 bytes each: words 0
   and 1 hold the four 16-bit tags (way w in bits 16 * (w % 2) of word
   w / 2), words 2..5 the index + 1 of each window (position = index *
   step); index 0 = empty.  The tag only decides which entries are verified:
   two equal windows have the same hash, so a shorter tag adds failed
   verifications and never changes a match (it was 32 bits, 8 bytes per
   entry).  The bucket is the top tbits bits of the mixed hash.  (Sizing
   the table exactly instead of to a power of two, 27-50 % full, saves up
   to 70 % of it but remaps the buckets: -0.01 to +0.08 % after the
   backends, measured 2026-11-16, enough to undo the versions/xz margin.)
   filter: (1 << fbits) bits (only skips lookups, never changes a match). */
static uint32_t *lr_bucket(uint32_t *table, uint32_t tbits, uint64_t m) {
  return table + (m >> (64 - tbits)) * LR_BUCKET;
}

static uint32_t lr_tag(const uint32_t *b, uint32_t w) {
  return (b[w >> 1] >> (16u * (w & 1u))) & 0xFFFFu;
}

static void lr_insert(uint32_t *table, uint32_t tbits, uint8_t *filter,
                      uint32_t fbits, uint64_t h, uint32_t idx1) {
  uint64_t m = lr_mix(h);
  uint32_t *b = lr_bucket(table, tbits, m);
  uint64_t f = m & ((UINT64_C(1) << fbits) - 1u);
  filter[f >> 3] |= (uint8_t)(1u << (f & 7u));
  /* newest first: shift the others down, the oldest falls out */
  b[1] = (b[1] << 16) | (b[0] >> 16);
  b[0] = (b[0] << 16) | ((uint32_t)m & 0xFFFFu);
  b[5] = b[4];
  b[4] = b[3];
  b[3] = b[2];
  b[2] = idx1;
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
    for (i = 0; i < keep; i++) c->p[i] = c->p[off + i];
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
    const uint8_t *x = io->pr->mem + p, *y = io->pr->mem + q;
    while (fl < lim && x[fl] == y[fl]) fl++;
    return fl;
  }
  /* both in the cursor window (p < q, so q runs out first) */
  if (lr_in(&io->cur, p, 1) && lr_in(&io->cur, q, 1)) {
    const uint8_t *x = io->cur.p + (p - io->cur.base);
    const uint8_t *y = io->cur.p + (q - io->cur.base);
    uint64_t l2 = io->cur.base + io->cur.len - q;
    if (l2 > lim) l2 = lim;
    while (fl < l2 && x[fl] == y[fl]) fl++;
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
    for (k = 0; k < c && x[k] == y[k]; k++) {
    }
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
    const uint8_t *x = io->pr->mem + p, *y = io->pr->mem + q;
    while (bl < lim && x[-1 - (int64_t)bl] == y[-1 - (int64_t)bl]) bl++;
    return bl;
  }
  /* both in the cursor window (p < q, so p runs out first) */
  if (p > io->cur.base && lr_in(&io->cur, p - 1u, 1) &&
      lr_in(&io->cur, q - 1u, 1)) {
    const uint8_t *x = io->cur.p + (p - io->cur.base);
    const uint8_t *y = io->cur.p + (q - io->cur.base);
    uint64_t l2 = p - io->cur.base;
    if (l2 > lim) l2 = lim;
    while (bl < l2 && x[-1 - (int64_t)bl] == y[-1 - (int64_t)bl]) bl++;
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
    for (k = 0; k < c && x[c - 1u - k] == y[c - 1u - k]; k++) {
    }
    bl += k;
    if (k < c) break;
    if (chunk < io->a.cap) chunk *= 2;
  }
  return bl;
}

/* ---- the scan -------------------------------------------------------- */

/* Returns the number of matches emitted, or a negative OSREP_LR_ERR_*.
   With `read`, buf_cap must be at least 8 * (win + 1); it is split into
   the cursor window (1/2), the source slots and their tags (1/4), and the
   two caches (1/8 each). */
int64_t osrep_lr_find(const osrep_lr_params *pr) {
  const uint32_t win = pr->win, step = pr->step, align = pr->align;
  const uint64_t n = pr->n;
  uint64_t bw1 = 1, h, q, last_end = 0, next_ins = 0, cend;
  int64_t count = 0;
  const uint8_t *cq;
  uint32_t *table;
  uint8_t *filter;
  uint64_t fmask;
  lr_io io;
  uint32_t i;
  if (win == 0 || step == 0 || align == 0 || n < (uint64_t)win ||
      pr->minlen < win || pr->tbits == 0 || pr->tbits > 32)
    return 0;
  io.pr = pr;
  io.err = 0;
  io.cur.len = io.a.len = io.b.len = 0;
  io.cur.base = io.a.base = io.b.base = 0;
  io.s.nslots = 0;
  io.s.half = 0;
  if (!pr->mem) {
    size_t eighth = (size_t)(pr->buf_cap / 8u), region = 2u * eighth, i;
    uintptr_t t;
    if (eighth < (size_t)win + 1u) return OSREP_LR_ERR_BUF;
    io.cur.p = pr->buf;
    io.cur.cap = 4u * eighth;
    io.a.p = pr->buf + 4u * eighth;
    io.a.cap = eighth;
    io.b.p = pr->buf + 5u * eighth;
    io.b.cap = eighth;
    /* slots of 2 * half bytes plus an 8-byte tag each, tags 8-aligned */
    io.s.half = 4096u;
    io.s.shift = 12u;
    while (io.s.half > 1u && region / (2u * io.s.half + 8u) < 16u) {
      io.s.half /= 2u;
      io.s.shift--;
    }
    io.s.nslots = 1u;
    while (2u * io.s.nslots * (2u * io.s.half + 8u) + 8u <= region)
      io.s.nslots *= 2u;
    if (io.s.nslots * (2u * io.s.half + 8u) + 8u > region) io.s.nslots = 0;
    if (io.s.nslots > 0) {
      t = (uintptr_t)(pr->buf + 6u * eighth);
      t = (t + 7u) & ~(uintptr_t)7u;
      io.s.tag = (uint64_t *)t;
      io.s.p = (uint8_t *)(io.s.tag + io.s.nslots);
      for (i = 0; i < io.s.nslots; i++) io.s.tag[i] = 0;
    }
  } else {
    io.cur.p = io.a.p = io.b.p = NULL;
    io.cur.cap = io.a.cap = io.b.cap = (size_t)-1;
  }
  for (i = 1; i < win; i++) bw1 *= LR_B;
  table = pr->table;
  filter = pr->filter;
  fmask = (UINT64_C(1) << pr->fbits) - 1u;
  cq = lr_cursor(&io, 0, win);
  if (!cq) return io.err;
  cend = pr->mem ? n : io.cur.base + io.cur.len;
  h = lr_hash(cq, win);
  q = 0;
  while (q + win <= n) {
    uint64_t m = lr_mix(h);
    uint64_t f = m & fmask;
    if (filter[f >> 3] & (1u << (f & 7u))) {
      uint32_t *b = lr_bucket(table, pr->tbits, m);
      uint32_t tag = (uint32_t)m & 0xFFFFu;
      uint64_t best_len = 0, best_src = 0, best_back = 0;
      uint32_t w;
      for (w = 0; w < LR_WAYS; w++) {
        uint64_t p, fl, bl, blim;
        if (b[2u + w] == 0) break;
        if (lr_tag(b, w) != tag) continue;
        p = (uint64_t)(b[2u + w] - 1u) * step;
        if (p >= q) continue;
        fl = lr_fwd(&io, p, q, n - q);
        if (io.err) return io.err;
        if (fl < win) continue;
        blim = q - last_end < p ? q - last_end : p;
        bl = lr_back(&io, p, q, blim);
        if (io.err) return io.err;
        if (fl + bl > best_len) {
          best_len = fl + bl;
          best_src = p - bl;
          best_back = bl;
        }
      }
      best_len -= lr_mod(best_len, align);
      if (best_len >= pr->minlen) {
        uint64_t dst = q - best_back, end = dst + best_len;
        if (pr->emit(pr->ctx, best_src, dst, best_len) != 0)
          return OSREP_LR_ERR_EMIT;
        count++;
        last_end = end;
        /* index the windows the match skips over */
        while (next_ins * step < end) {
          uint64_t at = next_ins * step;
          if (at + win <= n) {
            const uint8_t *x = lr_fetch(&io, &io.b, at, win, io.b.cap);
            if (!x) return io.err;
            lr_insert(pr->table, pr->tbits, pr->filter, pr->fbits,
                      lr_hash(x, win), (uint32_t)(next_ins + 1u));
          }
          next_ins++;
        }
        q = end;
        if (q + win > n) break;
        cq = lr_cursor(&io, q, win);
        if (!cq) return io.err;
        cend = pr->mem ? n : io.cur.base + io.cur.len;
        h = lr_hash(cq, win);
        continue;
      }
    }
    if (q == next_ins * step) {
      lr_insert(pr->table, pr->tbits, pr->filter, pr->fbits, h,
                (uint32_t)(next_ins + 1u));
      next_ins++;
    }
    if (q + win >= n) break;
    if (q + win + 1u > cend) {
      cq = lr_cursor(&io, q, (size_t)win + 1u);
      if (!cq) return io.err;
      cend = io.cur.base + io.cur.len;
    }
    h = (h - (uint64_t)(cq[0] + 1u) * bw1) * LR_B + cq[win] + 1u;
    q++;
    cq++;
  }
  return count;
}
