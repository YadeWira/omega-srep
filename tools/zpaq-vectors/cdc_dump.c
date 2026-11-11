/* Dump OSREP CDC chunks as TSV: offset, size.
   Built against src/c/osrep_cdc.c; used to compare with the zpaq-std Phase 0
   vectors (tests/zpaq-vectors). */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct {
  uint64_t offset;
  uint32_t len;
  uint64_t hash;
} osrep_chunk;

size_t osrep_cdc_find(const uint8_t *data, size_t n, int chunker,
                      osrep_chunk *out, size_t cap);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s FILE\n", argv[0]);
    return 2;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 3;
  }
  if (fseek(f, 0, SEEK_END) != 0) return 3;
  long sz = ftell(f);
  if (sz < 0) return 3;
  rewind(f);
  uint8_t *data = NULL;
  if (sz > 0) {
    data = (uint8_t *)malloc((size_t)sz);
    if (!data) return 3;
    if (fread(data, 1, (size_t)sz, f) != (size_t)sz) return 3;
  }
  fclose(f);

  size_t cap = 16;
  osrep_chunk *chunks = (osrep_chunk *)malloc(cap * sizeof *chunks);
  if (!chunks) return 3;
  size_t n = osrep_cdc_find(data, (size_t)sz, 0, chunks, cap);
  if (n == (size_t)-1) {
    free(chunks);
    cap = (size_t)sz / 1024 + 1024;
    chunks = (osrep_chunk *)malloc(cap * sizeof *chunks);
    if (!chunks) return 3;
    n = osrep_cdc_find(data, (size_t)sz, 0, chunks, cap);
  }
  if (n == (size_t)-1) {
    fprintf(stderr, "cdc cap too small\n");
    return 3;
  }
  printf("offset\tsize\n");
  for (size_t i = 0; i < n; i++)
    printf("%llu\t%u\n", (unsigned long long)chunks[i].offset,
           (unsigned)chunks[i].len);
  free(chunks);
  free(data);
  return 0;
}
