/* libosrep: OSREP as a library, for archivers and other programs.

   OSREP is an LZ77 preprocessor: the .osr stream holds matches and
   literals, not entropy-coded data, and a backend (zpaq-std, an archiver)
   does the final compression. The library writes and reads the v6 format
   (spec/format-v6.md) and does not add a container of its own.

   Two functions are enough for the common case:

     osrep_compress()    a buffer -> a .osr stream, in memory
     osrep_decompress()  a .osr stream -> the original, checked against the
                         block CRCs and the per-block digest

   Every buffer the library returns is freed with osrep_free(). The error
   text of the last failed call is thread-local and returned by
   osrep_last_error(); no exception crosses this interface.

   osrep_options_default() fills the options with the same defaults as the
   `osrep -m3` command: 8 MiB blocks, minimum match 4, chain depth 16,
   stride 1, VHASH-128 digest and the deterministic seed 0. Call it before
   changing a field; a zeroed struct is accepted, but digest = 0 then means
   "no digest", not "the default". */
#ifndef OSREP_H
#define OSREP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(_WIN64)
#define OSREP_CALL __cdecl
#else
#define OSREP_CALL
#endif

#define OSREP_API_VERSION 1

enum {
  OSREP_OK = 0,
  OSREP_E_DATA = 1,        /* damaged, truncated or not an OSR6 stream */
  OSREP_E_MEMORY = 2,      /* out of memory, or over max_output */
  OSREP_E_IO = 3,          /* a read or write failed */
  OSREP_E_ARG = 4,         /* a null pointer or a bad option */
  OSREP_E_VERSION = 5,     /* written by a newer OSREP (v6 is the only one
                              this release writes and reads) */
  OSREP_E_NOT_TAKEN = 6,   /* reserved: OSREP takes any bytes, so it is not
                              returned by this release */
  OSREP_E_UNSUPPORTED = 7  /* an option or method not implemented yet */
};

/* Error codes may be added. A caller treats one it does not know as an
   error, as it treats OSREP_E_DATA. */

typedef struct osrep_options {
  uint32_t struct_size;   /* sizeof(osrep_options), or 0 */
  int32_t  method;        /* 0 = default, 1..5 = -m1..-m5 */
  int32_t  format;        /* 0 = default, 6 = v6 */
  int32_t  dedup;         /* 0 = off, 1 = -dup (CDC + DUPR meta); ignored
                             when decoding (the flag in the archive decides) */
  int32_t  threads;       /* 0 = auto, 1 = one; the MVP encoder is
                             single-threaded, the value is accepted so the
                             ABI does not change when it uses it */
  uint64_t seed;          /* 0 = the CLI's deterministic default;
                             otherwise SeedFromNumber(seed) */
  uint64_t block_size;    /* 0 = 8 MiB */
  uint64_t max_output;    /* decompress: 0 = no extra cap; checked before
                             the output is allocated and while a -dup
                             archive is restored */
  int32_t  min_match;     /* 0 = 4 */
  int32_t  chain_depth;   /* 0 = 16 */
  int32_t  stride;        /* 0 = 1 */
  int32_t  digest;        /* -1 = default (VHASH-128), 0 = none (-hash-) */
  uint32_t reserved[8];   /* must be zero */
} osrep_options;

void OSREP_CALL osrep_options_default(osrep_options *o);

/* "OSREP 0.0.2" */
const char *OSREP_CALL osrep_version(void);

/* The last error on this thread; "" after a successful call. */
const char *OSREP_CALL osrep_last_error(void);

/* in[0..in_size) -> a .osr stream in *out, *out_size bytes, to free with
   osrep_free(). o may be NULL for the defaults. On failure *out is NULL and
   *out_size is 0. */
int OSREP_CALL osrep_compress(const void *in, size_t in_size,
                              void **out, size_t *out_size,
                              const osrep_options *o);

/* A .osr stream -> the original in *out, *out_size bytes, to free with
   osrep_free(). o may be NULL for the defaults; o->max_output caps the
   original's size (0 = no extra cap). */
int OSREP_CALL osrep_decompress(const void *in, size_t in_size,
                                void **out, size_t *out_size,
                                const osrep_options *o);

/* A file -> a .osr file, and back. Paths are UTF-8 on Unix; on Windows the
   RTL's file system code page is used, so a host with non-ASCII names sets
   it to CP_UTF8. The output is created/truncated; on failure it may be
   partial. */
int OSREP_CALL osrep_compress_file(const char *in_path, const char *out_path,
                                   const osrep_options *o);
int OSREP_CALL osrep_decompress_file(const char *in_path, const char *out_path,
                                     const osrep_options *o);

void OSREP_CALL osrep_free(void *p);

#ifdef __cplusplus
}
#endif
#endif
