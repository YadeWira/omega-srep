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
//
// F5.6: the chunk-boundary hash is selectable (CDC_HASH_FNV, the
// default/legacy algorithm, or CDC_HASH_GEAR, an opt-in Gear-hash CDC
// with an implicit content window that finds non-buffer-aligned
// duplicates FNV misses -- see the CDC_HASH_FNV/CDC_HASH_GEAR enum
// below). This is purely an encoder-side chunking choice: it changes
// where boundaries fall, never the .dupref format described above,
// so old and new archives keep interoperating with no version bump.

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

// F5.6: chunk-boundary hash algorithm selector, threaded through
// cdc_split/cdc_split_buffer/encode/encode_streaming. CDC_HASH_FNV is
// the original algorithm and stays the default everywhere -- this is
// purely an opt-in alternative (--chunk-hash=gear at the CLI).
//
// Choice of algorithm is an encoder-side-only decision: it changes
// *where* chunk boundaries fall, not the .dupref wire format. decode()
// and decode_streaming() only replay stored (tag, length/ref_index)
// records -- they never recompute a boundary or care which hash chose
// it, so old and new archives keep interoperating; there is no format
// version bump.
enum {
    CDC_HASH_FNV  = 0,  // h = h*CDC_PRIME + byte, reset only at cuts.
                        // No fixed window: two occurrences of the same
                        // bytes only produce the same cut decision if
                        // they sit at the same *absolute* hash state,
                        // which in practice means the same distance
                        // from the last reset -- so duplicates that
                        // aren't buffer-aligned are routinely missed
                        // (F5.6 finding).
    CDC_HASH_GEAR = 1,  // Gear-hash: h = (h<<1) + GEAR_TABLE[byte].
                        // Only the low ~64 bits of shift history affect
                        // the cut test, i.e. an implicit ~64-byte
                        // content window that resyncs on repeated
                        // content regardless of its absolute offset.
                        // FastCDC-style dual mask (tight below avg,
                        // lax above) plus a gated degenerate-input
                        // safeguard; see cdc_split_buffer_gear.
};
static const int DEFAULT_CHUNK_HASH = CDC_HASH_FNV;

