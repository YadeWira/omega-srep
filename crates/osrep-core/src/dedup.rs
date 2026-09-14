//! Omega SREP `-dup` mode: CDC + dedup pre-pass (encoder + decoder).
//!
//! Rust port of `Compression/SREP/dedup.cpp`. The `.dupref` wire format
//! and the CDC chunk boundaries are byte-compatible with the C++
//! implementation; `crates/osrep-conformance` verifies that
//! differentially against `bin/dedup_test` rather than trusting a
//! re-reading of the format description.
//!
//! File format (little-endian):
//!
//! ```text
//! header (24 bytes): magic u32 "DUPR" = 0x52505544
//!                    version u32 = 1
//!                    chunk_count  u64
//!                    unique_count u64
//! chunk table (chunk_count records):
//!                    tag u8 (0 = unique, 1 = ref)
//!                    tag 0 -> length u32 (bytes of this unique chunk in the body)
//!                    tag 1 -> LEB128 unsigned index, must be < unique_count
//! body:              concatenated unique chunks, in order of first appearance
//! ```
//!
//! Two CDC boundary hashes exist. `CDC_HASH_FNV` is the default and
//! matches the original prototype; `CDC_HASH_GEAR` is an opt-in
//! FastCDC-style rolling hash with an implicit content window. The
//! choice never reaches the wire format -- `decode` only replays stored
//! records -- so both interoperate without a version bump.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

pub const MAGIC: u32 = 0x5250_5544; // "DUPR" LE
pub const VERSION: u32 = 1;
const TAG_UNIQUE: u8 = 0;
const TAG_REF: u8 = 1;
const HEADER_SIZE: usize = 24;

pub const DEFAULT_AVG: usize = 4096;
pub const DEFAULT_MIN: usize = 1024;
pub const DEFAULT_MAX: usize = 16384;
/// 0 means "single buffer" (no buffer-bounded CDC); anything else makes
/// the rolling hash reset at every buffer boundary, so identical buffers
/// produce identical chunk sequences and long-range duplicates dedupe.
pub const DEFAULT_BUF_SIZE: usize = 0;

/// FNV-style multiplier; matches `PRIME` in `tests/dup_prototype.py`.
const CDC_PRIME: u64 = 0x100_0000_01B3;

pub const CDC_HASH_FNV: i32 = 0;
pub const CDC_HASH_GEAR: i32 = 1;
pub const DEFAULT_CHUNK_HASH: i32 = CDC_HASH_FNV;

pub const DEDUP_OK: i32 = 0;
pub const DEDUP_ERR_TRUNCATED: i32 = 1;
pub const DEDUP_ERR_BAD_MAGIC: i32 = 2;
pub const DEDUP_ERR_BAD_VER: i32 = 3;
pub const DEDUP_ERR_BAD_TAG: i32 = 4;
pub const DEDUP_ERR_BAD_REF: i32 = 5;
pub const DEDUP_ERR_BAD_VARINT: i32 = 6;
pub const DEDUP_ERR_BAD_BODY: i32 = 7;
pub const DEDUP_ERR_INVAL: i32 = 8;
pub const DEDUP_ERR_NOMEM: i32 = 9;

