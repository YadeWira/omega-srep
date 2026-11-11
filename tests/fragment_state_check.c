/* The incremental osrep_frag_state_* path (used by zpaq-std's add loop) must
   produce exactly the same fragments as osrep_fragment_buffer(), for both
   the zpaq exact mode and the OSREP mode. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "osrep_fragment.h"

#define N (256 * 1024)

static uint8_t buf[N];

static int check_mode(const osrep_frag_params *p, const char *label) {
  osrep_frag *arr = NULL;
  size_t n = 0, got = 0, start = 0, i;
  osrep_frag_state st;
  if (osrep_fragment_buffer(buf, N, p, &arr, &n) != OSREP_FRAG_OK) {
    fprintf(stderr, "%s: buffer failed\n", label);
    return 1;
  }
  osrep_frag_state_reset(&st, p);
  for (i = 0; i < N; i++) {
    int cut = osrep_frag_state_push(&st, buf[i]);
    if (cut || st.size >= p->max) {
      uint8_t sha1[20];
      if (got >= n) {
        fprintf(stderr, "%s: too many state fragments\n", label);
        return 1;
      }
      osrep_sha1(buf + start, st.size, sha1);
      if (arr[got].off != start || arr[got].size != st.size ||
          arr[got].hits != st.hits ||
          memcmp(arr[got].sha1, sha1, 20) != 0 ||
          memcmp(arr[got].o1, st.o1, 256) != 0) {
        fprintf(stderr, "%s: state mismatch at %zu\n", label, got);
        return 1;
      }
      ++got;
      start = i + 1;
      osrep_frag_state_reset(&st, p);
    }
  }
  if (st.size != 0) {
    uint8_t sha1[20];
    if (got >= n) {
      fprintf(stderr, "%s: too many state fragments\n", label);
      return 1;
    }
    osrep_sha1(buf + start, st.size, sha1);
    if (arr[got].off != start || arr[got].size != st.size ||
        arr[got].hits != st.hits ||
        memcmp(arr[got].sha1, sha1, 20) != 0 ||
        memcmp(arr[got].o1, st.o1, 256) != 0) {
      fprintf(stderr, "%s: final state mismatch\n", label);
      return 1;
    }
    ++got;
  }
  if (got != n) {
    fprintf(stderr, "%s: %zu state vs %zu buffer fragments\n", label, got, n);
    return 1;
  }
  osrep_frag_free(arr);
  return 0;
}

int main(void) {
  static const unsigned zpaq_frags[] = {0, 3, 6, 9};
  static const unsigned osrep_frags[] = {3, 6};
  osrep_frag_params p;
  uint32_t x = 123456789u;
  size_t i, f;

  for (i = 0; i < N; i++) {
    x = x * 1664525u + 1013904223u;
    buf[i] = (uint8_t)(x >> 24);
  }
  for (f = 0; f < sizeof(zpaq_frags) / sizeof(zpaq_frags[0]); f++) {
    if (osrep_frag_params_zpaq(&p, zpaq_frags[f], 0) != OSREP_FRAG_OK)
      return 2;
    if (check_mode(&p, "zpaq")) return 1;
  }
  for (f = 0; f < sizeof(osrep_frags) / sizeof(osrep_frags[0]); f++) {
    if (osrep_frag_params_osrep(&p, osrep_frags[f], 0) != OSREP_FRAG_OK)
      return 2;
    if (check_mode(&p, "osrep")) return 1;
  }
  if (osrep_frag_params_osrep(&p, 6, 0) != OSREP_FRAG_OK || p.avg != 8192)
    return 1;
  if (osrep_frag_params_osrep(&p, 3, 0) != OSREP_FRAG_OK || p.avg != 1024)
    return 1;
  if (osrep_frag_params_osrep(&p, 9, 0) != OSREP_FRAG_OK || p.avg != 65536)
    return 1;
  printf("fragmenter: incremental state matches the buffer API (zpaq and OSREP)\n");
  return 0;
}
