//! I/O-LZ decoding (format v1/v2) -- the Rust port of `decompress.cpp:9-45`
//! and the block loop in `srep.cpp:1142-1230`.
//!
//! v1/v2 are the `o` (I/O-LZ) variants: every block carries its own match list
//! inline, immediately after the block header and before its literal bytes, and
//! a match may reach back into any previously decoded block. That back
//! reference is why the sink is `Read + Write + Seek`: the C++ passes the same
//! `FILE*` it writes to, seeking back to re-read already-emitted bytes (and the
//! CLI spools to a tempfile when the real output is not seekable).
//!
//! Match lengths are encoded relative to `L` (`BASE_LEN` from the archive
//! header), and in v1 both offset and length are divided by `L`, so the
//! decoder rounds the destination down to a multiple of `L` before subtracting
//! the offset.

use std::io::{self, Read, Seek, SeekFrom, Write};

use crate::container::{ArchiveHeader, BlockHeader, ContainerError, HashInfo, Version};
use crate::hashes;
use crate::hashes_keyed;
use crate::vmac;

#[derive(Debug)]
pub enum DecodeError {
    Container(ContainerError),
    Io(io::Error),
    /// The match list or literals violate an invariant `decompress()` checks,
    /// i.e. `srep.cpp`'s "Decompression problem: broken compressed data".
    BadData(&'static str),
    /// The archive is not v1/v2.
    NotIoLz(Version),
    /// The archive is not v3/v4.
    NotFutureLz(Version),
    /// A block's stored digest does not match the decoded bytes.
    DigestMismatch {
        block: usize,
    },
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::Container(e) => write!(f, "{e}"),
            DecodeError::Io(e) => write!(f, "{e}"),
            DecodeError::BadData(why) => write!(f, "broken compressed data: {why}"),
            DecodeError::NotIoLz(v) => write!(f, "not an I/O-LZ archive (v{})", v.code()),
            DecodeError::NotFutureLz(v) => {
                write!(f, "not a Future/Index-LZ archive (v{})", v.code())
            }
            DecodeError::DigestMismatch { block } => {
                write!(
                    f,
                    "checksum of decoded block {block} differs from the stored one"
                )
            }
        }
    }
}

impl std::error::Error for DecodeError {}

impl From<io::Error> for DecodeError {
    fn from(e: io::Error) -> Self {
        DecodeError::Io(e)
    }
}

impl From<ContainerError> for DecodeError {
    fn from(e: ContainerError) -> Self {
        DecodeError::Container(e)
    }
}

/// How much work a decode did, and whether the digests were actually checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeStats {
    pub blocks: usize,
    pub origsize: u64,
    /// False when the archive stores no usable digest (`-hash-`, or one the
    /// descriptors cannot reproduce).
    pub verified: bool,
}

/// Forward byte copy with LZ77 replication, mirroring `memcpy_lz_match`
/// (`srep.cpp:145-152`), which is a plain `do { *dest++ = *src++; } while
/// (--len)`. When the match overlaps the bytes it is producing, that repeats
/// the bytes just written; `copy_within` alone would be wrong because it has
/// memmove semantics and would read the displaced originals instead.
///
/// `src < dest` is guaranteed by the caller. The non-overlapping case is a
/// single memmove; the overlapping one is seeded with the `dest - src` bytes
/// before the destination and then extended by doubling, which reproduces the
/// period-`dist` pattern without a per-byte loop.
pub(crate) fn lz_copy(buf: &mut [u8], src: usize, dest: usize, len: usize) {
    if len == 0 {
        return;
    }
    debug_assert!(src < dest && dest + len <= buf.len() && src + len <= buf.len());
    let dist = dest - src;
    if dist >= len {
        buf.copy_within(src..src + len, dest);
        return;
    }
    buf.copy_within(src..src + dist, dest);
    let mut filled = dist;
    while filled < len {
        let n = filled.min(len - filled);
        buf.copy_within(dest..dest + n, dest + filled);
        filled += n;
    }
}

