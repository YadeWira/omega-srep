//! The v5 container (`docs/format-spec-v5.md`).
//!
//! v5 re-frames the archive around the *same* match decisions the encoder
//! already makes (they are byte-verified against the C++ through v4), so the
//! only new things here are the framing, the LEB128 record codec, and CRC-32C
//! integrity on the header, the footer and the `-dup` meta.
//!
//! What v5 drops on purpose: the second magic word (`BULAT_ZIGANSHIN_SIGNATURE`
//! means nothing now), the `-16` bias on the stored hash size (which wrapped
//! SipHash's 8 to 248), `BASE_LEN` (lengths are stored raw, so there is no
//! implicit encoder/decoder agreement outside the archive), the unrecorded
//! `maximum_save`, the implicit block count, and the two `ROUND_MATCHES` record
//! shapes (one varint form replaces both).

use crate::container::{self, HashInfo};
use crate::rolling::crc32c_of;
use crate::vmac;

/// `"OSR5"` little-endian.
pub const MAGIC: u32 = 0x3552_534F;
/// `"DUPR"`: the v5 `-dup` meta blob's magic. v5 does **not** wrap the payload
/// in a header of its own -- the blob *is* the `.dupref` payload, so this is
/// that format's magic (`docs/format-spec.md` §3.1) and its version, which v5
/// describes as one byte plus three reserved ones.
pub const META_MAGIC: &[u8; 4] = b"DUPR";
pub const META_VERSION: u8 = 1;
/// The `.dupref` header every payload starts with: magic, version,
/// `chunk_count`, `unique_count`.
pub const META_PAYLOAD_HEADER_SIZE: usize = 24;
/// What the blob carries on top of the payload: the trailing CRC-32C.
pub const META_OVERHEAD: usize = 4;
/// `"OSRF"` little-endian: the footer's own magic.
pub const FOOTER_MAGIC: u32 = 0x4652_534F;
pub const VERSION: u8 = 5;
pub const HEADER_SIZE: usize = 28;
pub const FOOTER_SIZE: usize = 32;
pub const BLOCK_HEADER_SIZE: usize = 12;
/// `flags` bit 0: the file carries a `-dup` meta blob.
pub const FLAG_HAS_DUP: u8 = 1;
/// The only bits `flags` may carry today.
pub const KNOWN_FLAGS: u8 = FLAG_HAS_DUP;
/// The C++'s effective default `maximum_save`: `vm_block - 24` with the default
/// 8 MiB `-vmblock` (`srep.cpp:288,459`). v4 never records it, so encoder and
/// decoder have to agree through the shared default; v5 writes it down.
pub const DEFAULT_MAX_MATCH: u32 = 8 * 1024 * 1024 - 24;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V5Error {
    Truncated,
    BadMagic,
    BadFooterMagic,
    /// A version this reader does not implement.
    BadVersion(u8),
    /// A `flags` bit that is not defined.
    BadFlags(u8),
    /// `hash_id`/`hash_size` do not describe a usable function.
    BadHash { id: u8, size: u8 },
    /// Any of the three CRCs did not match.
    BadCrc(&'static str),
    /// The header's and the footer's block counts disagree, or the table does.
    BlockCountMismatch,
    /// A record ran past its block's match list, or past the data.
    BadBlock,
    /// A varint that never terminates or overflows 64 bits.
    BadVarint,
    /// The `-dup` meta is missing, out of range, or not a `DUPR` blob.
    BadMeta,
    /// A block digest did not match the archive key.
    BadDigest { block: usize },
}

// ------------------------------------------------------------- crc --

/// `LEB128`: seven bits per byte, high bit set means "another byte follows".
pub fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        out.push((value as u8 & 0x7F) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

/// The inverse of [`put_varint`]. Rejects unterminated and over-wide encodings
/// rather than wrapping, so a corrupt stream fails at the same place every time.
pub fn get_varint(b: &[u8], pos: &mut usize) -> Result<u64, V5Error> {
    let mut result: u64 = 0;
    let mut shift = 0u32;
    loop {
        if *pos >= b.len() {
            return Err(V5Error::BadVarint);
        }
        let byte = b[*pos];
        *pos += 1;
        if shift > 63 || (shift == 63 && byte & 0x7F > 1) {
            return Err(V5Error::BadVarint);
        }
        result |= (byte as u64 & 0x7F) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
    }
}

// ---------------------------------------------------------- header --

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub flags: u8,
    pub hash_id: u8,
    pub hash_size: u8,
    pub max_match: u32,
    pub block_count: u32,
    pub original_size: u64,
}

impl Header {
    /// The 28 bytes, CRC included.
    pub fn encode(&self) -> [u8; HEADER_SIZE] {
        let mut out = [0u8; HEADER_SIZE];
        out[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        out[4] = VERSION;
        out[5] = self.flags;
        out[6] = self.hash_id;
        out[7] = self.hash_size;
        out[8..12].copy_from_slice(&self.max_match.to_le_bytes());
        out[12..16].copy_from_slice(&self.block_count.to_le_bytes());
        out[16..24].copy_from_slice(&self.original_size.to_le_bytes());
        let crc = crc32c_of(&out[..24]);
        out[24..28].copy_from_slice(&crc.to_le_bytes());
        out
    }

    pub fn decode(b: &[u8]) -> Result<Header, V5Error> {
        if b.len() < HEADER_SIZE {
            return Err(V5Error::Truncated);
        }
        if u32::from_le_bytes(b[0..4].try_into().unwrap()) != MAGIC {
            return Err(V5Error::BadMagic);
        }
        if b[4] != VERSION {
            return Err(V5Error::BadVersion(b[4]));
        }
        let crc = u32::from_le_bytes(b[24..28].try_into().unwrap());
        if crc != crc32c_of(&b[..24]) {
            return Err(V5Error::BadCrc("header"));
        }
        let flags = b[5];
        if flags & !KNOWN_FLAGS != 0 {
            return Err(V5Error::BadFlags(flags));
        }
        Ok(Header {
            flags,
            hash_id: b[6],
            hash_size: b[7],
            max_match: u32::from_le_bytes(b[8..12].try_into().unwrap()),
            block_count: u32::from_le_bytes(b[12..16].try_into().unwrap()),
            original_size: u64::from_le_bytes(b[16..24].try_into().unwrap()),
        })
    }

    /// The hash descriptor `hash_id` names, cross-checked against `hash_size`
    /// so a mismatched pair is rejected instead of silently mis-read.
    pub fn hash(&self) -> Result<&'static HashInfo, V5Error> {
        let h = container::hash_by_num(self.hash_id)
            .ok_or(V5Error::BadHash { id: self.hash_id, size: self.hash_size })?;
        // `-hash-` is `id = 1` with no digest at all; otherwise the size must
        // be the one the descriptor declares.
        let expected = if h.name.is_empty() { 0 } else { h.hash_size };
        if self.hash_size != expected {
            return Err(V5Error::BadHash { id: self.hash_id, size: self.hash_size });
        }
        Ok(h)
    }
}

// ---------------------------------------------------------- footer --

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Footer {
    pub block_count: u32,
    pub stat_size: u64,
    pub meta_offset: u64,
    pub meta_size: u32,
}

impl Footer {
    pub fn encode(&self) -> [u8; FOOTER_SIZE] {
        let mut out = [0u8; FOOTER_SIZE];
        out[0..4].copy_from_slice(&FOOTER_MAGIC.to_le_bytes());
        out[4..8].copy_from_slice(&self.block_count.to_le_bytes());
        out[8..16].copy_from_slice(&self.stat_size.to_le_bytes());
        out[16..24].copy_from_slice(&self.meta_offset.to_le_bytes());
        out[24..28].copy_from_slice(&self.meta_size.to_le_bytes());
        let crc = crc32c_of(&out[..28]);
        out[28..32].copy_from_slice(&crc.to_le_bytes());
        out
    }

    pub fn decode(b: &[u8]) -> Result<Footer, V5Error> {
        if b.len() < FOOTER_SIZE {
            return Err(V5Error::Truncated);
        }
        if u32::from_le_bytes(b[0..4].try_into().unwrap()) != FOOTER_MAGIC {
            return Err(V5Error::BadFooterMagic);
        }
        let crc = u32::from_le_bytes(b[28..32].try_into().unwrap());
        if crc != crc32c_of(&b[..28]) {
            return Err(V5Error::BadCrc("footer"));
        }
        Ok(Footer {
            block_count: u32::from_le_bytes(b[4..8].try_into().unwrap()),
            stat_size: u64::from_le_bytes(b[8..16].try_into().unwrap()),
            meta_offset: u64::from_le_bytes(b[16..24].try_into().unwrap()),
            meta_size: u32::from_le_bytes(b[24..28].try_into().unwrap()),
        })
    }
}

// --------------------------------------------------------- records --

/// One decoded v5 record (`docs/format-spec-v5.md` §3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Record {
    pub lit_len: u64,
    pub match_len: u64,
    pub distance: u64,
}