/// Fixed, deterministically-generated Gear table: splitmix64 seeded with
/// 0xC0FFEE, generated once during the F5.6 tuning phase and hardcoded
/// in the C++ source. Only needs to be fixed and shared within a build.
const GEAR_TABLE: [u64; 256] = [
    0xCA8216FA9058D0FA, 0xECE45BABCE870479, 0x87BE93A4A16A73CB, 0x5A71C08957A50D44,
    0xC345D6E168AD2C78, 0xE47DF32A3A624293, 0x08CAB724CA100235, 0xDFA4529422A994BF,
    0x1A4C7945EF3E2887, 0xA3148D0AD0AD2A9A, 0x62D1D0D9D4002759, 0x507065D804077EDC,
    0x75A5A799430A358C, 0xDFAA618F05E814AD, 0xDFDC1F1E3FD80EE5, 0xAA4F1B082AF8064F,
    0x2DD35B22825E9E21, 0x8258297E8B33077C, 0x9547A3D84C96AFB2, 0x14A2E2D414D15ACE,
    0x401D2708B1A6F24C, 0x07E7425232185DF7, 0x40F1CC64D4F6E966, 0x62FBD74C6CF6756C,
    0xB6E2C223523178D0, 0xD15193D6622B12A9, 0xFAFA7D3979287E70, 0xC3CAC3E16D161A69,
    0x23F31DFC3ECB73D1, 0xA9827391BEC8A294, 0x1E19E3078153254B, 0x7DD0207825606CC8,
    0x099DC1F55073DEBE, 0x86CA2CBA13FE4CB8, 0x0A0F4FCF12D727B5, 0xA1FDDB44848138BC,
    0xB3DE8FA80A8312A2, 0xFD12F2B74F7EFCFD, 0x38ADC0A83F9E49C5, 0x0498B8209519EBF4,
    0x07D6DA6CE496B3EF, 0x9AF4C0EE4D2B954D, 0x4AFB105F29F066E6, 0x485BE9E0C0AB7C01,
    0xB6C2D889268CF23E, 0xBE38F54F7A211B90, 0x993E0F3EC7F8FB5D, 0xC48F71AFC86DCE2D,
    0x546E05CCC2DD8F0C, 0x0CAC6676C2EE96F9, 0xBEE5C87F89022FDA, 0x8ED8B8C0991A945F,
    0xCF40C10841B90D6C, 0x80F4F265A3D68295, 0xF163669B673B6E74, 0xD6012B81B39BB79A,
    0x3AD56BD0CC64F2D7, 0x6497BA74EECAA7A0, 0xAF5C8FE9E41C3B70, 0xD658D0BEDD5F4FB2,
    0x5BD3A48419F36CD3, 0xBF05FE0B7C822E14, 0x5E289FD028330A6F, 0x7FAF20355D9DF546,
    0x2385A661EB378F85, 0x6C3C64E859D466D4, 0x7B9A958E68EA55E2, 0xA9E0901A88436E83,
    0x86A00465918DBD79, 0xF15B171086DCA960, 0x78F7A812703A3AA0, 0xD86D278D0B030DC1,
    0x9845B2D26E56066E, 0x29281E8D6135F90E, 0x6E85C3E1E3F391AD, 0x33AD175B764C99EB,
    0x61E9D7FFD8725DA2, 0x21B7DB0500A53299, 0x2F880AF58CFD395C, 0x54A1D27E41A267DF,
    0xA2164DCEBC06DA4B, 0x1B073DFB56FE939B, 0x17F7503974FA2CD4, 0x4D30E6F3B8AF66E6,
    0xCD33DA64109E6A66, 0xA5DE441ADA7029CD, 0x87FF248BD515301D, 0x2692EE2107A8BCFC,
    0xD921539364E848BB, 0xBFBB0037355A313C, 0x303AA10EA1A1B4C2, 0xD37981DA6858F6D8,
    0x6AFAA8080F4B3282, 0x39BB2C389AA33FF8, 0x6669EE8DDEF70BBF, 0x21D9CC4ACA626926,
    0x5B47DFAA75C325DB, 0xF7F390220C99B426, 0x5B1D07A2900A83D5, 0xD7CCC1259E5526EB,
    0xB3B0B7A96BF7884D, 0x40FF77434D087133, 0x8C210667F36FA608, 0xE0EA4D4A9577E127,
    0x10F3AC04260E8616, 0x405DFE51E0EEF9B6, 0x3A27E95E67710143, 0xADE78E0546E539FC,
    0xDE8F33EF43979DF1, 0x802AF2D2376437E3, 0x679CFE92CD023AD9, 0xDC82E76283DC4C08,
    0x98C94E6B3AA7E83D, 0xB86598FE74D7396A, 0xE75A17EAFC5ABC87, 0xBD24FDCE56D4166F,
    0xC674ACFABE3B443A, 0x9D3B7F64D6C71035, 0x155D05517984566E, 0xA310D669E0F0510B,
    0x160EFB654E237FF6, 0xCC402C0AB00A1A6A, 0xD92A4B0A5AB280D4, 0xA9887C970C31ED35,
    0xCA9447EBCEE330CA, 0x768DCB82D4A2B18D, 0x7028116DC8A44676, 0xFE1DA002E69FDA56,
    0x79D087F0742D2C55, 0x0F04017B24C944A5, 0x6561523B282FADD9, 0x6060AE201039E082,
    0x575B97CF14452D06, 0xDF901E7A5A1B6694, 0x20CF2C098273D243, 0xD5024729FAB3B903,
    0x8E771881A1B0460F, 0x55D8034CD0D170AB, 0x01C2A792E9CD902F, 0x1E20776AF967D136,
    0xF07E378B5E366F61, 0xD9D2DC6E8FEF95E4, 0x741922BD9CB3F57A, 0xA379DBC1687554EE,
    0x47A9A10331C2E095, 0x2A0EA02DC1F6E395, 0xDB97797CE0DD715E, 0xD6D6CF017F143E67,
    0xEA0DBA00B2B20877, 0x893CCB7CFF00405F, 0x97C440DCCD6DDAFC, 0xFEAA90892B727623,
    0xEDCEA4BFE988B0A8, 0xB728A7F916D5EC00, 0x13E1D51DFA05636D, 0x8AEF400974FC0707,
    0xA149C32CDF8774FE, 0x0FBDB93A761BF982, 0xADDD934F0AED69B7, 0x91A680196F0B1AA9,
    0x94F489D18997FF15, 0xE8DE8101CF16A5AF, 0x94409AC12663F454, 0xF95FD7899FE08CC7,
    0x510476542D5A83EF, 0x88E1C061191518CC, 0x87AB2FEC3351D9A4, 0x47C04E17E896D142,
    0x853C71808408163C, 0xBB57D210DB10E4AB, 0x57AC49333A940FC0, 0x89EB5DDB06FD0BEB,
    0x3C0A758D94DA73D9, 0xB76383A603B810D1, 0x39237C4B1F2CF83B, 0x3302F1C5711EAF7A,
    0x9B402BF33C9AE5EA, 0xE7AAA76F7E2559A5, 0xCB71970C94555D16, 0x56B8F2D2814D128D,
    0x40C36243DE7FEA10, 0x3103206774B8F8E0, 0xFC5F051B7DFD6622, 0x1615A3E13ED78A79,
    0xBA6D1FCB88576B92, 0x1703743AB31B17CA, 0x2B4744AD4C32AA79, 0xED2B764D4EC841CD,
    0xB0E2495891F7CEAC, 0xAF56EE02DBD67449, 0x2A16069D634C773F, 0x089534B56207CE32,
    0xC1F7411B5AC1C2A1, 0xA267A9D566922D9B, 0x456617AA6CB6BD6D, 0x8B745FB301D6C5F1,
    0x4CED9A5F1AD65800, 0xB0F7DE11FD6CB79C, 0xEAC80EAE2F231162, 0xE86C6D6D36B641A3,
    0x8FA8B25FDD101E56, 0x17FD90456463570D, 0x2A459DEF280428B5, 0x84FF8A8B1C9C7A1E,
    0xC4131B9C46C58F73, 0xC74DA225BEA51135, 0x90C54753D8C2EB8C, 0x3DE7E6BCAF828AC5,
    0x807C608DE42BB460, 0x6FC8B32CD08386AA, 0x6296C7200CA2C8D2, 0x998A95F5D75DD04F,
    0x5B72EEF38E353E39, 0xE563989D4FD74AF2, 0x7DA65433AE511416, 0x495A4D08E8BDA6F3,
    0x251C0FB1CF7DC4BE, 0x20DF590F07E49CA0, 0x54A05DBE6DA42DD7, 0xD846B0E0B454E971,
    0x364499C239E60552, 0x97B24AC50BF1080A, 0xC22F0F3774E65E6D, 0xF5AE335C6A286619,
    0xE5BB5D54BF41B52E, 0x828C9DF52CAD1CB9, 0xACA48D5F26569929, 0xDDC7E30D1EF3A048,
    0xDEDC9C339C3F402C, 0xB5036326DD8D7A7E, 0x7FA89B9DAF2DFF65, 0x269D3BFF05CB599E,
    0xB5B1BFFA10B007B8, 0x3009B729BA8B0136, 0x19B02F619F3A0B64, 0x691452237FD30257,
    0x0878A44A01E9DF91, 0x7EF047F6042B5249, 0xE81C45513F6F915F, 0xB9E4760B60294400,
    0x16776CDECE0B193A, 0x1B9D61DD64D2CF9F, 0x56FCE4A79BC2A22C, 0xBB56A2602F15D473,
    0x3223CFCD1AE02A49, 0x8FE4148FCF8F4E23, 0x8B23C12AF0F1FF9F, 0x71ECDD934D038B22,
    0xD7DC05B9974E993B, 0x7E93610091AAAC16, 0xE131E265162F985C, 0xC3890258DF389EEA,
    0xACE6294D39D61FCF, 0x925E00FF1CD3C77C, 0x02A36DB0D4E31BD0, 0xBFEF09E10E911A8E,
];

