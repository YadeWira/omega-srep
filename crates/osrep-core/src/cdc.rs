//! Content-defined chunking (`compress_cdc.cpp`) for `-m1`/`-m2`.
//!
//! The block is split at points where a rolling hash of the last `WINSIZE`
//! bytes crosses a threshold (~one per `L` bytes), and each chunk is looked up
//! in the hash table by a 32-byte VMAC pair: the first 20 bytes are the chunk
//! digest and the 8 after it are the table index.
//!
//! Two boundary hashes exist and the C++ picks between them at *runtime*:
//! `crc32c()` (`hashes.cpp:226`) selects `CrcRollingHash<uint32>` (the hardware
//! instruction is present on every SSE4.2 x86) and falls back to
//! `PolynomialRollingHash<uint64>`. The 4c-0 experiment showed they produce
//! different archives, so both are ported and the choice is made the same way.
//!
//! The C++ overlaps stripes across worker threads and processes each stripe's
//! chunks in order; the port runs the stripes sequentially, which is
//! output-identical (`docs/rust-port.md`, 4c-0).
//!
//! `OSREP_CDC_POLY=1` forces the polynomial route even on an SSE4.2 CPU. It is
//! a test hook, in the same spirit as the C++'s `OSREP_SEED_HEX`: the fallback
//! is otherwise unreachable on any modern machine, and the two routes really do
//! produce different archives.

use crate::hash_table::HashTable;
use crate::lz::{self, EncodeError};
use crate::rolling::{CrcRollingHash, PolynomialRollingHash, CRC32_CASTAGNOLI_POLYNOM, PRIME1};
use crate::vmac::{Vmac, VMAC_KEY_LEN_BYTES, VMAC_TAG_LEN_BYTES};

/// `STRIPE` (`compress_cdc.cpp:96`).
pub const STRIPE: usize = 116 * 1024;
/// `WINSIZE` (`compress_cdc.cpp:98`).
pub const WINSIZE: usize = 48;
/// `MINIMAL_MIN_MATCH` (`srep.cpp:41`): the floor CDC clamps `MIN_MATCH` to.
pub const MINIMAL_MIN_MATCH: usize = 16;
/// `2*VMAC_TAG_LEN_BYTES` is what one chunk's hashes occupy.
const VHASH_BYTES: usize = 2 * VMAC_TAG_LEN_BYTES;

/// A boundary hash, normalised to `u64` so one loop drives either width.
trait BoundaryHash: Clone {
    /// `HashType(-1)`: `maxhash = MAX - MAX / L` is the ~1/L test.
    const MAX: u64;
    fn moveto(&mut self, buf: &[u8], off: usize);
    fn update(&mut self, sub: u8, add: u8) -> u64;
}

#[derive(Clone)]
struct PolyBoundary(PolynomialRollingHash);

impl BoundaryHash for PolyBoundary {
    const MAX: u64 = u64::MAX;
    fn moveto(&mut self, buf: &[u8], off: usize) {
        self.0.moveto(&buf[off..]);
    }
    fn update(&mut self, sub: u8, add: u8) -> u64 {
        self.0.update(sub, add);
        self.0.value
    }
}

#[derive(Clone)]
struct CrcBoundary(CrcRollingHash);

impl BoundaryHash for CrcBoundary {
    const MAX: u64 = u32::MAX as u64;
    fn moveto(&mut self, buf: &[u8], off: usize) {
        self.0.moveto(&buf[off..]);
    }
    fn update(&mut self, sub: u8, add: u8) -> u64 {
        self.0.update(sub, add);
        self.0.value as u64
    }
}