impl Record {
    pub fn encode(&self, out: &mut Vec<u8>) {
        put_varint(out, self.lit_len);
        put_varint(out, self.match_len);
        put_varint(out, self.distance);
    }

    pub fn decode(b: &[u8], pos: &mut usize) -> Result<Record, V5Error> {
        let lit_len = get_varint(b, pos)?;
        let match_len = get_varint(b, pos)?;
        let distance = get_varint(b, pos)?;
        Ok(Record {
            lit_len,
            match_len,
            distance,
        })
    }
}

/// Walk a block's whole match list (the `statsize` bytes the block header
/// declares) into records. `docs/format-spec-v5.md` §6 uses this to compare a
/// v4 archive's matches with a v5 one's, triple by triple.
pub fn decode_records(list: &[u8]) -> Result<Vec<Record>, V5Error> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < list.len() {
        out.push(Record::decode(list, &mut pos)?);
    }
    Ok(out)
}

// ---------------------------------------------------------- reader --

/// One block of a parsed archive, borrowed from the input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockView<'a> {
    pub literal_bytes: u32,
    pub origsize: u32,
    pub statsize: u32,
    pub digest: &'a [u8],
    pub literals: &'a [u8],
    pub records: Vec<Record>,
}

/// A v5 archive taken apart, without reconstructing the data.
///
/// Reconstruction is deliberately *not* done here: a v5 block's records are
/// anchored at their **source** (`src = block cursor + lit_len`,
/// `dest = src + distance`), exactly like v3/v4, so the destination of a match
/// can lie far ahead of the block that carries it. That is what
/// `future_lz.rs` implements with the VM, and a plain in-order pass over the
/// bytes cannot honour it. The v5 front-end for that decoder arrives with the
/// CLI; what this checks is the container and the record syntax.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed<'a> {
    pub header: Header,
    pub seed: &'a [u8],
    pub blocks: Vec<BlockView<'a>>,
    pub footer: Footer,
}

