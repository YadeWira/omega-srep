/* libosrep's test, in C against osrep.h, the way an archiver uses it:

     test_lib                  self-tests (empty, text, pattern, errors)
     test_lib FILE...          each file through osrep_compress and
                               osrep_decompress, byte for byte
     test_lib --emit N IN OUT  compress IN with seed N (0 = default) and
                               write the .osr (for the CLI comparison)
     test_lib --emit-opt SEED BLOCK MIN CHAIN STRIDE IN OUT
                               the same with every encoder option
     test_lib --decode IN OUT  decompress IN and write OUT

   Prints a line per failure and "N checks, 0 failures" at the end. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include "osrep.h"

static int checks, failures;

static void check(int ok, const char *what, const char *name) {
  checks++;
  if (!ok) {
    failures++;
    printf("  FAIL  %s%s%s\n", what, (name && *name) ? ": " : "", name ? name : "");
  }
}

static unsigned char *read_file(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  unsigned char *d;
  long sz;
  if (!f) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
  sz = ftell(f);
  if (sz < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
  d = malloc(sz > 0 ? (size_t)sz : 1);
  if (!d) { fclose(f); return NULL; }
  if (sz > 0 && fread(d, 1, (size_t)sz, f) != (size_t)sz) {
    free(d); fclose(f); return NULL;
  }
  fclose(f);
  *n = (size_t)sz;
  return d;
}

static int write_file(const char *path, const void *d, size_t n) {
  FILE *f = fopen(path, "wb");
  if (!f) return 0;
  if (n > 0 && fwrite(d, 1, n, f) != n) { fclose(f); return 0; }
  return fclose(f) == 0;
}

static int compress_buf(const void *in, size_t n, void **out, size_t *outn,
                        uint64_t seed) {
  osrep_options o;
  osrep_options_default(&o);
  o.method = 3;
  o.seed = seed;
  return osrep_compress(in, n, out, outn, &o);
}

static void roundtrip(const unsigned char *d, size_t n, const char *name) {
  void *z = NULL, *back = NULL;
  size_t zn = 0, bn = 0;
  int rc = osrep_compress(d, n, &z, &zn, NULL); /* NULL: defaults */
  check(rc == OSREP_OK, "compress", name);
  if (rc != OSREP_OK) {
    printf("        %s\n", osrep_last_error());
    return;
  }
  check(zn >= 28 + 36, "archive has header and footer", name);
  rc = osrep_decompress(z, zn, &back, &bn, NULL);
  check(rc == OSREP_OK, "decompress", name);
  if (rc == OSREP_OK) {
    check(bn == n, "size", name);
    check(n == 0 || memcmp(back, d, n) == 0, "bytes", name);
    check(osrep_last_error()[0] == '\0', "empty last_error after success", name);
  } else {
    printf("        %s\n", osrep_last_error());
  }
  osrep_free(z);
  osrep_free(back);
}

static void determinism(void) {
  size_t n = 200000, zn1 = 0, zn2 = 0;
  unsigned char *d = malloc(n);
  void *z1 = NULL, *z2 = NULL;
  size_t i;
  for (i = 0; i < n; i++)
    d[i] = (unsigned char)((i * 31 + (i >> 7)) & 0xFF);
  memmove(d + 1000, d + 5000, 8000);
  check(compress_buf(d, n, &z1, &zn1, 12345) == OSREP_OK, "compress seed 12345", "");
  check(compress_buf(d, n, &z2, &zn2, 12345) == OSREP_OK, "compress seed 12345 again", "");
  check(zn1 == zn2 && zn1 > 0 && memcmp(z1, z2, zn1) == 0,
        "same seed, same archive", "");
  osrep_free(z1);
  osrep_free(z2);
  free(d);
}

