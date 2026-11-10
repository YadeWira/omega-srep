/* libosrep as a 7-Zip codec plugin: put osrep.so (osrep.dll) in the Codecs
   folder next to 7-Zip, and the method OSREP is there:

     7z a -m0=OSREP -m1=LZMA2 files.7z files/     (7-Zip-zstd: -m1=zstd)

   OSREP is a filter in 7-Zip's sense of a first coder: it takes the solid
   block as one stream, writes the .osr stream, and the next coder (LZMA2,
   zstd) compresses that. Extracting reverses it; the archive needs this
   plugin to be extracted.

   7-Zip's interfaces are C++ classes with only virtual methods, which is a
   table of function pointers first in the object: plain C builds them. On
   Windows x86 they are __stdcall; elsewhere the default convention. The
   exported functions are osrep_lib.pas's, which call the osrep7z_* ones
   here. The method ID, 03 7F 03, is in the slot 7-Zip's DOC/Methods.txt
   leaves for an experimental method, until 7-Zip gives OSREP an ID of its
   own. */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && !defined(_WIN64)
#define COMCALL __stdcall
#define OSREP_CALL __cdecl
#else
#define COMCALL
#define OSREP_CALL
#endif

typedef int32_t HRESULT;
#define S_OK ((HRESULT)0)
#define S_FALSE ((HRESULT)1)
#define E_NOTIMPL ((HRESULT)0x80004001u)
#define E_NOINTERFACE ((HRESULT)0x80004002u)
#define E_FAIL ((HRESULT)0x80004005u)
#define E_OUTOFMEMORY ((HRESULT)0x8007000Eu)
#define E_INVALIDARG ((HRESULT)0x80070057u)
#define CLASS_E_CLASSNOTAVAILABLE ((HRESULT)0x80040111u)

typedef struct { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; } guid_t;

enum { VT_EMPTY = 0, VT_BOOL = 11, VT_UI4 = 19, VT_UI8 = 21, VT_BSTR = 8 };
typedef struct {
  uint16_t vt, r1, r2, r3;
  union { uint64_t u64; uint32_t u32; int16_t b; void *p; } v;
} propvariant_t;

/* what osrep_lib.pas gives: a BSTR the way this platform's 7-Zip frees it,
   memory for the buffers, and a thread count when 7-Zip says nothing */
typedef struct {
  void *(*bstr)(const void *bytes, uint32_t len);
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  int threads;
} host7z_t;
static host7z_t H7;
void osrep7z_host(const host7z_t *h) { H7 = *h; }

/* the library's C ABI, in the same shared object */
int OSREP_CALL osrep_compress(const void *in, size_t in_size, void **out,
                              size_t *out_size, const void *options);
int OSREP_CALL osrep_decompress(const void *in, size_t in_size, void **out,
                                size_t *out_size, const void *options);
void OSREP_CALL osrep_free(void *p);

/* ---------- the streams 7-Zip hands in ---------- */

typedef struct instream instream_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(instream_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(instream_t *);
  uint32_t (COMCALL *Release)(instream_t *);
  HRESULT (COMCALL *Read)(instream_t *, void *data, uint32_t size, uint32_t *processed);
} instream_vt;
struct instream { const instream_vt *vt; };

typedef struct outstream outstream_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(outstream_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(outstream_t *);
  uint32_t (COMCALL *Release)(outstream_t *);
  HRESULT (COMCALL *Write)(outstream_t *, const void *data, uint32_t size, uint32_t *processed);
} outstream_vt;
struct outstream { const outstream_vt *vt; };

typedef struct progress progress_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(progress_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(progress_t *);
  uint32_t (COMCALL *Release)(progress_t *);
  HRESULT (COMCALL *SetRatioInfo)(progress_t *, const uint64_t *in_size, const uint64_t *out_size);
} progress_vt;
struct progress { const progress_vt *vt; };

typedef struct {
  progress_t *progress;
  uint64_t in_pos, out_pos, next_report;
  HRESULT err;
} run_t;

enum { REPORT_EVERY = 1 << 20 };