/// Take a v5 archive apart, validating every structure it can without
/// reconstructing: the three CRCs, the magic numbers, the flags, the hash
/// pair, the block count agreement, and every varint.
pub fn parse(bytes: &[u8]) -> Result<Parsed<'_>, V5Error> {
    let header = Header::decode(bytes)?;
    let hash = header.hash()?;
    let hash_size = header.hash_size as usize;

    let mut pos = HEADER_SIZE;
    let seed_size = hash.seed_size as usize;
    if bytes.len() < pos + seed_size + FOOTER_SIZE {
        return Err(V5Error::Truncated);
    }
    let seed = &bytes[pos..pos + seed_size];
    pos += seed_size;

    let mut blocks: Vec<BlockView> = Vec::with_capacity(header.block_count as usize);
    let mut total_stat: u64 = 0;
    for block in 0..header.block_count as usize {
        if bytes.len() < pos + BLOCK_HEADER_SIZE + hash_size {
            return Err(V5Error::Truncated);
        }
        // The block header keeps the C++'s field order (`srep.cpp:743-747`):
        // literal bytes, block size, match-list bytes.
        let literal_bytes = u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap());
        let origsize = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap());
        let statsize = u32::from_le_bytes(bytes[pos + 8..pos + 12].try_into().unwrap());
        pos += BLOCK_HEADER_SIZE;
        if bytes.len() < pos + hash_size + statsize as usize + literal_bytes as usize {
            return Err(V5Error::Truncated);
        }
        let digest = &bytes[pos..pos + hash_size];
        pos += hash_size;
        // A self-contained block: the records, then the literals it leaves.
        let records = decode_records(&bytes[pos..pos + statsize as usize])?;
        pos += statsize as usize;
        let literals = &bytes[pos..pos + literal_bytes as usize];
        pos += literal_bytes as usize;
        total_stat += statsize as u64;
        let _ = block;
        blocks.push(BlockView {
            literal_bytes,
            origsize,
            statsize,
            digest,
            literals,
            records,
        });
    }

    // The footer is always the last thing in the file, so it can be read
    // before the blocks it follows -- which is what tells us how big the
    // `-dup` blob sitting between them is.
    if bytes.len() < FOOTER_SIZE {
        return Err(V5Error::Truncated);
    }
    let footer = Footer::decode(&bytes[bytes.len() - FOOTER_SIZE..])?;
    if footer.block_count != header.block_count || footer.stat_size != total_stat {
        return Err(V5Error::BlockCountMismatch);
    }
    if pos as u64 + u64::from(footer.meta_size) + FOOTER_SIZE as u64 != bytes.len() as u64 {
        return Err(V5Error::BadMeta);
    }
    // Validate the blob here too, so `parse` alone rejects a corrupt archive.
    if let Some(meta) = dup_meta(bytes, &footer, &header)? {
        let _ = meta;
    }
    Ok(Parsed {
        header,
        seed,
        blocks,
        footer,
    })
}

