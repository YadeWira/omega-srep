/* Quick dedup analysis of fragmenter variants without zpaq.

   usage: frag_sim LIST N[,N...] VARIANT...

   LIST has one path per line: the files zpaq would add, in order (unchanged
   files of a later version already left out). Each file is cut on its own,
   as zpaq does, and fragments are deduplicated across the whole list by a
   128-bit hash of their bytes. For every VARIANT and every N (average
   2^N KiB) it prints one TSV line:

     variant N bytes frags unique ubytes maxcuts est

   est = ubytes + 24 * unique + 4 * frags, the raw size of the unique data
   plus the index zpaq writes (SHA-1 and size per unique fragment in the h
   blocks, one 4-byte id per reference in the i blocks).

   VARIANT is "zpaq" (zpaq-std's order-1 fragmenter at -fragment N) or
   HASH:POLICY:LEVEL[:SWITCH]:
     HASH    fnv (48-byte rolling FNV-1a style), gear (h = (h<<1) + G[c])
             or gz (gear with G[0] = 0: 64 zeros give h = 0, a cut)
     POLICY  z (min A/16, max 8128<<N, zpaq's), f (min A/4), e (min A/8),
             h (min A/2), c (the shipped one: min A/2, max 8128<<(N+3) and
             threshold UINT64_MAX/A, no calibration)
     LEVEL   0 single threshold; 1..3 FastCDC normalized chunking: before
             the switch point the threshold is T>>L, after it T<<L
     SWITCH  switch point in 1/16 of A (default 16, the average)
   A = 1024 << N. Except for c, the base threshold is calibrated (random
   data model) so that the expected fragment size is A. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXV 64
#define MAXN 8

typedef struct {
  uint64_t a, b;
} key128;

typedef struct {
  key128 *k;
  size_t cap, n;
} kset;

typedef struct {
  char name[64];
  int zpaq, gear, policy, level, sw16;
  const uint64_t *g;
  /* per N */
  uint32_t min[MAXN], max[MAXN], sw[MAXN];
  uint64_t ts[MAXN], tl[MAXN];
  uint64_t bytes[MAXN], frags[MAXN], uniq[MAXN], ubytes[MAXN], maxcuts[MAXN];
  kset set[MAXN];
} variant;

static uint64_t G[256], GZ[256];
static int nN;
static unsigned Ns[MAXN];

static uint64_t splitmix(uint64_t *s) {
  uint64_t z = (*s += UINT64_C(0x9E3779B97F4A7C15));
  z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
  z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
  return z ^ (z >> 31);
}

static key128 hash128(const uint8_t *p, size_t n) {
  uint64_t a = UINT64_C(0x243F6A8885A308D3) ^ n, b = UINT64_C(0x13198A2E03707344);
  size_t i = 0;
  key128 k;
  for (; i + 8 <= n; i += 8) {
    uint64_t w;
    memcpy(&w, p + i, 8);
    a = (a ^ w) * UINT64_C(0x9FB21C651E98DF25);
    a ^= a >> 29;
    b = (b + w) * UINT64_C(0xC2B2AE3D27D4EB4F);
    b = (b << 31) | (b >> 33);
  }
  for (; i < n; i++) {
    a = (a ^ p[i]) * UINT64_C(0x9FB21C651E98DF25);
    b = (b + p[i]) * UINT64_C(0xC2B2AE3D27D4EB4F);
  }
  a ^= a >> 32;
  a *= UINT64_C(0xD6E8FEB86659FD93);
  a ^= a >> 32;
  b ^= b >> 29;
  b *= UINT64_C(0x94D049BB133111EB);
  b ^= b >> 32;
  k.a = a ^ (b >> 7);
  k.b = b;
  return k;
}

static int kset_add(kset *s, key128 k) {
  size_t i;
  if (k.a == 0 && k.b == 0) k.b = 1;
  if ((s->n + 1) * 2 > s->cap) {
    size_t nc = s->cap ? s->cap * 2 : 1024, j;
    key128 *nk = (key128 *)calloc(nc, sizeof(key128));
    if (!nk) {
      fprintf(stderr, "out of memory\n");
      exit(3);
    }
    for (j = 0; j < s->cap; j++)
      if (s->k[j].a | s->k[j].b) {
        size_t h = (size_t)(s->k[j].a & (nc - 1));
        while (nk[h].a | nk[h].b) h = (h + 1) & (nc - 1);
        nk[h] = s->k[j];
      }
    free(s->k);
    s->k = nk;
    s->cap = nc;
  }
  i = (size_t)(k.a & (s->cap - 1));
  while (s->k[i].a | s->k[i].b) {
    if (s->k[i].a == k.a && s->k[i].b == k.b) return 0;
    i = (i + 1) & (s->cap - 1);
  }
  s->k[i] = k;
  s->n++;
  return 1;
}