/// Decode one I/O-LZ block in place, mirroring `decompress()`
/// (`decompress.cpp:9-45`). `outbuf` must be exactly the block's `origsize`;
/// the C++ derives that from `outend - outbuf`.
///
/// `sink` is the output so far: matches that start before `block_start` are
/// read back from it, the rest come from `outbuf` itself.
fn decompress_block<S: Read + Write + Seek>(
    round_matches: bool,
    l: u32,
    sink: &mut S,
    block_start: u64,
    stats: &[u32],
    literals: &[u8],
    outbuf: &mut [u8],
) -> Result<(), DecodeError> {
    let per = if round_matches { 3 } else { 4 };
    let l1: u64 = if round_matches { u64::from(l) } else { 1 };
    let l = u64::from(l);

    let mut stat = 0usize;
    let mut in_pos = 0usize;
    let mut out_pos = 0usize;

    while stats.len() - stat >= per {
        let lit_len = u64::from(stats[stat]);
        stat += 1;
        let mut offset = u64::from(stats[stat]);
        stat += 1;
        if !round_matches {
            offset += u64::from(stats[stat]) << 32;
            stat += 1;
        }
        offset *= l1;
        let mut mlen = u64::from(stats[stat]) * l1 + l;
        stat += 1;

        // DECODE_LZ_MATCH with basic_pos = block_start + (out - outbuf).
        let basic_pos = block_start + out_pos as u64;
        let dest = basic_pos + lit_len;
        // Rounds the destination down to a multiple of L1, then subtracts the
        // offset. The subtraction wraps like the C's unsigned Offset, and the
        // src >= dest test below rejects the result.
        let mut src = (dest / l1 * l1).wrapping_sub(offset);

        if lit_len > (literals.len() - in_pos) as u64
            || lit_len + mlen > (outbuf.len() - out_pos) as u64
            || src >= dest
        {
            return Err(DecodeError::BadData("record does not fit the block"));
        }

        // Longest literal run first, then the match: strictly interleaved.
        outbuf[out_pos..out_pos + lit_len as usize]
            .copy_from_slice(&literals[in_pos..in_pos + lit_len as usize]);
        in_pos += lit_len as usize;
        out_pos += lit_len as usize;

        // The part of the match that lives in earlier blocks comes from the
        // sink; whatever is left comes from this block's outbuf.
        if src < block_start {
            let bytes = mlen.min(block_start - src);
            sink.seek(SeekFrom::Start(src))?;
            sink.read_exact(&mut outbuf[out_pos..out_pos + bytes as usize])?;
            out_pos += bytes as usize;
            src += bytes;
            mlen -= bytes;
        }

        lz_copy(outbuf, (src - block_start) as usize, out_pos, mlen as usize);
        out_pos += mlen as usize;
    }

    // Whatever literals are left must exactly fill the rest of the block.
    if literals.len() - in_pos != outbuf.len() - out_pos {
        return Err(DecodeError::BadData("literal run does not fill the block"));
    }
    outbuf[out_pos..].copy_from_slice(&literals[in_pos..]);
    Ok(())
}

/// A block digest, or the absence of one.
pub(crate) enum Digest {
    None,
    Md5,
    Sha1,
    Sha512,
    Siphash([u8; 16]),
    Vmac(Box<vmac::Vmac>),
}

impl Digest {
    /// Pick the verifier for an archive, mirroring `srep.cpp:1017-1029`: the
    /// tag selects the descriptor, and verification is silently skipped when
    /// the archive's sizes exceed what that descriptor produces.
    pub(crate) fn for_archive(header: &ArchiveHeader, seed: &[u8]) -> Digest {
        let Some(info) = header.hash() else {
            return Digest::None;
        };
        if header.hash_seed_size > info.seed_size || header.hash_size > info.hash_size {
            return Digest::None;
        }
        Digest::for_hash(info, seed)
    }

