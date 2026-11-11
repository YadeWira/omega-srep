/* Print the OSREP SHA-1 of a file (for differential tests). */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "osrep_fragment.h"

int main(int argc, char **argv) {
  FILE *f;
  long sz;
  uint8_t *data = NULL, out[20];
  int i;
  if (argc != 2) {
    fprintf(stderr, "usage: %s FILE\n", argv[0]);
    return 2;
  }
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
  osrep_sha1(data, (size_t)sz, out);
  for (i = 0; i < 20; i++) printf("%02x", out[i]);
  printf("\n");
  free(data);
  return 0;
}