/* Expected fragment size on random data: cut probability ps at sizes
   [min, sw), pl at [sw, max), forced at max. Sum of P(len > s). */
static double expected_len(double min, double sw, double max, double ps,
                           double pl) {
  double e = min, surv = 1.0, n1, n2;
  if (sw < min) sw = min;
  if (sw > max) sw = max;
  n1 = sw - min;
  n2 = max - sw;
  /* sizes min..sw-1: P(len > s) = (1-ps)^(s-min+1) */
  if (ps > 0) {
    e += (1 - ps) * (1 - pow(1 - ps, n1)) / ps;
    surv = pow(1 - ps, n1);
  } else
    e += n1;
  if (pl > 0)
    e += surv * (1 - pl) * (1 - pow(1 - pl, n2 - 1)) / pl;
  else
    e += surv * (n2 - 1);
  return e;
}

static void setup(variant *v) {
  int i;
  for (i = 0; i < nN; i++) {
    unsigned N = Ns[i];
    double A = (double)(1024u << N), lo, hi, p = 0, t;
    v->max[i] = 8128u << N;
    switch (v->policy) {
      case 'z': v->min[i] = 64u << N; break;
      case 'e': v->min[i] = 128u << N; break;
      case 'f': v->min[i] = 256u << N; break;
      case 'h': v->min[i] = 512u << N; break;
      case 'c':
        v->min[i] = 512u << N;
        v->max[i] = 8128u << (N + 3);
        break;
    }
    v->sw[i] = (uint32_t)((1024u << N) / 16u * (unsigned)v->sw16);
    if (v->policy == 'c') {
      v->ts[i] = v->tl[i] = UINT64_MAX / (uint64_t)(1024u << N);
      continue;
    }
    lo = 1e-9;
    hi = 1.0;
    for (int it = 0; it < 200; it++) {
      double ps, pl, e;
      p = sqrt(lo * hi);
      ps = p / (double)(1 << v->level);
      pl = p * (double)(1 << v->level);
      if (pl > 1) pl = 1;
      e = expected_len(v->min[i], v->sw[i], v->max[i], ps, pl);
      if (e > A)
        lo = p;
      else
        hi = p;
    }
    t = p * 18446744073709551616.0;
    v->ts[i] = (uint64_t)(t / (double)(1 << v->level));
    t = t * (double)(1 << v->level);
    v->tl[i] = t >= 18446744073709551615.0 ? UINT64_MAX : (uint64_t)t;
  }
}

static const uint64_t FNV_PRIME = UINT64_C(0x100000001B3);

static void cut_file(variant *v, int ni, const uint8_t *d, size_t n) {
  size_t start = 0;
  uint32_t min = v->min[ni], max = v->max[ni], sw = v->sw[ni];
  uint64_t ts = v->ts[ni], tl = v->tl[ni];
  uint64_t pow48 = 1;
  int k;
  for (k = 0; k < 48; k++) pow48 *= FNV_PRIME;
  if (n == 0) {
    v->frags[ni]++;
    if (kset_add(&v->set[ni], hash128(d, 0))) v->uniq[ni]++;
    return;
  }
  while (start < n) {
    size_t rem = n - start, len = 0, lim = rem < max ? rem : max;
    int forced = 0;
    if (v->zpaq) {
      uint32_t h = 0, thr = 1u << (22 - Ns[ni]);
      uint8_t o1[256], c1 = 0;
      memset(o1, 0, 256);
      for (len = 0; len < lim;) {
        uint8_t c = d[start + len++];
        h = (h + c + 1) * (c == o1[c1] ? 314159265u : 271828182u);
        o1[c1] = c;
        c1 = c;
        if (h < thr && len >= min) break;
      }
      if (len == max) forced = 1;
    } else if (v->gear) {
      uint64_t h = 0;
      size_t s0 = min > 64 ? min - 64 : 0;
      len = lim;
      if (lim > min) {
        size_t j;
        for (j = s0; j < lim; j++) {
          h = (h << 1) + v->g[d[start + j]];
          if (j + 1 >= min) {
            uint64_t t = (j + 1 < sw) ? ts : tl;
            if (h < t) {
              len = j + 1;
              break;
            }
          }
        }
      }
      if (len == max && !(len < lim)) forced = 1;
    } else {
      uint64_t h = 0;
      size_t s0 = min > 48 ? min - 48 : 0, j;
      len = lim;
      if (lim > min) {
        for (j = s0; j < lim; j++) {
          h = h * FNV_PRIME + d[start + j];
          if (j >= s0 + 48) h -= (uint64_t)d[start + j - 48] * pow48;
          if (j + 1 >= min) {
            uint64_t t = (j + 1 < sw) ? ts : tl;
            if (h < t) {
              len = j + 1;
              break;
            }
          }
        }
      }
      if (len == max) forced = 1;
    }
    v->frags[ni]++;
    v->maxcuts[ni] += forced;
    if (kset_add(&v->set[ni], hash128(d + start, len))) {
      v->uniq[ni]++;
      v->ubytes[ni] += len;
    }
    start += len;
  }
}