/// What `--verify` checked, so the caller can say it rather than imply it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerifyReport {
    pub blocks: u32,
    pub original_size: u64,
    pub records: u64,
    /// Whether the archive carries a `-dup` meta blob (covered by `meta_crc`).
    pub has_dup_meta: bool,
    /// True when the archive stores per-block digests. They are digests of the
    /// *decoded* bytes, so verification cannot use them -- their presence is
    /// what a later full check would rely on.
    pub has_block_digests: bool,
}

/// Check everything a v5 archive can be checked for **without reconstructing
/// it**, which is the thing v4 cannot offer at all: v4 has no checksum
/// anywhere, so the only way to know a v4 archive is sound is to decompress it.
///
/// What this covers, all of it structural or checksummed:
///
/// * `header_crc`, `footer_crc` and `meta_crc` (via [`parse`]);
/// * the magic numbers, the `flags` bits, and that `hash_id`/`hash_size`
///   describe a real function;
/// * the two block counts agreeing, `stat_size` matching the blocks walked,
///   and the file ending exactly where the footer says -- so truncation and
///   trailing junk are both caught;
/// * every varint decoding, and every record passing the same range rules the
///   decoder applies: its match source inside its block, its length fitting,
///   and its destination ahead of the source and inside the stream;
/// * the blocks' `origsize` summing to the header's `original_size`.
///
/// What it **cannot** cover: a bit flipped inside a literal run, or inside a
/// varint in a way that keeps it well-formed and keeps the arithmetic
/// consistent. Nothing in a v5 archive checksums the stored block bytes, so
/// that damage is only found by decoding, where the per-block digest catches
/// it. Saying so is the point -- a verify that implied more than it checked
/// would be worse than none.
pub fn verify(bytes: &[u8]) -> Result<VerifyReport, V5Error> {
    let parsed = parse(bytes)?;

    let mut block_start: u64 = 0;
    let mut records: u64 = 0;
    for b in &parsed.blocks {
        let block_end = block_start
            .checked_add(u64::from(b.origsize))
            .ok_or(V5Error::BadBlock)?;

        // The same range rules `decompress_block` (`future_lz.rs:544-551`)
        // applies as it walks a block, checked here without applying them.
        // Future-LZ records are not "literal run then match": `lit_len` is the
        // gap to the next match *source*, the match is copied *forward* to
        // `src + distance`, and the cursor advances to `src` -- not past the
        // match. Assuming the usual LZ arithmetic here is wrong, and a check
        // built on it rejects healthy archives.
        let mut pos = block_start;
        for r in &b.records {
            let src = pos.checked_add(r.lit_len).ok_or(V5Error::BadBlock)?;
            if src >= block_end {
                return Err(V5Error::BadBlock);
            }
            if r.match_len > block_end - src {
                return Err(V5Error::BadBlock);
            }
            // `dest <= src` is rejected by the decoder: a Future-LZ match
            // always points ahead.
            if r.distance == 0 {
                return Err(V5Error::BadBlock);
            }
            let dest = src.checked_add(r.distance).ok_or(V5Error::BadBlock)?;
            // And it has to land inside the stream it is describing.
            if dest.checked_add(r.match_len).ok_or(V5Error::BadBlock)?
                > parsed.header.original_size
            {
                return Err(V5Error::BadBlock);
            }
            pos = src;
        }
        records += b.records.len() as u64;
        block_start = block_end;
    }
    // The blocks have to describe exactly the stream the header claims.
    if block_start != parsed.header.original_size {
        return Err(V5Error::BadBlock);
    }

    Ok(VerifyReport {
        blocks: parsed.header.block_count,
        original_size: parsed.header.original_size,
        records,
        has_dup_meta: parsed.footer.meta_size > 0,
        has_block_digests: parsed.header.hash_size > 0,
    })
}