static void error_paths(void) {
  void *out = (void *)1;
  size_t outn = 1;
  int rc;
  osrep_options o;

  rc = osrep_compress(NULL, 1, &out, &outn, NULL);
  check(rc == OSREP_E_ARG && out == NULL && outn == 0,
        "nil input with size is E_ARG", "");
  rc = osrep_compress("x", 1, NULL, &outn, NULL);
  check(rc == OSREP_E_ARG, "nil output is E_ARG", "");
  rc = osrep_decompress("x", 1, &out, NULL, NULL);
  check(rc == OSREP_E_ARG, "nil out_size is E_ARG", "");
  rc = osrep_decompress("x", 1, &out, &outn, NULL);
  check(rc == OSREP_E_DATA && out == NULL && outn == 0,
        "not an archive is E_DATA", "");
  check(osrep_last_error()[0] != '\0', "last_error explains the failure", "");

  osrep_options_default(&o);
  o.method = 4;
  rc = osrep_compress("x", 1, &out, &outn, &o);
  check(rc == OSREP_E_UNSUPPORTED, "method 4 is E_UNSUPPORTED", "");
  osrep_options_default(&o);
  o.dedup = 1;
  rc = osrep_compress("x", 1, &out, &outn, &o);
  check(rc == OSREP_E_UNSUPPORTED, "dedup encoding is E_UNSUPPORTED", "");
  osrep_options_default(&o);
  o.struct_size = 1;
  rc = osrep_compress("x", 1, &out, &outn, &o);
  check(rc == OSREP_E_ARG, "a bad struct_size is E_ARG", "");

  osrep_options_default(&o);
  {
    void *arc = NULL;
    size_t arcn = 0;
    rc = osrep_compress("OSREP", 5, &arc, &arcn, &o);
    check(rc == OSREP_OK, "compress for version test", "");
    if (rc == OSREP_OK) {
      ((unsigned char *)arc)[4] = 7;
      rc = osrep_decompress(arc, arcn, &out, &outn, &o);
      check(rc == OSREP_E_VERSION, "a newer version is E_VERSION", "");
    }
    osrep_free(arc);
    osrep_free(out);
  }
}

static void damaged_and_limit(void) {
  unsigned char d[4096];
  void *z = NULL;
  void *back = NULL;
  size_t zn = 0, bn = 0;
  osrep_options o;
  int rc;
  size_t i;

  for (i = 0; i < sizeof d; i++)
    d[i] = (unsigned char)((i * 7) & 0xFF);
  rc = osrep_compress(d, sizeof d, &z, &zn, NULL);
  check(rc == OSREP_OK, "compress for damage test", "");
  if (rc != OSREP_OK) return;

  ((unsigned char *)z)[zn / 2] ^= 0x5A;
  rc = osrep_decompress(z, zn, &back, &bn, NULL);
  check(rc != OSREP_OK, "a damaged archive is rejected", "");
  check(back == NULL && bn == 0, "a failed decompress returns nothing", "");
  osrep_free(z);

  z = NULL; zn = 0;
  check(osrep_compress(d, sizeof d, &z, &zn, NULL) == OSREP_OK,
        "compress for truncation test", "");
  rc = osrep_decompress(z, zn / 2, &back, &bn, NULL);
  check(rc != OSREP_OK, "a truncated archive is rejected", "");
  osrep_free(z);

  z = NULL; zn = 0;
  check(osrep_compress(d, sizeof d, &z, &zn, NULL) == OSREP_OK,
        "compress for max_output test", "");
  osrep_options_default(&o);
  o.max_output = 16;
  rc = osrep_decompress(z, zn, &back, &bn, &o);
  check(rc == OSREP_E_MEMORY, "max_output is enforced", "");
  o.max_output = 1 << 20;
  rc = osrep_decompress(z, zn, &back, &bn, &o);
  check(rc == OSREP_OK && bn == sizeof d, "a larger max_output is accepted", "");
  osrep_free(z);
  osrep_free(back);
}

static void pattern(void) {
  size_t n = 262144, i;
  unsigned char *d = malloc(n);
  for (i = 0; i < n; i++)
    d[i] = (unsigned char)((i * 17 + (i >> 5)) & 0xFF);
  for (i = 0; i + 4096 <= n; i += 16384)
    memset(d + i, 'O', 4096);
  roundtrip(d, n, "pattern 256 KiB");
  free(d);
}

typedef struct {
  int id;
  int ok;
} thread_arg;

static void *thread_work(void *p) {
  thread_arg *a = p;
  unsigned char d[8192];
  int round, i;
  a->ok = 0;
  for (i = 0; i < (int)sizeof d; i++)
    d[i] = (unsigned char)((a->id * 37 + i * 11) & 0xFF);
  memcpy(d + 512, d + 2048, 1024);
  for (round = 0; round < 25; round++) {
    void *z = NULL, *back = NULL;
    size_t zn = 0, bn = 0;
    if (osrep_compress(d, sizeof d, &z, &zn, NULL) != OSREP_OK) return NULL;
    if (osrep_decompress(z, zn, &back, &bn, NULL) != OSREP_OK ||
        bn != sizeof d || memcmp(back, d, sizeof d) != 0) {
      osrep_free(z);
      osrep_free(back);
      return NULL;
    }
    osrep_free(z);
    osrep_free(back);
  }
  a->ok = 1;
  return NULL;
}

