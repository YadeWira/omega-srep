/* Dedup statistics of a fragmenter over a set of files, as zpaq-std would
   see them when they are added to one archive (each file is cut on its own,
   fragments are deduplicated by SHA-1 across all files).

   usage: frag_stats MODE N FLAGS < list-of-files
     MODE  zpaq | osrep (osrep_frag_params_osrep: the gear CDC of -osrep)
     N     -fragment N (2^N KiB on average for both)
     FLAGS OSREP_FRAG_F_* bit mask (osrep only; 0 = plain gear CDC,
           42 = OSREP_FRAG_F_FORMAT, what -osrep uses)

   Prints: files bytes fragments unique_fragments unique_bytes mean_size
   index_est seconds (cut + SHA-1, without reading). index_est is the
   archive index estimate: 24 bytes per unique fragment + 4 per reference. */
#define _POSIX_C_SOURCE 199309L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "osrep_fragment.h"

static uint8_t (*tab)[20];
static uint64_t tabcap, tabn;

static int seen(const uint8_t h[20]) {
  uint64_t i;
  memcpy(&i, h, sizeof i);
  for (i &= tabcap - 1;; i = (i + 1) & (tabcap - 1)) {
    static const uint8_t zero[20];
    if (memcmp(tab[i], zero, 20) == 0) {
      memcpy(tab[i], h, 20);
      if (++tabn * 2 > tabcap) {
        fprintf(stderr, "table full\n");
        exit(3);
      }
      return 0;
    }
    if (memcmp(tab[i], h, 20) == 0) return 1;
  }
}

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
  osrep_frag_params p;
  char line[8192];
  uint64_t files = 0, bytes = 0, frags = 0, ufr = 0, ubytes = 0;
  double secs = 0;
  unsigned n;
  int osrep;
  if (argc != 4) {
    fprintf(stderr, "usage: %s zpaq|osrep N FLAGS < files\n", argv[0]);
    return 2;
  }
  osrep = strcmp(argv[1], "osrep") == 0;
  n = (unsigned)strtoul(argv[2], NULL, 10);
  if ((osrep ? osrep_frag_params_osrep(&p, n, 0)
             : osrep_frag_params_zpaq(&p, n, 0)) != OSREP_FRAG_OK)
    return 2;
  if (osrep) p.flags = (uint32_t)strtoul(argv[3], NULL, 0);
  tabcap = (uint64_t)1 << 24;
  tab = calloc((size_t)tabcap, 20);
  if (!tab) return 3;
  while (fgets(line, sizeof line, stdin)) {
    FILE *f;
    long sz;
    uint8_t *data = NULL;
    osrep_frag *fr = NULL;
    size_t fn = 0, i;
    double t0;
    line[strcspn(line, "\n")] = 0;
    f = fopen(line, "rb");
    if (!f) {
      fprintf(stderr, "cannot open %s\n", line);
      return 3;
    }
    if (fseek(f, 0, SEEK_END) != 0 || (sz = ftell(f)) < 0) return 3;
    rewind(f);
    if (sz > 0) {
      data = (uint8_t *)malloc((size_t)sz);
      if (!data || fread(data, 1, (size_t)sz, f) != (size_t)sz) return 3;
    }
    fclose(f);
    t0 = now();
    if (osrep_fragment_buffer(data, (size_t)sz, &p, &fr, &fn) != OSREP_FRAG_OK)
      return 3;
    secs += now() - t0;
    ++files;
    bytes += (uint64_t)sz;
    for (i = 0; i < fn; i++) {
      ++frags;
      if (!seen(fr[i].sha1)) {
        ++ufr;
        ubytes += fr[i].size;
      }
    }
    osrep_frag_free(fr);
    free(data);
  }
  printf("%llu\t%llu\t%llu\t%llu\t%llu\t%.0f\t%llu\t%.3f\n",
         (unsigned long long)files, (unsigned long long)bytes,
         (unsigned long long)frags, (unsigned long long)ufr,
         (unsigned long long)ubytes, frags ? (double)bytes / frags : 0.0,
         (unsigned long long)(ufr * 24 + frags * 4), secs);
  return 0;
}