    /// The same choice for a v5 archive, which names its hash by descriptor and
    /// declares the digest size itself instead of packing both into a word.
    pub(crate) fn for_hash(info: &HashInfo, seed: &[u8]) -> Digest {
        match info.name {
            "md5" => Digest::Md5,
            "sha1" => Digest::Sha1,
            "sha512" => Digest::Sha512,
            "siphash" => {
                let mut key = [0u8; 16];
                if seed.len() >= 16 {
                    key.copy_from_slice(&seed[..16]);
                }
                Digest::Siphash(key)
            }
            "vmac" => {
                let mut key = [0u8; 32];
                if seed.len() >= 32 {
                    key.copy_from_slice(&seed[..32]);
                }
                Digest::Vmac(Box::new(vmac::Vmac::new(&key)))
            }
            // The empty name is the "checksums disabled" descriptor.
            _ => Digest::None,
        }
    }

    pub(crate) fn enabled(&self) -> bool {
        !matches!(self, Digest::None)
    }

    pub(crate) fn compute(&self, data: &[u8]) -> Vec<u8> {
        match self {
            Digest::None => Vec::new(),
            Digest::Md5 => hashes::md5(data).to_vec(),
            Digest::Sha1 => hashes::sha1(data).to_vec(),
            Digest::Sha512 => hashes::sha512(data).to_vec(),
            Digest::Siphash(k) => hashes_keyed::siphash(k, data).to_vec(),
            Digest::Vmac(v) => v.compute(data).to_vec(),
        }
    }
}

/// Read exactly `n` bytes, mapping a short read to `Truncated`.
pub(crate) fn read_exact_or_eof<R: Read>(r: &mut R, buf: &mut [u8]) -> Result<bool, DecodeError> {
    let mut filled = 0;
    while filled < buf.len() {
        match r.read(&mut buf[filled..])? {
            0 => {
                if filled == 0 {
                    return Ok(false);
                }
                return Err(ContainerError::Truncated.into());
            }
            n => filled += n,
        }
    }
    Ok(true)
}

/// Decode a v1/v2 archive. `sink` receives the decompressed bytes at their
/// final offsets and must allow reading them back, exactly like the C++'s
/// single read/write `FILE*`.
pub fn decode_io_lz<R: Read + Seek, S: Read + Write + Seek>(
    input: &mut R,
    sink: &mut S,
) -> Result<DecodeStats, DecodeError> {
    let mut header_bytes = [0u8; crate::container::ARCHIVE_HEADER_SIZE];
    if !read_exact_or_eof(input, &mut header_bytes)? {
        return Err(ContainerError::Truncated.into());
    }
    let header = ArchiveHeader::decode(&header_bytes)?;
    if !header.version.io_lz() {
        return Err(DecodeError::NotIoLz(header.version));
    }

    let mut seed = vec![0u8; header.hash_seed_size as usize];
    if !read_exact_or_eof(input, &mut seed)? {
        return Err(ContainerError::Truncated.into());
    }
    let digest = Digest::for_archive(&header, &seed);
    let verified = digest.enabled();

    let header_size = crate::container::BLOCK_HEADER_SIZE + header.hash_size as usize;
    let mut block_buf = vec![0u8; header_size];
    let mut block_start = 0u64;
    let mut blocks = 0usize;

    loop {
        if !read_exact_or_eof(input, &mut block_buf)? {
            break;
        }
        let bh = BlockHeader::decode(&block_buf[..crate::container::BLOCK_HEADER_SIZE])?;
        // A zero-length block ends the stream; the encoder does not write one,
        // but the decoder accepts it (`srep.cpp:1147`).
        if bh.literal_bytes == 0 && bh.origsize == 0 {
            break;
        }

        let mut stat_bytes = vec![0u8; bh.statsize as usize];
        if !read_exact_or_eof(input, &mut stat_bytes)? {
            return Err(ContainerError::Truncated.into());
        }
        if stat_bytes.len() % 4 != 0 {
            return Err(DecodeError::BadData(
                "match list is not a whole number of STATs",
            ));
        }
        let stats: Vec<u32> = stat_bytes
            .chunks_exact(4)
            .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
            .collect();

        let mut literals = vec![0u8; bh.literal_bytes as usize];
        if !read_exact_or_eof(input, &mut literals)? {
            return Err(ContainerError::Truncated.into());
        }

        let mut outbuf = vec![0u8; bh.origsize as usize];
        decompress_block(
            header.version.round_matches(),
            header.base_len,
            sink,
            block_start,
            &stats,
            &literals,
            &mut outbuf,
        )?;

        if verified {
            let want = digest.compute(&outbuf);
            let got = &block_buf[crate::container::BLOCK_HEADER_SIZE
                ..crate::container::BLOCK_HEADER_SIZE + want.len()];
            if got != want.as_slice() {
                return Err(DecodeError::DigestMismatch { block: blocks });
            }
        }

        sink.seek(SeekFrom::Start(block_start))?;
        sink.write_all(&outbuf)?;

        block_start += u64::from(bh.origsize);
        blocks += 1;
    }

    Ok(DecodeStats {
        blocks,
        origsize: block_start,
        verified,
    })
}

