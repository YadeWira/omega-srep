#ifndef OSREP_FRAGMENT_H
#define OSREP_FRAGMENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mode 0 reproduces zpaq-std's order-1 fragmenter byte for byte. Mode 1 is
   OSREP's first content-defined fragmenter: a 48-byte FNV rolling hash that
   cuts at the target average, between the same minimum and maximum (the -m1
   CDC). Mode 2 is the one -osrep uses: a 64-byte gear hash with cut-point
   skipping; it can also do FastCDC normalized chunking (a stricter cut
   condition before the normal size, a looser one after), which -osrep does
   not use (docs/experiments/frag-normalized.md). */
#define OSREP_FRAG_MODE_ZPAQ 0u
#define OSREP_FRAG_MODE_OSREP 1u
#define OSREP_FRAG_MODE_GEAR 2u

#define OSREP_FRAG_OK 0
#define OSREP_FRAG_EINVAL 1
#define OSREP_FRAG_ENOMEM 2
#define OSREP_FRAG_ENOTSUP 3

/* Format-aware cuts (gear mode only): forced cuts at archive structure
   boundaries, decided only from the bytes of the current fragment, so the
   state still starts fresh at every cut and add2_scan's resync holds. They
   ignore the minimum and never move a cut back (no byte is given back).
   TAR_AFTER: after a ustar/gnu/pax header with a valid checksum.
   ZIP_SIG: after a zip local header signature ("PK\3\4") and after the
     first central directory signature ("PK\1\2" ending a fragment that did
     not begin inside the central directory).
   ZIP_AFTER (with ZIP_SIG): also after the rest of a local header (26 bytes
     plus name and extra), so a member's data starts its own fragment.
   The values are those of docs/experiments/frag-formataware.md, where the
   rules that give bytes back (TAR_BEFORE 1, ZIP_BEFORE 4) and the newline
   rule (TEXT 16) were measured and left out. osrep_frag_params_osrep() sets
   OSREP_FRAG_F_FORMAT. */
#define OSREP_FRAG_F_TAR_AFTER 2u
#define OSREP_FRAG_F_ZIP_AFTER 8u
#define OSREP_FRAG_F_ZIP_SIG 32u
#define OSREP_FRAG_F_FORMAT \
  (OSREP_FRAG_F_TAR_AFTER | OSREP_FRAG_F_ZIP_AFTER | OSREP_FRAG_F_ZIP_SIG)

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
  uint32_t avg;        /* OSREP and gear modes: target average size */
  /* Gear mode: cut when h < t_small at sizes [min, norm), when h < t_large
     at sizes [norm, max), and at max. osrep_frag_params_osrep() fills them. */
  uint32_t norm;
  uint64_t t_small;
  uint64_t t_large;
  uint32_t flags;      /* gear mode: OSREP_FRAG_F_* (0 = plain CDC) */
} osrep_frag_params;

/* Incremental state for callers that read a file in blocks. Reset it at the
   start of every file and after every cut; push one byte and it returns 1
   when the fragment must end after that byte. In zpaq mode the max-size cut
   stays with the caller; the OSREP and gear modes also return 1 at max. The
   cuts depend only on the bytes since the last cut. */
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
  uint32_t norm;
  uint64_t t_small;
  uint64_t t_large;
  uint32_t flags;     /* OSREP_FRAG_F_* */
  uint32_t last4;     /* the last four bytes, big-endian */
  uint32_t zend;      /* ZIP_AFTER: end of the local header at the start */
  uint32_t zcd;       /* ZIP_SIG: this fragment began in the central dir */
  uint8_t ring[512];  /* format rules: the last 512 bytes; not cleared */
} osrep_frag_state;

void osrep_frag_state_reset(osrep_frag_state *state,
                            const osrep_frag_params *params);
int osrep_frag_state_push(osrep_frag_state *state, uint8_t c);
/* The same as pushing buf[0..len) one byte at a time, but stops after the
   byte that ends the fragment (content or format cut, or max in the OSREP
   and gear modes). Returns the number of bytes consumed and sets *cut to 1
   when the fragment ended there. The fast path for the gear mode without
   flags; with flags it pushes byte by byte. */
size_t osrep_frag_state_scan(osrep_frag_state *state, const uint8_t *buf,
                             size_t len, int *cut);

/* Fill params with zpaq-std's -fragment N mapping. block_size is zpaq's
   block size (0 = 64 MiB), used to clamp max the same way zpaq does. */
int osrep_frag_params_zpaq(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size);
/* -osrep, the whole policy (what zpaq-std calls; docs/zpaq-fragment-api.md):
   the gear fragmenter with -fragment N meaning what it means in zpaq, an
   average of 2^N KiB (N=3 8 KiB, N=6 64 KiB): min A/2, max 8128 << N
   (zpaq's MAX_FRAGMENT: pass zpaq's block size to clamp it the same way),
   one threshold calibrated so that random data averages A, and
   flags = OSREP_FRAG_F_FORMAT. N <= 21. zpaq-std's -osrep uses N=3 when
   -fragment is not given. */
int osrep_frag_params_osrep(osrep_frag_params *params, unsigned fragment,
                            uint32_t block_size);
/* The gear fragmenter with an explicit policy, for experiments and tests:
   average A = 2^N KiB, min A >> min_shift (1..4), normalized chunking level
   0..3 (0 = one threshold; L > 0 cuts with T >> L below A and T << L from A
   on), max 8128 << N as in zpaq. osrep_frag_params_osrep() is this with
   min_shift 1 and level 0. */
int osrep_frag_params_gear(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size, unsigned min_shift,
                           unsigned level);
/* The first OSREP mode (48-byte FNV) with its old mapping: average
   64 KiB << (N-9), 1 KiB to 1 MiB, zpaq's min and max. */
int osrep_frag_params_fnv(osrep_frag_params *params, unsigned fragment,
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