/// FastCDC-style normalized-chunking mask spread, off
/// `mask_bits = floor(log2(avg))`: a tighter mask below `avg` and a looser
/// one once past it. 5/5 is the F5.6 tuning phase's recommendation.
const GEAR_DELTA_S: i32 = 5;
const GEAR_DELTA_L: i32 = 5;

/// CDC/dedup tunables, matching the CLI's `--chunk-*` options.
#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub avg: usize,
    pub min_chunk: usize,
    pub max_chunk: usize,
    pub buf_size: usize,
    pub hash_algo: i32,
}

impl Default for Params {
    fn default() -> Self {
        Params {
            avg: DEFAULT_AVG,
            min_chunk: DEFAULT_MIN,
            max_chunk: DEFAULT_MAX,
            buf_size: DEFAULT_BUF_SIZE,
            hash_algo: DEFAULT_CHUNK_HASH,
        }
    }
}

impl Params {
    fn valid(&self) -> bool {
        self.avg != 0 && self.min_chunk != 0 && self.max_chunk >= self.min_chunk
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ChunkRange {
    pub start: usize,
    pub end: usize,
}

// ---------------------------------------------------------------- CDC --

fn gear_log2_floor(mut v: usize) -> i32 {
    let mut bits = 0;
    while v > 1 {
        v >>= 1;
        bits += 1;
    }
    bits
}

/// Full 64-bit avalanche mix of `span` (bytes since the last cut, never
/// the absolute offset, so this does not reintroduce FNV's
/// alignment-dependence). splitmix64-style.
fn gear_mix_span(span: u64) -> u64 {
    let mut x = span;
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51afd7ed558ccd);
    x ^= x >> 33;
    x = x.wrapping_mul(0xc4ceb9fe1a85ec53);
    x ^= x >> 33;
    x
}

fn cdc_split_buffer_fnv(
    data: &[u8],
    buf_lo: usize,
    buf_hi: usize,
    avg: usize,
    min_chunk: usize,
    max_chunk: usize,
    out: &mut Vec<ChunkRange>,
) {
    if buf_lo >= buf_hi {
        return;
    }
    let mask = avg.wrapping_sub(1);
    let use_mask = avg > 0 && (avg & mask) == 0;
    let mut start = buf_lo;
    let mut h: u64 = 0;
    for i in buf_lo..buf_hi {
        h = h.wrapping_mul(CDC_PRIME).wrapping_add(data[i] as u64);
        let span = i - start;
        if span < min_chunk {
            continue;
        }
        if span >= max_chunk {
            out.push(ChunkRange { start, end: i + 1 });
            start = i + 1;
            h = 0;
            continue;
        }
        let boundary = if use_mask {
            (h & mask as u64) == 0
        } else {
            avg > 0 && (h % avg as u64) == 0
        };
        if boundary {
            out.push(ChunkRange { start, end: i + 1 });
            start = i + 1;
            h = 0;
        }
    }
    if start < buf_hi {
        out.push(ChunkRange { start, end: buf_hi });
    }
}

fn cdc_split_buffer_gear(
    data: &[u8],
    buf_lo: usize,
    buf_hi: usize,
    avg: usize,
    min_chunk: usize,
    max_chunk: usize,
    out: &mut Vec<ChunkRange>,
) {
    if buf_lo >= buf_hi {
        return;
    }
    let have_avg = avg > 0;
    let mask_bits = if have_avg { gear_log2_floor(avg) } else { 0 };
    let sb = mask_bits + GEAR_DELTA_S;
    let mask_s: u64 = if sb >= 63 { !0u64 } else { (1u64 << sb) - 1 };
    // Clamped to >= 1: below --chunk-avg=64 a 0-bit mask would make the
    // `span >= avg` test unconditionally true and collapse to
    // near-fixed-size chunking.
    let lb = if mask_bits - GEAR_DELTA_L < 1 {
        1
    } else {
        mask_bits - GEAR_DELTA_L
    };
    let mask_l: u64 = (1u64 << lb) - 1;
    let escape_threshold = (max_chunk / 4) * 3;
    let escape_win_hi = if max_chunk >= 2 {
        max_chunk - 1
    } else {
        escape_threshold + 1
    };

    let mut start = buf_lo;
    let mut h: u64 = 0;
    for i in buf_lo..buf_hi {
        h = (h << 1).wrapping_add(GEAR_TABLE[data[i] as usize]);
        let span = i - start;
        if span < min_chunk {
            continue;
        }
        if span >= max_chunk {
            out.push(ChunkRange { start, end: i + 1 });
            start = i + 1;
            h = 0;
            continue;
        }
        let mut boundary = false;
        if have_avg {
            let (test, m) = if span >= escape_threshold {
                let win_lo = escape_threshold;
                let win_hi = if win_lo < escape_win_hi {
                    escape_win_hi
                } else {
                    win_lo + 1
                };
                let window = win_hi - win_lo;
                let progress = if span > win_lo { span - win_lo } else { 0 };
                let mut start_bits: i64 = 4;
                if lb >= 0 && (lb as i64) < start_bits {
                    start_bits = lb as i64;
                }
                let dec = (progress as u64 * (start_bits as u64 + 1)) / (window as u64 + 1);
                let mut bits = start_bits - dec as i64;
                if bits < 0 {
                    bits = 0;
                }
                let escape_mask: u64 = if bits <= 0 { 0 } else { (1u64 << bits) - 1 };
                (h ^ gear_mix_span(span as u64), escape_mask)
            } else {
                (h, if span < avg { mask_s } else { mask_l })
            };
            boundary = (test & m) == 0;
        }
        if boundary {
            out.push(ChunkRange { start, end: i + 1 });
            start = i + 1;
            h = 0;
        }
    }
    if start < buf_hi {
        out.push(ChunkRange { start, end: buf_hi });
    }
}

fn cdc_split_buffer(
    data: &[u8],
    buf_lo: usize,
    buf_hi: usize,
    p: Params,
    out: &mut Vec<ChunkRange>,
) {
    if p.hash_algo == CDC_HASH_GEAR {
        cdc_split_buffer_gear(data, buf_lo, buf_hi, p.avg, p.min_chunk, p.max_chunk, out);
    } else {
        cdc_split_buffer_fnv(data, buf_lo, buf_hi, p.avg, p.min_chunk, p.max_chunk, out);
    }
}

/// Buffer-bounded CDC: with `buf_size > 0` the rolling hash restarts at
/// every buffer boundary, which is what makes long-range duplicate blocks
/// dedupe cleanly. `buf_size == 0` is a single buffer.
pub fn cdc_split(data: &[u8], p: Params, out: &mut Vec<ChunkRange>) {
    if data.is_empty() {
        return;
    }
    if p.buf_size == 0 {
        cdc_split_buffer(data, 0, data.len(), p, out);
        return;
    }
    let mut lo = 0;
    while lo < data.len() {
        let hi = (lo + p.buf_size).min(data.len());
        cdc_split_buffer(data, lo, hi, p, out);
        lo += p.buf_size;
    }
}

// -------------------------------------------------------------- hashes --

#[inline]
fn read_word_le(p: &[u8]) -> u64 {
    let mut w = [0u8; 8];
    w.copy_from_slice(&p[..8]);
    u64::from_le_bytes(w)
}

/// `memcpy(&tail, p, n)` for n < 8: little-endian, zero-padded.
#[inline]
fn read_tail_le(p: &[u8]) -> u64 {
    debug_assert!(p.len() < 8);
    let mut t = [0u8; 8];
    t[..p.len()].copy_from_slice(p);
    u64::from_le_bytes(t)
}

/// 64-bit word-at-a-time hash over chunk bytes. In-memory dedup key only,
/// never emitted, so it may use unaligned little-endian reads freely.
fn chunk_hash(p: &[u8]) -> u64 {
    let n = p.len();
    let mut h: u64 = 0x9E3779B97F4A7C15;
    let mut i = 0;
    while i + 8 <= n {
        h ^= read_word_le(&p[i..]);
        h = h.wrapping_mul(0x9E3779B97F4A7C15);
        h ^= h >> 32;
        i += 8;
    }
    h ^= read_tail_le(&p[i..n]);
    h = h.wrapping_mul(0xC2B2AE3D27D4EB4F);
    h ^= h >> 29;
    h
}

/// Second, independent 64-bit mix. Paired with `chunk_hash` it forms the
/// 128-bit dedup key the streaming encoder uses, so a collision can no
/// longer map silently to the wrong `ref_index` (the C++ port's fix;
/// `--dup-paranoid` still layers an explicit byte-compare on top).
fn chunk_hash_alt(p: &[u8]) -> u64 {
    let n = p.len();
    let mut h: u64 = 0xD1B54A32D192ED03;
    let mut i = 0;
    while i + 8 <= n {
        h ^= read_word_le(&p[i..]).wrapping_mul(0xC2B2AE3D27D4EB4F);
        h = (h << 27) | (h >> 37);
        h = h.wrapping_mul(0x165667B19E3779F9);
        i += 8;
    }
    h ^= read_tail_le(&p[i..n]);
    h = h.wrapping_mul(0x9E3779B97F4A7C15);
    h ^= h >> 31;
    h
}

// --------------------------------------------------------------- codec --

#[inline]
fn put_u32_le(out: &mut [u8], v: u32) {
    out[..4].copy_from_slice(&v.to_le_bytes());
}

#[inline]
fn put_u64_le(out: &mut [u8], v: u64) {
    out[..8].copy_from_slice(&v.to_le_bytes());
}

#[inline]
fn get_u32_le(p: &[u8]) -> u32 {
    u32::from_le_bytes([p[0], p[1], p[2], p[3]])
}

#[inline]
fn get_u64_le(p: &[u8]) -> u64 {
    let mut w = [0u8; 8];
    w.copy_from_slice(&p[..8]);
    u64::from_le_bytes(w)
}

/// LEB128 unsigned varint. Returns bytes written.
fn varint_encode(mut value: u64, out: &mut [u8]) -> usize {
    let mut n = 0;
    while value >= 0x80 {
        out[n] = ((value & 0x7F) as u8) | 0x80;
        value >>= 7;
        n += 1;
    }
    out[n] = value as u8;
    n + 1
}

fn varint_decode(p: &[u8]) -> Result<(u64, usize), i32> {
    let mut result: u64 = 0;
    let mut shift = 0;
    for (n, &b) in p.iter().enumerate() {
        result |= ((b & 0x7F) as u64) << shift;
        if b & 0x80 == 0 {
            return Ok((result, n + 1));
        }
        shift += 7;
        if shift > 63 {
            return Err(DEDUP_ERR_BAD_VARINT);
        }
    }
    Err(DEDUP_ERR_TRUNCATED)
}

#[derive(Clone, Copy)]
struct Rec {
    tag: u8,
    payload: u64,
}

/// Parse and validate the meta header + chunk table.
fn parse_meta(meta: &[u8]) -> Result<(Vec<Rec>, u64), i32> {
    if meta.len() < HEADER_SIZE {
        return Err(DEDUP_ERR_TRUNCATED);
    }
    if get_u32_le(meta) != MAGIC {
        return Err(DEDUP_ERR_BAD_MAGIC);
    }
    if get_u32_le(&meta[4..]) != VERSION {
        return Err(DEDUP_ERR_BAD_VER);
    }
    let chunk_count = get_u64_le(&meta[8..]);
    let unique_count = get_u64_le(&meta[16..]);

    // Each record is at least 2 bytes (tag + 1-byte varint), so
    // chunk_count cannot exceed the remaining size. Without this a
    // corrupted UINT64_MAX allocates unboundedly.
    if chunk_count > (meta.len() - HEADER_SIZE) as u64 / 2 {
        return Err(DEDUP_ERR_TRUNCATED);
    }
    if unique_count > chunk_count {
        return Err(DEDUP_ERR_BAD_REF);
    }

    let mut records: Vec<Rec> = Vec::with_capacity(chunk_count as usize);
    let mut pos = HEADER_SIZE;
    for _ in 0..chunk_count {
        if pos >= meta.len() {
            return Err(DEDUP_ERR_TRUNCATED);
        }
        let tag = meta[pos];
        pos += 1;
        let payload = match tag {
            TAG_UNIQUE => {
                if pos + 4 > meta.len() {
                    return Err(DEDUP_ERR_TRUNCATED);
                }
                let v = get_u32_le(&meta[pos..]) as u64;
                pos += 4;
                v
            }
            TAG_REF => {
                let (v, consumed) = varint_decode(&meta[pos..])?;
                if v >= unique_count {
                    return Err(DEDUP_ERR_BAD_REF);
                }
                pos += consumed;
                v
            }
            _ => return Err(DEDUP_ERR_BAD_TAG),
        };
        records.push(Rec { tag, payload });
    }
    Ok((records, unique_count))
}

// ----------------------------------------------------------- in-memory --

/// Encode `data` into a freshly built `.dupref` blob (header + table +
/// body). Full-buffer: every candidate duplicate is byte-compared.
pub fn encode(data: &[u8], p: Params) -> Result<Vec<u8>, i32> {
    if !p.valid() {
        return Err(DEDUP_ERR_INVAL);
    }

    let mut chunks: Vec<ChunkRange> = Vec::new();
    cdc_split(data, p, &mut chunks);

    let mut records: Vec<Rec> = Vec::with_capacity(chunks.len());
    let mut unique_chunks: Vec<ChunkRange> = Vec::with_capacity(chunks.len());
    let mut seen: HashMap<u64, u64> = HashMap::with_capacity(chunks.len() * 2);

    for c in &chunks {
        let clen = c.end - c.start;
        let cp = &data[c.start..c.end];
        let h = chunk_hash(cp);
        if let Some(&uidx) = seen.get(&h) {
            let u = unique_chunks[uidx as usize];
            let ulen = u.end - u.start;
            if ulen == clen && data[u.start..u.end] == *cp {
                records.push(Rec { tag: TAG_REF, payload: uidx });
                continue;
            }
            // hash collision (different bytes): fall through, overwrite seen[h]
        }
        seen.insert(h, unique_chunks.len() as u64);
        records.push(Rec { tag: TAG_UNIQUE, payload: clen as u64 });
        unique_chunks.push(*c);
    }

    let mut table_size = 0usize;
    for r in &records {
        table_size += 1;
        if r.tag == TAG_UNIQUE {
            table_size += 4;
        } else {
            let mut v = r.payload;
            loop {
                table_size += 1;
                v >>= 7;
                if v == 0 {
                    break;
                }
            }
        }
    }
    let body_size: usize = unique_chunks.iter().map(|c| c.end - c.start).sum();
    let mut out = vec![0u8; HEADER_SIZE + table_size + body_size];

    put_u32_le(&mut out, MAGIC);
    put_u32_le(&mut out[4..], VERSION);
    put_u64_le(&mut out[8..], chunks.len() as u64);
    put_u64_le(&mut out[16..], unique_chunks.len() as u64);

    let mut pos = HEADER_SIZE;
    for r in &records {
        out[pos] = r.tag;
        pos += 1;
        if r.tag == TAG_UNIQUE {
            put_u32_le(&mut out[pos..], r.payload as u32);
            pos += 4;
        } else {
            let mut tmp = [0u8; 10];
            let n = varint_encode(r.payload, &mut tmp);
            out[pos..pos + n].copy_from_slice(&tmp[..n]);
            pos += n;
        }
    }
    for c in &unique_chunks {
        out[pos..pos + (c.end - c.start)].copy_from_slice(&data[c.start..c.end]);
        pos += c.end - c.start;
    }
    Ok(out)
}

/// Decode a whole `.dupref` blob (header + table + body in one buffer).
pub fn decode(blob: &[u8]) -> Result<Vec<u8>, i32> {
    let (records, unique_count) = parse_meta(blob)?;

    let mut unique_chunks: Vec<ChunkRange> = Vec::with_capacity(unique_count as usize);
    let mut pos = {
        // The table ends where parse_meta stopped; recompute it the same
        // way the C++ does (walk the table again) to stay byte-identical.
        let mut p = HEADER_SIZE;
        for r in &records {
            p += 1;
            if r.tag == TAG_UNIQUE {
                p += 4;
            } else {
                let (_, consumed) = varint_decode(&blob[p..])?;
                p += consumed;
            }
        }
        p
    };
    for r in &records {
        if r.tag != TAG_UNIQUE {
            continue;
        }
        let ulen = r.payload as usize;
        if pos + ulen > blob.len() {
            return Err(DEDUP_ERR_TRUNCATED);
        }
        unique_chunks.push(ChunkRange { start: pos, end: pos + ulen });
        pos += ulen;
    }
    if unique_chunks.len() as u64 != unique_count {
        return Err(DEDUP_ERR_BAD_BODY);
    }

    let mut out_total = 0usize;
    {
        let mut next_unique = 0usize;
        for r in &records {
            let u = if r.tag == TAG_UNIQUE {
                let u = unique_chunks[next_unique];
                next_unique += 1;
                u
            } else {
                unique_chunks[r.payload as usize]
            };
            out_total += u.end - u.start;
        }
    }

    let mut out = vec![0u8; out_total];
    let mut opos = 0usize;
    let mut next_unique = 0usize;
    for r in &records {
        let src = if r.tag == TAG_UNIQUE {
            let u = unique_chunks[next_unique];
            next_unique += 1;
            u
        } else {
            unique_chunks[r.payload as usize]
        };
        let n = src.end - src.start;
        out[opos..opos + n].copy_from_slice(&blob[src.start..src.end]);
        opos += n;
    }
    Ok(out)
}

/// Split form: `(meta, body)`. The body is the only piece worth feeding
/// to SREP; the meta becomes the archive's ODUP trailer.
pub fn encode_split(data: &[u8], p: Params) -> Result<(Vec<u8>, Vec<u8>), i32> {
    let full = encode(data, p)?;
    if full.len() < HEADER_SIZE {
        return Err(DEDUP_ERR_TRUNCATED);
    }
    let chunk_count = get_u64_le(&full[8..]);
    let mut pos = HEADER_SIZE;
    for _ in 0..chunk_count {
        if pos >= full.len() {
            return Err(DEDUP_ERR_TRUNCATED);
        }
        let tag = full[pos];
        pos += 1;
        match tag {
            TAG_UNIQUE => {
                if pos + 4 > full.len() {
                    return Err(DEDUP_ERR_TRUNCATED);
                }
                pos += 4;
            }
            TAG_REF => {
                let (_, consumed) = varint_decode(&full[pos..])?;
                pos += consumed;
            }
            _ => return Err(DEDUP_ERR_BAD_TAG),
        }
    }
    Ok((full[..pos].to_vec(), full[pos..].to_vec()))
}

/// Inverse of `encode_split`: meta + post-SREP body -> original input.
pub fn decode_split(meta: &[u8], body: &[u8]) -> Result<Vec<u8>, i32> {
    let mut full = Vec::with_capacity(meta.len() + body.len());
    full.extend_from_slice(meta);
    full.extend_from_slice(body);
    decode(&full)
}

// ------------------------------------------------------------ streaming --

/// Streaming encoder: reads `in_path` in `buf_size`-sized chunks, runs
/// CDC + dedup on each, writes unique chunks to `body_path` as they are
/// decided, and keeps only the chunk table in memory. Returns the meta
/// blob. This is the API `osrep -dup` uses.
///
/// `paranoid` adds an explicit byte-compare against the already-written
/// body on every hit (one seek + read per dedup hit); the default path
/// already keys on a 128-bit tag.
pub fn encode_streaming(
    in_path: &Path,
    body_path: &Path,
    p: Params,
    paranoid: bool,
) -> Result<Vec<u8>, i32> {
    if !p.valid() {
        return Err(DEDUP_ERR_INVAL);
    }

    let mut fi = File::open(in_path).map_err(|_| DEDUP_ERR_INVAL)?;
    let mut fb = if paranoid {
        OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(body_path)
    } else {
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(body_path)
    }
    .map_err(|_| DEDUP_ERR_INVAL)?;

    let effective_buf = if p.buf_size > 0 {
        p.buf_size
    } else {
        8 * 1024 * 1024
    };

    let mut work = vec![0u8; effective_buf];
    let mut records: Vec<Rec> = Vec::new();
    let mut seen: HashMap<(u64, u64), u64> = HashMap::new();
    let mut unique_count: u64 = 0;
    let mut unique_off: Vec<u64> = Vec::new();
    let mut unique_len: Vec<u32> = Vec::new();
    let mut cmp_buf: Vec<u8> = Vec::new();
    let mut body_pos: u64 = 0;

    loop {
        let got = fi.read(&mut work).map_err(|_| DEDUP_ERR_INVAL)?;
        if got == 0 {
            break;
        }

        let mut chunks: Vec<ChunkRange> = Vec::new();
        cdc_split_buffer(&work, 0, got, p, &mut chunks);

        for c in &chunks {
            let clen = c.end - c.start;
            let cp = &work[c.start..c.end];
            let key = (chunk_hash(cp), chunk_hash_alt(cp));
            let mut is_dup = seen.get(&key).copied();

            if paranoid {
                if let Some(uidx) = is_dup {
                    let off = unique_off[uidx as usize];
                    let ulen = unique_len[uidx as usize];
                    if ulen as usize != clen {
                        is_dup = None;
                    } else {
                        if cmp_buf.len() < clen {
                            cmp_buf.resize(clen, 0);
                        }
                        fb.flush().map_err(|_| DEDUP_ERR_INVAL)?;
                        fb.seek(SeekFrom::Start(off)).map_err(|_| DEDUP_ERR_INVAL)?;
                        fb.read_exact(&mut cmp_buf[..clen]).map_err(|_| DEDUP_ERR_INVAL)?;
                        fb.seek(SeekFrom::Start(body_pos)).map_err(|_| DEDUP_ERR_INVAL)?;
                        if cmp_buf[..clen] != *cp {
                            is_dup = None;
                        }
                    }
                }
            }

            if let Some(uidx) = is_dup {
                records.push(Rec { tag: TAG_REF, payload: uidx });
                continue;
            }
            seen.insert(key, unique_count);
            records.push(Rec { tag: TAG_UNIQUE, payload: clen as u64 });
            if paranoid {
                unique_off.push(body_pos);
                unique_len.push(clen as u32);
            }
            fb.write_all(cp).map_err(|_| DEDUP_ERR_INVAL)?;
            body_pos += clen as u64;
            unique_count += 1;
        }

        if got < effective_buf {
            break;
        }
    }
    fb.flush().map_err(|_| DEDUP_ERR_INVAL)?;

    let mut table_size = 0usize;
    for r in &records {
        table_size += 1;
        if r.tag == TAG_UNIQUE {
            table_size += 4;
        } else {
            let mut v = r.payload;
            loop {
                table_size += 1;
                v >>= 7;
                if v == 0 {
                    break;
                }
            }
        }
    }
    let mut meta = vec![0u8; HEADER_SIZE + table_size];
    put_u32_le(&mut meta, MAGIC);
    put_u32_le(&mut meta[4..], VERSION);
    put_u64_le(&mut meta[8..], records.len() as u64);
    put_u64_le(&mut meta[16..], unique_count);

    let mut pos = HEADER_SIZE;
    for r in &records {
        meta[pos] = r.tag;
        pos += 1;
        if r.tag == TAG_UNIQUE {
            put_u32_le(&mut meta[pos..], r.payload as u32);
            pos += 4;
        } else {
            let mut tmp = [0u8; 10];
            let n = varint_encode(r.payload, &mut tmp);
            meta[pos..pos + n].copy_from_slice(&tmp[..n]);
            pos += n;
        }
    }
    Ok(meta)
}

/// Streaming decoder: meta in memory, body read sequentially from
/// `body_path`, records expanded into `out_path`. On a ref it seeks back
/// into the output file (already written once) and copies forward, so
/// peak RAM stays independent of the input size.
///
/// A ref must point at a chunk that has already been seen: `unique_slots`
/// only grows as uniques appear, so a corrupt meta whose first record is
/// a ref is rejected here rather than indexing past a 0-length table.
pub fn decode_streaming(meta: &[u8], body_path: &Path, out_path: &Path) -> Result<(), i32> {
    let (records, _unique_count) = parse_meta(meta)?;

    let mut fb = File::open(body_path).map_err(|_| DEDUP_ERR_INVAL)?;
    let mut fo = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(out_path)
        .map_err(|_| DEDUP_ERR_INVAL)?;

    // (offset in the output file, length) per unique chunk, in order.
    let mut unique_slots: Vec<(u64, u32)> = Vec::new();
    let mut out_pos: u64 = 0;
    let mut io_buf = vec![0u8; 64 * 1024];

    for r in &records {
        if r.tag == TAG_UNIQUE {
            let mut need = r.payload as usize;
            while need > 0 {
                let take = need.min(io_buf.len());
                fb.read_exact(&mut io_buf[..take]).map_err(|_| DEDUP_ERR_TRUNCATED)?;
                fo.write_all(&io_buf[..take]).map_err(|_| DEDUP_ERR_INVAL)?;
                need -= take;
            }
            unique_slots.push((out_pos, r.payload as u32));
            out_pos += r.payload;
        } else {
            let uidx = r.payload as usize;
            if uidx >= unique_slots.len() {
                return Err(DEDUP_ERR_BAD_REF);
            }
            let (mut read_at, len) = unique_slots[uidx];
            let mut write_at = out_pos;
            let mut remaining = len as usize;
            while remaining > 0 {
                let take = remaining.min(io_buf.len());
                fo.seek(SeekFrom::Start(read_at)).map_err(|_| DEDUP_ERR_INVAL)?;
                fo.read_exact(&mut io_buf[..take]).map_err(|_| DEDUP_ERR_TRUNCATED)?;
                fo.seek(SeekFrom::Start(write_at)).map_err(|_| DEDUP_ERR_INVAL)?;
                fo.write_all(&io_buf[..take]).map_err(|_| DEDUP_ERR_INVAL)?;
                read_at += take as u64;
                write_at += take as u64;
                remaining -= take;
            }
            out_pos = write_at;
        }
    }
    fo.flush().map_err(|_| DEDUP_ERR_INVAL)?;
    Ok(())
}
