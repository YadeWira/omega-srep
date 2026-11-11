/* OSREP mode must reproduce the existing -m1/-m2 CDC boundaries from
   osrep_cdc_find() when given the same min/max/average. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "osrep_fragment.h"

typedef struct {
  uint64_t offset;
  uint32_t len;
  uint64_t hash;
} osrep_chunk;

size_t osrep_cdc_find(const uint8_t *data, size_t n, int chunker,
                      osrep_chunk *out, size_t cap);

int main(int argc, char **argv) {
  FILE *f;
  long sz;
  uint8_t *data = NULL;
  osrep_chunk *chunks;
  osrep_frag *frags = NULL;
  osrep_frag_params p;
  size_t cap, n, fn, i;

  if (argc != 2) {
    fprintf(stderr, "usage: %s FILE\n", argv[0]);
    return 2;
  }
  f = fopen(argv[1], "rb");
  if (!f) return 3;
  if (fseek(f, 0, SEEK_END) != 0) return 3;
  sz = ftell(f);
  if (sz < 0) return 3;
  rewind(f);
  if (sz > 0) {
    data = (uint8_t *)malloc((size_t)sz);
    if (!data) return 3;
    if (fread(data, 1, (size_t)sz, f) != (size_t)sz) return 3;
  }
  fclose(f);

  cap = (size_t)sz / 1024 + 1024;
  chunks = (osrep_chunk *)malloc(cap * sizeof(*chunks));
  if (!chunks) return 3;
  n = osrep_cdc_find(data, (size_t)sz, 1, chunks, cap);
  if (n == (size_t)-1) {
    fprintf(stderr, "cdc cap too small\n");
    return 3;
  }

  p.mode = OSREP_FRAG_MODE_OSREP;
  p.min = 4096;
  p.max = 8128u << 6;
  p.threshold = 0;
  p.avg = 8192;
  if (osrep_fragment_buffer(data, (size_t)sz, &p, &frags, &fn) !=
      OSREP_FRAG_OK) {
    fprintf(stderr, "fragment_buffer failed\n");
    return 3;
  }
  if (fn != n) {
    fprintf(stderr, "%s: %zu fragments vs %zu chunks\n", argv[1], fn, n);
    return 1;
  }
  for (i = 0; i < n; i++) {
    if (frags[i].off != chunks[i].offset || frags[i].size != chunks[i].len) {
      fprintf(stderr, "%s: fragment %zu mismatch\n", argv[1], i);
      return 1;
    }
  }
  osrep_frag_free(frags);
  free(chunks);
  free(data);
  return 0;
}
