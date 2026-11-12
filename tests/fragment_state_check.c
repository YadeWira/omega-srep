/* The incremental osrep_frag_state_* path (used by zpaq-std's add loop) must
   produce exactly the same fragments as osrep_fragment_buffer(), for the zpaq
   exact mode, the FNV mode and the gear mode (-osrep), and
   osrep_frag_state_scan() must cut exactly where pushing byte by byte does,
   whatever the block sizes. The gear cuts are pinned by a checksum, the same
   on every platform. */
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

/* Feed buf to osrep_frag_state_scan() in blocks of pseudo-random sizes and
   compare every fragment with the buffer API. */
static int check_scan(const osrep_frag_params *p, const char *label,
                      uint32_t seed) {
  osrep_frag *arr = NULL;
  size_t n = 0, got = 0, start = 0, pos = 0;
  osrep_frag_state st;
  if (osrep_fragment_buffer(buf, N, p, &arr, &n) != OSREP_FRAG_OK) return 1;
  osrep_frag_state_reset(&st, p);
  while (pos < N) {
    size_t blk, used;
    int cut;
    seed = seed * 1664525u + 1013904223u;
    blk = 1 + (seed >> 8) % 9000;
    if (blk > N - pos) blk = N - pos;
    while (blk > 0) {
      used = osrep_frag_state_scan(&st, buf + pos, blk, &cut);
      pos += used;
      blk -= used;
      if (cut) {
        if (got >= n || arr[got].off != start || arr[got].size != st.size ||
            arr[got].hits != st.hits ||
            memcmp(arr[got].o1, st.o1, 256) != 0) {
          fprintf(stderr, "%s: scan mismatch at fragment %zu\n", label, got);
          return 1;
        }
        ++got;
        start = pos;
        osrep_frag_state_reset(&st, p);
      }
    }
  }
  if (st.size != 0) {
    if (got >= n || arr[got].size != st.size || arr[got].hits != st.hits) {
      fprintf(stderr, "%s: scan final mismatch\n", label);
      return 1;
    }
    ++got;
  }
  osrep_frag_free(arr);
  if (got != n) {
    fprintf(stderr, "%s: scan %zu vs buffer %zu fragments\n", label, got, n);
    return 1;
  }
  return 0;
}

/* Random data with ustar headers (valid checksums) and zip local headers
   every few KiB, plus one central directory signature: what the -osrep
   format-aware cuts look for. */
static void put_octal(uint8_t *f, unsigned width, uint32_t v) {
  unsigned k;
  for (k = width - 1; k-- > 0;) {
    f[k] = (uint8_t)('0' + (v & 7u));
    v >>= 3;
  }
  f[width - 1] = 0;
}

static void make_format_buf(void) {
  uint32_t x = 987654321u;
  size_t i = 0, k;
  unsigned m = 0;
  for (k = 0; k < N; k++) {
    x = x * 1664525u + 1013904223u;
    buf[k] = (uint8_t)(x >> 24);
  }
  while (i + 4096 < N) {
    uint8_t *h = buf + i;
    x = x * 1664525u + 1013904223u;
    if (m % 3 != 2) { /* ustar header */
      uint32_t sum = 0;
      memset(h, 0, 512);
      h[0] = 'f';
      h[1] = (uint8_t)('a' + m % 26);
      put_octal(h + 100, 8, 0644);
      put_octal(h + 108, 8, 0);
      put_octal(h + 116, 8, 0);
      put_octal(h + 124, 12, (x >> 12) % 20000u);
      put_octal(h + 136, 12, 1700000000u);
      h[156] = '0';
      memcpy(h + 257, "ustar\0" "00", 8);
      memset(h + 148, ' ', 8);
      for (k = 0; k < 512; k++) sum += h[k];
      put_octal(h + 148, 7, sum);
      h[155] = ' ';
      i += 512;
    } else { /* zip local header: PK 3 4, version 20, deflate, name */
      static const uint8_t lh[30] = {'P', 'K', 3, 4, 20, 0, 0, 0, 8, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 9, 0, 0, 0};
      memcpy(h, lh, 30);
      memcpy(h + 30, "dir/a.txt", 9);
      i += 39;
    }
    i += 600 + (x >> 8) % 7000u;
    ++m;
  }
  memcpy(buf + N - 3000, "PK\1\2", 4);
}

/* FNV-1a over the fragment sizes: pins the gear cuts across platforms. */
static uint64_t cut_sum(const osrep_frag_params *p, size_t *count) {
  osrep_frag *arr = NULL;
  size_t n = 0, i;
  uint64_t h = UINT64_C(0xCBF29CE484222325);
  if (osrep_fragment_buffer(buf, N, p, &arr, &n) != OSREP_FRAG_OK) return 0;
  for (i = 0; i < n; i++) {
    h = (h ^ arr[i].size) * UINT64_C(0x100000001B3);
  }
  osrep_frag_free(arr);
  *count = n;
  return h;
}

