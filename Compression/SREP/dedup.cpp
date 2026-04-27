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
#include <vector>
#include <unordered_map>

namespace osrep_dedup {

static const uint32_t MAGIC       = 0x52505544u;  // "DUPR" LE
static const uint32_t VERSION     = 1u;
static const uint8_t  TAG_UNIQUE  = 0;
static const uint8_t  TAG_REF     = 1;
static const size_t   HEADER_SIZE = 24;

static const size_t DEFAULT_AVG = 4096;
static const size_t DEFAULT_MIN = 1024;
static const size_t DEFAULT_MAX = 16384;

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

// Matches tests/dup_prototype.py:cdc_split. Boundary at every position
// where the rolling hash hits the threshold, with min/max bounds. Min
// is a "skip below" gate, max forces a cut at exactly span==max_chunk.
static inline void cdc_split(const uint8_t* data, size_t size,
                             size_t avg, size_t min_chunk, size_t max_chunk,
                             std::vector<ChunkRange>& out)
{
    if (size == 0) return;
    const size_t mask = avg - 1;
    const bool use_mask = (avg > 0) && ((avg & mask) == 0);
    size_t start = 0;
    uint64_t h = 0;
    for (size_t i = 0; i < size; ++i) {
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
    if (start < size) {
        ChunkRange c = { start, size };
        out.push_back(c);
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
                  size_t max_chunk = DEFAULT_MAX)
{
    *out_buf = NULL;
    *out_size = 0;
    if (avg == 0 || min_chunk == 0 || max_chunk < min_chunk) return DEDUP_ERR_INVAL;

    std::vector<ChunkRange> chunks;
    cdc_split(data, size, avg, min_chunk, max_chunk, chunks);

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

}  // namespace osrep_dedup

#endif  // OSREP_DEDUP_CPP
