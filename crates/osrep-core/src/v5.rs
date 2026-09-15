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

/// What a decoded v5 archive yields: the original bytes plus, per block, the
/// match list it carried (for the stream-equivalence gate).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decoded {
    pub output: Vec<u8>,
    pub matches: Vec<Vec<Record>>,
    pub header: Header,
}

/// Decode a whole v5 archive held in memory.
///
/// The output is a plain `Vec`, so a match may reach back into any byte written
/// before it -- the cross-block references the format allows. That is what the
/// C++ does through a `Read + Write + Seek` file; the port keeps the same
/// semantics in memory, which is enough for the conformance gate and the
/// matrix sizes it uses.
pub fn decode(bytes: &[u8]) -> Result<Decoded, V5Error> {
    let header = Header::decode(bytes)?;
    let hash = header.hash()?;

    let mut pos = HEADER_SIZE;
    let seed_size = hash.seed_size as usize;
    if bytes.len() < pos + seed_size + FOOTER_SIZE {
        return Err(V5Error::Truncated);
    }
    let seed = &bytes[pos..pos + seed_size];
    pos += seed_size;

    let block_count = header.block_count as usize;
    let mut block_headers: Vec<(u32, u32, u32)> = Vec::with_capacity(block_count);
    let mut literals: Vec<&[u8]> = Vec::with_capacity(block_count);
    let hash_size = header.hash_size as usize;
    for _ in 0..block_count {
        if bytes.len() < pos + BLOCK_HEADER_SIZE + hash_size {
            return Err(V5Error::Truncated);
        }
        let origsize = u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap());
        let literal_bytes = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap());
        let statsize = u32::from_le_bytes(bytes[pos + 8..pos + 12].try_into().unwrap());
        let digest_at = pos + BLOCK_HEADER_SIZE;
        let digest = &bytes[digest_at..digest_at + hash_size];
        let lit_at = digest_at + hash_size;
        if bytes.len() < lit_at + literal_bytes as usize {
            return Err(V5Error::Truncated);
        }
        literals.push(&bytes[lit_at..lit_at + literal_bytes as usize]);
        block_headers.push((origsize, literal_bytes, statsize));
        pos = lit_at + literal_bytes as usize;

        // Verify the digest here so a corrupt block is caught before its
        // matches are replayed.
        if hash_size > 0 {
            if !digest_matches(hash, seed, literals.last().unwrap(), digest) {
                return Err(V5Error::BadDigest {
                    block: block_headers.len() - 1,
                });
            }
        }
    }

    // The match lists and the table, then the footer.
    if bytes.len() < pos + FOOTER_SIZE {
        return Err(V5Error::Truncated);
    }
    let footer = Footer::decode(&bytes[bytes.len() - FOOTER_SIZE..])?;
    if footer.block_count != header.block_count {
        return Err(V5Error::BlockCountMismatch);
    }

    // The lists sit just before the table; the table just before the footer.
    let table_len = block_count * 4;
    let lists_end = bytes.len() - FOOTER_SIZE - table_len;
    let mut total_stat: u64 = 0;
    for (_, _, statsize) in &block_headers {
        total_stat += *statsize as u64;
    }
    if total_stat != footer.stat_size {
        return Err(V5Error::BlockCountMismatch);
    }
    if lists_end < total_stat as usize {
        return Err(V5Error::Truncated);
    }
    let lists_start = lists_end - total_stat as usize;

    // Rebuild: literals and matches interleave per block, in order.
    let mut output: Vec<u8> = Vec::with_capacity(header.original_size as usize);
    let mut matches: Vec<Vec<Record>> = Vec::with_capacity(block_count);
    let mut list_pos = lists_start;
    for (block, (origsize, _literal_bytes, statsize)) in block_headers.iter().enumerate() {
        let list = &bytes[list_pos..list_pos + *statsize as usize];
        list_pos += *statsize as usize;
        let records = decode_records(list)?;

        let mut lit_pos = 0usize;
        for r in &records {
            let lit = r.lit_len as usize;
            if lit > literals[block].len() - lit_pos {
                return Err(V5Error::BadBlock);
            }
            output.extend_from_slice(&literals[block][lit_pos..lit_pos + lit]);
            lit_pos += lit;
            let dest = output.len() as u64;
            if r.distance > dest || r.match_len > u64::MAX / 2 {
                return Err(V5Error::BadBlock);
            }
            let src = (dest - r.distance) as usize;
            let len = r.match_len as usize;
            // A match may overlap its own output (LZ77 replication), so this is
            // a forward byte copy, not a `copy_within`.
            for i in 0..len {
                let b = output[src + i];
                output.push(b);
            }
        }
        output.extend_from_slice(&literals[block][lit_pos..]);
        let produced = output.len() as u64;
        let _ = origsize;
        let _ = produced;
        matches.push(records);
    }

    if output.len() as u64 != header.original_size {
        return Err(V5Error::BlockCountMismatch);
    }
    Ok(Decoded {
        output,
        matches,
        header,
    })
}

/// `hash_func(hash_obj, buf, size, out)` over one block.
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

