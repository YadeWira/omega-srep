/* OSREP fragmenter API: zpaq-std's order-1 CDC (exact mode) and OSREP's
   48-byte FNV rolling CDC, with SHA-1 and the order-1 state zpaq's data-type
   analysis consumes.

   Pure functions, no globals, thread-safe. The exact-mode loop is the same as
   zpaq-std's fragment_buffer(); tests/fixtures/zpaq-fragments pin it. */
#include "osrep_fragment.h"

#include <stdlib.h>
#include <string.h>

#define HASH_MULT_HIT UINT32_C(314159265)
#define HASH_MULT_MISS UINT32_C(271828182)
#define FNV_PRIME UINT64_C(0x100000001B3)
#define OSREP_WINDOW 48
#define ZPAQ_DEFAULT_BLOCK (UINT32_C(64) * 1024 * 1024)

int osrep_frag_params_zpaq(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size) {
  uint64_t max64, min64;
  if (params == NULL || fragment > 22) return OSREP_FRAG_EINVAL;
  if (block_size == 0) block_size = ZPAQ_DEFAULT_BLOCK;
  if (block_size <= 12) return OSREP_FRAG_EINVAL;
  max64 = (uint64_t)8128u << fragment;
  if (fragment > 19 || max64 > (uint64_t)block_size - 12)
    max64 = (uint64_t)block_size - 12;
  min64 = (uint64_t)64u << fragment;
  if (min64 > max64) min64 = max64;
  params->mode = OSREP_FRAG_MODE_ZPAQ;
  params->min = (uint32_t)min64;
  params->max = (uint32_t)max64;
  params->threshold = (fragment <= 22) ? (UINT32_C(1) << (22 - fragment)) : 0;
  params->avg = 0;
  return OSREP_FRAG_OK;
}

int osrep_frag_params_osrep(osrep_frag_params *params, unsigned fragment,
                            uint32_t block_size) {
  uint64_t avg;
  if (osrep_frag_params_zpaq(params, fragment, block_size) != OSREP_FRAG_OK)
    return OSREP_FRAG_EINVAL;
  /* Default N=6 maps to the 8 KiB OSREP average that benchmarked well for
     -m5; smaller N gives smaller fragments (N=3 -> 1 KiB). */
  avg = UINT64_C(65536);
  if (fragment > 9)
    avg <<= (fragment - 9);
  else if (fragment < 9)
    avg >>= (9 - fragment);
  if (avg < 1024) avg = 1024;
  if (avg > (UINT64_C(1) << 20)) avg = UINT64_C(1) << 20;
  params->mode = OSREP_FRAG_MODE_OSREP;
  params->avg = (uint32_t)avg;
  return OSREP_FRAG_OK;
}

void osrep_frag_state_reset(osrep_frag_state *state,
                            const osrep_frag_params *params) {
  memset(state, 0, sizeof *state);
  state->mode = params->mode;
  state->min = params->min;
  state->max = params->max;
  state->threshold = params->threshold;
  state->avg = params->avg;
  if (params->mode == OSREP_FRAG_MODE_OSREP) {
    uint64_t p = 1;
    int i;
    for (i = 0; i < OSREP_WINDOW; i++) p *= FNV_PRIME;
    state->pow = p;
  }
}

int osrep_frag_state_push(osrep_frag_state *state, uint8_t c) {
  uint8_t pred = state->o1[state->c1];
  state->hits += (c == pred);
  state->o1[state->c1] = c;
  state->c1 = c;
  ++state->size;

  if (state->mode == OSREP_FRAG_MODE_OSREP) {
    state->h64 = state->h64 * FNV_PRIME + c;
    if (state->winlen >= OSREP_WINDOW)
      state->h64 -= (uint64_t)state->win[state->winpos] * state->pow;
    state->win[state->winpos] = c;
    state->winpos = (state->winpos + 1) % OSREP_WINDOW;
    if (state->winlen < OSREP_WINDOW) ++state->winlen;
    if (state->size >= state->min && state->avg != 0 &&
        (state->h64 < UINT64_MAX / state->avg || state->size >= state->max))
      return 1;
    return 0;
  }

  state->h = (state->h + (uint32_t)c + 1u) *
             ((c == pred) ? HASH_MULT_HIT : HASH_MULT_MISS);
  if (state->threshold != 0 && state->h < state->threshold &&
      state->size >= state->min)
    return 1;
  return 0;
}

static int append_fragment(osrep_frag **arr, size_t *cap, size_t *count,
                           const uint8_t *buf, size_t start, size_t len,
                           uint32_t hits, const uint8_t o1[256]) {
  osrep_frag *f;
  if (*count == *cap) {
    size_t newcap = *cap * 2;
    osrep_frag *grown;
    if (newcap <= *cap || newcap > SIZE_MAX / sizeof(**arr))
      return OSREP_FRAG_ENOMEM;
    grown = (osrep_frag *)realloc(*arr, newcap * sizeof(**arr));
    if (grown == NULL) return OSREP_FRAG_ENOMEM;
    *arr = grown;
    *cap = newcap;
  }
  f = &(*arr)[*count];
  f->off = (uint64_t)start;
  f->size = (uint32_t)len;
  f->hits = hits;
  memcpy(f->o1, o1, 256);
  osrep_sha1(buf + start, len, f->sha1);
  ++*count;
  return OSREP_FRAG_OK;
}

int osrep_fragment_buffer(const uint8_t *buf, size_t len,
                          const osrep_frag_params *params, osrep_frag **out,
                          size_t *out_n) {
  osrep_frag *arr;
  osrep_frag_state st;
  size_t cap, count = 0, start = 0, i;
  int rc;

  if (out == NULL || out_n == NULL || params == NULL) return OSREP_FRAG_EINVAL;
  *out = NULL;
  *out_n = 0;
  if (buf == NULL && len != 0) return OSREP_FRAG_EINVAL;
  if (params->mode != OSREP_FRAG_MODE_ZPAQ &&
      params->mode != OSREP_FRAG_MODE_OSREP)
    return OSREP_FRAG_ENOTSUP;
  if (params->min == 0 || params->max == 0) return OSREP_FRAG_EINVAL;
  if (params->mode == OSREP_FRAG_MODE_OSREP && params->avg == 0)
    return OSREP_FRAG_EINVAL;
  if (len == 0) return OSREP_FRAG_OK;

  cap = len / (size_t)params->min + 2;
  if (cap > 1024) cap = 1024;
  if (cap < 8) cap = 8;
  if (cap > SIZE_MAX / sizeof(*arr)) return OSREP_FRAG_ENOMEM;
  arr = (osrep_frag *)malloc(cap * sizeof(*arr));
  if (arr == NULL) return OSREP_FRAG_ENOMEM;

  osrep_frag_state_reset(&st, params);
  for (i = 0; i < len; i++) {
    int cut = osrep_frag_state_push(&st, buf[i]);
    if (cut || st.size >= params->max) {
      rc = append_fragment(&arr, &cap, &count, buf, start, st.size, st.hits,
                           st.o1);
      if (rc != OSREP_FRAG_OK) {
        free(arr);
        return rc;
      }
      start = i + 1;
      osrep_frag_state_reset(&st, params);
    }
  }
  if (st.size != 0) {
    rc = append_fragment(&arr, &cap, &count, buf, start, st.size, st.hits,
                         st.o1);
    if (rc != OSREP_FRAG_OK) {
      free(arr);
      return rc;
    }
  }

  *out = arr;
  *out_n = count;
  return OSREP_FRAG_OK;
}

void osrep_frag_free(osrep_frag *p) { free(p); }
