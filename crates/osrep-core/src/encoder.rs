//! The compression driver: what `srep.cpp`'s first pass does around the
//! per-mode compressors, and what `io.cpp`'s background thread does for it.
//!
//! The C++ overlaps reading a block with compressing the previous one through
//! a two-slot ring and two events. Both orderings produce the same bytes — the
//! 4c-0 `-t1`/`-t8` experiment in `docs/rust-port.md` is what established that
//! the interleaving is output-invisible — so the port runs the same steps
//! sequentially. The block layout written here is `save_data`'s
//! (`io.cpp:282-307`): block header, digest, match list, then the literal runs
//! the records interleave with.
//!
//! Only the single-pass I/O-LZ path is driven today (format v2 through
//! `-m0o`); the Future/Index-LZ second pass lands with phase 4c-5.

use std::io::{Read, Write};

use crate::container::{self, ArchiveHeader, BlockHeader, HashInfo, Version};
use crate::inmem::DictionaryCompressor;
use crate::lz;
use crate::{hashes, hashes_keyed, vmac};

/// `-b` default (`srep.cpp:288`).
pub const DEFAULT_BUFSIZE: usize = 8 * 1024 * 1024;
/// `-d` default for `-m0` (`srep.cpp:285,445`).
pub const DEFAULT_DICTSIZE: u64 = 512 * 1024 * 1024;
/// `BUFFERS` (`io.cpp:90`): the ring carries two extra blocks of headroom.
const BUFFERS: usize = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EncodeError {
    Io,
    /// The encoder produced a match shorter than `BASE_LEN`, which the record
    /// shape cannot encode (the C++ aborts through `error()`,
    /// `srep.cpp:121`).
    MatchTooSmall { match_len: u32, base_len: u32 },
    /// A block's own match list did not decode back into the literal layout.
    BadBlockRecord,
    /// A keyed hash needs `--seed=N`: without it the C++ draws the key from
    /// Fortuna, which no port can reproduce.
    NeedsSeed,
    UnknownHash(String),
}

impl From<std::io::Error> for EncodeError {
    fn from(_: std::io::Error) -> Self {
        EncodeError::Io
    }
}

impl From<lz::EncodeError> for EncodeError {
    fn from(e: lz::EncodeError) -> Self {
        match e {
            lz::EncodeError::MatchTooSmall { match_len, base_len } => {
                EncodeError::MatchTooSmall { match_len, base_len }
            }
        }
    }
}

impl From<lz::DecodeError> for EncodeError {
    fn from(_: lz::DecodeError) -> Self {
        EncodeError::BadBlockRecord
    }
}

/// Everything the driver needs besides the input. Defaults mirror the option
/// defaults in `srep.cpp`.
pub struct EncodeOptions {
    /// `-b` (block size).
    pub bufsize: usize,
    /// `-d` (dictionary size; 0 disables the in-memory pass).
    pub dictsize: u64,
    /// `-dh` (dictionary hash-table size hint; 0 = derive).
    pub dict_hashsize: u64,
    /// `-l` (minimum match); 0 = the mode's default.
    pub min_match: usize,
    /// `-dl` (dictionary minimum match); 0 = 512. Feeds `BASE_LEN` and is the
    /// minimum match the in-memory pass accepts.
    pub dict_min_match: usize,
    /// `-dc` (dictionary chunk = the in-memory pass's hash window); 0 =
    /// `dict_min_match / 8` (`srep.cpp:456`). Note this is *not* `-c`: the
    /// compressor is built as `DictionaryCompressor(dictsize, dict_hashsize,
    /// dict_min_match, dict_chunk, BASE_LEN, ...)` (`srep.cpp:663`), so its
    /// window comes from `-dc`, not from `-c`.
    pub dict_chunk: usize,
    /// `-c` (hash window); 0 = derive from `min_match`.
    pub l: usize,
    /// `--seed=N`: derive the per-archive hash key instead of drawing it from
    /// the PRNG.
    pub seed: Option<u64>,
    /// `-hash=` name; empty selects disabled checksums (`-hash-`).
    pub hash: String,
}

impl Default for EncodeOptions {
    fn default() -> Self {
        EncodeOptions {
            bufsize: DEFAULT_BUFSIZE,
            dictsize: 0,
            dict_hashsize: 0,
            min_match: 0,
            dict_min_match: 0,
            dict_chunk: 0,
            l: 0,
            seed: None,
            hash: container::DEFAULT_HASH_NAME.to_string(),
        }
    }
}