int main(int argc, char **argv) {
  static variant V[MAXV];
  int nv = 0, i, j;
  FILE *lf;
  char line[8192];
  uint64_t seed = UINT64_C(0x4F5352455047454E); /* "OSREPGEN" */
  uint8_t *buf = NULL;
  size_t bcap = 0;
  char *tok;

  if (argc < 4) {
    fprintf(stderr, "usage: %s LIST N[,N...] VARIANT...\n", argv[0]);
    return 2;
  }
  for (i = 0; i < 256; i++) G[i] = GZ[i] = splitmix(&seed);
  GZ[0] = 0;
  for (tok = strtok(argv[2], ","); tok && nN < MAXN; tok = strtok(NULL, ","))
    Ns[nN++] = (unsigned)atoi(tok);
  for (i = 3; i < argc && nv < MAXV; i++) {
    variant *v = &V[nv++];
    char hash[16];
    char pol;
    int lev = 0, sw = 16, got;
    snprintf(v->name, sizeof v->name, "%s", argv[i]);
    if (strcmp(argv[i], "zpaq") == 0) {
      v->zpaq = 1;
      for (j = 0; j < nN; j++) {
        v->min[j] = 64u << Ns[j];
        v->max[j] = 8128u << Ns[j];
      }
      continue;
    }
    got = sscanf(argv[i], "%15[a-z]:%c:%d:%d", hash, &pol, &lev, &sw);
    if (got < 3) {
      fprintf(stderr, "bad variant %s\n", argv[i]);
      return 2;
    }
    v->gear = strcmp(hash, "gear") == 0 || strcmp(hash, "gz") == 0;
    v->g = strcmp(hash, "gz") == 0 ? GZ : G;
    v->policy = pol;
    v->level = lev;
    v->sw16 = sw;
    setup(v);
  }
  lf = fopen(argv[1], "r");
  if (!lf) return 3;
  while (fgets(line, sizeof line, lf)) {
    FILE *f;
    long sz;
    size_t L = strlen(line);
    while (L && (line[L - 1] == '\n' || line[L - 1] == '\r')) line[--L] = 0;
    if (!L) continue;
    f = fopen(line, "rb");
    if (!f) {
      fprintf(stderr, "cannot open %s\n", line);
      continue;
    }
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    rewind(f);
    if ((size_t)sz + 1 > bcap) {
      bcap = (size_t)sz + 1;
      buf = (uint8_t *)realloc(buf, bcap);
      if (!buf) return 3;
    }
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
      fclose(f);
      continue;
    }
    fclose(f);
    for (i = 0; i < nv; i++)
      for (j = 0; j < nN; j++) {
        V[i].bytes[j] += (uint64_t)sz;
        cut_file(&V[i], j, buf, (size_t)sz);
      }
  }
  fclose(lf);
  for (i = 0; i < nv; i++)
    for (j = 0; j < nN; j++) {
      variant *v = &V[i];
      printf("%s\t%u\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\n", v->name, Ns[j],
             (unsigned long long)v->bytes[j], (unsigned long long)v->frags[j],
             (unsigned long long)v->uniq[j], (unsigned long long)v->ubytes[j],
             (unsigned long long)v->maxcuts[j],
             (unsigned long long)(v->ubytes[j] + 24 * v->uniq[j] +
                                  4 * v->frags[j]));
    }
  return 0;
}