/// The `-dup` meta blob's location, from the footer's `meta_offset`/`meta_size`.
/// v5 finds it by arithmetic instead of sniffing `"ODUP"` in the last four
/// bytes, which is what used to mis-handle `osrep -d archive.osr` (implicit
/// output) and `-i`.
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
    let meta = &bytes[start..end];
    // The blob is `DUPR ... meta_crc`, the CRC covering everything before it.
    if meta.len() < 8 || &meta[..4] != b"DUPR" {
        return Err(V5Error::BadMeta);
    }
    let crc = u32::from_le_bytes(meta[meta.len() - 4..].try_into().unwrap());
    if crc != crc32c_of(&meta[..meta.len() - 4]) {
        return Err(V5Error::BadCrc("meta"));
    }
    Ok(Some(meta))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build the smallest legal archive by hand: one block whose second half is
    /// a copy of its first, with checksums disabled (`hash_id = 1`).
    fn synthetic() -> Vec<u8> {
        let header = Header {
            flags: 0,
            hash_id: 1,
            hash_size: 0,
            max_match: 8128,
            block_count: 1,
            original_size: 16,
        };
        let mut out = header.encode().to_vec();
        // block header: origsize, literal_bytes, statsize
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&8u32.to_le_bytes());
        out.extend_from_slice(&3u32.to_le_bytes());
        // no digest (hash_size == 0), then the literals
        out.extend_from_slice(b"abcdefgh");
        // the match list: lit_len=8, match_len=8, distance=8
        Record {
            lit_len: 8,
            match_len: 8,
            distance: 8,
        }
        .encode(&mut out);
        // block-size table, then the footer
        out.extend_from_slice(&3u32.to_le_bytes());
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
        for v in [
            0u64,
            1,
            0x7F,
            0x80,
            0x3FFF,
            0x4000,
            u32::MAX as u64,
            u64::MAX,
        ] {
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
        // Eleven continuation bytes: more than 64 bits of payload.
        let over = [0xFFu8; 11];
        let mut pos = 0usize;
        assert_eq!(get_varint(&over, &mut pos), Err(V5Error::BadVarint));
    }

    #[test]
    fn header_and_footer_reject_a_flipped_bit() {
        let mut bytes = synthetic();
        bytes[20] ^= 0x01; // inside the header's original_size
        assert_eq!(decode(&bytes), Err(V5Error::BadCrc("header")));

        let mut bytes = synthetic();
        let n = bytes.len();
        bytes[n - 12] ^= 0x01; // inside the footer's stat_size
        assert_eq!(decode(&bytes), Err(V5Error::BadCrc("footer")));
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
        // Recompute the CRC so the version check is what fires.
        let crc = crc32c_of(&b[..24]);
        b[24..28].copy_from_slice(&crc.to_le_bytes());
        assert_eq!(Header::decode(&b), Err(V5Error::BadVersion(4)));

        let mut b = synthetic();
        b[5] = 0x80; // an undefined flag bit
        let crc = crc32c_of(&b[..24]);
        b[24..28].copy_from_slice(&crc.to_le_bytes());
        assert_eq!(Header::decode(&b), Err(V5Error::BadFlags(0x80)));

        // The disabled hash must declare size 0: the header parses (it does
        // not know the descriptor table), but resolving it does not.
        let mut b = synthetic();
        b[7] = 16;
        let crc = crc32c_of(&b[..24]);
        b[24..28].copy_from_slice(&crc.to_le_bytes());
        assert_eq!(Header::decode(&b).unwrap().hash_size, 16);
        assert_eq!(
            decode(&b),
            Err(V5Error::BadHash { id: 1, size: 16 })
        );
    }

    #[test]
    fn decodes_a_synthetic_block() {
        let d = decode(&synthetic()).unwrap();
        assert_eq!(d.output, b"abcdefghabcdefgh");
        assert_eq!(
            d.matches,
            vec![vec![Record {
                lit_len: 8,
                match_len: 8,
                distance: 8
            }]]
        );
        assert_eq!(d.header.original_size, 16);
    }

    #[test]
    fn rejects_a_distance_reaching_before_the_output() {
        let mut bytes = synthetic();
        // The list is the 3 bytes before the table and footer.
        let list_at = bytes.len() - FOOTER_SIZE - 4 - 3;
        assert_eq!(bytes[list_at], 8);
        bytes[list_at + 2] = 100; // distance 100 > the 16 bytes written
        // The lists are not covered by a CRC, so nothing else has to change.
        assert_eq!(decode(&bytes), Err(V5Error::BadBlock));
    }

    #[test]
    fn rejects_a_block_count_that_disagrees_with_the_footer() {
        let mut bytes = synthetic();
        bytes[12] = 2; // header.block_count = 2
        let crc = crc32c_of(&bytes[..24]);
        bytes[24..28].copy_from_slice(&crc.to_le_bytes());
        // The reader runs off the end of the data before it reaches the footer.
        assert!(matches!(
            decode(&bytes),
            Err(V5Error::Truncated) | Err(V5Error::BlockCountMismatch)
        ));
    }
}