/// `hash_func(hash_obj, buf, size, out)` over one block. The reconstruction
/// step (CLI) verifies each block with it.
#[allow(dead_code)]
fn digest_matches(hash: &'static HashInfo, seed: &[u8], data: &[u8], expected: &[u8]) -> bool {
    match hash.name {
        "vmac" => {
            let mut key = [0u8; vmac::VMAC_KEY_LEN_BYTES];
            key.copy_from_slice(seed);
            vmac::Vmac::new(&key).compute(data).as_slice() == expected
        }
        "siphash" => {
            let mut key = [0u8; crate::hashes_keyed::SIPHASH_KEY_LEN_BYTES];
            key.copy_from_slice(seed);
            crate::hashes_keyed::siphash(&key, data).as_slice() == expected
        }
        "md5" => crate::hashes::md5(data).as_slice() == expected,
        "sha1" => crate::hashes::sha1(data).as_slice() == expected,
        "sha512" => crate::hashes::sha512(data).as_slice() == expected,
        _ => true, // the digest field is absent when hash_size == 0
    }
}

/// Build the v5 `-dup` meta blob from a `.dupref` payload: the payload
/// unchanged, plus a trailing CRC-32C over all of it.
///
/// v4 appends that payload as a bare ODUP trailer with no integrity at all, and
/// finds it by sniffing the last four bytes -- which is what mis-handles
/// `osrep -d archive.osr` (implicit output) and `-i`. v5 writes the same bytes
/// with a checksum, and the footer says where they are.
///
/// The payload already starts with the `.dupref` header, so the blob's first
/// four bytes are `DUPR` exactly as in v4, and `meta_size` is
/// `payload.len() + META_OVERHEAD` (`docs/format-spec-v5.md` §2). Rejecting a
/// payload that is not a `.dupref` blob keeps a caller from silently writing an
/// archive that no reader can take apart.
pub fn encode_meta(dupref: &[u8]) -> Result<Vec<u8>, V5Error> {
    if !is_dupref(dupref) {
        return Err(V5Error::BadMeta);
    }
    let mut out = Vec::with_capacity(dupref.len() + META_OVERHEAD);
    out.extend_from_slice(dupref);
    let crc = crc32c_of(&out);
    out.extend_from_slice(&crc.to_le_bytes());
    Ok(out)
}

