/* orep_bigsrc: a deterministic, finite generator of large test streams for
 * OREP (positions past 2^32 and 2^33), written to stdout without holding the
 * data in memory.
 *
 *   orep_bigsrc <size>[k|m|g] <seed> [-v]
 *
 * The output is a sequence of segments. Every segment is a slice of a
 * "source": a virtual byte string defined by a 64-bit key, whose byte i is a
 * pure function of (key, i) (a counter-based PRNG), so any slice of any
 * source can be produced again later without storing it. Only small records
 * are kept: for each emitted segment, (output position, key, offset in the
 * source, length), a few tens of bytes per segment.
 *
 * Segment kinds:
 *  - fresh: a new source (random bytes, "text" from a 64-letter alphabet, or
 *    a run of one byte), never seen before;
 *  - repeat: a slice of an earlier segment chosen at a log-uniform distance
 *    from 16 KiB up to 1.9 GB, at any byte offset and any length (some short,
 *    near the minimum match, most 4 KiB..4 MiB), so its bytes equal earlier
 *    bytes exactly;
 *  - shift: 1..7 fresh bytes that misalign what follows.
 * At each of 2^31, 2^32, 3*2^31 and 2^33 (those below the size) a repeat is
 * placed whose destination straddles the boundary (its source about 700 MB
 * or 1.5 GB back), and that straddling segment is then repeated again
 * 64 MB, 1000 MB and 1.9 GB later, so sources straddle the boundaries too.
 *
 * The same (size, seed) gives the same bytes on every run and platform.
 * -v prints a summary to stderr.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint64_t pos, key, off, len;
} region;

static region *reg;
static size_t nreg, capreg;

static uint64_t rngs;
static uint64_t mix(uint64_t z) {
  z += 0x9E3779B97F4A7C15ull;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}
static uint64_t rnd(void) { return mix(rngs++ * 0x2545F4914F6CDD1Dull); }
static uint64_t rndr(uint64_t lo, uint64_t hi) { /* [lo, hi] */
  return lo + rnd() % (hi - lo + 1);
}
static uint64_t rndlog(uint64_t lo, uint64_t hi) { /* log-uniform-ish */
  double a = (double)lo, b = (double)hi;
  double u = (double)(rnd() >> 11) / 9007199254740992.0;
  double x = a;
  /* x = a * (b/a)^u without libm: repeated squaring is overkill; use exp2 by
   * integer part + linear fraction (piecewise log-uniform is enough) */
  double r = b / a, e = u;
  int bits = 0;
  while (r >= 2.0) { r /= 2.0; bits++; }
  {
    double t = e * (bits + (r - 1.0));
    int ip = (int)t;
    double fp = t - ip;
    while (ip-- > 0) x *= 2.0;
    x *= 1.0 + fp;
  }
  if (x < a) x = a;
  if (x > b) x = b;
  return (uint64_t)x;
}

/* ---- output ---- */
static uint8_t obuf[1 << 20];
static size_t olen;
static uint64_t opos, osize;
static void flush(void) {
  if (olen && fwrite(obuf, 1, olen, stdout) != olen) {
    perror("orep_bigsrc: write");
    exit(1);
  }
  olen = 0;
}

static const char alpha[65] =
    "etaoinshrdlucmfwypvbgkqjxz ETAOINSHRDLU.,;:\n0123456789-()'\"!?/=+*";

