/* Dump the OSREP fragmenter output as TSV, matching the zpaq-std Phase 0
   vectors: offset size hits sha1(hex) o1(hex).

   usage: fragment_dump FILE [FRAGMENT] [BLOCK_SIZE] */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "osrep_fragment.h"

int main(int argc, char **argv) {
  FILE *f;
  long sz;
  uint8_t *data = NULL;
  unsigned fragment = 6;
  unsigned long block_size = 0;
  osrep_frag_params params;
  osrep_frag *frags = NULL;
  size_t n = 0, i;
  int rc;

  if (argc < 2 || argc > 4) {
    fprintf(stderr, "usage: %s FILE [FRAGMENT] [BLOCK_SIZE]\n", argv[0]);
    return 2;
  }
  if (argc >= 3) fragment = (unsigned)strtoul(argv[2], NULL, 10);
  if (argc >= 4) block_size = strtoul(argv[3], NULL, 10);
  f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 3;
  }
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

  rc = osrep_frag_params_zpaq(&params, fragment, (uint32_t)block_size);
  if (rc != OSREP_FRAG_OK) {
    fprintf(stderr, "bad params (rc=%d)\n", rc);
    return 3;
  }
  rc = osrep_fragment_buffer(data, (size_t)sz, &params, &frags, &n);
  if (rc != OSREP_FRAG_OK) {
    fprintf(stderr, "fragment_buffer failed (rc=%d)\n", rc);
    return 3;
  }
  printf("offset\tsize\thits\tsha1\to1\n");
  for (i = 0; i < n; i++) {
    int j;
    printf("%llu\t%u\t%u\t", (unsigned long long)frags[i].off,
           (unsigned)frags[i].size, (unsigned)frags[i].hits);
    for (j = 0; j < 20; j++) printf("%02x", frags[i].sha1[j]);
    printf("\t");
    for (j = 0; j < 256; j++) printf("%02x", frags[i].o1[j]);
    printf("\n");
  }
  osrep_frag_free(frags);
  free(data);
  return 0;
}