/// The `.dupref` header a payload must carry: the magic, the version, and
/// enough bytes for the two counts (`docs/format-spec.md` §3.1).
fn is_dupref(payload: &[u8]) -> bool {
    payload.len() >= META_PAYLOAD_HEADER_SIZE
        && payload[..4] == *META_MAGIC
        && payload[4] == META_VERSION
}

/// The `-dup` meta blob's location, from the footer's `meta_offset`/`meta_size`.
/// Returns the `.dupref` payload inside it, checksum verified.
pub fn dup_meta<'a>(bytes: &'a [u8], footer: &Footer, header: &Header) -> Result<Option<&'a [u8]>, V5Error> {
    if header.flags & FLAG_HAS_DUP == 0 {
        return Ok(None);
    }
    if footer.meta_size == 0 {
        return Err(V5Error::BadMeta);
    }
    let start = footer.meta_offset as usize;
    let end = start
        .checked_add(footer.meta_size as usize)
        .ok_or(V5Error::BadMeta)?;
    if end > bytes.len() {
        return Err(V5Error::BadMeta);
    }
    Ok(Some(decode_meta(&bytes[start..end])?))
}

/// Take a standalone meta blob apart: the `.dupref` payload it carries, with
/// the trailing CRC verified. `dup_meta` is the same thing for a caller that
/// has the whole archive; this one is for a caller that read just the blob,
/// which is what a decoder working over a file (rather than a byte slice) has.
pub fn decode_meta(blob: &[u8]) -> Result<&[u8], V5Error> {
    if blob.len() < META_PAYLOAD_HEADER_SIZE + META_OVERHEAD {
        return Err(V5Error::BadMeta);
    }
    let (payload, crc_bytes) = blob.split_at(blob.len() - META_OVERHEAD);
    if !is_dupref(payload) {
        return Err(V5Error::BadMeta);
    }
    let crc = u32::from_le_bytes(crc_bytes.try_into().unwrap());
    if crc != crc32c_of(payload) {
        return Err(V5Error::BadCrc("meta"));
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The smallest legal archive, built by hand: one block whose second half
    /// is a copy of its first, with checksums disabled (`hash_id = 1`).
    fn synthetic() -> Vec<u8> {
        let header = Header {
            flags: 0,
            hash_id: 1,
            hash_size: 0,
            max_match: DEFAULT_MAX_MATCH,
            block_count: 1,
            original_size: 16,
        };
        let mut out = header.encode().to_vec();
        // block header: literal bytes, block size, match-list bytes
        out.extend_from_slice(&8u32.to_le_bytes());
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&3u32.to_le_bytes());
        // the match list: lit_len=8, match_len=8, distance=8
        Record {
            lit_len: 8,
            match_len: 8,
            distance: 8,
        }
        .encode(&mut out);
        // ... then the literals, then the footer (v5 blocks are self-contained)
        out.extend_from_slice(b"abcdefgh");
        out.extend_from_slice(
            &Footer {
                block_count: 1,
                stat_size: 3,
                meta_offset: 0,
                meta_size: 0,
            }
            .encode(),
        );
        out
    }

    #[test]
    fn varint_round_trips_at_the_boundaries() {
        for v in [0u64, 1, 0x7F, 0x80, 0x3FFF, 0x4000, u32::MAX as u64, u64::MAX] {
            let mut buf = Vec::new();
            put_varint(&mut buf, v);
            let mut pos = 0usize;
            assert_eq!(get_varint(&buf, &mut pos).unwrap(), v, "v={v}");
            assert_eq!(pos, buf.len());
        }
    }

    #[test]
    fn varint_rejects_unterminated_and_overwide() {
        let mut pos = 0usize;
        assert_eq!(get_varint(&[0x80, 0x80], &mut pos), Err(V5Error::BadVarint));
        let over = [0xFFu8; 11]; // more than 64 bits of payload
        let mut pos = 0usize;
        assert_eq!(get_varint(&over, &mut pos), Err(V5Error::BadVarint));
    }

    #[test]
    fn header_and_footer_reject_a_flipped_bit() {
        let mut bytes = synthetic();
        bytes[20] ^= 0x01; // inside the header's original_size
        assert!(matches!(parse(&bytes), Err(V5Error::BadCrc("header"))));

        let mut bytes = synthetic();
        let n = bytes.len();
        bytes[n - 12] ^= 0x01; // inside the footer's stat_size
        assert!(matches!(parse(&bytes), Err(V5Error::BadCrc("footer"))));
    }

    #[test]
    fn header_rejects_bad_magic_version_flags_and_hash() {
        let mut b = Header {
            flags: 0,
            hash_id: 1,
            hash_size: 0,
            max_match: 1,
            block_count: 0,
            original_size: 0,
        }
        .encode();
        b[0] ^= 0xFF;
        assert_eq!(Header::decode(&b), Err(V5Error::BadMagic));

        let mut b = synthetic();
        b[4] = 4;
        let crc = crc32c_of(&b[..24]);
        b[24..28].copy_from_slice(&crc.to_le_bytes());
        assert_eq!(Header::decode(&b), Err(V5Error::BadVersion(4)));

        let mut b = synthetic();
        b[5] = 0x80; // an undefined flag bit
        let crc = crc32c_of(&b[..24]);
        b[24..28].copy_from_slice(&crc.to_le_bytes());
        assert_eq!(Header::decode(&b), Err(V5Error::BadFlags(0x80)));

        // The disabled hash must declare size 0: the header parses (it does not
        // know the descriptor table), but resolving it does not.
        let mut b = synthetic();
        b[7] = 16;
        let crc = crc32c_of(&b[..24]);
        b[24..28].copy_from_slice(&crc.to_le_bytes());
        assert!(matches!(
            parse(&b),
            Err(V5Error::BadHash { id: 1, size: 16 })
        ));
    }

    #[test]
    fn parses_a_synthetic_block() {
        let bytes = synthetic();
        let p = parse(&bytes).unwrap();
        assert_eq!(p.header.original_size, 16);
        assert_eq!(p.blocks.len(), 1);
        let b = &p.blocks[0];
        assert_eq!(b.literals, b"abcdefgh");
        assert_eq!(b.origsize, 16);
        assert_eq!(b.literal_bytes, 8);
        assert_eq!(b.statsize, 3);
        assert!(b.digest.is_empty()); // hash_size == 0 means no digest at all
        assert_eq!(
            b.records,
            vec![Record {
                lit_len: 8,
                match_len: 8,
                distance: 8
            }]
        );
        assert_eq!(p.footer.stat_size, 3);
    }

    #[test]
    fn rejects_a_record_list_that_runs_past_its_size() {
        let mut bytes = synthetic();
        // The list is the 3 bytes before the literals and the footer.
        let list_at = bytes.len() - FOOTER_SIZE - 8 - 3;
        assert_eq!(bytes[list_at], 8);
        bytes[list_at + 2] = 0x80; // a continuation bit with nothing after it
        assert_eq!(parse(&bytes), Err(V5Error::BadVarint));
    }

    #[test]
    fn rejects_a_block_count_that_disagrees_with_the_footer() {
        let mut bytes = synthetic();
        bytes[12] = 2; // header.block_count = 2
        let crc = crc32c_of(&bytes[..24]);
        bytes[24..28].copy_from_slice(&crc.to_le_bytes());
        // The reader now expects a second block where the footer is; which
        // error fires depends on how those bytes parse. What matters is that it
        // is rejected rather than silently truncated.
        assert!(parse(&bytes).is_err());
    }
}