static void report(run_t *r) {
  if (!r->progress || r->in_pos + r->out_pos < r->next_report) return;
  r->next_report = r->in_pos + r->out_pos + REPORT_EVERY;
  HRESULT h = r->progress->vt->SetRatioInfo(r->progress, &r->in_pos, &r->out_pos);
  if (h != S_OK && !r->err) r->err = h;
}

/* ---------- input and output buffers ---------- */

typedef struct { uint8_t *p; size_t n, cap; } buf_t;

static int reserve(buf_t *b, size_t need) {
  size_t cap;
  uint8_t *p;
  size_t i;
  if (need <= b->cap) return 1;
  cap = b->cap ? b->cap : (size_t)1 << 16;
  while (cap < need) {
    if (cap > ((size_t)-1) / 2) { cap = need; break; }
    cap *= 2;
  }
  p = (uint8_t *)H7.alloc(cap);
  if (!p) return 0;
  for (i = 0; i < b->n; i++) p[i] = b->p[i];
  if (b->p) H7.release(b->p);
  b->p = p;
  b->cap = cap;
  return 1;
}

static HRESULT read_all(instream_t *in, buf_t *b, run_t *r) {
  for (;;) {
    uint32_t want, got = 0;
    HRESULT h;
    if (!reserve(b, b->n + ((size_t)1 << 16))) return E_OUTOFMEMORY;
    want = (uint32_t)(b->cap - b->n);
    if (want > 0x40000000u) want = 0x40000000u;
    h = in->vt->Read(in, b->p + b->n, want, &got);
    if (h != S_OK) { r->err = h; return h; }
    if (got == 0) return S_OK;
    b->n += got;
    r->in_pos += got;
    report(r);
  }
}

static HRESULT write_all(outstream_t *out, const void *data, size_t size, run_t *r) {
  const uint8_t *p = (const uint8_t *)data;
  while (size) {
    uint32_t n = size > 0x40000000u ? 0x40000000u : (uint32_t)size, done = 0;
    HRESULT h = out->vt->Write(out, p, n, &done);
    if (h != S_OK) { r->err = h; return h; }
    if (!done) { r->err = E_FAIL; return E_FAIL; }
    p += done;
    size -= done;
    r->out_pos += done;
    report(r);
  }
  return S_OK;
}

/* ---------- the coder ---------- */

typedef struct coder coder_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(coder_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(coder_t *);
  uint32_t (COMCALL *Release)(coder_t *);
  HRESULT (COMCALL *Code)(coder_t *, instream_t *, outstream_t *, const uint64_t *in_size,
                          const uint64_t *out_size, progress_t *);
} coder_vt;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(void *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(void *);
  uint32_t (COMCALL *Release)(void *);
  HRESULT (COMCALL *SetNumberOfThreads)(void *, uint32_t threads);
} coder_mt_vt;
struct coder {
  const coder_vt *vt;
  const coder_mt_vt *mt_vt;
  int32_t refs;
  int encode;
  int threads;
};

static coder_t *from_mt(void *p) { return (coder_t *)((char *)p - offsetof(coder_t, mt_vt)); }

static HRESULT COMCALL c_query(coder_t *c, const guid_t *iid, void **out);
static uint32_t COMCALL c_addref(coder_t *c) { return (uint32_t)++c->refs; }
static uint32_t COMCALL c_release(coder_t *c) {
  int32_t n = --c->refs;
  if (!n) H7.release(c);
  return (uint32_t)n;
}

static HRESULT map_osrep(int rc) {
  switch (rc) {
    case 0: return S_OK;
    case 2: return E_OUTOFMEMORY;
    case 1: return S_FALSE;   /* damaged data: 7-Zip's "Data Error" */
    case 4: return E_INVALIDARG;
    case 5: return E_NOTIMPL; /* a newer OSREP: "Unsupported Method" */
    case 7: return E_NOTIMPL;
    default: return E_FAIL;
  }
}

