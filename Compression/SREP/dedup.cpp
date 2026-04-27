// Omega SREP -dup mode: CDC + dedup pre-pass (encoder + decoder).
//
// C++ port of tests/dup_prototype.py. Self-contained: no SREP includes,
// stdint + stdlib only. Format and CDC parameters match the prototype
// exactly so .dupref blobs are interchangeable between C++ and Python
// tools (modulo 64-bit hash collisions, statistically irrelevant).
//
// File format (little-endian, x86_64 only):
//   header (24 bytes):
//     magic        uint32  "DUPR" = 0x52505544 LE
//     version      uint32  = 1
//     chunk_count  uint64
//     unique_count uint64
//   chunk table (chunk_count repetitions):
//     tag uint8  (0 = unique, 1 = ref)
//     tag==0: length uint32   (bytes of unique chunk in body)
//     tag==1: ref_index varint (LEB128 unsigned, < unique_count)
//   body:
//     concatenated unique chunk bytes in order of first appearance.
//
// F5.3 will #include this from srep.cpp to wire dedup into the main
// pipeline; for now the module is exercised by tests/dedup_test.cpp.

#ifndef OSREP_DEDUP_CPP
#define OSREP_DEDUP_CPP

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <vector>
#include <unordered_map>

// Portable 64-bit file seek. fseeko's portability is uneven on
// Windows MinGW (off_t may stay 32-bit despite -D_FILE_OFFSET_BITS=64),
// which silently truncates offsets > 2 GiB and breaks decode_streaming
// on multi-GB archives. _fseeki64 is supplied by the msvcrt runtime
// MinGW-w64 links against. POSIX uses fseeko + off_t.
static inline int osrep_fseek64(FILE* f, int64_t off, int whence) {
#ifdef _WIN32
    return _fseeki64(f, (long long)off, whence);
#else
    return fseeko(f, (off_t)off, whence);
#endif
}