/// `fast_find_chunks_in_3_streams` (`compress_cdc.cpp:9-24`): three interleaved
/// scans over one stripe, which is why the marks come out unsorted.
fn find_chunks_in_3_streams<H: BoundaryHash>(
    buf: &[u8],
    ptr: usize,
    piece: usize,
    maxhash: u64,
    min_match: usize,
    hash: &H,
    marks: &mut Vec<usize>,
) {
    let mut lastp = [ptr, ptr + piece, ptr + 2 * piece];
    let mut streams = [hash.clone(), hash.clone(), hash.clone()];
    for (s, start) in streams.iter_mut().zip(lastp.iter()) {
        s.moveto(buf, *start);
    }

    let mut p = ptr + WINSIZE;
    let pend = ptr + piece;
    while p < pend {
        for s in 0..3 {
            let base = p + s * piece;
            let value = streams[s].update(buf[base - WINSIZE], buf[base]);
            if value > maxhash && base - lastp[s] >= min_match {
                marks.push(base);
                lastp[s] = base;
            }
        }
        p += 1;
    }
}

/// `fast_find_chunks` (`compress_cdc.cpp:28-56`). Returns the advanced `ptr`.
fn fast_find_chunks<H: BoundaryHash>(
    buf: &[u8],
    ptr: usize,
    pend: usize,
    bufend: usize,
    marks: &mut Vec<usize>,
    l: usize,
    min_match: usize,
    hash: &H,
) -> usize {
    let maxhash = H::MAX - H::MAX / l as u64;
    let mut ptr = ptr;
    if pend - ptr >= STRIPE / 3 * 3 {
        let piece = STRIPE / 3;
        find_chunks_in_3_streams(buf, ptr, piece, maxhash, min_match, hash, marks);
        marks.sort_unstable();
        ptr += STRIPE / 3 * 3;
    } else {
        if pend - ptr >= WINSIZE {
            let mut lastp = ptr;
            let mut h = hash.clone();
            h.moveto(buf, lastp);
            let mut p = ptr + WINSIZE;
            while p < pend {
                let value = h.update(buf[p - WINSIZE], buf[p]);
                if value > maxhash && p - lastp >= min_match {
                    marks.push(p);
                    lastp = p;
                }
                p += 1;
            }
        }
        ptr = pend;
    }
    if pend == bufend {
        marks.push(bufend);
    }
    ptr
}

/// `zpaq_find_chunks` (`compress_cdc.cpp:60-88`): an order-1 model decides which
/// bytes are mispredicted, and a rolling hash over those picks the boundaries.
fn zpaq_find_chunks(
    buf: &[u8],
    ptr: usize,
    pend: usize,
    bufend: usize,
    marks: &mut Vec<usize>,
    l: usize,
    min_match: usize,
) -> usize {
    let maxhash = u32::MAX as u64 - (u32::MAX as u64) / l as u64;
    let mut hash: u32 = 0;
    let mut c1: u8 = 0;
    let mut o1 = [0u8; 256];

    // Modelling starts up to 8000 bytes before the stripe.
    let start = if ptr > 8000 { ptr - 8000 } else { 0 };
    let mut lastp = start;
    let mut p = start;
    while p < pend {
        let c = buf[p];
        hash = (hash.wrapping_add(c as u32).wrapping_add(1))
            .wrapping_mul(if c != o1[c1 as usize] {
                271828182
            } else {
                314159265
            });
        o1[c1 as usize] = c;
        c1 = c;
        if hash as u64 > maxhash && p - lastp >= min_match {
            // The stripe's first chunk may be shorter than MIN_MATCH; it gets
            // filtered out just before the match is emitted.
            if p > ptr {
                marks.push(p);
            }
            lastp = p;
            c1 = 0;
            hash = 0;
            o1 = [0u8; 256];
        }
        p += 1;
    }
    if pend == bufend {
        marks.push(bufend);
    }
    pend
}

/// The two VMAC instances every chunk is hashed with (`CDC_Thread::vhash1/2`).
/// Like `-m3`'s digests, the C++ keys them from the PRNG and never stores them
/// — they are only compared for equality — so the port pins them to zeroes.
pub struct CdcChunkHasher {
    vhash1: Vmac,
    vhash2: Vmac,
}

impl Default for CdcChunkHasher {
    fn default() -> Self {
        Self::new()
    }
}