static HRESULT COMCALL c_code(coder_t *c, instream_t *in, outstream_t *out,
                              const uint64_t *in_size, const uint64_t *out_size,
                              progress_t *progress) {
  run_t r = {progress, 0, 0, REPORT_EVERY, S_OK};
  buf_t input = {0, 0, 0};
  void *result = 0;
  size_t result_size = 0;
  HRESULT h;
  (void)in_size;
  (void)out_size;
  (void)c->threads;
  if (!in || !out) return E_INVALIDARG;
  h = read_all(in, &input, &r);
  if (h == S_OK) {
    int rc = c->encode ? osrep_compress(input.p, input.n, &result, &result_size, 0)
                       : osrep_decompress(input.p, input.n, &result, &result_size, 0);
    if (rc != 0) h = map_osrep(rc);
    else {
      h = write_all(out, result, result_size, &r);
      osrep_free(result);
    }
  }
  if (input.p) H7.release(input.p);
  return h;
}

static HRESULT COMCALL m_query(void *p, const guid_t *iid, void **out) { return c_query(from_mt(p), iid, out); }
static uint32_t COMCALL m_addref(void *p) { return c_addref(from_mt(p)); }
static uint32_t COMCALL m_release(void *p) { return c_release(from_mt(p)); }
static HRESULT COMCALL m_threads(void *p, uint32_t threads) {
  coder_t *c = from_mt(p);
  c->threads = threads < 1 ? 1 : threads > 64 ? 64 : (int)threads;
  return S_OK;
}

static const coder_vt CODER_VT = {c_query, c_addref, c_release, c_code};
static const coder_mt_vt CODER_MT_VT = {m_query, m_addref, m_release, m_threads};

/* {23170F69-40C1-278A-0000-00gg00ss0000}: 7-Zip's interfaces, group g and
   sub-id s; the coder classes: Data3 2790 (decoder) or 2791 (encoder) and
   the method's ID in Data4, little-endian */
static int is_7zip_iid(const guid_t *g, uint8_t group, uint8_t sub) {
  return g->d1 == 0x23170F69u && g->d2 == 0x40C1 && g->d3 == 0x278A && g->d4[0] == 0 && g->d4[1] == 0
         && g->d4[2] == 0 && g->d4[3] == group && g->d4[4] == 0 && g->d4[5] == sub && g->d4[6] == 0
         && g->d4[7] == 0;
}
static int is_iunknown(const guid_t *g) {
  static const uint8_t d4[8] = {0xC0, 0, 0, 0, 0, 0, 0, 0x46};
  int k;
  if (g->d1 || g->d2 || g->d3) return 0;
  for (k = 0; k < 8; k++) if (g->d4[k] != d4[k]) return 0;
  return 1;
}
enum { G_CODER = 4, S_CODER = 0x05, S_CODER_MT = 0x25 };

static HRESULT COMCALL c_query(coder_t *c, const guid_t *iid, void **out) {
  if (!out || !iid) return E_INVALIDARG;
  *out = 0;
  if (is_iunknown(iid) || is_7zip_iid(iid, G_CODER, S_CODER)) *out = c;
  else if (is_7zip_iid(iid, G_CODER, S_CODER_MT)) *out = &c->mt_vt;
  else return E_NOINTERFACE;
  c_addref(c);
  return S_OK;
}

/* ---------- what the plugin exports (through osrep_lib.pas) ---------- */

typedef struct { const char *name; uint64_t id; } method_t;
static const method_t METHODS[] = {{"OSREP", 0x037F03}};
enum { NUM_METHODS = sizeof METHODS / sizeof METHODS[0] };

static HRESULT new_coder(uint32_t index, int encode, const guid_t *iid, void **out) {
  coder_t *c;
  HRESULT r;
  if (!out) return E_INVALIDARG;
  *out = 0;
  if (index >= NUM_METHODS) return CLASS_E_CLASSNOTAVAILABLE;
  c = (coder_t *)H7.alloc(sizeof *c);
  if (!c) return E_OUTOFMEMORY;
  c->vt = &CODER_VT;
  c->mt_vt = &CODER_MT_VT;
  c->refs = 1;
  c->encode = encode;
  c->threads = H7.threads > 0 ? H7.threads : 1;
  r = c_query(c, iid, out);
  c_release(c);
  return r;
}

HRESULT osrep7z_GetNumberOfMethods(uint32_t *n) {
  if (!n) return E_INVALIDARG;
  *n = NUM_METHODS;
  return S_OK;
}