#[cfg(test)]
mod meta_tests {
    use super::*;
    use crate::encoder::{self, Container, EncodeOptions, Kind, Mode, Seed};
    use std::io::Cursor;

    /// Encode with a `-dup` payload and read it back through the footer.
    ///
    /// The payload is a real `.dupref` blob rather than arbitrary bytes,
    /// because what this has to catch is v5 wrapping it a *second* time: the
    /// stored blob must be that payload plus nothing but the CRC.
    #[test]
    fn dup_meta_round_trips_through_the_writer() {
        let mut data = Vec::new();
        for i in 0..400_000u32 {
            data.push((i % 251) as u8);
        }
        let (payload, _body) =
            crate::dedup::encode_split(&data, crate::dedup::Params::default()).unwrap();

        let opts = EncodeOptions {
            dup_meta: Some(payload.clone()),
            seed: Seed::Value(7),
            ..EncodeOptions::default()
        };
        let mut input = Cursor::new(data.clone());
        let mut out = Vec::new();
        encoder::encode(
            &mut input,
            &mut out,
            &opts,
            Mode {
                kind: Kind::Digest,
                container: Container::V5,
            },
            None,
            None,
        )
        .unwrap();

        let parsed = parse(&out).unwrap();
        assert_eq!(parsed.header.flags & FLAG_HAS_DUP, FLAG_HAS_DUP);
        assert_eq!(parsed.footer.meta_size as usize, payload.len() + META_OVERHEAD);
        assert_eq!(
            parsed.footer.meta_offset as usize + parsed.footer.meta_size as usize + FOOTER_SIZE,
            out.len()
        );
        // The bytes on disk: the payload verbatim, then the CRC. A `DUPR`
        // header of its own in front would make the dedup pass read the blob
        // one field out of step.
        let at = parsed.footer.meta_offset as usize;
        let blob = &out[at..at + parsed.footer.meta_size as usize];
        assert_eq!(&blob[..payload.len()], &payload[..]);
        assert_eq!(&blob[payload.len()..], &crc32c_of(&payload).to_le_bytes());

        let got = dup_meta(&out, &parsed.footer, &parsed.header).unwrap();
        assert_eq!(got, Some(&payload[..]));

        // A payload byte flipped after the fact must be caught by the meta CRC.
        let mut corrupt = out.clone();
        corrupt[at + 8] ^= 0x01;
        assert!(matches!(
            dup_meta(&corrupt, &parsed.footer, &parsed.header),
            Err(V5Error::BadCrc("meta"))
        ));
    }