/* emit len bytes of source key starting at offset off */
static void emit(uint64_t key, uint64_t off, uint64_t len) {
  unsigned kind = (unsigned)(mix(key ^ 0x5A5A5A5A5A5A5A5Aull) % 20);
  /* 0..14 random, 15..18 text, 19 run */
  opos += len;
  if (kind == 19) {
    uint8_t b = (uint8_t)(key >> 8);
    while (len) {
      size_t n = sizeof obuf - olen;
      if (n > len) n = (size_t)len;
      memset(obuf + olen, b, n);
      olen += n; len -= n;
      if (olen == sizeof obuf) flush();
    }
    return;
  }
  while (len) {
    uint64_t wi = off >> 3;
    unsigned sh = (unsigned)(off & 7);
    uint64_t w = mix(key + wi * 0xD1B54A32D192ED03ull);
    if (sh == 0 && len >= 8 && sizeof obuf - olen >= 8) {
      /* fast path: whole words */
      size_t room = (sizeof obuf - olen) / 8;
      uint64_t nw = len / 8;
      if (nw > room) nw = room;
      uint8_t *p = obuf + olen;
      if (kind < 15) {
        for (uint64_t k = 0; k < nw; k++) {
          uint64_t v = mix(key + (wi + k) * 0xD1B54A32D192ED03ull);
          for (int j = 0; j < 8; j++) p[8 * k + j] = (uint8_t)(v >> (8 * j));
        }
      } else {
        for (uint64_t k = 0; k < nw; k++) {
          uint64_t v = mix(key + (wi + k) * 0xD1B54A32D192ED03ull);
          for (int j = 0; j < 8; j++)
            p[8 * k + j] = (uint8_t)alpha[(v >> (8 * j)) & 63];
        }
      }
      olen += (size_t)(nw * 8);
      off += nw * 8;
      len -= nw * 8;
    } else {
      uint8_t b = (uint8_t)(w >> (8 * sh));
      if (kind >= 15) b = (uint8_t)alpha[b & 63];
      obuf[olen++] = b;
      off++;
      len--;
    }
    if (olen == sizeof obuf) flush();
  }
}

static void addreg(uint64_t pos, uint64_t key, uint64_t off, uint64_t len) {
  if (nreg == capreg) {
    capreg = capreg ? capreg * 2 : 4096;
    reg = realloc(reg, capreg * sizeof *reg);
    if (!reg) { fprintf(stderr, "orep_bigsrc: out of memory\n"); exit(1); }
  }
  reg[nreg].pos = pos; reg[nreg].key = key;
  reg[nreg].off = off; reg[nreg].len = len;
  nreg++;
}

/* index of the last region starting at or before p (regions sorted by pos) */
static size_t findreg(uint64_t p) {
  size_t lo = 0, hi = nreg; /* answer in [lo, hi) */
  while (hi - lo > 1) {
    size_t m = (lo + hi) / 2;
    if (reg[m].pos <= p) lo = m; else hi = m;
  }
  return lo;
}

/* stats */
static uint64_t nfresh, nrep, nshift, nstraddle, nsched, maxdist, repbytes;
static uint64_t fresh_id;
static uint64_t seed;

static uint64_t remain(void) { return osize - opos; }

static void fresh(uint64_t len) {
  if (len > remain()) len = remain();
  if (!len) return;
  uint64_t key = mix(seed ^ mix(++fresh_id));
  addreg(opos, key, 0, len);
  emit(key, 0, len);
  nfresh++;
}

/* copy [off, off+len) of region r to the output */
static void repeat(size_t r, uint64_t off, uint64_t len) {
  if (len > remain()) len = remain();
  if (!len) return;
  region s = reg[r];
  uint64_t d = opos - (s.pos + off);
  if (d > maxdist) maxdist = d;
  addreg(opos, s.key, s.off + off, len);
  emit(s.key, s.off + off, len);
  nrep++;
  repbytes += len;
}

/* a region at about distance d back with at least minlen bytes, or -1 */
static long pickreg(uint64_t d, uint64_t minlen) {
  if (!nreg || opos < d) return -1;
  size_t i = findreg(opos - d);
  for (size_t k = 0; k < 4096 && i + k < nreg; k++)
    if (reg[i + k].len >= minlen) return (long)(i + k);
  return -1;
}

