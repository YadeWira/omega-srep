/* test_run_win <osrep.dll> <input> <rounds>: osrep_run() on Windows, many
   times in one process, with HANDLEs.  Each round: -m6 (-t1 and -t4), -m3
   and -dup file -> file and through anonymous pipes; decode by file and by
   pipes; a damaged archive (exit 4, no output left); a bad option (exit 2,
   the message on the err pipe); -1 handles.  The handle and thread counts
   must stay where they were after the first round.  Run in the input's
   directory; it writes and deletes a.osr, p.osr, o.bin, q.bin, x.bin.
   Built with mingw (x64 and x86). */
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int(__cdecl *run_t)(int, char **, intptr_t, intptr_t, intptr_t);
typedef const char *(__cdecl *ver_t)(void);
static run_t osrep_run;
static int fails = 0, passes = 0;
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

static int count_threads(void) {
  HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  THREADENTRY32 e;
  int n = 0;
  DWORD me = GetCurrentProcessId();
  e.dwSize = sizeof e;
  if (Thread32First(s, &e))
    do
      if (e.th32OwnerProcessID == me) n++;
    while (Thread32Next(s, &e));
  CloseHandle(s);
  return n;
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
static int exists(const char *p) { return GetFileAttributesA(p) != INVALID_FILE_ATTRIBUTES; }
static int run_h(const char **args, intptr_t in, intptr_t out, intptr_t err) {
  char *argv[32] = {(char *)"osrep"};
  int n = 1;
  for (; args[n - 1]; n++) argv[n] = (char *)args[n - 1];
  argv[n] = NULL;
  return osrep_run(n, argv, in, out, err);
}
struct pump { HANDLE h; const char *path; int write; char buf[4096]; DWORD len; };
static DWORD WINAPI pump(LPVOID p) {
  struct pump *q = p;
  char buf[65536];
  DWORD n, w;
  if (q->write) {
    FILE *in = fopen(q->path, "rb");
    size_t k;
    while ((k = fread(buf, 1, sizeof buf, in)) > 0)
      if (!WriteFile(q->h, buf, (DWORD)k, &w, NULL) || w != k) break;
    fclose(in);
  } else if (q->path) {
    FILE *out = fopen(q->path, "wb");
    while (ReadFile(q->h, buf, sizeof buf, &n, NULL) && n > 0) fwrite(buf, 1, n, out);
    fclose(out);
  } else {
    while (ReadFile(q->h, buf, sizeof buf, &n, NULL) && n > 0)
      if (q->len + n < sizeof q->buf) { memcpy(q->buf + q->len, buf, n); q->len += n; }
    q->buf[q->len] = 0;
  }
  CloseHandle(q->h);
  return 0;
}
static int run_pipes(const char **args, const char *src, const char *dst) {
  HANDLE ir, iw, or_, ow;
  if (!CreatePipe(&ir, &iw, NULL, 0) || !CreatePipe(&or_, &ow, NULL, 0)) return -1;
  struct pump a = {iw, src, 1}, b = {or_, dst, 0};
  HANDLE ta = CreateThread(NULL, 0, pump, &a, 0, NULL), tb = CreateThread(NULL, 0, pump, &b, 0, NULL);
  int rc = run_h(args, (intptr_t)ir, (intptr_t)ow, -1);
  WaitForSingleObject(ta, INFINITE);
  WaitForSingleObject(tb, INFINITE);
  CloseHandle(ta);
  CloseHandle(tb);
  return rc;
}
static int run_msg(const char **args, char *msg, size_t cap) {
  HANDLE er, ew;
  if (!CreatePipe(&er, &ew, NULL, 0)) return -1;
  struct pump s = {er, NULL, 0};
  HANDLE t = CreateThread(NULL, 0, pump, &s, 0, NULL);
  int rc = run_h(args, -1, -1, (intptr_t)ew);
  WaitForSingleObject(t, INFINITE);
  CloseHandle(t);
  snprintf(msg, cap, "%s", s.buf);
  return rc;
}

static const char *methods[] = {"-m6 -t1", "-m6 -t4", "-m3", "-dup"};
#define NM 4

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: test_run_win <osrep.dll> <input> <rounds>\n"); return 2; }
  HMODULE h = LoadLibraryA(argv[1]);
  if (!h) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 2; }
  osrep_run = (run_t)GetProcAddress(h, "osrep_run");
  ver_t ver = (ver_t)GetProcAddress(h, "osrep_version");
  if (!osrep_run || !ver) { printf("missing osrep_run / osrep_version\n"); return 2; }
  printf("%s, %d-bit\n", ver(), (int)(8 * sizeof(void *)));
  const char *in = argv[2];
  int rounds = atoi(argv[3]);
  DWORD h0 = 0, hc;
  int th0 = 0;
  char msg[4096], st[128];
  for (int r = 0; r < rounds; r++) {
    for (int m = 0; m < NM; m++) {
      const char *a[16];
      int k = 0;
      strcpy(st, methods[m]);
      for (char *t = strtok(st, " "); t; t = strtok(NULL, " ")) a[k++] = t;
      a[k] = in; a[k + 1] = "a.osr"; a[k + 2] = NULL;
      int rc = run_h(a, -1, -1, -1);
      CHECK(rc == 0, "round %d %s: compress rc=%d", r, methods[m], rc);
      a[k] = "-"; a[k + 1] = "-"; a[k + 2] = NULL;
      rc = run_pipes(a, in, "p.osr");
      CHECK(rc == 0 && files_equal("a.osr", "p.osr"), "round %d %s: compress pipes rc=%d", r, methods[m], rc);
      const char *d[] = {"-d", "a.osr", "o.bin", NULL};
      rc = run_h(d, -1, -1, -1);
      CHECK(rc == 0 && files_equal(in, "o.bin"), "round %d %s: decode rc=%d", r, methods[m], rc);
      const char *dp[] = {"-d", "-", "-", NULL};
      rc = run_pipes(dp, "a.osr", "q.bin");
      CHECK(rc == 0 && files_equal(in, "q.bin"), "round %d %s: decode pipes rc=%d", r, methods[m], rc);
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
      CHECK(rc == 4 && !exists("x.bin") && !strncmp(msg, "OSREP: ", 7), "round %d %s: damaged rc=%d msg \"%s\"",
            r, methods[m], rc, msg);
      DeleteFileA("x.bin"); DeleteFileA("o.bin"); DeleteFileA("q.bin"); DeleteFileA("p.osr");
    }
    const char *bad[] = {"-zzz", in, "b.osr", NULL};
    int rc = run_msg(bad, msg, sizeof msg);
    CHECK(rc == 2 && strstr(msg, "unknown option: -zzz") && !exists("b.osr"), "round %d: bad option rc=%d \"%s\"", r,
          rc, msg);
    DeleteFileA("a.osr");
    GetProcessHandleCount(GetCurrentProcess(), &hc);
    int th = count_threads();
    if (r == 0) { h0 = hc; th0 = th; }
    CHECK(hc <= h0 + 2, "round %d: %lu handles, %lu after round 0", r, hc, h0);
    /* the loader's idle pool threads may leave; none may be added */
    CHECK(th <= th0, "round %d: %d threads, %d after round 0", r, th, th0);
    printf("round %d: handles=%lu threads=%d\n", r, hc, th);
    fflush(stdout);
  }
  printf("%d checks, %d failures\n", passes + fails, fails);
  return fails ? 1 : 0;
}
