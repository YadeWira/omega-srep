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
//! The read-ahead below is not only a speed choice: `compress` reads a few
//! bytes past the block end (the batch of four can overshoot `next_chunk`,
//! compress.cpp:178-183), and in the C++ those bytes are the next ring slot --
//! which the background thread has usually already filled with the following
//! block. Reading one block ahead reproduces that deterministically.
//!
//! Only the single-pass I/O-LZ path is driven (format v2 through the `o`
//! suffix); the Future/Index-LZ second pass lands with phase 4c-5 and the
//! digest-verified `-m3` with 4c-4.

use std::io::{Read, Seek, SeekFrom, Write};

use crate::cdc;
use crate::v5;
use crate::compress as lz_compress;
use crate::container::{self, ArchiveHeader, BlockHeader, HashInfo, Version};
use crate::hash_table::HashTable;
use crate::inmem::DictionaryCompressor;
use crate::lz;
use crate::second_pass::{self, CompressedBlock};
use crate::util::rounddown_to_power_of_two;
use crate::{hashes, hashes_keyed, vmac};

/// `-b` default (`srep.cpp:288`).
pub const DEFAULT_BUFSIZE: usize = 8 * 1024 * 1024;
/// `-d` default for `-m0` (`srep.cpp:285,445`).
pub const DEFAULT_DICTSIZE: u64 = 512 * 1024 * 1024;
/// `BUFFERS` (`io.cpp:90`): the ring carries two extra blocks of headroom.
const BUFFERS: usize = 2;

/// Which per-block compressor runs (`-m0`/`-m3`/`-m4`/`-m5`); `-m1`/`-m2`
/// (CDC) land with 4c-6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `-m0`: the in-memory REP pass, no hash table.
    Inmem,
    /// `-m1`: content-defined chunking.
    Cdc,
    /// `-m2`: content-defined chunking with the ZPAQ boundary model.
    CdcZpaq,
    /// `-m4`: fixed-size chunks, matches verified by rereading the input.
    Fixed,
    /// `-m5`: `-m4` with exhaustive search and the slice filter.
    FixedExhaustive,
    /// `-m3`: fixed chunks with a precomputed 20-byte digest per chunk.
    Digest,
}

/// How the match lists reach the archive, i.e. the `f`/`o` suffix
/// (`srep.cpp:693`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Container {
    /// No suffix (`o`): per-block match lists inline, format v1/v2.
    IoLz,
    /// No suffix at all: one match list for all blocks at the tail, format v4.
    IndexLz,
    /// `f`: matches hoisted to their source block, format v3.
    FutureLz,
    /// v5 (`docs/format-spec-v5.md`): the same self-contained block shape as
    /// Future-LZ, with the v5 container and LEB128 records.
    V5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mode {
    pub kind: Kind,
    pub container: Container,
}

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
    /// `EncodeOptions::dup_meta` is not a `.dupref` payload, so it cannot be
    /// embedded as a v5 `-dup` meta blob.
    BadDupMeta,
    /// `Seed::Bytes` does not carry exactly the archive's key length, which is
    /// what `OSREP_SEED_HEX` being a fixed-length hex string means.
    BadSeed { want: usize, got: usize },
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
            lz::EncodeError::BadInputMatch => EncodeError::BadBlockRecord,
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
#[derive(Debug, Clone)]
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
    /// Where the per-archive hash key comes from.
    pub seed: Seed,
    /// `-sBYTES`: the length to compress *as*. The C++ only needs it to read
    /// from stdin; the port spools stdin, so it can always measure, but an
    /// explicit declaration still wins because it decides the block count and
    /// what the hash table is sized for.
    pub declared_size: Option<u64>,
    /// `-hash=` name; empty selects disabled checksums (`-hash-`).
    pub hash: String,
    /// The `-dup` `.dupref` payload to embed. The dedup pass builds it; the v5
    /// writer puts it before the footer and points the footer at it. v4 keeps
    /// its ODUP trailer, which the caller appends itself.
    pub dup_meta: Option<Vec<u8>>,
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
            seed: Seed::Random,
            declared_size: None,
            hash: container::DEFAULT_HASH_NAME.to_string(),
            dup_meta: None,
        }
    }
}