/// Convenience wrapper for a whole in-memory archive.
pub fn decode_io_lz_to_vec(bytes: &[u8]) -> Result<Vec<u8>, DecodeError> {
    let mut input = io::Cursor::new(bytes);
    let mut sink = io::Cursor::new(Vec::new());
    decode_io_lz(&mut input, &mut sink)?;
    Ok(sink.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lz_copy_non_overlapping_is_a_plain_copy() {
        // "abcdefgh" with src[0..3] copied over 3..6 -> "abcabcgh".
        let mut buf = b"abcdefgh".to_vec();
        lz_copy(&mut buf, 0, 3, 3);
        assert_eq!(buf, b"abcabcgh");
    }

    #[test]
    fn lz_copy_replicates_overlapping_matches() {
        // src=0 dest=2 len=6 with period 2: a,b,a,b,a,b,a,b.
        let mut buf = b"abcdefgh".to_vec();
        lz_copy(&mut buf, 0, 2, 6);
        assert_eq!(&buf, b"abababab");
    }

    #[test]
    fn lz_copy_matches_a_byte_by_byte_forward_copy() {
        // The reference is memcpy_lz_match: dest[i] = src[i] evaluated in
        // order, so later reads see the bytes written earlier.
        for dist in 1..8usize {
            for len in 0..24usize {
                let mut want = b"0123456789abcdefghijklmnopqrstuv".to_vec();
                let (src, dest) = (0usize, dist);
                for i in 0..len {
                    want[dest + i] = want[src + i];
                }
                let mut got = b"0123456789abcdefghijklmnopqrstuv".to_vec();
                lz_copy(&mut got, src, dest, len);
                assert_eq!(got, want, "dist={dist} len={len}");
            }
        }
    }

    #[test]
    fn read_exact_or_eof_distinguishes_eof_from_truncation() {
        let mut c = io::Cursor::new(b"ab".to_vec());
        let mut buf = [0u8; 2];
        assert!(read_exact_or_eof(&mut c, &mut buf).unwrap());
        assert_eq!(&buf, b"ab");
        // Clean EOF: nothing left to read.
        assert!(!read_exact_or_eof(&mut c, &mut buf).unwrap());

        let mut c = io::Cursor::new(b"a".to_vec());
        let mut buf = [0u8; 2];
        assert!(matches!(
            read_exact_or_eof(&mut c, &mut buf),
            Err(DecodeError::Container(ContainerError::Truncated))
        ));
    }

    #[test]
    fn digest_none_for_the_disabled_descriptor() {
        let header = ArchiveHeader::new(
            Version::V1,
            crate::container::hash_by_name("").unwrap(),
            512,
        );
        assert!(!Digest::for_archive(&header, &[]).enabled());
    }

    #[test]
    fn digest_matches_the_keyed_hashes() {
        let seed = [7u8; 32];
        let header = ArchiveHeader::new(
            Version::V4,
            crate::container::hash_by_name("vmac").unwrap(),
            0,
        );
        let d = Digest::for_archive(&header, &seed);
        assert!(d.enabled());
        assert_eq!(
            d.compute(b"osrep"),
            vmac::Vmac::new(&seed).compute(b"osrep")
        );
    }
}