static void threads(void) {
  pthread_t t[4];
  thread_arg a[4];
  int i, created = 0;
  for (i = 0; i < 4; i++) {
    a[i].id = i + 1;
    a[i].ok = 0;
    if (pthread_create(&t[i], NULL, thread_work, &a[i]) != 0) break;
    created++;
  }
  for (i = 0; i < created; i++)
    pthread_join(t[i], NULL);
  check(created == 4, "four threads run", "");
  check(created == 4 && a[0].ok && a[1].ok && a[2].ok && a[3].ok,
        "concurrent compress/decompress", "");
}

int main(int argc, char **argv) {
  if (argc == 5 && strcmp(argv[1], "--emit") == 0) {
    size_t n = 0, zn = 0;
    unsigned char *d = read_file(argv[3], &n);
    void *z = NULL;
    int rc;
    if (!d) { fprintf(stderr, "test_lib: cannot read %s\n", argv[3]); return 1; }
    rc = compress_buf(d, n, &z, &zn, strtoull(argv[2], NULL, 10));
    if (rc != OSREP_OK) {
      fprintf(stderr, "test_lib: compress: %s\n", osrep_last_error());
      free(d);
      return 1;
    }
    if (!write_file(argv[4], z, zn)) {
      fprintf(stderr, "test_lib: cannot write %s\n", argv[4]);
      osrep_free(z); free(d);
      return 1;
    }
    osrep_free(z);
    free(d);
    return 0;
  }
  if (argc == 9 && strcmp(argv[1], "--emit-opt") == 0) {
    size_t n = 0, zn = 0;
    unsigned char *d = read_file(argv[7], &n);
    osrep_options o;
    void *z = NULL;
    int rc;
    if (!d) { fprintf(stderr, "test_lib: cannot read %s\n", argv[7]); return 1; }
    osrep_options_default(&o);
    o.seed = strtoull(argv[2], NULL, 10);
    o.block_size = strtoull(argv[3], NULL, 10);
    o.min_match = (int32_t)strtol(argv[4], NULL, 0);
    o.chain_depth = (int32_t)strtol(argv[5], NULL, 0);
    o.stride = (int32_t)strtol(argv[6], NULL, 0);
    rc = osrep_compress(d, n, &z, &zn, &o);
    if (rc != OSREP_OK) {
      fprintf(stderr, "test_lib: compress: %s\n", osrep_last_error());
      free(d);
      return 1;
    }
    if (!write_file(argv[8], z, zn)) {
      fprintf(stderr, "test_lib: cannot write %s\n", argv[8]);
      osrep_free(z); free(d);
      return 1;
    }
    osrep_free(z);
    free(d);
    return 0;
  }
  if (argc == 4 && strcmp(argv[1], "--decode") == 0) {
    size_t n = 0, bn = 0;
    unsigned char *d = read_file(argv[2], &n);
    void *back = NULL;
    int rc;
    if (!d) { fprintf(stderr, "test_lib: cannot read %s\n", argv[2]); return 1; }
    rc = osrep_decompress(d, n, &back, &bn, NULL);
    if (rc != OSREP_OK) {
      fprintf(stderr, "test_lib: decompress: %s\n", osrep_last_error());
      free(d);
      return 1;
    }
    if (!write_file(argv[3], back, bn)) {
      fprintf(stderr, "test_lib: cannot write %s\n", argv[3]);
      osrep_free(back); free(d);
      return 1;
    }
    osrep_free(back);
    free(d);
    return 0;
  }

  check(strncmp(osrep_version(), "OSREP ", 6) == 0, "osrep_version", osrep_version());
  {
    osrep_options o;
    osrep_options_default(&o);
    check(o.struct_size == sizeof o, "struct_size", "");
    check(o.method == 3 && o.format == 6, "default method and format", "");
    check(o.block_size == 8u * 1024 * 1024, "default block size", "");
    check(o.min_match == 4 && o.chain_depth == 16 && o.stride == 1,
          "default match options", "");
    check(o.digest == 1, "default digest", "");
    check(o.reserved[0] == 0 && o.reserved[7] == 0, "reserved is zero", "");
  }

  roundtrip(NULL, 0, "empty");
  roundtrip((const unsigned char *)"", 0, "empty pointer");
  roundtrip((const unsigned char *)"OSREP library round-trip", 25, "text");
  pattern();
  determinism();
  threads();
  error_paths();
  damaged_and_limit();

  if (argc > 1) {
    int i;
    for (i = 1; i < argc; i++) {
      size_t n = 0;
      unsigned char *d = read_file(argv[i], &n);
      if (!d) { check(0, "read", argv[i]); continue; }
      roundtrip(d, n, argv[i]);
      free(d);
    }
  }

  printf("%d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