int main(int argc, char **argv) {
  static const unsigned zpaq_frags[] = {0, 3, 6, 9};
  static const unsigned fnv_frags[] = {3, 6};
  static const unsigned gear_frags[] = {0, 2, 3};
  osrep_frag_params p;
  uint32_t x = 123456789u;
  size_t i, f, s, l;

  for (i = 0; i < N; i++) {
    x = x * 1664525u + 1013904223u;
    buf[i] = (uint8_t)(x >> 24);
  }
  /* runs of zeros and of a repeated byte: the gear table has G[0] = 0 */
  memset(buf + 40000, 0, 30000);
  memset(buf + 120000, 0x41, 5000);
  memset(buf + 200000, 0, 700);
  for (f = 0; f < sizeof(zpaq_frags) / sizeof(zpaq_frags[0]); f++) {
    if (osrep_frag_params_zpaq(&p, zpaq_frags[f], 0) != OSREP_FRAG_OK)
      return 2;
    if (check_mode(&p, "zpaq") || check_scan(&p, "zpaq", 7)) return 1;
  }
  for (f = 0; f < sizeof(fnv_frags) / sizeof(fnv_frags[0]); f++) {
    if (osrep_frag_params_fnv(&p, fnv_frags[f], 0) != OSREP_FRAG_OK)
      return 2;
    if (check_mode(&p, "fnv") || check_scan(&p, "fnv", 8)) return 1;
  }
  for (f = 0; f < sizeof(gear_frags) / sizeof(gear_frags[0]); f++)
    for (s = 1; s <= 4; s++)
      for (l = 0; l <= 3; l++) {
        if (osrep_frag_params_gear(&p, gear_frags[f], 0, (unsigned)s,
                                   (unsigned)l) != OSREP_FRAG_OK)
          return 2;
        if (check_mode(&p, "gear") ||
            check_scan(&p, "gear", (uint32_t)(f * 16 + s * 4 + l)))
          return 1;
      }
  for (f = 0; f < sizeof(gear_frags) / sizeof(gear_frags[0]); f++) {
    if (osrep_frag_params_osrep(&p, gear_frags[f], 0) != OSREP_FRAG_OK)
      return 2;
    if (check_mode(&p, "osrep") || check_scan(&p, "osrep", 99)) return 1;
  }
  /* -fragment N means an average of 2^N KiB, zpaq's max */
  if (osrep_frag_params_osrep(&p, 6, 0) != OSREP_FRAG_OK || p.avg != 65536 ||
      p.max != (8128u << 6) || p.mode != OSREP_FRAG_MODE_GEAR)
    return 1;
  if (osrep_frag_params_osrep(&p, 3, 0) != OSREP_FRAG_OK || p.avg != 8192)
    return 1;
  if (osrep_frag_params_osrep(&p, 0, 0) != OSREP_FRAG_OK || p.avg != 1024)
    return 1;
  if (osrep_frag_params_gear(&p, 3, 0, 0, 0) == OSREP_FRAG_OK ||
      osrep_frag_params_gear(&p, 3, 0, 1, 4) == OSREP_FRAG_OK ||
      osrep_frag_params_osrep(&p, 22, 0) == OSREP_FRAG_OK)
    return 1;
  /* the FNV mode keeps its old mapping */
  if (osrep_frag_params_fnv(&p, 6, 0) != OSREP_FRAG_OK || p.avg != 8192)
    return 1;
  if (osrep_frag_params_fnv(&p, 3, 0) != OSREP_FRAG_OK || p.avg != 1024)
    return 1;
  {
    static const struct {
      unsigned n, s, l;
      uint64_t sum;
      size_t count;
    } pin[] = {
#include "fragment_gear_pins.inc"
    };
    for (i = 0; i < sizeof(pin) / sizeof(pin[0]); i++) {
      size_t cnt = 0;
      uint64_t h;
      if (osrep_frag_params_gear(&p, pin[i].n, 0, pin[i].s, pin[i].l) !=
          OSREP_FRAG_OK)
        return 2;
      h = cut_sum(&p, &cnt);
      if (argc > 1 && strcmp(argv[1], "--print-pins") == 0) {
        printf("{%u, %u, %u, UINT64_C(0x%016llX), %zu},\n", pin[i].n,
               pin[i].s, pin[i].l, (unsigned long long)h, cnt);
        continue;
      }
      if (h != pin[i].sum || cnt != pin[i].count) {
        fprintf(stderr, "gear N=%u s=%u L=%u: cuts changed (%zu fragments)\n",
                pin[i].n, pin[i].s, pin[i].l, cnt);
        return 1;
      }
    }
  }
  /* the format-aware cuts that -osrep uses (osrep_frag_params_osrep sets
     OSREP_FRAG_F_FORMAT), on data that has the headers they look for */
  make_format_buf();
  {
    static const struct {
      unsigned n;
      uint64_t sum;
      size_t count;
    } fpin[] = {
#include "fragment_format_pins.inc"
    };
    for (i = 0; i < sizeof(fpin) / sizeof(fpin[0]); i++) {
      size_t cnt = 0, cnt0 = 0;
      uint64_t h;
      if (osrep_frag_params_osrep(&p, fpin[i].n, 0) != OSREP_FRAG_OK ||
          p.flags != OSREP_FRAG_F_FORMAT)
        return 2;
      if (check_mode(&p, "format") || check_scan(&p, "format", 77)) return 1;
      h = cut_sum(&p, &cnt);
      if (argc > 1 && strcmp(argv[1], "--print-pins") == 0) {
        printf("format {%u, UINT64_C(0x%016llX), %zu},\n", fpin[i].n,
               (unsigned long long)h, cnt);
        continue;
      }
      if (h != fpin[i].sum || cnt != fpin[i].count) {
        fprintf(stderr, "format N=%u: cuts changed (%zu fragments)\n",
                fpin[i].n, cnt);
        return 1;
      }
      /* the rules must have cut more than the plain gear CDC does */
      p.flags = 0;
      (void)cut_sum(&p, &cnt0);
      if (cnt <= cnt0) {
        fprintf(stderr, "format N=%u: no format cuts\n", fpin[i].n);
        return 1;
      }
    }
    if (argc > 1) return 0;
  }
  printf("fragmenter: incremental state and scan match the buffer API (zpaq, "
         "FNV, gear, -osrep format cuts); cuts pinned\n");
  return 0;
}