/// The per-block checksum, keyed with the archive's seed (`hash_obj` in the
/// C++). Keyed variants hold their key; the unkeyed ones hash per call,
/// exactly like `compute_md5` &c.
pub enum BlockHasher {
    Disabled,
    Md5,
    Sha1,
    Sha512,
    Vmac(vmac::Vmac),
    SipHash([u8; hashes_keyed::SIPHASH_KEY_LEN_BYTES]),
}

impl BlockHasher {
    pub fn new(hash: &'static HashInfo, seed: &[u8]) -> BlockHasher {
        match hash.name {
            "" => BlockHasher::Disabled,
            "md5" => BlockHasher::Md5,
            "sha1" => BlockHasher::Sha1,
            "sha512" => BlockHasher::Sha512,
            "vmac" => {
                let mut key = [0u8; vmac::VMAC_KEY_LEN_BYTES];
                key.copy_from_slice(seed);
                BlockHasher::Vmac(vmac::Vmac::new(&key))
            }
            "siphash" => {
                let mut key = [0u8; hashes_keyed::SIPHASH_KEY_LEN_BYTES];
                key.copy_from_slice(seed);
                BlockHasher::SipHash(key)
            }
            _ => BlockHasher::Disabled,
        }
    }

    /// `hash_func(hash_obj, buf, size, header+3)` (`io.cpp:261-262`). The
    /// disabled variant never runs in the C++ — the header is `calloc`'d, so
    /// the digest bytes stay zero — and the port reproduces that.
    pub fn compute(&mut self, data: &[u8]) -> Option<Vec<u8>> {
        match self {
            BlockHasher::Disabled => None,
            BlockHasher::Md5 => Some(hashes::md5(data).to_vec()),
            BlockHasher::Sha1 => Some(hashes::sha1(data).to_vec()),
            BlockHasher::Sha512 => Some(hashes::sha512(data).to_vec()),
            BlockHasher::Vmac(v) => Some(v.compute(data).to_vec()),
            BlockHasher::SipHash(k) => Some(hashes_keyed::siphash(k, data).to_vec()),
        }
    }
}

/// `osrep_fill_seed_from` (`srep.cpp:251-261`): xorshift64 over the seed
/// value, one byte at a time. `--seed=0` degenerates to all zeroes, which the
/// C++ calls legal.
pub fn fill_seed_from(out: &mut [u8], seed64: u64) {
    let mut s = seed64;
    for b in out.iter_mut() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        *b = (s & 0xFF) as u8;
    }
}