    /// A payload that is not a `.dupref` blob is refused when the blob is
    /// built, rather than written into an archive no reader can take apart.
    #[test]
    fn a_payload_that_is_not_dupref_is_refused() {
        assert_eq!(encode_meta(b"not a .dupref blob"), Err(V5Error::BadMeta));

        let mut header = [0u8; META_PAYLOAD_HEADER_SIZE];
        header[..4].copy_from_slice(META_MAGIC);
        header[4] = META_VERSION;
        assert!(encode_meta(&header).is_ok());

        header[4] = META_VERSION + 1;
        assert_eq!(encode_meta(&header), Err(V5Error::BadMeta));
        header[4] = META_VERSION;
        header[0] = b'X';
        assert_eq!(encode_meta(&header), Err(V5Error::BadMeta));
    }

    /// Without a payload nothing is written and the footer says so.
    #[test]
    fn no_dup_meta_leaves_the_footer_clean() {
        let data = vec![7u8; 100_000];
        let mut opts = EncodeOptions::default();
        opts.seed = Seed::Value(7);
        let mut input = Cursor::new(data);
        let mut out = Vec::new();
        encoder::encode(
            &mut input,
            &mut out,
            &opts,
            Mode {
                kind: Kind::Digest,
                container: Container::V5,
            },
            None,
            None,
        )
        .unwrap();
        let parsed = parse(&out).unwrap();
        assert_eq!(parsed.header.flags, 0);
        assert_eq!(parsed.footer.meta_offset, 0);
        assert_eq!(parsed.footer.meta_size, 0);
        assert_eq!(dup_meta(&out, &parsed.footer, &parsed.header).unwrap(), None);
    }
}