impl CdcChunkHasher {
    pub fn new() -> CdcChunkHasher {
        let key = [0u8; VMAC_KEY_LEN_BYTES];
        CdcChunkHasher {
            vhash1: Vmac::new(&key),
            vhash2: Vmac::new(&key),
        }
    }

    /// `compute_single_chunk_hash` (`compress_cdc.cpp:109-113`): vhash1 at offset
    /// 0, vhash2 at 16 -- *not* the overlapping `VDigest` layout, because the
    /// table also wants a 64-bit index out of the same 32 bytes.
    pub fn chunk_hashes(&self, chunk: &[u8]) -> [u8; VHASH_BYTES] {
        let mut out = [0u8; VHASH_BYTES];
        out[..VMAC_TAG_LEN_BYTES].copy_from_slice(&self.vhash1.compute(chunk));
        out[VMAC_TAG_LEN_BYTES..].copy_from_slice(&self.vhash2.compute(chunk));
        out
    }
}

/// `compress_CDC` (`compress_cdc.cpp:176-217`).
///
/// Emits the block's match records through `stat` and the literal total through
/// `literal_bytes`, exactly like the single-threaded reading of the C++'s
/// stripe pool.
#[allow(clippy::too_many_arguments)]
pub fn compress_cdc(
    zpaq: bool,
    l: usize,
    min_match_in: usize,
    block_start: u64,
    h: &mut HashTable,
    buf: &[u8],
    block_size: usize,
    literal_bytes: &mut u32,
    stat: &mut Vec<u32>,
    chunk_hasher: &CdcChunkHasher,
) -> Result<(), EncodeError> {
    let mut min_match = min_match_in;
    if min_match < MINIMAL_MIN_MATCH {
        min_match = MINIMAL_MIN_MATCH;
    }
    *literal_bytes = 0;
    let bufend = block_size;

    // Created once per block, exactly like the C++'s locals.
    let poly = PolyBoundary(PolynomialRollingHash::new(WINSIZE, PRIME1));
    let crc = CrcBoundary(CrcRollingHash::new(WINSIZE, CRC32_CASTAGNOLI_POLYNOM));

    let mut last_match = 0usize;
    let mut last_chunk = 0usize;
    let mut ptr = 0usize;

    while ptr < bufend {
        let pend = if bufend - ptr < STRIPE {
            bufend
        } else {
            ptr + STRIPE
        };

        let mut marks: Vec<usize> = Vec::new();
        if zpaq {
            zpaq_find_chunks(buf, ptr, pend, bufend, &mut marks, l, min_match);
        } else if crate::rolling::crc32c() && std::env::var_os("OSREP_CDC_POLY").is_none() {
            fast_find_chunks(buf, ptr, pend, bufend, &mut marks, l, min_match, &crc);
        } else {
            fast_find_chunks(buf, ptr, pend, bufend, &mut marks, l, min_match, &poly);
        }

        // The chunks this stripe ends: the first one starts in the previous
        // stripe (or the block), the rest run mark to mark.
        let mut vhashes: Vec<[u8; VHASH_BYTES]> = Vec::with_capacity(marks.len());
        if let Some(&first) = marks.first() {
            vhashes.push(chunk_hasher.chunk_hashes(&buf[last_chunk..first]));
            for i in 0..marks.len() - 1 {
                vhashes.push(chunk_hasher.chunk_hashes(&buf[marks[i]..marks[i + 1]]));
            }
        }

        for (idx, &mark) in marks.iter().enumerate() {
            let len = mark - last_chunk;
            let match_offset =
                h.find_match_cdc(block_start + last_chunk as u64, len, &vhashes[idx]);
            if match_offset != 0 && len >= min_match {
                lz::encode_lz_match(
                    stat,
                    false,
                    min_match as u32,
                    (last_chunk - last_match) as u32,
                    match_offset,
                    len as u32,
                )?;
                last_match = mark;
            } else {
                *literal_bytes += len as u32;
            }
            last_chunk = mark;
        }

        ptr = pend;
    }
    Ok(())
}