/// `-m0o`: the in-memory REP match finder through the single-pass I/O-LZ path
/// (`srep.cpp:693` with `INDEX_LZ=false, FUTURE_LZ=false`, so `ROUND_MATCHES`
/// is false and the format is v2).
///
/// Returns the compressed size. `opts.dictsize` is the `-d` value (0 = no
/// in-memory pass); the caller applies the `-m0` default itself if it wants
/// one.
pub fn encode_inmem_io_lz<R: Read, W: Write>(
    input: &mut R,
    output: &mut W,
    opts: &EncodeOptions,
) -> Result<u64, EncodeError> {
    let hash = match container::hash_by_name(&opts.hash) {
        Some(h) => h,
        None => return Err(EncodeError::UnknownHash(opts.hash.clone())),
    };

    // Option defaults (`srep.cpp:448-457`): -m0 is neither
    // CONTENT_DEFINED_CHUNKING nor EXHAUSTIVE_SEARCH, so `min_match` defaults
    // to 512, and `BASE_LEN` is the smaller of it and the dictionary's own
    // minimum match.
    let min_match = if opts.min_match != 0 { opts.min_match } else { 512 };
    let dict_min_match = if opts.dict_min_match != 0 {
        opts.dict_min_match
    } else {
        512
    };
    let dict_chunk = if opts.dict_chunk != 0 {
        opts.dict_chunk
    } else {
        dict_min_match / 8
    };
    let base_len = min_match.min(dict_min_match);
    let bufsize = opts.bufsize;

    // The archive seed (`srep.cpp:643-653`); without `--seed=N` the C++ draws
    // it from Fortuna, which is not reproducible, so the port refuses.
    let seed_size = hash.seed_size as usize;
    let mut seed = vec![0u8; seed_size];
    if seed_size > 0 {
        match opts.seed {
            Some(n) => fill_seed_from(&mut seed, n),
            None => return Err(EncodeError::NeedsSeed),
        }
    }
    let mut hasher = BlockHasher::new(hash, &seed);

    let header_size = container::BLOCK_HEADER_SIZE + hash.hash_size as usize;
    let mut compsize = 0u64;
    output.write_all(&ArchiveHeader::new(Version::V2, hash, base_len as u32).encode())?;
    output.write_all(&seed)?;
    compsize += container::ARCHIVE_HEADER_SIZE as u64 + seed_size as u64;

    // The dictionary ring (`io.cpp:127`): the dictionary rounded up to whole
    // blocks, plus two blocks of headroom for the background reads. `MAX_DIST`
    // stays the *unrounded* `-d` value.
    let use_dict = opts.dictsize != 0;
    let ring_size = if use_dict {
        (round_up(opts.dictsize, bufsize as u64) + (BUFFERS as u64) * bufsize as u64) as usize
    } else {
        0
    };
    let mut dict = vec![0u8; ring_size];
    let mut block = vec![0u8; bufsize];
    // `srep.cpp:663`: the compressor takes the *dictionary* minimum match and
    // the dictionary chunk, not `-l`/`-c`.
    let mut inmem = DictionaryCompressor::new(
        opts.dictsize,
        opts.dict_hashsize,
        dict_min_match,
        dict_chunk,
        base_len,
    );

    let mut buf_offset = 0usize;
    loop {
        // Read the next block into the ring (`io.cpp:253-256`).
        let filled = if use_dict {
            read_block(input, &mut dict[buf_offset..buf_offset + bufsize])?
        } else {
            read_block(input, &mut block)?
        };
        if filled == 0 {
            break;
        }

        // Per-block header: `calloc`'d, then the digest at word 3
        // (`io.cpp:262`), then the three `STAT`s filled in below.
        let mut header = vec![0u8; header_size];
        if let Some(digest) = hasher.compute(&dict[buf_offset..buf_offset + filled]) {
            header[container::BLOCK_HEADER_SIZE..container::BLOCK_HEADER_SIZE + digest.len()]
                .copy_from_slice(&digest);
        }

        // `io.cpp:264` then `srep.cpp:722`.
        let mut hashptr = Vec::new();
        inmem.prepare_buffer(&mut hashptr, &dict[buf_offset..buf_offset + filled]);
        let mut stat: Vec<u32> = Vec::new();
        let mut literal_bytes = 0u32;
        inmem.compress(
            &dict,
            ring_size,
            buf_offset,
            filled,
            &hashptr,
            &mut literal_bytes,
            &mut stat,
        )?;

        // `srep.cpp:719-721`: literal bytes, block size, match-list bytes
        // (zero for Index-LZ, which keeps them in the footer instead).
        let bh = BlockHeader {
            literal_bytes,
            origsize: filled as u32,
            statsize: (stat.len() * 4) as u32,
        };
        header[0..container::BLOCK_HEADER_SIZE].copy_from_slice(&bh.encode());

        // `save_data` (`io.cpp:282-307`): header, whole match list, then the
        // literal runs the records interleave with.
        output.write_all(&header)?;
        for word in &stat {
            output.write_all(&word.to_le_bytes())?;
        }
        compsize += (header.len() + stat.len() * 4) as u64;

        let mut in_pos = 0usize;
        let mut rest = &stat[..];
        while rest.len() >= lz::stats_per_match(false) {
            let (m, used) = lz::decode_lz_match(rest, false, false, base_len as u32, 0)?;
            let lit = m.lit_len as usize;
            if lit > filled - in_pos {
                return Err(EncodeError::BadBlockRecord);
            }
            output.write_all(&dict[buf_offset + in_pos..buf_offset + in_pos + lit])?;
            in_pos += lit + m.len as usize;
            if in_pos > filled {
                return Err(EncodeError::BadBlockRecord);
            }
            rest = &rest[used..];
        }
        output.write_all(&dict[buf_offset + in_pos..buf_offset + filled])?;
        compsize += (filled - in_pos) as u64;

        if use_dict {
            buf_offset = (buf_offset + bufsize) % ring_size;
        }
    }
    Ok(compsize)
}

/// `roundUp` (`Common.h:692`) for the base the ring uses.
fn round_up(a: u64, b: u64) -> u64 {
    if a != 0 && b > 1 {
        ((a - 1) / b) * b + b
    } else {
        a
    }
}

/// One `fread`: fill `buf` as far as the input allows, stopping only at EOF.
fn read_block<R: Read>(input: &mut R, buf: &mut [u8]) -> Result<usize, EncodeError> {
    let mut filled = 0usize;
    while filled < buf.len() {
        match input.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) => return Err(e.into()),
        }
    }
    Ok(filled)
}
