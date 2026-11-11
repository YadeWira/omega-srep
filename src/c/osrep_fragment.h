#ifndef OSREP_FRAGMENT_H
#define OSREP_FRAGMENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mode 0 reproduces zpaq-std's order-1 fragmenter byte for byte. Mode 1 is
   OSREP's content-defined fragmenter: a 48-byte FNV rolling hash that cuts
   at the target average, between the same minimum and maximum. */
#define OSREP_FRAG_MODE_ZPAQ 0u
#define OSREP_FRAG_MODE_OSREP 1u

#define OSREP_FRAG_OK 0
#define OSREP_FRAG_EINVAL 1
#define OSREP_FRAG_ENOMEM 2
#define OSREP_FRAG_ENOTSUP 3

/* What zpaq-std needs for its fragment table and data-type analysis. */
typedef struct {
  uint64_t off;      /* byte offset in the input buffer */
  uint32_t size;     /* fragment length */
  uint8_t sha1[20];  /* SHA-1 of the fragment */
  uint32_t hits;     /* order-1 prediction hits inside the fragment */
  uint8_t o1[256];   /* order-1 table at the end of the fragment */
} osrep_frag;

typedef struct {
  uint32_t mode;       /* OSREP_FRAG_MODE_* */
  uint32_t min;        /* minimum fragment size */
  uint32_t max;        /* maximum fragment size */
  uint32_t threshold;  /* zpaq mode: cut when h < threshold */
  uint32_t avg;        /* OSREP mode: target average fragment size */
} osrep_frag_params;

/* Incremental state for callers that read a file in blocks. Reset it at the
   start of every fragment; push one byte and it returns 1 when the fragment
   must end after that byte (the max-size cut stays with the caller). */
typedef struct {
  uint32_t mode;
  uint32_t h;
  uint32_t hits;
  uint32_t min;
  uint32_t max;
  uint32_t threshold;
  uint32_t avg;
  uint32_t size;
  uint8_t c1;
  uint8_t o1[256];
  uint64_t h64;
  uint64_t pow;
  uint8_t win[48];
  uint32_t winpos;
  uint32_t winlen;
} osrep_frag_state;

void osrep_frag_state_reset(osrep_frag_state *state,
                            const osrep_frag_params *params);
int osrep_frag_state_push(osrep_frag_state *state, uint8_t c);

/* Fill params with zpaq-std's -fragment N mapping. block_size is zpaq's
   block size (0 = 64 MiB), used to clamp max the same way zpaq does. */
int osrep_frag_params_zpaq(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size);
/* OSREP mode: 48-byte FNV rolling hash. The average is derived from the
   zpaq fragment level (N=6 -> 64 KiB, lower N -> smaller); min/max follow
   the zpaq mapping. */
int osrep_frag_params_osrep(osrep_frag_params *params, unsigned fragment,
                            uint32_t block_size);

/* Fragment a whole buffer. On success *out is a malloc'ed array of *out_n
   entries; free it with osrep_frag_free(). The function keeps no state and
   is safe to call from several threads. */
int osrep_fragment_buffer(const uint8_t *buf, size_t len,
                          const osrep_frag_params *params, osrep_frag **out,
                          size_t *out_n);

void osrep_frag_free(osrep_frag *p);

/* SHA-1 (FIPS 180-4) of a memory buffer. */
void osrep_sha1(const uint8_t *data, size_t len, uint8_t out[20]);

#ifdef __cplusplus
}
#endif

#endif
