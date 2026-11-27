/* test_run_loop <libosrep> <input> <workdir> <rounds> [<expected dir>]

   osrep_run() called many times in one process, in the shape of ytool's
   lib_loop.c for libsrep.  Each round: every method file -> file, through
   pipes and with the -1 (process) handles; decode by file and by pipes; a
   damaged archive; a bad option; a missing input; and two calls at the
   same time on two threads.  Checks: every round trip exact, the archives
   equal to the CLI's (<expected dir>/<n>.osr, written by tests/lib_run.sh),
   the exit codes, the messages on err_handle, no output left after a
   failure, no descriptor or thread left, and the resident set stable.  It
   is built with -fsanitize=address too (tests/lib_run.sh), against a
   library whose Pascal heap is the C one (cmem), so a leak shows. */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

typedef int (*run_t)(int, char **, intptr_t, intptr_t, intptr_t);
typedef const char *(*ver_t)(void);
static run_t osrep_run;
static int fails = 0, passes = 0;
static const char *expected_dir = NULL;
#define CHECK(c, ...)                                                        \
  do {                                                                       \
    if (c)                                                                   \
      passes++;                                                              \
    else {                                                                   \
      fails++;                                                               \
      printf("FAIL: ");                                                      \
      printf(__VA_ARGS__);                                                   \
      printf("\n");                                                          \
      fflush(stdout);                                                        \
    }                                                                        \
  } while (0)

static int count_fds(void) {
  int n = 0;
  for (int fd = 0; fd < 4096; fd++)
    if (fcntl(fd, F_GETFD) != -1) n++;
  return n;
}
static int count_threads(void) {
  DIR *d = opendir("/proc/self/task");
  int n = 0;
  struct dirent *e;
  if (!d) return -1;
  while ((e = readdir(d)) != NULL)
    if (e->d_name[0] != '.') n++;
  closedir(d);
  return n;
}
static long rss_kb(void) {
  FILE *f = fopen("/proc/self/status", "r");
  char line[256];
  long v = -1;
  if (f) {
    while (fgets(line, sizeof line, f))
      if (!strncmp(line, "VmRSS:", 6)) v = atol(line + 6);
    fclose(f);
  }
  return v;
}
static int files_equal(const char *a, const char *b) {
  FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
  int ok = fa && fb;
  while (ok) {
    int ca = fgetc(fa), cb = fgetc(fb);
    if (ca != cb) ok = 0;
    if (ca == EOF || cb == EOF) break;
  }
  if (fa) fclose(fa);
  if (fb) fclose(fb);
  return ok;
}
/* argv from "osrep" + a NULL-terminated list */
static int run_h(const char **args, intptr_t in, intptr_t out, intptr_t err) {
  char *argv[32] = {(char *)"osrep"};
  int n = 1;
  for (; args[n - 1]; n++) argv[n] = (char *)args[n - 1];
  argv[n] = NULL;
  return osrep_run(n, argv, in, out, err);
}
/* err_handle is a pipe read into msg (so the messages are checked) */
struct sink { int fd; char buf[4096]; size_t len; };
static void *drain(void *p) {
  struct sink *s = p;
  ssize_t n;
  char tmp[1024];
  while ((n = read(s->fd, tmp, sizeof tmp)) > 0)
    if (s->len + n < sizeof s->buf) { memcpy(s->buf + s->len, tmp, n); s->len += n; }
  s->buf[s->len] = 0;
  close(s->fd);
  return NULL;
}
static int run_msg(const char **args, char *msg, size_t cap) {
  int pe[2];
  struct sink s = {0};
  pthread_t t;
  if (pipe(pe)) return -1;
  s.fd = pe[0];
  pthread_create(&t, NULL, drain, &s);
  int rc = run_h(args, -1, -1, pe[1]); /* closes pe[1] */
  pthread_join(t, NULL);
  snprintf(msg, cap, "%s", s.buf);
  return rc;
}
struct pump { int fd; const char *path; int write; };
static void *pump(void *p) {
  struct pump *q = p;
  char buf[65536];
  ssize_t n;
  if (q->write) {
    FILE *in = fopen(q->path, "rb");
    size_t k;
    while ((k = fread(buf, 1, sizeof buf, in)) > 0)
      if (write(q->fd, buf, k) != (ssize_t)k) break;
    fclose(in);
  } else {
    FILE *out = fopen(q->path, "wb");
    while ((n = read(q->fd, buf, sizeof buf)) > 0) fwrite(buf, 1, n, out);
    fclose(out);
  }
  close(q->fd);
  return NULL;
}
/* osrep <args> - - through pipes: src in, dst out */
static int run_pipes(const char **args, const char *src, const char *dst) {
  int pin[2], pout[2];
  if (pipe(pin) || pipe(pout)) return -1;
  struct pump a = {pin[1], src, 1}, b = {pout[0], dst, 0};
  pthread_t ta, tb;
  pthread_create(&ta, NULL, pump, &a);
  pthread_create(&tb, NULL, pump, &b);
  int rc = run_h(args, pin[0], pout[1], -1);
  pthread_join(ta, NULL);
  pthread_join(tb, NULL);
  return rc;
}

