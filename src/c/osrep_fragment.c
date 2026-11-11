/* OSREP fragmenter API: the zpaq-std order-1 content-defined chunker plus
   SHA-1 and the order-1 state zpaq's data-type analysis consumes.

   Pure function, no globals, thread-safe. The exact-mode loop is the same as
   zpaq-std's fragment_buffer() (MIN/MAX/threshold and multipliers); the
   vectors in tests/fixtures/zpaq-fragments pin it. */
#include "osrep_fragment.h"

#include <stdlib.h>
#include <string.h>

#define HASH_MULT_HIT UINT32_C(314159265)
#define HASH_MULT_MISS UINT32_C(271828182)
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
  return OSREP_FRAG_OK;
}

void osrep_frag_state_reset(osrep_frag_state *state,
                            const osrep_frag_params *params) {
  memset(state, 0, sizeof *state);
  state->min = params->min;
  state->max = params->max;
  state->threshold = params->threshold;
}

int osrep_frag_state_push(osrep_frag_state *state, uint8_t c) {
  uint8_t pred = state->o1[state->c1];
  state->h = (state->h + (uint32_t)c + 1u) *
             ((c == pred) ? HASH_MULT_HIT : HASH_MULT_MISS);
  state->hits += (c == pred);
  state->o1[state->c1] = c;
  state->c1 = c;
  ++state->size;
  if (state->threshold != 0 && state->h < state->threshold &&
      state->size >= state->min)
    return 1;
  return 0;
}

int osrep_fragment_buffer(const uint8_t *buf, size_t len,
                          const osrep_frag_params *params, osrep_frag **out,
                          size_t *out_n) {
  osrep_frag *arr;
  size_t cap, count = 0, pos = 0;
  uint32_t min, max, threshold;

  if (out == NULL || out_n == NULL || params == NULL) return OSREP_FRAG_EINVAL;
  *out = NULL;
  *out_n = 0;
  if (buf == NULL && len != 0) return OSREP_FRAG_EINVAL;
  if (params->mode != OSREP_FRAG_MODE_ZPAQ) return OSREP_FRAG_ENOTSUP;
  min = params->min;
  max = params->max;
  threshold = params->threshold;
  if (min == 0 || max == 0) return OSREP_FRAG_EINVAL;
  if (min > max) min = max;
  if (len == 0) return OSREP_FRAG_OK;

  cap = len / (size_t)min + 2;
  if (cap > 1024) cap = 1024;  /* grow on demand; do not size for the minimum */
  if (cap < 8) cap = 8;
  if (cap > SIZE_MAX / sizeof(*arr)) return OSREP_FRAG_ENOMEM;
  arr = (osrep_frag *)malloc(cap * sizeof(*arr));
  if (arr == NULL) return OSREP_FRAG_ENOMEM;

  while (pos < len) {
    size_t start = pos, sz = 0;
    uint32_t h = 0, hits = 0;
    uint8_t o1[256], c1 = 0;
    memset(o1, 0, sizeof o1);
    while (pos < len && sz < (size_t)max) {
      uint8_t uc = buf[pos++];
      uint8_t pred = o1[c1];
      h = (h + (uint32_t)uc + 1u) *
          ((uc == pred) ? HASH_MULT_HIT : HASH_MULT_MISS);
      hits += (uc == pred);
      o1[c1] = uc;
      c1 = uc;
      ++sz;
      if (threshold != 0 && h < threshold && sz >= (size_t)min) break;
    }
    if (sz == 0) break;
    if (count == cap) {
      size_t newcap = cap * 2;
      osrep_frag *grown;
      if (newcap <= cap || newcap > SIZE_MAX / sizeof(*arr)) {
        free(arr);
        return OSREP_FRAG_ENOMEM;
      }
      grown = (osrep_frag *)realloc(arr, newcap * sizeof(*arr));
      if (grown == NULL) {
        free(arr);
        return OSREP_FRAG_ENOMEM;
      }
      arr = grown;
      cap = newcap;
    }
    arr[count].off = (uint64_t)start;
    arr[count].size = (uint32_t)sz;
    arr[count].hits = hits;
    memcpy(arr[count].o1, o1, sizeof o1);
    osrep_sha1(buf + start, sz, arr[count].sha1);
    ++count;
  }

  *out = arr;
  *out_n = count;
  return OSREP_FRAG_OK;
}

void osrep_frag_free(osrep_frag *p) { free(p); }
