/* The incremental osrep_frag_state_* path (used by zpaq-std's add loop) must
   produce exactly the same fragments as osrep_fragment_buffer(). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "osrep_fragment.h"

#define N (256 * 1024)

static uint8_t buf[N];

int main(void) {
  static const unsigned frags[] = {0, 3, 6, 9};
  uint32_t x = 123456789u;
  size_t i, f;
  for (i = 0; i < N; i++) {
    x = x * 1664525u + 1013904223u;
    buf[i] = (uint8_t)(x >> 24);
  }

  for (f = 0; f < sizeof(frags) / sizeof(frags[0]); f++) {
    osrep_frag_params p;
    osrep_frag *arr = NULL;
    size_t n = 0, got = 0, start = 0;
    osrep_frag_state st;
    if (osrep_frag_params_zpaq(&p, frags[f], 0) != OSREP_FRAG_OK) return 2;
    if (osrep_fragment_buffer(buf, N, &p, &arr, &n) != OSREP_FRAG_OK) return 2;
    osrep_frag_state_reset(&st, &p);
    for (i = 0; i < N; i++) {
      int cut = osrep_frag_state_push(&st, buf[i]);
      if (cut || st.size >= p.max) {
        uint8_t sha1[20];
        if (got >= n) {
          fprintf(stderr, "fragment %u: too many state fragments\n", frags[f]);
          return 1;
        }
        osrep_sha1(buf + start, st.size, sha1);
        if (arr[got].off != start || arr[got].size != st.size ||
            arr[got].hits != st.hits ||
            memcmp(arr[got].sha1, sha1, 20) != 0 ||
            memcmp(arr[got].o1, st.o1, 256) != 0) {
          fprintf(stderr, "fragment %u: state mismatch at %zu\n", frags[f],
                  got);
          return 1;
        }
        ++got;
        start = i + 1;
        osrep_frag_state_reset(&st, &p);
      }
    }
    if (st.size != 0) {
      uint8_t sha1[20];
      if (got >= n) {
        fprintf(stderr, "fragment %u: too many state fragments\n", frags[f]);
        return 1;
      }
      osrep_sha1(buf + start, st.size, sha1);
      if (arr[got].off != start || arr[got].size != st.size ||
          arr[got].hits != st.hits ||
          memcmp(arr[got].sha1, sha1, 20) != 0 ||
          memcmp(arr[got].o1, st.o1, 256) != 0) {
        fprintf(stderr, "fragment %u: final state mismatch\n", frags[f]);
        return 1;
      }
      ++got;
      osrep_frag_state_reset(&st, &p);
    }
    if (got != n) {
      fprintf(stderr, "fragment %u: %zu state vs %zu buffer fragments\n",
              frags[f], got, n);
      return 1;
    }
    osrep_frag_free(arr);
  }
  printf("fragmenter: incremental state matches the buffer API\n");
  return 0;
}