static void set_bstr(propvariant_t *v, const void *bytes, uint32_t len) {
  void *b = H7.bstr(bytes, len);
  if (b) { v->vt = VT_BSTR; v->v.p = b; }
}
static void class_id(uint32_t index, uint16_t data3, guid_t *g) {
  int k;
  g->d1 = 0x23170F69u;
  g->d2 = 0x40C1;
  g->d3 = data3;
  for (k = 0; k < 8; k++) g->d4[k] = (uint8_t)(METHODS[index].id >> (8 * k));
}

enum { P_ID, P_NAME, P_DECODER, P_ENCODER, P_PACK_STREAMS, P_UNPACK_STREAMS, P_DESCRIPTION,
       P_DECODER_ASSIGNED, P_ENCODER_ASSIGNED, P_DIGEST_SIZE, P_IS_FILTER };

HRESULT osrep7z_GetMethodProperty(uint32_t index, uint32_t prop, propvariant_t *v) {
  guid_t g;
  const method_t *m;
  if (!v) return E_INVALIDARG;
  if (index >= NUM_METHODS) return E_INVALIDARG;
  v->vt = VT_EMPTY;
  m = &METHODS[index];
  switch (prop) {
    case P_ID: v->vt = VT_UI8; v->v.u64 = m->id; break;
    case P_NAME: {
      /* a BSTR holds wchar_t: 2 bytes on Windows, 4 on Linux and macOS */
      __WCHAR_TYPE__ w[8];
      unsigned n = 0;
      while (m->name[n] && n < 7) { w[n] = (__WCHAR_TYPE__)(uint8_t)m->name[n]; n++; }
      w[n] = 0;
      set_bstr(v, w, (uint32_t)(sizeof w[0] * n));
      break;
    }
    case P_DECODER: class_id(index, 0x2790, &g); set_bstr(v, &g, sizeof g); break;
    case P_ENCODER: class_id(index, 0x2791, &g); set_bstr(v, &g, sizeof g); break;
    case P_DECODER_ASSIGNED: case P_ENCODER_ASSIGNED: v->vt = VT_BOOL; v->v.b = -1; break;
    case P_IS_FILTER: v->vt = VT_BOOL; v->v.b = 0; break;
    default: break;
  }
  return S_OK;
}

HRESULT osrep7z_CreateDecoder(uint32_t index, const guid_t *iid, void **out) {
  return new_coder(index, 0, iid, out);
}
HRESULT osrep7z_CreateEncoder(uint32_t index, const guid_t *iid, void **out) {
  return new_coder(index, 1, iid, out);
}
HRESULT osrep7z_CreateObject(const guid_t *clsid, const guid_t *iid, void **out) {
  uint32_t i;
  if (out) *out = 0;
  if (!clsid) return E_INVALIDARG;
  for (i = 0; i < NUM_METHODS; i++) {
    guid_t d, e;
    const uint8_t *a = (const uint8_t *)clsid;
    const uint8_t *bd;
    const uint8_t *be;
    int isd = 1, ise = 1;
    unsigned k;
    class_id(i, 0x2790, &d);
    class_id(i, 0x2791, &e);
    bd = (const uint8_t *)&d;
    be = (const uint8_t *)&e;
    for (k = 0; k < sizeof d; k++) {
      if (a[k] != bd[k]) isd = 0;
      if (a[k] != be[k]) ise = 0;
    }
    if (isd || ise) return new_coder(i, ise, iid, out);
  }
  return CLASS_E_CLASSNOTAVAILABLE;
}

enum { M_INTERFACE_TYPE = 0, M_VERSION = 1 };
HRESULT osrep7z_GetModuleProp(uint32_t prop, propvariant_t *v) {
  if (!v) return E_INVALIDARG;
  v->vt = VT_EMPTY;
  if (prop == M_INTERFACE_TYPE) { v->vt = VT_UI4; v->v.u32 = 0; }
  else if (prop == M_VERSION) { v->vt = VT_UI4; v->v.u32 = 7; } /* 0.07 = OSREP 0.0.7 */
  return S_OK;
}
