/* Speed of the fragmenter alone (cut decisions plus the order-1 hits and o1
   table zpaq needs; no SHA-1, no I/O inside the timing).

   usage: frag_speed FILE REPS N MODE...

   MODE is zpaq, fnv (the -m1 CDC with its old mapping: -fragment N averages
   2^(N-3) KiB, so pass N+3 for the same average), gear:S:L (min A >> S,
   normalized chunking level L) or osrep (the shipped -osrep policy). Each
   mode is timed REPS times with osrep_frag_state_push() byte by byte (what
   zpaq-std's add loop does) and with osrep_frag_state_scan(); the median
   MB/s of each is printed with the fragment count.

   cc -O2 -std=c99 -Isrc/c src/c/osrep_fragment.c src/c/osrep_sha1.c \
      tools/zpaq-vectors/frag_speed.c -o frag_speed */
#define _POSIX_C_SOURCE 199309L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "osrep_fragment.h"

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int cmpd(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

static size_t run_push(const osrep_frag_params *p, const uint8_t *buf,
                       size_t n, uint32_t *sink) {
  osrep_frag_state st;
  size_t i, frags = 0;
  osrep_frag_state_reset(&st, p);
  for (i = 0; i < n; i++)
    if (osrep_frag_state_push(&st, buf[i]) || st.size >= p->max) {
      *sink += st.hits;
      ++frags;
      osrep_frag_state_reset(&st, p);
    }
  return frags + (st.size != 0);
}

static size_t run_scan(const osrep_frag_params *p, const uint8_t *buf,
                       size_t n, uint32_t *sink) {
  osrep_frag_state st;
  size_t pos = 0, frags = 0;
  int cut;
  osrep_frag_state_reset(&st, p);
  while (pos < n) {
    pos += osrep_frag_state_scan(&st, buf + pos, n - pos, &cut);
    if (cut) {
      *sink += st.hits;
      ++frags;
      osrep_frag_state_reset(&st, p);
    }
  }
  return frags + (st.size != 0);
}

int main(int argc, char **argv) {
  FILE *f;
  long sz;
  uint8_t *buf;
  int reps, a, r, k;
  unsigned n;
  uint32_t sink = 0;
  if (argc < 5) {
    fprintf(stderr, "usage: %s FILE REPS N MODE...\n", argv[0]);
    return 2;
  }
  f = fopen(argv[1], "rb");
  if (!f) return 3;
  fseek(f, 0, SEEK_END);
  sz = ftell(f);
  rewind(f);
  buf = (uint8_t *)malloc((size_t)sz + 1);
  if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) return 3;
  fclose(f);
  reps = atoi(argv[2]);
  if (reps < 1 || reps > 99) reps = 3;
  n = (unsigned)atoi(argv[3]);
  printf("mode\tN\tfrags\tpush_MBps\tscan_MBps\n");
  for (a = 4; a < argc; a++) {
    osrep_frag_params p;
    unsigned s = 0, l = 0;
    int rc;
    double t[2][99];
    size_t frags[2] = {0, 0};
    if (strcmp(argv[a], "zpaq") == 0)
      rc = osrep_frag_params_zpaq(&p, n, 0);
    else if (strcmp(argv[a], "fnv") == 0)
      rc = osrep_frag_params_fnv(&p, n, 0);
    else if (strcmp(argv[a], "osrep") == 0)
      rc = osrep_frag_params_osrep(&p, n, 0);
    else if (sscanf(argv[a], "gear:%u:%u", &s, &l) == 2)
      rc = osrep_frag_params_gear(&p, n, 0, s, l);
    else
      rc = -1;
    if (rc != OSREP_FRAG_OK) {
      fprintf(stderr, "bad mode %s\n", argv[a]);
      return 2;
    }
    for (r = 0; r < reps; r++)
      for (k = 0; k < 2; k++) {
        double t0 = now();
        frags[k] = k == 0 ? run_push(&p, buf, (size_t)sz, &sink)
                          : run_scan(&p, buf, (size_t)sz, &sink);
        t[k][r] = (double)sz / 1e6 / (now() - t0);
      }
    if (frags[0] != frags[1]) {
      fprintf(stderr, "%s: push %zu vs scan %zu fragments\n", argv[a],
              frags[0], frags[1]);
      return 1;
    }
    qsort(t[0], (size_t)reps, sizeof(double), cmpd);
    qsort(t[1], (size_t)reps, sizeof(double), cmpd);
    printf("%s\t%u\t%zu\t%.0f\t%.0f\n", argv[a], n, frags[0], t[0][reps / 2],
           t[1][reps / 2]);
  }
  fprintf(stderr, "(sink %u)\n", (unsigned)sink);
  free(buf);
  return 0;
}