typedef struct { uint64_t at; size_t r; } sched;
static sched sq[64];
static int nsq;

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: orep_bigsrc <size>[k|m|g] <seed> [-v]\n");
    return 2;
  }
  char *e;
  osize = strtoull(argv[1], &e, 10);
  if (*e == 'k' || *e == 'K') osize <<= 10;
  else if (*e == 'm' || *e == 'M') osize <<= 20;
  else if (*e == 'g' || *e == 'G') osize <<= 30;
  seed = strtoull(argv[2], NULL, 10);
  int verbose = argc > 3 && !strcmp(argv[3], "-v");
  rngs = mix(seed * 0x9E3779B97F4A7C15ull + 1);

  const uint64_t bnd[4] = {1ull << 31, 1ull << 32, 3ull << 31, 1ull << 33};
  int bdone[4] = {0, 0, 0, 0};
  const uint64_t sdist[4] = {700000000ull, 1500000000ull, 700000000ull,
                             1000000000ull};
  const uint64_t later[3] = {64000000ull, 1000000000ull, 1900000000ull};

  while (opos < osize) {
    /* scheduled re-repeats of the straddling segments */
    int did = 0;
    for (int q = 0; q < nsq; q++)
      if (opos >= sq[q].at) {
        repeat(sq[q].r, 0, reg[sq[q].r].len);
        nsched++;
        sq[q] = sq[--nsq];
        did = 1;
        break;
      }
    if (did) continue;

    /* straddle the boundaries */
    for (int b = 0; b < 4 && !did; b++) {
      if (bdone[b] || opos >= bnd[b] || bnd[b] >= osize) continue;
      if (opos + (8u << 20) < bnd[b]) continue;
      bdone[b] = 1;
      long r = pickreg(sdist[b], 1 << 16);
      if (r < 0) break;
      uint64_t len = reg[r].len;
      if (len > 2097157) len = 2097157;
      uint64_t start = bnd[b] - len / 2 - 1; /* odd offsets around B */
      if (start > opos) fresh(start - opos);
      size_t newr = nreg;
      repeat((size_t)r, reg[r].len - len, len);
      nstraddle++;
      for (int k = 0; k < 3 && nsq < 64; k++) {
        sq[nsq].at = opos + later[k];
        sq[nsq].r = newr;
        nsq++;
      }
      did = 1;
    }
    if (did) continue;

    uint64_t c = rnd() % 100;
    if (c < 3) { /* misalign */
      fresh(rndr(1, 7));
      nshift++;
    } else if (c < 45 || nreg < 8) { /* fresh */
      fresh(rndlog(4096, 4u << 20));
    } else { /* repeat */
      uint64_t maxd = opos < 1900000000ull ? opos : 1900000000ull;
      if (maxd < 16384) { fresh(65536); continue; }
      uint64_t d = rndlog(16384, maxd);
      size_t r = findreg(opos - d);
      uint64_t rl = reg[r].len;
      uint64_t off = rl > 1 ? rnd() % rl : 0;
      uint64_t len = (rnd() % 8 == 0) ? rndr(16, 600) : rndlog(4096, 4u << 20);
      if (off + len > rl) len = rl - off;
      if (!len) { fresh(4096); continue; }
      repeat(r, off, len);
    }
  }
  flush();
  if (fflush(stdout)) { perror("orep_bigsrc: write"); return 1; }
  if (verbose)
    fprintf(stderr,
            "orep_bigsrc: %llu bytes, %llu segments (fresh %llu, repeat %llu "
            "= %llu bytes, shift %llu, straddle %llu, scheduled %llu), "
            "max distance %llu\n",
            (unsigned long long)opos, (unsigned long long)nreg,
            (unsigned long long)nfresh, (unsigned long long)nrep,
            (unsigned long long)repbytes, (unsigned long long)nshift,
            (unsigned long long)nstraddle, (unsigned long long)nsched,
            (unsigned long long)maxdist);
  return 0;
}