/// Where the archive's hash key comes from (`srep.cpp:643-653`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Seed {
    /// Nothing given: the C++ draws the key from Fortuna, which no port can
    /// reproduce, so a keyed hash is refused rather than guessed.
    Random,
    /// `--seed=N`: xorshift64 expands N into the key (`srep.cpp:251-261`).
    Value(u64),
    /// `OSREP_SEED_HEX`: the key bytes verbatim, a debug hook that replays the
    /// seed an existing archive recorded.
    Bytes(Vec<u8>),
}

impl Default for Seed {
    fn default() -> Self {
        Seed::Random
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

/// The single-pass I/O-LZ driver: `-m0o`, `-m4o` and `-m5o` today, all of
/// which store format v2 (`INDEX_LZ=false, FUTURE_LZ=false`, `ROUND_MATCHES`
/// false because `-m3` is not wired yet).
///
/// Returns the compressed size. `opts.dictsize` is the `-d` value (0 = no
/// in-memory pass); the caller applies the `-m0` default itself if it wants
/// one.
pub fn encode<R: Read + Seek, W: Write>(
    input: &mut R,
    output: &mut W,
    opts: &EncodeOptions,
    mode: Mode,
    progress: Option<&mut dyn FnMut(u64, u64)>,
    // `-index=`. Both passes can own the match lists -- I/O-LZ writes them
    // inline in this loop, Future-LZ re-emits them in the second pass -- so
    // the sink is threaded through both.
    mut index: Option<&mut dyn Write>,
) -> Result<u64, EncodeError> {
    let mut progress = progress;
    let kind = mode.kind;
    let cdc = matches!(kind, Kind::Cdc | Kind::CdcZpaq);
    let io_lz = mode.container == Container::IoLz;
    let index_lz = mode.container == Container::IndexLz;
    let future_lz = mode.container == Container::FutureLz;
    let v5 = mode.container == Container::V5;
    let hash = match container::hash_by_name(&opts.hash) {
        Some(h) => h,
        None => return Err(EncodeError::UnknownHash(opts.hash.clone())),
    };

    // Option defaults (`srep.cpp:448-457`). `-m0` is neither
    // CONTENT_DEFINED_CHUNKING nor EXHAUSTIVE_SEARCH, so its `min_match`
    // defaults to 512 and `L` to it; `-m5` searches exhaustively from half the
    // window, so its `L` is the power of two below `min_match`, divided by two.
    // `srep.cpp:448-454`, in the C++'s own order: for CDC, `-l` becomes the
    // window `L` and `MIN_MATCH` collapses to DEFAULT_MIN_MATCH (32).
    let mut min_match = opts.min_match;
    let mut l = opts.l;
    if l == 0 && min_match == 0 {
        min_match = if cdc { 4096 } else { 512 };
    }
    if l == 0 {
        if cdc {
            l = min_match;
            min_match = 0;
        } else if kind == Kind::FixedExhaustive {
            l = (rounddown_to_power_of_two(min_match as u64 + 1) / 2) as usize;
        } else {
            l = min_match;
        }
    }
    if min_match == 0 {
        min_match = if cdc { 32 } else { l };
    }
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

    // `ROUND_MATCHES = (method == -m3) && dictsize == 0` (`srep.cpp:443`):
    // `-m3o` writes format v1 with 3-word records, `-m3o -d` falls back to v2.
    let round_matches = kind == Kind::Digest && opts.dictsize == 0;

    // The archive seed (`srep.cpp:643-653`); without `--seed=N` the C++ draws
    // it from Fortuna, which is not reproducible, so the port refuses.
    let seed_size = hash.seed_size as usize;
    let mut seed = vec![0u8; seed_size];
    if seed_size > 0 {
        match &opts.seed {
            Seed::Random => return Err(EncodeError::NeedsSeed),
            Seed::Value(n) => fill_seed_from(&mut seed, *n),
            Seed::Bytes(bytes) => {
                if bytes.len() != seed_size {
                    return Err(EncodeError::BadSeed {
                        want: seed_size,
                        got: bytes.len(),
                    });
                }
                seed.copy_from_slice(bytes);
            }
        }
    }
    let mut hasher = BlockHasher::new(hash, &seed);

    // v5 omits the digest field entirely when checksums are off (`hash_size =
    // 0`, `docs/format-spec-v5.md` §2), where v1-v4 always reserve the
    // descriptor's 16 bytes. Sizing the per-block header from the descriptor
    // either way writes 16 bytes the reader is not expecting, which
    // desynchronizes every block that follows.
    let stored_hash_size = if v5 && hash.name.is_empty() {
        0
    } else {
        hash.hash_size as usize
    };
    let header_size = container::BLOCK_HEADER_SIZE + stored_hash_size;
    let version = if index_lz {
        Version::V4
    } else if future_lz {
        Version::V3
    } else if round_matches {
        Version::V1
    } else {
        Version::V2
    };
    // `header[3] = FUTURELZ_BASE_LEN = IO_LZ? BASE_LEN : 0` (`srep.cpp:458`):
    // the v3/v4 decoder reads its match-length base from here, and 0 is what
    // makes those records carry raw lengths.
    let futurelz_base_len = if io_lz { base_len as u32 } else { 0 };

    // The input length. `-sBYTES` overrides the measurement, because it is what
    // the C++ uses when the input is stdin and it is what decides the block
    // count and the match finder's sizing.
    let filesize = match opts.declared_size {
        Some(n) => n,
        None => {
            let n = input.seek(SeekFrom::End(0))?;
            input.seek(SeekFrom::Start(0))?;
            n
        }
    };

    if v5 {
        // `docs/format-spec-v5.md` §2: one magic, the hash pair un-biased, and
        // the block count and input size written down instead of inferred.
        let block_count = filesize.div_ceil(bufsize as u64) as u32;
        output.write_all(
            &v5::Header {
                flags: if opts.dup_meta.is_some() { v5::FLAG_HAS_DUP } else { 0 },
                hash_id: hash.num,
                // `-hash-` is the descriptor with no digest at all, and v5
                // encodes that as size 0 rather than reserving 16 dead bytes.
                hash_size: if hash.name.is_empty() { 0 } else { hash.hash_size },
                max_match: v5::DEFAULT_MAX_MATCH,
                block_count,
                original_size: filesize,
            }
            .encode(),
        )?;
    } else {
        output.write_all(&ArchiveHeader::new(version, hash, futurelz_base_len).encode())?;
    }
    output.write_all(&seed)?;

    // Where the second pass's output starts, for the footer's absolute offsets.
    let archive_header_len = if v5 {
        (v5::HEADER_SIZE + seed.len()) as u64
    } else {
        0
    };

    // The match finder, for the modes that have one. `-m4` leaves the slice
    // filter empty (its `check_slices` is <= 0), `-m5` fills it.
    let mut table = match kind {
        Kind::Inmem => None,
        Kind::Cdc | Kind::CdcZpaq | Kind::Fixed | Kind::FixedExhaustive | Kind::Digest => {
            // `io_accelerator` defaults to 1 (srep.cpp:291). `-m3` is the one
            // mode that precomputes and compares per-chunk digests.
            // `COMPARE_DIGESTS = (method <= -m3)` and
            // `PRECOMPUTE_DIGESTS = (method == -m3)` (`srep.cpp:441-442`):
            // `-m1`/`-m2` *compare* chunk digests but do not precompute them.
            let compare_digests = matches!(
                kind,
                Kind::Inmem | Kind::Cdc | Kind::CdcZpaq | Kind::Digest
            );
            let precompute_digests = kind == Kind::Digest;
            Some(HashTable::new(
                round_matches,
                compare_digests,
                precompute_digests,
                cdc,
                l,
                min_match,
                1,
                filesize,
            ))
        }
    };

    // The dictionary ring (`io.cpp:127`): the dictionary rounded up to whole
    // blocks, plus two blocks of headroom for the background reads. It exists
    // even with `-d0` (then it is just the two headroom blocks); `MAX_DIST`
    // stays the *unrounded* `-d` value, and the in-memory pass runs only when
    // it is non-zero.
    let ring_size =
        (round_up(opts.dictsize, bufsize as u64) + (BUFFERS as u64) * bufsize as u64) as usize;
    let use_dict = opts.dictsize != 0;
    let mut dict = vec![0u8; ring_size];
    let mut inmem = DictionaryCompressor::new(
        opts.dictsize,
        opts.dict_hashsize,
        dict_min_match,
        dict_chunk,
        base_len,
    );

    let mut compsize = container::ARCHIVE_HEADER_SIZE as u64 + seed_size as u64;

    // Read the first block, then keep one block of read-ahead in the ring.
    // `buf_offset` is a BYTE offset into the ring, cycling by `bufsize` exactly
    // like the C++'s `buf_offset = (buf_offset + bufsize) % dictsize`
    // (io.cpp:250).
    // The CDC chunk hasher (`-m1`/`-m2`), created once like the C++'s
    // per-thread `VHash` pair.
    let cdc_hasher = cdc::CdcChunkHasher::new();

    // Blocks captured for the second pass (`COMPRESSED_BLOCK`), in file order.
    let mut blocks: Vec<CompressedBlock> = Vec::new();
    let mut buf_offset = 0usize;
    let mut next_pos: u64 = 0;
    let mut filled = read_block_at(input, next_pos, &mut dict[buf_offset..buf_offset + bufsize])?;
    next_pos += filled as u64;
    let mut block_start: u64 = 0;

    while filled > 0 {
        // Read-ahead: fill the next ring slot, so the few bytes `compress` may
        // read past this block are the following block's, like the C++'s ring
        // (and, at EOF, whatever stale bytes that slot holds -- also the same).
        let next_offset = (buf_offset + bufsize) % ring_size;
        let next_filled = read_block_at(input, next_pos, &mut dict[next_offset..next_offset + bufsize])?;

        // Per-block header: `calloc`'d, then the digest at word 3
        // (`io.cpp:262`), then the three `STAT`s filled in below.
        let mut header = vec![0u8; header_size];
        if let Some(digest) = hasher.compute(&dict[buf_offset..buf_offset + filled]) {
            header[container::BLOCK_HEADER_SIZE..container::BLOCK_HEADER_SIZE + digest.len()]
                .copy_from_slice(&digest);
        }

        if let Some(t) = table.as_mut() {
            t.prepare_buffer(&dict, buf_offset, filled, block_start);
        }

        let mut stat: Vec<u32> = Vec::new();
        let mut literal_bytes = 0u32;
        match kind {
            Kind::Inmem => {
                // `-m0`: the in-memory pass *is* the compressor; no fence and
                // no second compressor (srep.cpp:726-727).
                let mut hashptr = Vec::new();
                inmem.prepare_buffer(&mut hashptr, &dict[buf_offset..buf_offset + filled]);
                inmem.compress(
                    &dict,
                    ring_size,
                    buf_offset,
                    filled,
                    &hashptr,
                    &mut literal_bytes,
                    &mut stat,
                )?;
            }
            Kind::Cdc | Kind::CdcZpaq => {
                cdc::compress_cdc(
                    kind == Kind::CdcZpaq,
                    l,
                    min_match,
                    block_start,
                    table.as_mut().unwrap(),
                    &dict[buf_offset..],
                    filled,
                    &mut literal_bytes,
                    &mut stat,
                    &cdc_hasher,
                )?;
            }
            Kind::Fixed | Kind::FixedExhaustive | Kind::Digest => {
                // `srep.cpp:722-724`: the in-memory pass (only with `-d`)
                // writes into the aux list, then the fence `len+1 / BASE_LEN /
                // BASE_LEN` is appended; its match starts past the block, so
                // `compress` never reaches it -- it only stops the walk.
                let mut in_stat: Vec<u32> = Vec::new();
                if use_dict {
                    let mut hashptr = Vec::new();
                    inmem.prepare_buffer(&mut hashptr, &dict[buf_offset..buf_offset + filled]);
                    inmem.compress(
                        &dict,
                        ring_size,
                        buf_offset,
                        filled,
                        &hashptr,
                        &mut literal_bytes,
                        &mut in_stat,
                    )?;
                }
                lz::encode_lz_match(
                    &mut in_stat,
                    round_matches,
                    base_len as u32,
                    (filled + 1) as u32,
                    base_len as u64,
                    base_len as u32,
                )?;
                let t = table.as_mut().unwrap();
                lz_compress::compress(
                    t,
                    &dict,
                    buf_offset,
                    filled,
                    round_matches,
                    l,
                    min_match,
                    base_len as u32,
                    block_start,
                    &in_stat,
                    &mut stat,
                    &mut literal_bytes,
                    input,
                )?;
            }
        }

        // `srep.cpp:743-747`: literal bytes, block size, match-list bytes
        // (zero for Index-LZ, which keeps them in the footer instead).
        let bh = BlockHeader {
            literal_bytes,
            origsize: filled as u32,
            // `header[2] = (INDEX_LZ? 0 : stat_size)` (`srep.cpp:747`).
            statsize: if index_lz { 0 } else { (stat.len() * 4) as u32 },
        };
        header[0..container::BLOCK_HEADER_SIZE].copy_from_slice(&bh.encode());

        if future_lz || v5 {
            // `no_writes = FUTURE_LZ` (`io.cpp:270`): the first pass writes
            // nothing at all -- the second pass re-emits the header, the match
            // list and the literals. v5 keeps that self-contained block shape.
            blocks.push(CompressedBlock {
                start: block_start,
                end: block_start + filled as u64,
                size: filled,
                header: header.clone(),
                stat: stat.clone(),
            });
        } else {
            // `save_data` (`io.cpp:282-307`): the header, the match list (which
            // is empty for Index-LZ) and then the literal runs the records
            // interleave with.
            output.write_all(&header)?;
            compsize += header.len() as u64;
            if !index_lz {
                let mut list_bytes = Vec::with_capacity(stat.len() * 4);
                for word in &stat {
                    list_bytes.extend_from_slice(&word.to_le_bytes());
                }
                match index.as_deref_mut() {
                    Some(ix) => ix.write_all(&list_bytes).map_err(|_| EncodeError::Io)?,
                    None => output.write_all(&list_bytes)?,
                }
                compsize += list_bytes.len() as u64;
            }
            compsize += write_literals(
                &dict,
                buf_offset,
                filled,
                &stat,
                round_matches,
                base_len as u32,
                output,
            )?;
            if index_lz {
                blocks.push(CompressedBlock {
                    start: block_start,
                    end: block_start + filled as u64,
                    size: filled,
                    header: header.clone(),
                    stat: stat.clone(),
                });
            }
        }

        // Advance; a zero read (EOF) ends the loop, like the background
        // thread's step 4.
        block_start += filled as u64;
        next_pos += next_filled as u64;
        buf_offset = next_offset;
        filled = next_filled;

        // `-bar` counts the input consumed against the size it is being
        // compressed as (`srep.cpp:808`).
        if let Some(p) = progress.as_deref_mut() {
            p(block_start, filesize);
        }
    }

    // A guaranteed final tick, so a consumer always sees `done == total`.
    if let Some(p) = progress.as_deref_mut() {
        p(filesize, filesize);
    }

    // Future-LZ and Index-LZ re-emit every block's match list (`srep.cpp:820`).
    if !io_lz {
        compsize += second_pass::second_pass(
            &blocks,
            input,
            output,
            index,
            round_matches,
            base_len as u32,
            futurelz_base_len,
            future_lz,
            index_lz,
            v5,
            archive_header_len,
            opts.dup_meta.as_deref(),
        )?;
    }
    Ok(compsize)
}

/// The literal runs `save_data` writes between the records, in the block's
/// record order. Returns the number of literal bytes written.
#[allow(clippy::too_many_arguments)]
fn write_literals<W: Write>(
    dict: &[u8],
    buf_offset: usize,
    filled: usize,
    stat: &[u32],
    round_matches: bool,
    base_len: u32,
    output: &mut W,
) -> Result<u64, EncodeError> {
    let mut in_pos = 0usize;
    let mut rest = stat;
    while rest.len() >= lz::stats_per_match(round_matches) {
        let (m, used) = lz::decode_lz_match(rest, round_matches, false, base_len, 0)?;
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
    Ok((filled - in_pos) as u64)
}

/// `roundUp` (`Common.h:692`) for the base the ring uses.
fn round_up(a: u64, b: u64) -> u64 {
    if a != 0 && b > 1 {
        ((a - 1) / b) * b + b
    } else {
        a
    }
}

/// One `fread` at an explicit offset. The offset is not redundant: the
/// match finder's `match_len` re-reads the *same* handle at arbitrary
/// positions (the C++ uses a second handle on the input file for that,
/// `srep.cpp:638`), so the sequential reads must re-anchor every time.
fn read_block_at<R: Read + Seek>(
    input: &mut R,
    off: u64,
    buf: &mut [u8],
) -> Result<usize, EncodeError> {
    input.seek(SeekFrom::Start(off))?;
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