namespace osrep_dedup {

static const uint32_t MAGIC       = 0x52505544u;  // "DUPR" LE
static const uint32_t VERSION     = 1u;
static const uint8_t  TAG_UNIQUE  = 0;
static const uint8_t  TAG_REF     = 1;
static const size_t   HEADER_SIZE = 24;

static const size_t DEFAULT_AVG = 4096;
static const size_t DEFAULT_MIN = 1024;
static const size_t DEFAULT_MAX = 16384;
// 0 means "single buffer" (no buffer-bounded CDC). Anything > 0 makes
// CDC reset its rolling-hash state at every buffer boundary, which is
// what FA's -dup actually does and what makes long-range duplicate
// blocks dedupe cleanly: identical buffers produce identical chunk
// sequences regardless of where they sit in the input stream.
static const size_t DEFAULT_BUF_SIZE = 0;

// FNV-style multiplier; matches PRIME in tests/dup_prototype.py.
static const uint64_t CDC_PRIME = 0x100000001B3ULL;

enum {
    DEDUP_OK             = 0,
    DEDUP_ERR_TRUNCATED  = 1,
    DEDUP_ERR_BAD_MAGIC  = 2,
    DEDUP_ERR_BAD_VER    = 3,
    DEDUP_ERR_BAD_TAG    = 4,
    DEDUP_ERR_BAD_REF    = 5,
    DEDUP_ERR_BAD_VARINT = 6,
    DEDUP_ERR_BAD_BODY   = 7,
    DEDUP_ERR_INVAL      = 8,
    DEDUP_ERR_NOMEM      = 9,
};

struct ChunkRange { size_t start; size_t end; };  // [start, end)

// CDC inside [buf_lo, buf_hi). Local helper used by cdc_split.
static inline void cdc_split_buffer(const uint8_t* data,
                                    size_t buf_lo, size_t buf_hi,
                                    size_t avg, size_t min_chunk, size_t max_chunk,
                                    std::vector<ChunkRange>& out)
{
    if (buf_lo >= buf_hi) return;
    const size_t mask = avg - 1;
    const bool use_mask = (avg > 0) && ((avg & mask) == 0);
    size_t start = buf_lo;
    uint64_t h = 0;
    for (size_t i = buf_lo; i < buf_hi; ++i) {
        h = h * CDC_PRIME + data[i];
        size_t span = i - start;
        if (span < min_chunk) continue;
        if (span >= max_chunk) {
            ChunkRange c = { start, i + 1 };
            out.push_back(c);
            start = i + 1;
            h = 0;
            continue;
        }
        bool boundary = use_mask ? ((h & mask) == 0)
                                 : (avg > 0 && (h % avg) == 0);
        if (boundary) {
            ChunkRange c = { start, i + 1 };
            out.push_back(c);
            start = i + 1;
            h = 0;
        }
    }
    // End-of-buffer trailing partial chunk; never spans buf_hi.
    if (start < buf_hi) {
        ChunkRange c = { start, buf_hi };
        out.push_back(c);
    }
}

// Boundary at every position where the rolling hash hits the
// threshold, with min/max bounds. When buf_size > 0 the rolling hash
// is reset at every buffer boundary so identical buffers produce
// identical chunk sequences (this is what makes long-range duplicates
// dedupe cleanly). buf_size = 0 means "single buffer" (legacy
// behavior, matches the original Python prototype default).
static inline void cdc_split(const uint8_t* data, size_t size,
                             size_t avg, size_t min_chunk, size_t max_chunk,
                             std::vector<ChunkRange>& out,
                             size_t buf_size = DEFAULT_BUF_SIZE)
{
    if (size == 0) return;
    if (buf_size == 0) {
        cdc_split_buffer(data, 0, size, avg, min_chunk, max_chunk, out);
        return;
    }
    for (size_t lo = 0; lo < size; lo += buf_size) {
        size_t hi = lo + buf_size;
        if (hi > size) hi = size;
        cdc_split_buffer(data, lo, hi, avg, min_chunk, max_chunk, out);
    }
}

// 64-bit FNV-1a over chunk bytes. Used only for the in-memory dedup
// hash table; never emitted to the .dupref file. Collisions are
// resolved by byte-comparing against the stored unique chunk before
// claiming a duplicate.
static inline uint64_t chunk_hash(const uint8_t* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

// LEB128 unsigned varint. Buffer must hold at least 10 bytes.
static inline size_t varint_encode(uint64_t value, uint8_t* out) {
    size_t n = 0;
    while (value >= 0x80) {
        out[n++] = (uint8_t)((value & 0x7F) | 0x80);
        value >>= 7;
    }
    out[n++] = (uint8_t)value;
    return n;
}

static inline int varint_decode(const uint8_t* p, size_t avail,
                                uint64_t* value, size_t* consumed) {
    uint64_t result = 0;
    size_t n = 0;
    int shift = 0;
    for (;;) {
        if (n >= avail) return DEDUP_ERR_TRUNCATED;
        uint8_t b = p[n++];
        result |= (uint64_t)(b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
            *value = result; *consumed = n; return DEDUP_OK;
        }
        shift += 7;
        if (shift > 63) return DEDUP_ERR_BAD_VARINT;
    }
}

// x86_64-only: little-endian memcpy is safe for unaligned reads/writes.
static inline void put_u32_le(uint8_t* p, uint32_t v) { memcpy(p, &v, 4); }
static inline void put_u64_le(uint8_t* p, uint64_t v) { memcpy(p, &v, 8); }
static inline uint32_t get_u32_le(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t get_u64_le(const uint8_t* p) { uint64_t v; memcpy(&v, p, 8); return v; }

// Encode `data[0..size)` into a freshly-malloc'd .dupref buffer.
// On success, sets *out_buf (caller frees with free_buf) and *out_size.
static int encode(const uint8_t* data, size_t size,
                  uint8_t** out_buf, size_t* out_size,
                  size_t avg = DEFAULT_AVG,
                  size_t min_chunk = DEFAULT_MIN,
                  size_t max_chunk = DEFAULT_MAX,
                  size_t buf_size = DEFAULT_BUF_SIZE)
{
    *out_buf = NULL;
    *out_size = 0;
    if (avg == 0 || min_chunk == 0 || max_chunk < min_chunk) return DEDUP_ERR_INVAL;

    std::vector<ChunkRange> chunks;
    cdc_split(data, size, avg, min_chunk, max_chunk, chunks, buf_size);

    struct Rec { uint8_t tag; uint64_t payload; };  // length (unique) | unique_idx (ref)
    std::vector<Rec> records;
    records.reserve(chunks.size());
    std::vector<ChunkRange> unique_chunks;
    unique_chunks.reserve(chunks.size());
    std::unordered_map<uint64_t, uint64_t> seen;
    seen.reserve(chunks.size() * 2);

    for (size_t i = 0; i < chunks.size(); ++i) {
        const ChunkRange& c = chunks[i];
        size_t clen = c.end - c.start;
        const uint8_t* cp = data + c.start;
        uint64_t h = chunk_hash(cp, clen);
        std::unordered_map<uint64_t, uint64_t>::iterator it = seen.find(h);
        if (it != seen.end()) {
            uint64_t uidx = it->second;
            const ChunkRange& u = unique_chunks[(size_t)uidx];
            size_t ulen = u.end - u.start;
            if (ulen == clen && memcmp(data + u.start, cp, clen) == 0) {
                Rec r = { TAG_REF, uidx };
                records.push_back(r);
                continue;
            }
            // hash collision (different bytes): fall through; overwrite seen[h]
        }
        seen[h] = (uint64_t)unique_chunks.size();
        Rec r = { TAG_UNIQUE, (uint64_t)clen };
        records.push_back(r);
        unique_chunks.push_back(c);
    }

    // Compute output size: header + chunk table + body
    size_t table_size = 0;
    for (size_t i = 0; i < records.size(); ++i) {
        table_size += 1;  // tag
        if (records[i].tag == TAG_UNIQUE) {
            table_size += 4;
        } else {
            uint64_t v = records[i].payload;
            do { table_size += 1; v >>= 7; } while (v);
        }
    }
    size_t body_size = 0;
    for (size_t i = 0; i < unique_chunks.size(); ++i) {
        body_size += unique_chunks[i].end - unique_chunks[i].start;
    }
    size_t total = HEADER_SIZE + table_size + body_size;

    uint8_t* buf = (uint8_t*)malloc(total > 0 ? total : 1);
    if (!buf) return DEDUP_ERR_NOMEM;

    put_u32_le(buf + 0, MAGIC);
    put_u32_le(buf + 4, VERSION);
    put_u64_le(buf + 8, (uint64_t)chunks.size());
    put_u64_le(buf + 16, (uint64_t)unique_chunks.size());

    size_t pos = HEADER_SIZE;
    for (size_t i = 0; i < records.size(); ++i) {
        buf[pos++] = records[i].tag;
        if (records[i].tag == TAG_UNIQUE) {
            put_u32_le(buf + pos, (uint32_t)records[i].payload);
            pos += 4;
        } else {
            pos += varint_encode(records[i].payload, buf + pos);
        }
    }
    for (size_t i = 0; i < unique_chunks.size(); ++i) {
        size_t ulen = unique_chunks[i].end - unique_chunks[i].start;
        memcpy(buf + pos, data + unique_chunks[i].start, ulen);
        pos += ulen;
    }

    *out_buf = buf;
    *out_size = total;
    return DEDUP_OK;
}

static int decode(const uint8_t* blob, size_t blob_size,
                  uint8_t** out_buf, size_t* out_size)
{
    *out_buf = NULL;
    *out_size = 0;
    if (blob_size < HEADER_SIZE) return DEDUP_ERR_TRUNCATED;
    if (get_u32_le(blob + 0) != MAGIC) return DEDUP_ERR_BAD_MAGIC;
    if (get_u32_le(blob + 4) != VERSION) return DEDUP_ERR_BAD_VER;
    uint64_t chunk_count  = get_u64_le(blob + 8);
    uint64_t unique_count = get_u64_le(blob + 16);

    // Sanity bounds before any allocation: each chunk-table record is
    // at least 2 bytes (tag + minimum 1-byte varint), so chunk_count
    // cannot exceed (blob_size - HEADER_SIZE) / 2. Without this check
    // a corrupted header with chunk_count = UINT64_MAX (libFuzzer
    // finds it in 4 execs) triggers std::bad_alloc on reserve().
    // unique_count <= chunk_count is required by the format.
    if (chunk_count > (blob_size - HEADER_SIZE) / 2) return DEDUP_ERR_TRUNCATED;
    if (unique_count > chunk_count) return DEDUP_ERR_BAD_REF;

    struct Rec { uint8_t tag; uint64_t payload; };
    std::vector<Rec> records;
    records.reserve((size_t)chunk_count);
    size_t pos = HEADER_SIZE;
    for (uint64_t i = 0; i < chunk_count; ++i) {
        if (pos >= blob_size) return DEDUP_ERR_TRUNCATED;
        uint8_t tag = blob[pos++];
        Rec r;
        r.tag = tag;
        if (tag == TAG_UNIQUE) {
            if (pos + 4 > blob_size) return DEDUP_ERR_TRUNCATED;
            r.payload = get_u32_le(blob + pos);
            pos += 4;
        } else if (tag == TAG_REF) {
            uint64_t v;
            size_t consumed;
            int rc = varint_decode(blob + pos, blob_size - pos, &v, &consumed);
            if (rc != DEDUP_OK) return rc;
            if (v >= unique_count) return DEDUP_ERR_BAD_REF;
            r.payload = v;
            pos += consumed;
        } else {
            return DEDUP_ERR_BAD_TAG;
        }
        records.push_back(r);
    }

    std::vector<ChunkRange> unique_chunks;
    unique_chunks.reserve((size_t)unique_count);
    for (size_t i = 0; i < records.size(); ++i) {
        if (records[i].tag != TAG_UNIQUE) continue;
        size_t ulen = (size_t)records[i].payload;
        if (pos + ulen > blob_size) return DEDUP_ERR_TRUNCATED;
        ChunkRange c = { pos, pos + ulen };
        unique_chunks.push_back(c);
        pos += ulen;
    }
    if ((uint64_t)unique_chunks.size() != unique_count) return DEDUP_ERR_BAD_BODY;

    size_t out_total = 0;
    {
        size_t next_unique = 0;
        for (size_t i = 0; i < records.size(); ++i) {
            if (records[i].tag == TAG_UNIQUE) {
                const ChunkRange& u = unique_chunks[next_unique++];
                out_total += u.end - u.start;
            } else {
                const ChunkRange& u = unique_chunks[(size_t)records[i].payload];
                out_total += u.end - u.start;
            }
        }
    }

    uint8_t* obuf = (uint8_t*)malloc(out_total > 0 ? out_total : 1);
    if (!obuf) return DEDUP_ERR_NOMEM;
    size_t opos = 0;
    size_t next_unique = 0;
    for (size_t i = 0; i < records.size(); ++i) {
        const ChunkRange* src;
        if (records[i].tag == TAG_UNIQUE) {
            src = &unique_chunks[next_unique++];
        } else {
            src = &unique_chunks[(size_t)records[i].payload];
        }
        size_t n = src->end - src->start;
        memcpy(obuf + opos, blob + src->start, n);
        opos += n;
    }

    *out_buf = obuf;
    *out_size = out_total;
    return DEDUP_OK;
}

static inline void free_buf(uint8_t* buf) { free(buf); }

// F5.3c: streaming decoder. Reads meta (small, in memory), reads
// body sequentially from `body_path`, expands records to `out_path`.
// For ref records, seeks back into the output file (already written
// once) and copies the previously-emitted unique-chunk bytes forward.
//
// Peak RAM ~= meta_size + chunk_offset_table + small I/O buffer;
// independent of input/output size. Output file is opened r+w for
// the seek-back trick. Returns DEDUP_OK on success.
static int decode_streaming(const uint8_t* meta, size_t meta_size,
                            const char* body_path, const char* out_path)
{
    if (meta_size < HEADER_SIZE) return DEDUP_ERR_TRUNCATED;
    if (get_u32_le(meta + 0) != MAGIC) return DEDUP_ERR_BAD_MAGIC;
    if (get_u32_le(meta + 4) != VERSION) return DEDUP_ERR_BAD_VER;
    uint64_t chunk_count  = get_u64_le(meta + 8);
    uint64_t unique_count = get_u64_le(meta + 16);

    // Bounds before allocation: see decode() for rationale. Each
    // record is >= 2 bytes; without this libFuzzer trips bad_alloc
    // on UINT64_MAX-style chunk_count corruption.
    if (chunk_count > (meta_size - HEADER_SIZE) / 2) return DEDUP_ERR_TRUNCATED;
    if (unique_count > chunk_count) return DEDUP_ERR_BAD_REF;

    struct Rec { uint8_t tag; uint64_t payload; };
    std::vector<Rec> records;
    records.reserve((size_t)chunk_count);
    size_t pos = HEADER_SIZE;
    for (uint64_t i = 0; i < chunk_count; ++i) {
        if (pos >= meta_size) return DEDUP_ERR_TRUNCATED;
        uint8_t tag = meta[pos++];
        Rec r;
        r.tag = tag;
        if (tag == TAG_UNIQUE) {
            if (pos + 4 > meta_size) return DEDUP_ERR_TRUNCATED;
            r.payload = get_u32_le(meta + pos);
            pos += 4;
        } else if (tag == TAG_REF) {
            uint64_t v; size_t consumed;
            int rc = varint_decode(meta + pos, meta_size - pos, &v, &consumed);
            if (rc != DEDUP_OK) return rc;
            if (v >= unique_count) return DEDUP_ERR_BAD_REF;
            r.payload = v;
            pos += consumed;
        } else {
            return DEDUP_ERR_BAD_TAG;
        }
        records.push_back(r);
    }

    FILE* fb = fopen(body_path, "rb");
    if (!fb) return DEDUP_ERR_INVAL;
    FILE* fo = fopen(out_path, "wb+");
    if (!fo) { fclose(fb); return DEDUP_ERR_INVAL; }

    struct Slot { uint64_t off; uint32_t len; };
    std::vector<Slot> unique_slots;
    unique_slots.reserve((size_t)unique_count);

    uint64_t out_pos = 0;
    std::vector<uint8_t> ioBuf(64 * 1024);

    for (size_t i = 0; i < records.size(); ++i) {
        if (records[i].tag == TAG_UNIQUE) {
            uint32_t need = (uint32_t)records[i].payload;
            // Stream from body to out, in 64K chunks.
            uint32_t remaining = need;
            while (remaining > 0) {
                size_t take = remaining < ioBuf.size() ? remaining : ioBuf.size();
                if (fread(ioBuf.data(), 1, take, fb) != take) {
                    fclose(fb); fclose(fo); return DEDUP_ERR_TRUNCATED;
                }
                if (fwrite(ioBuf.data(), 1, take, fo) != take) {
                    fclose(fb); fclose(fo); return DEDUP_ERR_INVAL;
                }
                remaining -= (uint32_t)take;
            }
            Slot s = { out_pos, need };
            unique_slots.push_back(s);
            out_pos += need;
        } else {
            uint64_t uidx = records[i].payload;
            const Slot& src = unique_slots[(size_t)uidx];
            // Seek back, read, then fseek to end and append.
            uint32_t remaining = src.len;
            uint64_t read_at = src.off;
            uint64_t write_at = out_pos;
            while (remaining > 0) {
                size_t take = remaining < ioBuf.size() ? remaining : ioBuf.size();
                if (osrep_fseek64(fo, (int64_t)read_at, SEEK_SET) != 0) {
                    fclose(fb); fclose(fo); return DEDUP_ERR_INVAL;
                }
                if (fread(ioBuf.data(), 1, take, fo) != take) {
                    fclose(fb); fclose(fo); return DEDUP_ERR_TRUNCATED;
                }
                if (osrep_fseek64(fo, (int64_t)write_at, SEEK_SET) != 0) {
                    fclose(fb); fclose(fo); return DEDUP_ERR_INVAL;
                }
                if (fwrite(ioBuf.data(), 1, take, fo) != take) {
                    fclose(fb); fclose(fo); return DEDUP_ERR_INVAL;
                }
                read_at += take;
                write_at += take;
                remaining -= (uint32_t)take;
            }
            out_pos = write_at;
        }
    }

    fclose(fb);
    if (fclose(fo) != 0) return DEDUP_ERR_INVAL;
    return DEDUP_OK;
}

// Split form. encode_split writes the (header + chunk table) into
// `*meta_buf` and the concatenated unique-chunk body into `*body_buf`.
// The body is the only piece worth feeding to SREP (its long-range
// duplicates are gone); the meta blob is small and is stored as an
// out-of-band trailer in the final archive. decode_split inverts it:
// given the meta blob and the body bytes (post-SREP-decompression),
// it reconstructs the original input.
static int encode_split(const uint8_t* data, size_t size,
                        uint8_t** meta_buf, size_t* meta_size,
                        uint8_t** body_buf, size_t* body_size,
                        size_t avg = DEFAULT_AVG,
                        size_t min_chunk = DEFAULT_MIN,
                        size_t max_chunk = DEFAULT_MAX,
                        size_t buf_size = DEFAULT_BUF_SIZE)
{
    *meta_buf = NULL; *meta_size = 0;
    *body_buf = NULL; *body_size = 0;

    uint8_t* full = NULL; size_t full_size = 0;
    int rc = encode(data, size, &full, &full_size, avg, min_chunk, max_chunk, buf_size);
    if (rc != DEDUP_OK) return rc;

    if (full_size < HEADER_SIZE) { free(full); return DEDUP_ERR_TRUNCATED; }
    uint64_t chunk_count = get_u64_le(full + 8);
    size_t pos = HEADER_SIZE;
    for (uint64_t i = 0; i < chunk_count; ++i) {
        if (pos >= full_size) { free(full); return DEDUP_ERR_TRUNCATED; }
        uint8_t tag = full[pos++];
        if (tag == TAG_UNIQUE) {
            if (pos + 4 > full_size) { free(full); return DEDUP_ERR_TRUNCATED; }
            pos += 4;
        } else if (tag == TAG_REF) {
            uint64_t v; size_t consumed;
            int vrc = varint_decode(full + pos, full_size - pos, &v, &consumed);
            if (vrc != DEDUP_OK) { free(full); return vrc; }
            pos += consumed;
        } else {
            free(full); return DEDUP_ERR_BAD_TAG;
        }
    }

    size_t mlen = pos;
    size_t blen = full_size - pos;

    uint8_t* mbuf = (uint8_t*)malloc(mlen > 0 ? mlen : 1);
    uint8_t* bbuf = (uint8_t*)malloc(blen > 0 ? blen : 1);
    if (!mbuf || !bbuf) {
        free(mbuf); free(bbuf); free(full);
        return DEDUP_ERR_NOMEM;
    }
    memcpy(mbuf, full, mlen);
    if (blen) memcpy(bbuf, full + mlen, blen);

    *meta_buf = mbuf; *meta_size = mlen;
    *body_buf = bbuf; *body_size = blen;
    free(full);
    return DEDUP_OK;
}

// F5.3c: streaming encoder. Reads `in_path` in `buf_size`-sized
// chunks, runs CDC + dedup on each, writes unique chunks to
// `body_path` as they're decided, and accumulates the chunk table in
// memory (kilobytes scale). Returns the meta blob via *meta_buf /
// *meta_size; caller frees with free_buf().
//
// Peak RAM ~= 2 * buf_size + chunk_table + dedup hash-table overhead;
// independent of input size. This is the API dup_wrapper.cpp uses to
// avoid the encode_split full-buffer load.
//
// `paranoid`: when true, perform a byte-compare against the
// already-written body before accepting a hash hit as a duplicate
// (re-reads the candidate chunk from the body file via fseek). This
// protects against the 64-bit hash collision case (collision rate
// of order 1e-7 per million chunks) at the cost of one disk seek +
// read per dedup hit. When false (default), the encoder trusts the
// 64-bit hash — matching the original F5.3c behavior and the
// design-doc "acceptable in practice" stance.
static int encode_streaming(const char* in_path, const char* body_path,
                            uint8_t** meta_buf, size_t* meta_size,
                            size_t avg = DEFAULT_AVG,
                            size_t min_chunk = DEFAULT_MIN,
                            size_t max_chunk = DEFAULT_MAX,
                            size_t buf_size = DEFAULT_BUF_SIZE,
                            bool paranoid = false)
{
    *meta_buf = NULL;
    *meta_size = 0;
    if (avg == 0 || min_chunk == 0 || max_chunk < min_chunk) return DEDUP_ERR_INVAL;

    FILE* fi = fopen(in_path, "rb");
    if (!fi) return DEDUP_ERR_INVAL;
    // Paranoid mode reads back from the body file to byte-compare,
    // so it needs r+w access. Non-paranoid is write-only.
    FILE* fb = fopen(body_path, paranoid ? "wb+" : "wb");
    if (!fb) { fclose(fi); return DEDUP_ERR_INVAL; }

    // Effective working buffer size. Even if the user asks for "no
    // buffering" (buf_size == 0), we cap reads at a sane size so we
    // don't slurp the whole file. 0 stays semantically "single
    // buffer" only when the file fits below this cap.
    size_t effective_buf = buf_size > 0 ? buf_size : (8 * 1024 * 1024);

    // Streaming mode trusts the 64-bit chunk_hash for dedup decisions
    // rather than byte-comparing on every match — keeping all unique
    // chunk bytes resident would defeat the RAM goal. The design doc
    // already documents 64-bit collision probability as "acceptable
    // in practice"; on real data this matches encode_split's output
    // byte-for-byte modulo collisions.
    std::vector<uint8_t> work(effective_buf);
    struct Rec { uint8_t tag; uint64_t payload; };
    std::vector<Rec> records;
    std::unordered_map<uint64_t, uint64_t> seen;
    uint64_t unique_count = 0;
    // Paranoid mode tracks where each unique chunk lives in the body
    // file so we can fseek back to byte-compare on a hash hit.
    std::vector<uint64_t> unique_off;       // byte offset in body
    std::vector<uint32_t> unique_len;       // length in body
    std::vector<uint8_t>  cmp_buf;          // scratch for byte-compare reads
    uint64_t body_pos = 0;

    while (true) {
        size_t got = fread(work.data(), 1, effective_buf, fi);
        if (got == 0) break;

        std::vector<ChunkRange> chunks;
        cdc_split_buffer(work.data(), 0, got, avg, min_chunk, max_chunk, chunks);

        for (size_t ci = 0; ci < chunks.size(); ++ci) {
            const ChunkRange& c = chunks[ci];
            size_t clen = c.end - c.start;
            const uint8_t* cp = work.data() + c.start;
            uint64_t h = chunk_hash(cp, clen);
            std::unordered_map<uint64_t, uint64_t>::iterator it = seen.find(h);
            bool is_dup = (it != seen.end());

            if (is_dup && paranoid) {
                // Verify by byte-comparing the candidate against the
                // unique chunk that was written earlier. Mismatch
                // means a 64-bit hash collision: fall through to
                // unique path and overwrite seen[h], matching
                // encode_split's collision semantics.
                uint64_t uidx = it->second;
                uint64_t off = unique_off[(size_t)uidx];
                uint32_t ulen = unique_len[(size_t)uidx];
                if (ulen != clen) {
                    is_dup = false;
                } else {
                    if (cmp_buf.size() < clen) cmp_buf.resize(clen);
                    if (fflush(fb) != 0) { fclose(fi); fclose(fb); return DEDUP_ERR_INVAL; }
                    if (osrep_fseek64(fb, (int64_t)off, SEEK_SET) != 0 ||
                        fread(cmp_buf.data(), 1, clen, fb) != clen) {
                        fclose(fi); fclose(fb);
                        return DEDUP_ERR_INVAL;
                    }
                    if (osrep_fseek64(fb, (int64_t)body_pos, SEEK_SET) != 0) {
                        fclose(fi); fclose(fb);
                        return DEDUP_ERR_INVAL;
                    }
                    if (memcmp(cmp_buf.data(), cp, clen) != 0) {
                        is_dup = false;
                    }
                }
            }

            if (is_dup) {
                Rec r = { TAG_REF, it->second };
                records.push_back(r);
                continue;
            }
            seen[h] = unique_count;
            Rec r = { TAG_UNIQUE, (uint64_t)clen };
            records.push_back(r);
            if (paranoid) {
                unique_off.push_back(body_pos);
                unique_len.push_back((uint32_t)clen);
            }
            if (fwrite(cp, 1, clen, fb) != clen) {
                fclose(fi); fclose(fb);
                return DEDUP_ERR_INVAL;
            }
            body_pos += clen;
            unique_count++;
        }

        if (got < effective_buf) break;
    }

    fclose(fi);
    if (fclose(fb) != 0) return DEDUP_ERR_INVAL;

    // Serialize meta = header + chunk table.
    size_t table_size = 0;
    for (size_t i = 0; i < records.size(); ++i) {
        table_size += 1;  // tag
        if (records[i].tag == TAG_UNIQUE) {
            table_size += 4;
        } else {
            uint64_t v = records[i].payload;
            do { table_size += 1; v >>= 7; } while (v);
        }
    }
    size_t mlen = HEADER_SIZE + table_size;
    uint8_t* mbuf = (uint8_t*)malloc(mlen > 0 ? mlen : 1);
    if (!mbuf) return DEDUP_ERR_NOMEM;

    put_u32_le(mbuf + 0, MAGIC);
    put_u32_le(mbuf + 4, VERSION);
    put_u64_le(mbuf + 8, (uint64_t)records.size());
    put_u64_le(mbuf + 16, unique_count);

    size_t pos = HEADER_SIZE;
    for (size_t i = 0; i < records.size(); ++i) {
        mbuf[pos++] = records[i].tag;
        if (records[i].tag == TAG_UNIQUE) {
            put_u32_le(mbuf + pos, (uint32_t)records[i].payload);
            pos += 4;
        } else {
            pos += varint_encode(records[i].payload, mbuf + pos);
        }
    }

    *meta_buf = mbuf;
    *meta_size = mlen;
    return DEDUP_OK;
}

static int decode_split(const uint8_t* meta, size_t meta_size,
                        const uint8_t* body, size_t body_size,
                        uint8_t** out_buf, size_t* out_size)
{
    size_t total = meta_size + body_size;
    uint8_t* full = (uint8_t*)malloc(total > 0 ? total : 1);
    if (!full) return DEDUP_ERR_NOMEM;
    if (meta_size) memcpy(full, meta, meta_size);
    if (body_size) memcpy(full + meta_size, body, body_size);
    int rc = decode(full, total, out_buf, out_size);
    free(full);
    return rc;
}

}  // namespace osrep_dedup

#endif  // OSREP_DEDUP_CPP
