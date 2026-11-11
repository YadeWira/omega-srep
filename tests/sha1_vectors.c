/* FIPS 180-4 SHA-1 vectors for osrep_sha1. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "osrep_fragment.h"

static int check(const uint8_t *data, size_t len, const char *hex) {
  uint8_t out[20];
  char got[41];
  int i;
  osrep_sha1(data, len, out);
  for (i = 0; i < 20; i++) sprintf(got + i * 2, "%02x", out[i]);
  if (strcmp(got, hex) != 0) {
    fprintf(stderr, "FAIL len=%zu: got %s want %s\n", len, got, hex);
    return 1;
  }
  return 0;
}

int main(void) {
  uint8_t *million;
  int rc = 0;
  rc |= check((const uint8_t *)"", 0,
              "da39a3ee5e6b4b0d3255bfef95601890afd80709");
  rc |= check((const uint8_t *)"abc", 3,
              "a9993e364706816aba3e25717850c26c9cd0d89d");
  rc |= check((const uint8_t *)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
              56, "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
  million = (uint8_t *)malloc(1000000);
  if (million == NULL) return 2;
  memset(million, 'a', 1000000);
  rc |= check(million, 1000000,
              "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
  free(million);
  if (rc == 0) printf("sha1: all FIPS vectors OK\n");
  return rc;
}
