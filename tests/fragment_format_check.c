/* Format-aware cuts of the -osrep fragmenter (OSREP_FRAG_F_*).

   fragment_format_check same FILE N FLAGS
     The ways a caller can drive the state must give the fragments of
     osrep_fragment_buffer(): zpaq-std's inline loop and add2_scan (one
     byte at a time), the block scan (osrep_frag_state_scan) and a restart
     at any cut (what add2_scan's workers do at their guessed starts).
     FLAGS "osrep" keeps what osrep_frag_params_osrep() sets.

   fragment_format_check newbytes OLD NEW N FLAGS
     Prints the bytes of NEW in fragments that OLD does not have: what a
     second version would add to an archive that holds the first one. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "osrep_fragment.h"

static uint8_t *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  long sz;
  uint8_t *data;
  if (f == NULL) return NULL;
  if (fseek(f, 0, SEEK_END) != 0 || (sz = ftell(f)) < 0) {
    fclose(f);
    return NULL;
  }
  rewind(f);
  data = (uint8_t *)malloc((size_t)sz + 1);
  if (data == NULL || fread(data, 1, (size_t)sz, f) != (size_t)sz) {
    fclose(f);
    free(data);
    return NULL;
  }
  fclose(f);
  *len = (size_t)sz;
  return data;
}

static int params_for(osrep_frag_params *p, const char *n, const char *fl) {
  if (osrep_frag_params_osrep(p, (unsigned)strtoul(n, NULL, 10), 0) !=
      OSREP_FRAG_OK)
    return 1;
  if (strcmp(fl, "osrep") != 0) p->flags = (uint32_t)strtoul(fl, NULL, 0);
  return 0;
}

static int same(const osrep_frag *a, uint64_t off, uint32_t size,
                uint32_t hits, const uint8_t o1[256], const uint8_t *buf) {
  uint8_t sha1[20];
  osrep_sha1(buf + off, size, sha1);
  return a->off == off && a->size == size && a->hits == hits &&
         memcmp(a->o1, o1, 256) == 0 && memcmp(a->sha1, sha1, 20) == 0;
}

/* zpaq-std's inline loop: one byte at a time, the cut after that byte */
static int check_inline(const uint8_t *buf, size_t len,
                        const osrep_frag_params *p, const osrep_frag *ref,
                        size_t n) {
  osrep_frag_state st;
  size_t i = 0, got = 0;
  uint64_t start = 0;
  while (i < len) {
    uint32_t sz = 0;
    osrep_frag_state_reset(&st, p);
    while (i < len && sz < p->max) {
      ++sz;
      if (osrep_frag_state_push(&st, buf[i++])) break;
    }
    if (got >= n || !same(&ref[got], start, sz, st.hits, st.o1, buf)) {
      fprintf(stderr, "inline: fragment %zu differs\n", got);
      return 1;
    }
    ++got;
    start += sz;
  }
  if (got != n) {
    fprintf(stderr, "inline: %zu fragments, buffer %zu\n", got, n);
    return 1;
  }
  return 0;
}

/* osrep_frag_state_scan() over reads of odd sizes, as a caller that reads
   a file in blocks would drive it */
static int check_scan(const uint8_t *buf, size_t len,
                      const osrep_frag_params *p, const osrep_frag *ref,
                      size_t n) {
  osrep_frag_state st;
  size_t pos = 0, from = 0, got = 0;
  uint32_t x = 12345u;
  osrep_frag_state_reset(&st, p);
  while (pos < len) {
    size_t want, used;
    int cut = 0;
    x = x * 1664525u + 1013904223u;
    want = 1 + (x >> 20) % 70000u;
    if (want > len - pos) want = len - pos;
    used = osrep_frag_state_scan(&st, buf + pos, want, &cut);
    pos += used;
    if (cut || pos == len) {
      if (got >= n ||
          !same(&ref[got], from, (uint32_t)(pos - from), st.hits, st.o1, buf)) {
        fprintf(stderr, "scan: fragment %zu differs\n", got);
        return 1;
      }
      ++got;
      from = pos;
      osrep_frag_state_reset(&st, p);
    }
  }
  if (got != n) {
    fprintf(stderr, "scan: %zu fragments, buffer %zu\n", got, n);
    return 1;
  }
  return 0;
}

/* a restart at a cut gives the same cuts from there on */
static int check_restart(const uint8_t *buf, size_t len,
                         const osrep_frag_params *p, const osrep_frag *ref,
                         size_t n) {
  size_t j, k, step = n / 16 + 1;
  for (j = 1; j < n; j += step) {
    osrep_frag *sub = NULL;
    size_t m = 0;
    const uint64_t at = ref[j].off;
    if (osrep_fragment_buffer(buf + at, len - (size_t)at, p, &sub, &m) !=
            OSREP_FRAG_OK ||
        m != n - j) {
      fprintf(stderr, "restart at %zu: %zu fragments, want %zu\n", j, m, n - j);
      osrep_frag_free(sub);
      return 1;
    }
    for (k = 0; k < m; k++)
      if (sub[k].off + at != ref[j + k].off || sub[k].size != ref[j + k].size ||
          memcmp(sub[k].sha1, ref[j + k].sha1, 20) != 0) {
        fprintf(stderr, "restart at %zu: fragment %zu differs\n", j, k);
        osrep_frag_free(sub);
        return 1;
      }
    osrep_frag_free(sub);
  }
  return 0;
}

static int cmp_sha(const void *a, const void *b) {
  return memcmp(((const osrep_frag *)a)->sha1, ((const osrep_frag *)b)->sha1,
                20);
}

int main(int argc, char **argv) {
  osrep_frag_params p;
  if (argc == 5 && strcmp(argv[1], "same") == 0) {
    size_t len = 0, n = 0;
    osrep_frag *ref = NULL;
    uint8_t *buf = slurp(argv[2], &len);
    int bad;
    if (buf == NULL || params_for(&p, argv[3], argv[4]) ||
        osrep_fragment_buffer(buf, len, &p, &ref, &n) != OSREP_FRAG_OK)
      return 2;
    bad = check_inline(buf, len, &p, ref, n) || check_scan(buf, len, &p, ref, n) ||
          check_restart(buf, len, &p, ref, n);
    printf("%s: %zu fragments%s\n", argv[2], n, bad ? " FAIL" : "");
    osrep_frag_free(ref);
    free(buf);
    return bad;
  }
  if (argc == 6 && strcmp(argv[1], "newbytes") == 0) {
    size_t la = 0, lb = 0, na = 0, nb = 0, i;
    osrep_frag *fa = NULL, *fb = NULL;
    uint8_t *a = slurp(argv[2], &la), *b = slurp(argv[3], &lb);
    uint64_t fresh = 0;
    if (a == NULL || b == NULL || params_for(&p, argv[4], argv[5]) ||
        osrep_fragment_buffer(a, la, &p, &fa, &na) != OSREP_FRAG_OK ||
        osrep_fragment_buffer(b, lb, &p, &fb, &nb) != OSREP_FRAG_OK)
      return 2;
    qsort(fa, na, sizeof *fa, cmp_sha);
    for (i = 0; i < nb; i++)
      if (bsearch(&fb[i], fa, na, sizeof *fa, cmp_sha) == NULL)
        fresh += fb[i].size;
    printf("%llu\n", (unsigned long long)fresh);
    osrep_frag_free(fa);
    osrep_frag_free(fb);
    free(a);
    free(b);
    return 0;
  }
  fprintf(stderr,
          "usage: %s same FILE N FLAGS | newbytes OLD NEW N FLAGS\n", argv[0]);
  return 2;
}