/* the methods; tests/lib_run.sh writes <n>.osr with the CLI for each */
static const char *methods[] = {
    "-m6", "-m6 -t4", "-m6 -l64 --align=1 -t2", "-m6 -hash- -t1", "-m3",
    "-m5 -b1mb", "-m1", "-dup", "-m0 --seed=7"};
#define NM ((int)(sizeof methods / sizeof *methods))

static int split(const char *m, char *store, const char **a) {
  int k = 0;
  strcpy(store, m);
  for (char *t = strtok(store, " "); t; t = strtok(NULL, " ")) a[k++] = t;
  return k;
}

struct par { const char *in; int idx; int rc; int ok; };
static void *par_job(void *p) {
  struct par *q = p;
  char a1[32], a2[32], b1[32], st[128];
  const char *a[16];
  snprintf(a1, sizeof a1, "par%d.osr", q->idx);
  snprintf(a2, sizeof a2, "par%d.bin", q->idx);
  int k = split(q->idx ? "-m6 -t3" : "-m3", st, a);
  a[k++] = q->in; a[k++] = a1; a[k] = NULL;
  q->rc = run_h(a, -1, -1, -1);
  const char *d[] = {"-d", a1, a2, NULL};
  q->rc |= run_h(d, -1, -1, -1);
  q->ok = q->rc == 0 && files_equal(q->in, a2);
  snprintf(b1, sizeof b1, "%s", a1); unlink(b1); unlink(a2);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: test_run_loop <lib> <input> <workdir> <rounds> [<expected dir>]\n");
    return 2;
  }
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
  osrep_run = (run_t)dlsym(h, "osrep_run");
  ver_t ver = (ver_t)dlsym(h, "osrep_version");
  if (!osrep_run || !ver) { printf("missing osrep_run / osrep_version\n"); return 2; }
  printf("%s\n", ver());
  const char *in = argv[2];
  int rounds = atoi(argv[4]);
  if (argc > 5) expected_dir = argv[5];
  if (chdir(argv[3])) return 2;
  int fd0 = -1, th0 = -1;
  long rss1 = 0, rss_last = 0;
  char msg[4096], st[256], exp[1024];
  const char *a[24];
  for (int r = 0; r < rounds; r++) {
    for (int m = 0; m < NM; m++) {
      int k = split(methods[m], st, a);
      a[k] = in; a[k + 1] = "a.osr"; a[k + 2] = NULL;
      int rc = run_h(a, -1, -1, -1);
      CHECK(rc == 0, "round %d %s: compress rc=%d", r, methods[m], rc);
      if (expected_dir && r == 0) {
        snprintf(exp, sizeof exp, "%s/%d.osr", expected_dir, m);
        CHECK(files_equal("a.osr", exp), "%s: not the CLI's archive", methods[m]);
      }
      /* compress through pipes: the same bytes */
      a[k] = "-"; a[k + 1] = "-"; a[k + 2] = NULL;
      rc = run_pipes(a, in, "p.osr");
      CHECK(rc == 0 && files_equal("a.osr", "p.osr"), "round %d %s: compress pipes rc=%d", r, methods[m], rc);
      const char *d[] = {"-d", "a.osr", "o.bin", NULL};
      rc = run_h(d, -1, -1, -1);
      CHECK(rc == 0 && files_equal(in, "o.bin"), "round %d %s: decode file rc=%d", r, methods[m], rc);
      const char *dp[] = {"-d", "-", "-", NULL};
      rc = run_pipes(dp, "a.osr", "q.bin");
      CHECK(rc == 0 && files_equal(in, "q.bin"), "round %d %s: decode pipes rc=%d", r, methods[m], rc);
      /* damaged: a byte in the middle */
      FILE *f = fopen("a.osr", "r+b");
      fseek(f, 0, SEEK_END);
      long sz = ftell(f);
      fseek(f, sz / 2, SEEK_SET);
      int c = fgetc(f);
      fseek(f, sz / 2, SEEK_SET);
      fputc(c ^ 0x5a, f);
      fclose(f);
      const char *dd[] = {"-d", "a.osr", "x.bin", NULL};
      rc = run_msg(dd, msg, sizeof msg);
      CHECK(rc == 4 && access("x.bin", F_OK) != 0 && strncmp(msg, "OSREP: ", 7) == 0,
            "round %d %s: damaged rc=%d, output %s, msg \"%s\"", r, methods[m], rc,
            access("x.bin", F_OK) == 0 ? "left" : "removed", msg);
      unlink("x.bin");
      unlink("o.bin"); unlink("q.bin"); unlink("p.osr");
    }
    const char *bad[] = {"-zzz", in, "b.osr", NULL};
    int rc = run_msg(bad, msg, sizeof msg);
    CHECK(rc == 2 && strstr(msg, "unknown option: -zzz") && access("b.osr", F_OK) != 0,
          "round %d: bad option rc=%d msg \"%s\"", r, rc, msg);
    const char *missing[] = {"does-not-exist", "b.osr", NULL};
    rc = run_msg(missing, msg, sizeof msg);
    CHECK(rc == 3 && access("b.osr", F_OK) != 0 && msg[0], "round %d: missing input rc=%d, b.osr %s", r, rc,
          access("b.osr", F_OK) == 0 ? "left" : "absent");
    unlink("b.osr");
    /* the version on out_handle */
    {
      int po[2]; struct sink s = {0}; pthread_t t;
      if (pipe(po) == 0) {
        s.fd = po[0];
        pthread_create(&t, NULL, drain, &s);
        const char *v[] = {"--version", NULL};
        rc = run_h(v, -1, po[1], -1);
        pthread_join(t, NULL);
        CHECK(rc == 0 && strncmp(s.buf, ver(), strlen(ver())) == 0, "round %d: --version \"%s\"", r, s.buf);
      }
    }
    /* two at once */
    {
      struct par p[2] = {{in, 0, 0, 0}, {in, 1, 0, 0}};
      pthread_t t[2];
      for (int i = 0; i < 2; i++) pthread_create(&t[i], NULL, par_job, &p[i]);
      for (int i = 0; i < 2; i++) pthread_join(t[i], NULL);
      CHECK(p[0].ok && p[1].ok, "round %d: parallel calls %d/%d", r, p[0].rc, p[1].rc);
    }
    unlink("a.osr");
    int fds = count_fds(), th = count_threads();
    if (r == 0) { fd0 = fds; th0 = th; rss1 = rss_kb(); }
    CHECK(fds == fd0, "round %d: %d descriptors open, %d after round 0", r, fds, fd0);
    CHECK(th == th0, "round %d: %d threads, %d after round 0", r, th, th0);
    rss_last = rss_kb();
    printf("round %d: fds=%d threads=%d rss=%ld KB\n", r, fds, th, rss_last);
    fflush(stdout);
  }
  if (rounds > 1)
    CHECK(rss_last - rss1 < 64 * 1024, "RSS grew %ld KB over %d rounds", rss_last - rss1, rounds);
  printf("%d checks, %d failures\n", passes + fails, fails);
  return fails ? 1 : 0;
}