// Fixed, deterministically-generated GEAR table for CDC_HASH_GEAR:
// splitmix64 (Steele/Vigna/Bacon finalizer) seeded with 0xC0FFEE,
// generated once (see the F5.6 tuning-phase harness) and hardcoded
// here. Does not need to match any published FastCDC table -- it only
// has to be fixed and shared between encode/encode_streaming calls
// within this build (see the CDC_HASH_FNV/CDC_HASH_GEAR comment above
// for why decode() never needs to know which hash produced a chunk
// boundary).
static const uint64_t GEAR_TABLE[256] = {
    0xCA8216FA9058D0FAULL, 0xECE45BABCE870479ULL, 0x87BE93A4A16A73CBULL, 0x5A71C08957A50D44ULL,
    0xC345D6E168AD2C78ULL, 0xE47DF32A3A624293ULL, 0x08CAB724CA100235ULL, 0xDFA4529422A994BFULL,
    0x1A4C7945EF3E2887ULL, 0xA3148D0AD0AD2A9AULL, 0x62D1D0D9D4002759ULL, 0x507065D804077EDCULL,
    0x75A5A799430A358CULL, 0xDFAA618F05E814ADULL, 0xDFDC1F1E3FD80EE5ULL, 0xAA4F1B082AF8064FULL,
    0x2DD35B22825E9E21ULL, 0x8258297E8B33077CULL, 0x9547A3D84C96AFB2ULL, 0x14A2E2D414D15ACEULL,
    0x401D2708B1A6F24CULL, 0x07E7425232185DF7ULL, 0x40F1CC64D4F6E966ULL, 0x62FBD74C6CF6756CULL,
    0xB6E2C223523178D0ULL, 0xD15193D6622B12A9ULL, 0xFAFA7D3979287E70ULL, 0xC3CAC3E16D161A69ULL,
    0x23F31DFC3ECB73D1ULL, 0xA9827391BEC8A294ULL, 0x1E19E3078153254BULL, 0x7DD0207825606CC8ULL,
    0x099DC1F55073DEBEULL, 0x86CA2CBA13FE4CB8ULL, 0x0A0F4FCF12D727B5ULL, 0xA1FDDB44848138BCULL,
    0xB3DE8FA80A8312A2ULL, 0xFD12F2B74F7EFCFDULL, 0x38ADC0A83F9E49C5ULL, 0x0498B8209519EBF4ULL,
    0x07D6DA6CE496B3EFULL, 0x9AF4C0EE4D2B954DULL, 0x4AFB105F29F066E6ULL, 0x485BE9E0C0AB7C01ULL,
    0xB6C2D889268CF23EULL, 0xBE38F54F7A211B90ULL, 0x993E0F3EC7F8FB5DULL, 0xC48F71AFC86DCE2DULL,
    0x546E05CCC2DD8F0CULL, 0x0CAC6676C2EE96F9ULL, 0xBEE5C87F89022FDAULL, 0x8ED8B8C0991A945FULL,
    0xCF40C10841B90D6CULL, 0x80F4F265A3D68295ULL, 0xF163669B673B6E74ULL, 0xD6012B81B39BB79AULL,
    0x3AD56BD0CC64F2D7ULL, 0x6497BA74EECAA7A0ULL, 0xAF5C8FE9E41C3B70ULL, 0xD658D0BEDD5F4FB2ULL,
    0x5BD3A48419F36CD3ULL, 0xBF05FE0B7C822E14ULL, 0x5E289FD028330A6FULL, 0x7FAF20355D9DF546ULL,
    0x2385A661EB378F85ULL, 0x6C3C64E859D466D4ULL, 0x7B9A958E68EA55E2ULL, 0xA9E0901A88436E83ULL,
    0x86A00465918DBD79ULL, 0xF15B171086DCA960ULL, 0x78F7A812703A3AA0ULL, 0xD86D278D0B030DC1ULL,
    0x9845B2D26E56066EULL, 0x29281E8D6135F90EULL, 0x6E85C3E1E3F391ADULL, 0x33AD175B764C99EBULL,
    0x61E9D7FFD8725DA2ULL, 0x21B7DB0500A53299ULL, 0x2F880AF58CFD395CULL, 0x54A1D27E41A267DFULL,
    0xA2164DCEBC06DA4BULL, 0x1B073DFB56FE939BULL, 0x17F7503974FA2CD4ULL, 0x4D30E6F3B8AF66E6ULL,
    0xCD33DA64109E6A66ULL, 0xA5DE441ADA7029CDULL, 0x87FF248BD515301DULL, 0x2692EE2107A8BCFCULL,
    0xD921539364E848BBULL, 0xBFBB0037355A313CULL, 0x303AA10EA1A1B4C2ULL, 0xD37981DA6858F6D8ULL,
    0x6AFAA8080F4B3282ULL, 0x39BB2C389AA33FF8ULL, 0x6669EE8DDEF70BBFULL, 0x21D9CC4ACA626926ULL,
    0x5B47DFAA75C325DBULL, 0xF7F390220C99B426ULL, 0x5B1D07A2900A83D5ULL, 0xD7CCC1259E5526EBULL,
    0xB3B0B7A96BF7884DULL, 0x40FF77434D087133ULL, 0x8C210667F36FA608ULL, 0xE0EA4D4A9577E127ULL,
    0x10F3AC04260E8616ULL, 0x405DFE51E0EEF9B6ULL, 0x3A27E95E67710143ULL, 0xADE78E0546E539FCULL,
    0xDE8F33EF43979DF1ULL, 0x802AF2D2376437E3ULL, 0x679CFE92CD023AD9ULL, 0xDC82E76283DC4C08ULL,
    0x98C94E6B3AA7E83DULL, 0xB86598FE74D7396AULL, 0xE75A17EAFC5ABC87ULL, 0xBD24FDCE56D4166FULL,
    0xC674ACFABE3B443AULL, 0x9D3B7F64D6C71035ULL, 0x155D05517984566EULL, 0xA310D669E0F0510BULL,
    0x160EFB654E237FF6ULL, 0xCC402C0AB00A1A6AULL, 0xD92A4B0A5AB280D4ULL, 0xA9887C970C31ED35ULL,
    0xCA9447EBCEE330CAULL, 0x768DCB82D4A2B18DULL, 0x7028116DC8A44676ULL, 0xFE1DA002E69FDA56ULL,
    0x79D087F0742D2C55ULL, 0x0F04017B24C944A5ULL, 0x6561523B282FADD9ULL, 0x6060AE201039E082ULL,
    0x575B97CF14452D06ULL, 0xDF901E7A5A1B6694ULL, 0x20CF2C098273D243ULL, 0xD5024729FAB3B903ULL,
    0x8E771881A1B0460FULL, 0x55D8034CD0D170ABULL, 0x01C2A792E9CD902FULL, 0x1E20776AF967D136ULL,
    0xF07E378B5E366F61ULL, 0xD9D2DC6E8FEF95E4ULL, 0x741922BD9CB3F57AULL, 0xA379DBC1687554EEULL,
    0x47A9A10331C2E095ULL, 0x2A0EA02DC1F6E395ULL, 0xDB97797CE0DD715EULL, 0xD6D6CF017F143E67ULL,
    0xEA0DBA00B2B20877ULL, 0x893CCB7CFF00405FULL, 0x97C440DCCD6DDAFCULL, 0xFEAA90892B727623ULL,
    0xEDCEA4BFE988B0A8ULL, 0xB728A7F916D5EC00ULL, 0x13E1D51DFA05636DULL, 0x8AEF400974FC0707ULL,
    0xA149C32CDF8774FEULL, 0x0FBDB93A761BF982ULL, 0xADDD934F0AED69B7ULL, 0x91A680196F0B1AA9ULL,
    0x94F489D18997FF15ULL, 0xE8DE8101CF16A5AFULL, 0x94409AC12663F454ULL, 0xF95FD7899FE08CC7ULL,
    0x510476542D5A83EFULL, 0x88E1C061191518CCULL, 0x87AB2FEC3351D9A4ULL, 0x47C04E17E896D142ULL,
    0x853C71808408163CULL, 0xBB57D210DB10E4ABULL, 0x57AC49333A940FC0ULL, 0x89EB5DDB06FD0BEBULL,
    0x3C0A758D94DA73D9ULL, 0xB76383A603B810D1ULL, 0x39237C4B1F2CF83BULL, 0x3302F1C5711EAF7AULL,
    0x9B402BF33C9AE5EAULL, 0xE7AAA76F7E2559A5ULL, 0xCB71970C94555D16ULL, 0x56B8F2D2814D128DULL,
    0x40C36243DE7FEA10ULL, 0x3103206774B8F8E0ULL, 0xFC5F051B7DFD6622ULL, 0x1615A3E13ED78A79ULL,
    0xBA6D1FCB88576B92ULL, 0x1703743AB31B17CAULL, 0x2B4744AD4C32AA79ULL, 0xED2B764D4EC841CDULL,
    0xB0E2495891F7CEACULL, 0xAF56EE02DBD67449ULL, 0x2A16069D634C773FULL, 0x089534B56207CE32ULL,
    0xC1F7411B5AC1C2A1ULL, 0xA267A9D566922D9BULL, 0x456617AA6CB6BD6DULL, 0x8B745FB301D6C5F1ULL,
    0x4CED9A5F1AD65800ULL, 0xB0F7DE11FD6CB79CULL, 0xEAC80EAE2F231162ULL, 0xE86C6D6D36B641A3ULL,
    0x8FA8B25FDD101E56ULL, 0x17FD90456463570DULL, 0x2A459DEF280428B5ULL, 0x84FF8A8B1C9C7A1EULL,
    0xC4131B9C46C58F73ULL, 0xC74DA225BEA51135ULL, 0x90C54753D8C2EB8CULL, 0x3DE7E6BCAF828AC5ULL,
    0x807C608DE42BB460ULL, 0x6FC8B32CD08386AAULL, 0x6296C7200CA2C8D2ULL, 0x998A95F5D75DD04FULL,
    0x5B72EEF38E353E39ULL, 0xE563989D4FD74AF2ULL, 0x7DA65433AE511416ULL, 0x495A4D08E8BDA6F3ULL,
    0x251C0FB1CF7DC4BEULL, 0x20DF590F07E49CA0ULL, 0x54A05DBE6DA42DD7ULL, 0xD846B0E0B454E971ULL,
    0x364499C239E60552ULL, 0x97B24AC50BF1080AULL, 0xC22F0F3774E65E6DULL, 0xF5AE335C6A286619ULL,
    0xE5BB5D54BF41B52EULL, 0x828C9DF52CAD1CB9ULL, 0xACA48D5F26569929ULL, 0xDDC7E30D1EF3A048ULL,
    0xDEDC9C339C3F402CULL, 0xB5036326DD8D7A7EULL, 0x7FA89B9DAF2DFF65ULL, 0x269D3BFF05CB599EULL,
    0xB5B1BFFA10B007B8ULL, 0x3009B729BA8B0136ULL, 0x19B02F619F3A0B64ULL, 0x691452237FD30257ULL,
    0x0878A44A01E9DF91ULL, 0x7EF047F6042B5249ULL, 0xE81C45513F6F915FULL, 0xB9E4760B60294400ULL,
    0x16776CDECE0B193AULL, 0x1B9D61DD64D2CF9FULL, 0x56FCE4A79BC2A22CULL, 0xBB56A2602F15D473ULL,
    0x3223CFCD1AE02A49ULL, 0x8FE4148FCF8F4E23ULL, 0x8B23C12AF0F1FF9FULL, 0x71ECDD934D038B22ULL,
    0xD7DC05B9974E993BULL, 0x7E93610091AAAC16ULL, 0xE131E265162F985CULL, 0xC3890258DF389EEAULL,
    0xACE6294D39D61FCFULL, 0x925E00FF1CD3C77CULL, 0x02A36DB0D4E31BD0ULL, 0xBFEF09E10E911A8EULL,
};

// FastCDC-style normalized-chunking mask spread, off mask_bits =
// floor(log2(avg)): mask_s uses mask_bits+GEAR_DELTA_S bits (tighter,
// applied while span < avg) and mask_l uses mask_bits-GEAR_DELTA_L
// bits (laxer, applied once span >= avg). delta=5/5 is the F5.6
// tuning phase's recommendation: it's the minimum width at which
// realistic text/mixed corpora start finding genuine tuned-mask cuts
// instead of falling back to the escape safeguard for a large
// fraction of chunks (see the tuning-phase results table), while
// matching plain Gear-hash's edit-locality resync distance.
static const int GEAR_DELTA_S = 5;
static const int GEAR_DELTA_L = 5;

static inline int gear_log2_floor(size_t v) {
    int bits = 0;
    while (v > 1) { v >>= 1; ++bits; }
    return bits;
}

// Degenerate-input safeguard finalizer: full 64-bit avalanche mix of
// `span` (bytes since the last cut -- local/relative, never the
// file's absolute offset, so this doesn't reintroduce FNV's
// alignment-dependence). splitmix64-style; deliberately not a small
// lookup table -- see cdc_split_buffer_gear for why a short-period
// salt fails on constant-byte input.
static inline uint64_t gear_mix_span(uint64_t span) {
    uint64_t x = span;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

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

// CDC inside [buf_lo, buf_hi), original FNV-based rolling hash. Local
// helper used by cdc_split_buffer. See the CDC_HASH_FNV enum comment
// above for its known non-buffer-aligned-duplicate limitation (F5.6).
static inline void cdc_split_buffer_fnv(const uint8_t* data,
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

// CDC inside [buf_lo, buf_hi), Gear-hash rolling hash (F5.6 port of
// the tuning-phase harness's gear_split). Opt-in alternative to
// cdc_split_buffer_fnv: h = (h<<1) + GEAR_TABLE[byte] has an implicit
// ~64-byte content window (older bytes' contribution shifts out of
// the 64-bit register), so two occurrences of the same ~64+ bytes
// reach the same hash state and the same cut decision regardless of
// their absolute distance from the last reset -- fixing the
// non-buffer-aligned-duplicate miss that motivates this port.
//
// Normalized chunking: a tight mask_s while span < avg (discourages
// short chunks) and a lax mask_l once span >= avg (encourages cutting
// soon after crossing the target), each GEAR_DELTA_{S,L} bits off
// mask_bits = floor(log2(avg)).
//
// Degenerate-input safeguard: gated behind span >= 0.75*max_chunk (a
// chunk that has gone abnormally long without a natural cut). Once
// gated, XORs the hash against a full-avalanche mix of `span` (never
// the absolute file offset) and progressively relaxes the mask from
// a few bits down to 0 as span sweeps up to max_chunk, guaranteeing a
// cut fires before the hard clamp. Gating -- rather than mixing span
// into every byte's test unconditionally -- is what keeps ordinary
// content's edit-locality resync fast: the cut decision stays a pure
// function of the ~64-byte content window on the >99% of chunks that
// never approach the gate.
static inline void cdc_split_buffer_gear(const uint8_t* data,
                                         size_t buf_lo, size_t buf_hi,
                                         size_t avg, size_t min_chunk, size_t max_chunk,
                                         std::vector<ChunkRange>& out)
{
    if (buf_lo >= buf_hi) return;
    const bool have_avg = (avg > 0);
    const int mask_bits = have_avg ? gear_log2_floor(avg) : 0;
    const int sb = mask_bits + GEAR_DELTA_S;
    const uint64_t mask_s = (sb >= 63) ? ~0ULL : ((1ULL << sb) - 1);
    // Clamped to >=1: for --chunk-avg < 64, mask_bits-GEAR_DELTA_L would
    // go to <=0, and an unclamped 0-bit mask makes the `span>=avg` cut
    // test unconditionally true -- collapsing to near-fixed-size
    // chunking regardless of content (confirmed on tests/corpus/random.bin
    // at --chunk-avg=32: stdev fell from fnv's ~31 to ~2). A 1-bit floor
    // keeps the cut genuinely content-defined (50% per-position odds)
    // even at small avg, at the cost of not hitting the exact target
    // average as precisely; --chunk-avg's default (4096) is unaffected.
    const int lb = (mask_bits - GEAR_DELTA_L < 1) ? 1 : (mask_bits - GEAR_DELTA_L);
    const uint64_t mask_l = (1ULL << lb) - 1;
    // 0.75*max_chunk gate, integer arithmetic (matches the tuning
    // harness's ESCAPE_THRESHOLD constant at the default 16384 max).
    const size_t escape_threshold = (max_chunk / 4) * 3;
    // One less than the forced-clamp trigger point below, so the
    // progressively-relaxed mask reaches 0 bits (guaranteed match)
    // strictly before the hard clamp can fire.
    const size_t escape_win_hi = (max_chunk >= 2) ? (max_chunk - 1) : escape_threshold + 1;

    size_t start = buf_lo;
    uint64_t h = 0;
    for (size_t i = buf_lo; i < buf_hi; ++i) {
        h = (h << 1) + GEAR_TABLE[data[i]];
        size_t span = i - start;
        if (span < min_chunk) continue;
        if (span >= max_chunk) {
            ChunkRange c = { start, i + 1 };
            out.push_back(c);
            start = i + 1;
            h = 0;
            continue;
        }
        bool boundary = false;
        if (have_avg) {
            bool escape = span >= escape_threshold;
            uint64_t test, m;
            if (escape) {
                size_t win_lo = escape_threshold;
                size_t win_hi = win_lo < escape_win_hi ? escape_win_hi : win_lo + 1;
                size_t window = win_hi - win_lo;
                size_t progress = (span > win_lo) ? (span - win_lo) : 0;
                int start_bits = 4;
                if (lb >= 0 && lb < start_bits) start_bits = lb;
                long long bits = start_bits -
                    (long long)((progress * (start_bits + 1)) / (window + 1));
                if (bits < 0) bits = 0;
                uint64_t escape_mask = (bits <= 0) ? 0ULL : ((1ULL << bits) - 1);
                test = h ^ gear_mix_span((uint64_t)span);
                m = escape_mask;
            } else {
                test = h;
                m = (span < avg) ? mask_s : mask_l;
            }
            boundary = (test & m) == 0;
        }
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

// CDC inside [buf_lo, buf_hi). Dispatches to the selected hash
// algorithm; defaults to CDC_HASH_FNV so every existing call site
// (positional args, no algo specified) is byte-for-byte unchanged.
static inline void cdc_split_buffer(const uint8_t* data,
                                    size_t buf_lo, size_t buf_hi,
                                    size_t avg, size_t min_chunk, size_t max_chunk,
                                    std::vector<ChunkRange>& out,
                                    int hash_algo = DEFAULT_CHUNK_HASH)
{
    if (hash_algo == CDC_HASH_GEAR) {
        cdc_split_buffer_gear(data, buf_lo, buf_hi, avg, min_chunk, max_chunk, out);
    } else {
        cdc_split_buffer_fnv(data, buf_lo, buf_hi, avg, min_chunk, max_chunk, out);
    }
}

// Boundary at every position where the rolling hash hits the
// threshold, with min/max bounds. When buf_size > 0 the rolling hash
// is reset at every buffer boundary so identical buffers produce
// identical chunk sequences (this is what makes long-range duplicates
// dedupe cleanly). buf_size = 0 means "single buffer" (legacy
// behavior, matches the original Python prototype default).
// `hash_algo` selects CDC_HASH_FNV (default, legacy) or CDC_HASH_GEAR
// (F5.6 opt-in); see the enum comment near CDC_PRIME.
static inline void cdc_split(const uint8_t* data, size_t size,
                             size_t avg, size_t min_chunk, size_t max_chunk,
                             std::vector<ChunkRange>& out,
                             size_t buf_size = DEFAULT_BUF_SIZE,
                             int hash_algo = DEFAULT_CHUNK_HASH)
{
    if (size == 0) return;
    if (buf_size == 0) {
        cdc_split_buffer(data, 0, size, avg, min_chunk, max_chunk, out, hash_algo);
        return;
    }
    for (size_t lo = 0; lo < size; lo += buf_size) {
        size_t hi = lo + buf_size;
        if (hi > size) hi = size;
        cdc_split_buffer(data, lo, hi, avg, min_chunk, max_chunk, out, hash_algo);
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
                  size_t buf_size = DEFAULT_BUF_SIZE,
                  int hash_algo = DEFAULT_CHUNK_HASH)
{
    *out_buf = NULL;
    *out_size = 0;
    if (avg == 0 || min_chunk == 0 || max_chunk < min_chunk) return DEDUP_ERR_INVAL;

    std::vector<ChunkRange> chunks;
    cdc_split(data, size, avg, min_chunk, max_chunk, chunks, buf_size, hash_algo);

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
                        size_t buf_size = DEFAULT_BUF_SIZE,
                        int hash_algo = DEFAULT_CHUNK_HASH)
{
    *meta_buf = NULL; *meta_size = 0;
    *body_buf = NULL; *body_size = 0;

    uint8_t* full = NULL; size_t full_size = 0;
    int rc = encode(data, size, &full, &full_size, avg, min_chunk, max_chunk, buf_size, hash_algo);
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
                            bool paranoid = false,
                            int hash_algo = DEFAULT_CHUNK_HASH)
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
        cdc_split_buffer(work.data(), 0, got, avg, min_chunk, max_chunk, chunks, hash_algo);

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
