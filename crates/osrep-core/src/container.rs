//! `.osr` container framing -- the bytes around the LZ payload.
//!
//! Rust port of the on-disk structures that `srep.cpp` writes and reads:
//!
//! * the 16-byte archive header (`srep.cpp:671-681` write, `:1003-1016` read)
//! * the per-block header, `12 + hash_size` bytes (`srep.cpp:724-731`)
//! * the v4 index footer and its block-size table (`srep.cpp:964-976` write,
//!   `:1052-1078` read)
//! * the `-dup` ODUP trailer (`dup_wrapper.cpp:254-262` write, `:273-338` read)
//!
//! Only framing is modelled here: no match record is decoded and no LZ payload
//! is interpreted, so `parse` can walk any v1-v4 archive and recover the exact
//! uncompressed size without a decompressor. It takes the whole file as a
//! slice; the streaming reader that seeks instead of loading comes with the
//! decoder.
//!
//! Every integer is little-endian and unaligned (`docs/format-spec.md` §1.6).

/// `BULAT_ZIGANSHIN_SIGNATURE` (`Compression.h:19`).
pub const BULAT_ZIGANSHIN_SIGNATURE: u32 = 0x2635_1817;
/// `SREP_SIGNATURE` = `"OSRP"` little-endian (`srep.cpp:27`).
pub const SREP_SIGNATURE: u32 = 0x5052_534F;
/// The `~SREP_SIGNATURE` word stored in the v4 footer.
pub const SREP_SIGNATURE_INV: u32 = !SREP_SIGNATURE;
/// The `~BULAT_ZIGANSHIN_SIGNATURE` word stored in the v4 footer.
pub const BULAT_ZIGANSHIN_SIGNATURE_INV: u32 = !BULAT_ZIGANSHIN_SIGNATURE;

/// `ARCHIVE_HEADER_SIZE` in `STAT`s, i.e. bytes.
pub const ARCHIVE_HEADER_SIZE: usize = 16;
/// `BLOCK_HEADER_SIZE` in `STAT`s, i.e. bytes; the digest follows it.
pub const BLOCK_HEADER_SIZE: usize = 12;
/// `INDEX_LZ_FOOTER_SIZE`: the fixed part of the v4 footer.
pub const INDEX_LZ_FOOTER_SIZE: usize = 24;
/// `SREP_FOOTER_VERSION1`: the only footer version defined.
pub const SREP_FOOTER_VERSION1: u32 = 1;
/// The `-dup` trailer magic (`dup_wrapper.cpp`).
pub const ODUP_MAGIC: [u8; 4] = *b"ODUP";

#[inline]
fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

// ----------------------------------------------------------- version --

/// `SREP_FORMAT_VERSION*`: how an archive stores its match lists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Version {
    /// I/O-LZ with round matches: 3 `STAT`s per record.
    V1 = 1,
    /// I/O-LZ: 4 `STAT`s per record.
    V2 = 2,
    /// Future-LZ: match lists inline, matches hoisted to their source block.
    V3 = 3,
    /// Index-LZ (the default): one concatenated match list after the blocks.
    V4 = 4,
}

impl Version {
    pub fn from_code(code: u32) -> Option<Version> {
        match code {
            1 => Some(Version::V1),
            2 => Some(Version::V2),
            3 => Some(Version::V3),
            4 => Some(Version::V4),
            _ => None,
        }
    }

    pub fn code(self) -> u32 {
        self as u32
    }

    /// `ROUND_MATCHES` (`srep.cpp:1043`): only v1 keeps the `L`-aligned form.
    pub fn round_matches(self) -> bool {
        self == Version::V1
    }

    /// `IO_LZ` (`srep.cpp:1044`): the v1/v2 decoder.
    pub fn io_lz(self) -> bool {
        self <= Version::V2
    }

    /// `FUTURE_LZ` (`srep.cpp:1045`).
    pub fn future_lz(self) -> bool {
        self == Version::V3
    }

    /// `INDEX_LZ` (`srep.cpp:1046`): the v4 decoder.
    pub fn index_lz(self) -> bool {
        self == Version::V4
    }

    /// `STATS_PER_MATCH(ROUND_MATCHES)`: 3 for v1, 4 otherwise.
    pub fn stats_per_match(self) -> usize {
        if self.round_matches() {
            3
        } else {
            4
        }
    }
}

// -------------------------------------------------------------- hash --

/// One row of `hash_descriptors[]` (`hashes.cpp:430-436`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HashInfo {
    /// Name used by `-hash=...`; empty for the descriptor that selects "off".
    pub name: &'static str,
    /// Numeric tag stored in the archive header.
    pub num: u8,
    /// Seed bytes that follow the archive header.
    pub seed_size: u8,
    /// Digest bytes stored in every block header.
    pub hash_size: u8,
}

/// `hash_descriptors[]`, in the order the C declares them.
pub const HASH_DESCRIPTORS: [HashInfo; 6] = [
    HashInfo {
        name: "md5",
        num: 0,
        seed_size: 0,
        hash_size: 16,
    },
    HashInfo {
        name: "",
        num: 1,
        seed_size: 0,
        hash_size: 16,
    },
    HashInfo {
        name: "sha1",
        num: 2,
        seed_size: 0,
        hash_size: 20,
    },
    HashInfo {
        name: "sha512",
        num: 3,
        seed_size: 0,
        hash_size: 64,
    },
    HashInfo {
        name: "vmac",
        num: 4,
        seed_size: 32,
        hash_size: 16,
    },
    HashInfo {
        name: "siphash",
        num: 5,
        seed_size: 16,
        hash_size: 8,
    },
];

/// `DEFAULT_HASH` (`hashes.cpp:438`).
pub const DEFAULT_HASH_NAME: &str = "vmac";

/// `hash_by_num` (`hashes.cpp:451`).
pub fn hash_by_num(num: u8) -> Option<&'static HashInfo> {
    HASH_DESCRIPTORS.iter().find(|h| h.num == num)
}

/// `hash_by_name` (`hashes.cpp:441`), an ASCII case-insensitive lookup. The
/// empty name resolves to the "checksums disabled" descriptor, which is what
/// `-hash-` selects; callers that must not accept an empty *option* enforce
/// that themselves (`srep.cpp:344`).
pub fn hash_by_name(name: &str) -> Option<&'static HashInfo> {
    HASH_DESCRIPTORS
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
}

// ------------------------------------------------------------- error --

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContainerError {
    /// Fewer bytes than the structure being read.
    Truncated,
    /// `header[0]`/`header[1]` are not the Omega SREP signatures.
    NotAnOsrepFile,
    /// `format_version` outside 1..=4 (`srep.cpp:1009`).
    UnsupportedVersion(u32),
    /// The v4 footer's inverted signatures do not match.
    NoFooter,
    /// `footer_version` is not the one version defined.
    UnsupportedFooterVersion(u32),
    /// `archive_header + footer + stat list` does not fit the file.
    FooterExceedsFile,
    /// The v4 block-size table and the block headers disagree.
    TableMismatch,
    /// Block headers do not tile the file exactly.
    BlockTiling { consumed: usize, expected: usize },
    /// The ODUP trailer's meta blob does not start with the `.dupref` magic.
    DupMetaNotDupr,
}

impl std::fmt::Display for ContainerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ContainerError::Truncated => write!(f, "truncated structure"),
            ContainerError::NotAnOsrepFile => write!(f, "not an Omega SREP file (.osr)"),
            ContainerError::UnsupportedVersion(v) => {
                write!(
                    f,
                    "incompatible compressed data format: v{v} (supports v1..v4)"
                )
            }
            ContainerError::NoFooter => write!(f, "no Omega SREP footer"),
            ContainerError::UnsupportedFooterVersion(v) => {
                write!(f, "incompatible footer format: v{v} (supports v1)")
            }
            ContainerError::FooterExceedsFile => write!(f, "footer + index exceeds the file size"),
            ContainerError::TableMismatch => {
                write!(f, "block-size table disagrees with the block headers")
            }
            ContainerError::BlockTiling { consumed, expected } => write!(
                f,
                "block headers consumed {consumed} bytes, expected {expected}"
            ),
            ContainerError::DupMetaNotDupr => {
                write!(f, "ODUP trailer present but the meta blob is not DUPR")
            }
        }
    }
}

impl std::error::Error for ContainerError {}

// ---------------------------------------------------- archive header --

/// The 16-byte archive header plus the hash seed that follows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArchiveHeader {
    pub version: Version,
    pub hash_num: u8,
    pub hash_seed_size: u8,
    pub hash_size: u8,
    /// `header[3]`: the match-length base, `BASE_LEN` for v1/v2 and 0 for v3/v4.
    pub base_len: u32,
}

impl ArchiveHeader {
    /// Build the header for a new archive, taking the hash sizes from the
    /// descriptor (`srep.cpp:674-678`).
    pub fn new(version: Version, hash: &HashInfo, base_len: u32) -> ArchiveHeader {
        ArchiveHeader {
            version,
            hash_num: hash.num,
            hash_seed_size: hash.seed_size,
            hash_size: hash.hash_size,
            base_len,
        }
    }

    /// The packed `header[2]` word. `hash_size - 16` wraps, which is how the
    /// 8-byte siphash digest is stored (`(8-16) << 24` = `0xF8000000`).
    pub fn selector_word(&self) -> u32 {
        self.version.code()
            | ((self.hash_num as u32) << 8)
            | ((self.hash_seed_size as u32) << 16)
            | ((self.hash_size as u32).wrapping_sub(16) << 24)
    }

    /// The hash descriptor this header names, if the tag is known.
    pub fn hash(&self) -> Option<&'static HashInfo> {
        hash_by_num(self.hash_num)
    }

    /// Serialize the 16 header bytes (the seed is written separately).
    pub fn encode(&self) -> [u8; ARCHIVE_HEADER_SIZE] {
        let mut out = [0u8; ARCHIVE_HEADER_SIZE];
        out[0..4].copy_from_slice(&BULAT_ZIGANSHIN_SIGNATURE.to_le_bytes());
        out[4..8].copy_from_slice(&SREP_SIGNATURE.to_le_bytes());
        out[8..12].copy_from_slice(&self.selector_word().to_le_bytes());
        out[12..16].copy_from_slice(&self.base_len.to_le_bytes());
        out
    }

    /// Parse and validate the 16 header bytes (`srep.cpp:1004-1016`).
    pub fn decode(b: &[u8]) -> Result<ArchiveHeader, ContainerError> {
        if b.len() < ARCHIVE_HEADER_SIZE {
            return Err(ContainerError::Truncated);
        }
        if u32_at(b, 0) != BULAT_ZIGANSHIN_SIGNATURE || u32_at(b, 4) != SREP_SIGNATURE {
            return Err(ContainerError::NotAnOsrepFile);
        }
        let w = u32_at(b, 8);
        let version =
            Version::from_code(w & 255).ok_or(ContainerError::UnsupportedVersion(w & 255))?;
        Ok(ArchiveHeader {
            version,
            hash_num: ((w >> 8) & 255) as u8,
            hash_seed_size: ((w >> 16) & 255) as u8,
            hash_size: (((w >> 24) + 16) & 255) as u8,
            base_len: u32_at(b, 12),
        })
    }
}

// ------------------------------------------------------ block header --

/// The `12 + hash_size`-byte header at the start of every block. The digest
/// follows the three words and is opaque to the container.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockHeader {
    /// `header[0]`: literal bytes this block contributes.
    pub literal_bytes: u32,
    /// `header[1]`: uncompressed size of this block.
    pub origsize: u32,
    /// `header[2]`: match-list bytes; **0 for v4**, where the size comes from
    /// the footer table instead (`srep.cpp:728`).
    pub statsize: u32,
}

impl BlockHeader {
    pub fn encode(&self) -> [u8; BLOCK_HEADER_SIZE] {
        let mut out = [0u8; BLOCK_HEADER_SIZE];
        out[0..4].copy_from_slice(&self.literal_bytes.to_le_bytes());
        out[4..8].copy_from_slice(&self.origsize.to_le_bytes());
        out[8..12].copy_from_slice(&self.statsize.to_le_bytes());
        out
    }

    pub fn decode(b: &[u8]) -> Result<BlockHeader, ContainerError> {
        if b.len() < BLOCK_HEADER_SIZE {
            return Err(ContainerError::Truncated);
        }
        Ok(BlockHeader {
            literal_bytes: u32_at(b, 0),
            origsize: u32_at(b, 4),
            statsize: u32_at(b, 8),
        })
    }
}

// ------------------------------------------------------------ footer --

/// The fixed 24 bytes at the very end of a v4 archive (`srep.cpp:1054-1065`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FooterHead {
    /// Total match-list bytes across all blocks (a 64-bit value in two words).
    pub total_stat_size: u64,
    /// `24 + 4 * block_count`.
    pub footer_size: u32,
    pub footer_version: u8,
}

impl FooterHead {
    /// Serialize the 24 footer bytes given the total and the table length.
    pub fn encode(total_stat_size: u64, block_count: usize) -> [u8; INDEX_LZ_FOOTER_SIZE] {
        let footer_size = INDEX_LZ_FOOTER_SIZE as u32 + 4 * block_count as u32;
        let mut out = [0u8; INDEX_LZ_FOOTER_SIZE];
        out[0..4].copy_from_slice(&(total_stat_size as u32).to_le_bytes());
        out[4..8].copy_from_slice(&((total_stat_size >> 32) as u32).to_le_bytes());
        out[8..12].copy_from_slice(&footer_size.to_le_bytes());
        out[12..16].copy_from_slice(&SREP_FOOTER_VERSION1.to_le_bytes());
        out[16..20].copy_from_slice(&SREP_SIGNATURE_INV.to_le_bytes());
        out[20..24].copy_from_slice(&BULAT_ZIGANSHIN_SIGNATURE_INV.to_le_bytes());
        out
    }

    pub fn decode(b: &[u8]) -> Result<FooterHead, ContainerError> {
        if b.len() < INDEX_LZ_FOOTER_SIZE {
            return Err(ContainerError::Truncated);
        }
        if u32_at(b, 16) != SREP_SIGNATURE_INV || u32_at(b, 20) != BULAT_ZIGANSHIN_SIGNATURE_INV {
            return Err(ContainerError::NoFooter);
        }
        let footer_version = (u32_at(b, 12) & 255) as u8;
        if u32::from(footer_version) != SREP_FOOTER_VERSION1 {
            return Err(ContainerError::UnsupportedFooterVersion(u32::from(
                footer_version,
            )));
        }
        Ok(FooterHead {
            total_stat_size: u64::from(u32_at(b, 0)) | (u64::from(u32_at(b, 4)) << 32),
            footer_size: u32_at(b, 8),
            footer_version,
        })
    }
}

/// The v4 index footer together with its block-size table: what the encoder
/// appends after the last block (`srep.cpp:964-976`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexFooter {
    pub total_stat_size: u64,
    /// One match-list size in bytes per block.
    pub block_stat_sizes: Vec<u32>,
}

impl IndexFooter {
    pub fn new(total_stat_size: u64, block_stat_sizes: Vec<u32>) -> IndexFooter {
        IndexFooter {
            total_stat_size,
            block_stat_sizes,
        }
    }

    pub fn footer_size(&self) -> u32 {
        INDEX_LZ_FOOTER_SIZE as u32 + 4 * self.block_stat_sizes.len() as u32
    }

    /// The bytes appended to the archive: the table, then the footer.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.footer_size() as usize);
        for s in &self.block_stat_sizes {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out.extend_from_slice(&FooterHead::encode(
            self.total_stat_size,
            self.block_stat_sizes.len(),
        ));
        out
    }

    /// Parse the table bytes that sit just before the 24-byte footer. The
    /// caller computes the length from `FooterHead::footer_size`.
    pub fn decode_table(b: &[u8]) -> Result<Vec<u32>, ContainerError> {
        if b.len() % 4 != 0 {
            return Err(ContainerError::TableMismatch);
        }
        Ok((0..b.len() / 4).map(|i| u32_at(b, i * 4)).collect())
    }
}

// ----------------------------------------------------------- ODUP -----

/// What the trailing bytes of a file turned out to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Trailer {
    /// No ODUP magic: the whole file is a standard archive.
    Plain,
    /// `-dup` archive: the first `body_len` bytes are a standard archive and
    /// `meta` is the `.dupref` blob (`dup_wrapper.cpp:299-338`).
    Odup { body_len: usize, meta: Vec<u8> },
}

/// Sniff the `-dup` ODUP trailer, mirroring `dup_wrapper.cpp`'s decision: the
/// magic alone selects the `-dup` path, and a meta blob that does not then
/// start with `DUPR` is a hard error rather than a fallback, because the
/// magic pair makes an accidental match ~2^-64.
pub fn split_trailer(bytes: &[u8]) -> Result<Trailer, ContainerError> {
    if bytes.len() < 12 || bytes[bytes.len() - 4..] != ODUP_MAGIC {
        return Ok(Trailer::Plain);
    }
    let meta_size =
        u64::from_le_bytes(bytes[bytes.len() - 12..bytes.len() - 4].try_into().unwrap());
    // meta_size was written as a size_t-derived u64; reject anything that
    // cannot fit before the 12-byte trailer.
    let avail = (bytes.len() - 12) as u64;
    if meta_size > avail {
        return Err(ContainerError::DupMetaNotDupr);
    }
    let body_len = bytes.len() - 12 - meta_size as usize;
    let meta = &bytes[body_len..body_len + meta_size as usize];
    if meta.len() < 4 || meta[0..4] != [0x44, 0x55, 0x50, 0x52] {
        return Err(ContainerError::DupMetaNotDupr);
    }
    Ok(Trailer::Odup {
        body_len,
        meta: meta.to_vec(),
    })
}

// ---------------------------------------------------------- archive --

/// Per-block framing as recovered from the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockInfo {
    pub header: BlockHeader,
    /// Match-list bytes actually belonging to this block. For v4 this is the
    /// table entry; otherwise it is `header.statsize`.
    pub stat_size: usize,
}

/// A structurally parsed archive: header, block framing and (for v4) footer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Archive {
    pub header: ArchiveHeader,
    pub blocks: Vec<BlockInfo>,
    /// Always 0 for v1/v2/v3; the footer table's sum for v4.
    pub total_stat_size: u64,
    /// Present for v4 only.
    pub footer: Option<IndexFooter>,
    /// Bytes after the last block structure (0 for a well-formed archive; the
    /// decoder tolerates a zero-length terminator block, so a parse may too).
    pub trailing_bytes: usize,
}

impl Archive {
    /// Bytes preceding the first block: header plus hash seed.
    pub fn seed_size(&self) -> usize {
        self.header.hash_seed_size as usize
    }

    /// Bytes in every block header: `12 + hash_size`.
    pub fn block_header_size(&self) -> usize {
        BLOCK_HEADER_SIZE + self.header.hash_size as usize
    }

    /// The true uncompressed size: the sum of the per-block sizes. This is
    /// `header[1]` in every version, including v4 where the match list is
    /// stored out of line.
    pub fn origsize(&self) -> u64 {
        self.blocks
            .iter()
            .map(|b| u64::from(b.header.origsize))
            .sum()
    }

    /// Total literal bytes, i.e. everything not covered by a match.
    pub fn literal_bytes(&self) -> u64 {
        self.blocks
            .iter()
            .map(|b| u64::from(b.header.literal_bytes))
            .sum()
    }

    /// Re-serialize the header and, for v4, the footer + table. Used by the
    /// conformance harness to prove the codec is byte-exact in both directions.
    pub fn header_bytes(&self) -> [u8; ARCHIVE_HEADER_SIZE] {
        self.header.encode()
    }

    pub fn footer_bytes(&self) -> Option<Vec<u8>> {
        self.footer.as_ref().map(|f| f.encode())
    }

    /// Walk the container without decoding any LZ payload.
    pub fn parse(bytes: &[u8]) -> Result<Archive, ContainerError> {
        let header = ArchiveHeader::decode(bytes)?;
        let block_header_size = BLOCK_HEADER_SIZE + header.hash_size as usize;
        let mut pos = ARCHIVE_HEADER_SIZE + header.hash_seed_size as usize;
        if pos > bytes.len() {
            return Err(ContainerError::Truncated);
        }

        let (footer, match_list_start) = if header.version.index_lz() {
            if bytes.len() < pos + INDEX_LZ_FOOTER_SIZE {
                return Err(ContainerError::Truncated);
            }
            let head = FooterHead::decode(&bytes[bytes.len() - INDEX_LZ_FOOTER_SIZE..])?;
            let stat_size = head.total_stat_size;
            let table_size = head
                .footer_size
                .checked_sub(INDEX_LZ_FOOTER_SIZE as u32)
                .ok_or(ContainerError::FooterExceedsFile)? as usize;
            // compsize = archive header + footer + match list, as
            // `srep.cpp:1060-1065` checks it.
            let start = (bytes.len() as u64)
                .checked_sub(u64::from(head.footer_size))
                .and_then(|v| v.checked_sub(stat_size))
                .ok_or(ContainerError::FooterExceedsFile)?;
            if start < pos as u64 || table_size % 4 != 0 {
                return Err(ContainerError::FooterExceedsFile);
            }
            let table_start = bytes.len() - head.footer_size as usize;
            let table = IndexFooter::decode_table(&bytes[table_start..table_start + table_size])?;
            (
                Some(IndexFooter {
                    total_stat_size: stat_size,
                    block_stat_sizes: table,
                }),
                start as usize,
            )
        } else {
            (None, bytes.len())
        };

        // Walk the blocks. For v4 they end where the concatenated match list
        // begins; for v1/v2/v3 they run to EOF.
        let mut blocks: Vec<BlockInfo> = Vec::new();
        let mut trailing_bytes = 0usize;
        loop {
            if pos == match_list_start {
                break;
            }
            if match_list_start - pos < block_header_size {
                return Err(ContainerError::BlockTiling {
                    consumed: pos,
                    expected: match_list_start,
                });
            }
            let bh = BlockHeader::decode(&bytes[pos..pos + BLOCK_HEADER_SIZE])?;
            if !header.version.index_lz() && bh.literal_bytes == 0 && bh.origsize == 0 {
                // A zero-length terminator block, which the decoder stops on
                // (`srep.cpp:1147`). The encoder never writes one.
                pos += block_header_size;
                trailing_bytes = match_list_start - pos;
                break;
            }
            let stat_size = if let Some(f) = &footer {
                let idx = blocks.len();
                if idx >= f.block_stat_sizes.len() {
                    return Err(ContainerError::TableMismatch);
                }
                // v4 writes header[2] as 0 and keeps the real size out of line.
                if bh.statsize != 0 {
                    return Err(ContainerError::TableMismatch);
                }
                f.block_stat_sizes[idx] as usize
            } else {
                bh.statsize as usize
            };
            // v4 keeps the match list out of line, so it is not part of the
            // per-block region here.
            let inline_stat = if footer.is_some() { 0 } else { stat_size };
            let need = block_header_size + inline_stat + bh.literal_bytes as usize;
            if match_list_start - pos < need {
                return Err(ContainerError::BlockTiling {
                    consumed: pos,
                    expected: match_list_start,
                });
            }
            blocks.push(BlockInfo {
                header: bh,
                stat_size,
            });
            pos += need;
        }

        if header.version.index_lz() {
            let f = footer.as_ref().unwrap();
            if f.block_stat_sizes.len() != blocks.len() {
                return Err(ContainerError::TableMismatch);
            }
            let table_sum: u64 = f.block_stat_sizes.iter().map(|s| u64::from(*s)).sum();
            if table_sum != f.total_stat_size {
                return Err(ContainerError::TableMismatch);
            }
            if match_list_start + f.total_stat_size as usize
                != bytes.len() - f.footer_size() as usize
            {
                return Err(ContainerError::TableMismatch);
            }
        }

        Ok(Archive {
            header,
            blocks,
            total_stat_size: footer.as_ref().map_or(0, |f| f.total_stat_size),
            footer,
            trailing_bytes,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hdr(version: Version, hash: &HashInfo, base_len: u32) -> ArchiveHeader {
        ArchiveHeader::new(version, hash, base_len)
    }

    #[test]
    fn header_round_trips_for_every_hash() {
        for hash in HASH_DESCRIPTORS {
            for version in [Version::V1, Version::V2, Version::V3, Version::V4] {
                let h = hdr(version, &hash, 0);
                let bytes = h.encode();
                let back = ArchiveHeader::decode(&bytes).unwrap();
                assert_eq!(h, back, "hash {} version {:?}", hash.name, version);
            }
        }
    }

    #[test]
    fn header_signature_words() {
        let h = hdr(Version::V4, hash_by_name("vmac").unwrap(), 0);
        let b = h.encode();
        assert_eq!(u32_at(&b, 0), 0x2635_1817);
        assert_eq!(u32_at(&b, 4), 0x5052_534F);
        assert_eq!(&b[4..8], b"OSRP");
    }

    #[test]
    fn siphash_digest_bias_wraps() {
        // (8 - 16) << 24 wraps to 0xF8000000 and read back as 8.
        let h = hdr(Version::V4, hash_by_name("siphash").unwrap(), 0);
        assert_eq!(h.selector_word() >> 24, 0xF8);
        assert_eq!(h.encode()[11], 0xF8);
        let back = ArchiveHeader::decode(&h.encode()).unwrap();
        assert_eq!(back.hash_size, 8);
        assert_eq!(back.hash_seed_size, 16);
        assert_eq!(back.hash_num, 5);
        assert_eq!(back.version, Version::V4);
    }

    #[test]
    fn version_predicates() {
        assert!(Version::V1.round_matches() && Version::V1.io_lz());
        assert!(!Version::V2.round_matches() && Version::V2.io_lz());
        assert!(Version::V3.future_lz() && !Version::V3.io_lz());
        assert!(Version::V4.index_lz() && !Version::V4.io_lz());
        assert_eq!(Version::V1.stats_per_match(), 3);
        assert_eq!(Version::V4.stats_per_match(), 4);
        assert_eq!(Version::from_code(5), None);
    }

    #[test]
    fn footer_round_trips_and_checks_signatures() {
        let f = IndexFooter::new(1000, vec![100, 200, 300, 400]);
        let bytes = f.encode();
        assert_eq!(bytes.len(), f.footer_size() as usize);
        let head = FooterHead::decode(&bytes[bytes.len() - 24..]).unwrap();
        assert_eq!(head.total_stat_size, 1000);
        assert_eq!(head.footer_size, 24 + 16);
        let table = IndexFooter::decode_table(&bytes[..bytes.len() - 24]).unwrap();
        assert_eq!(table, vec![100, 200, 300, 400]);
        // A mangled signature must be rejected.
        let mut bad = bytes.clone();
        let n = bad.len();
        bad[n - 4] ^= 0xFF;
        assert_eq!(
            FooterHead::decode(&bad[n - 24..]),
            Err(ContainerError::NoFooter)
        );
    }

    #[test]
    fn rejects_bad_signature() {
        let mut b = hdr(Version::V4, hash_by_name("vmac").unwrap(), 0).encode();
        b[1] ^= 0x01;
        assert_eq!(
            ArchiveHeader::decode(&b),
            Err(ContainerError::NotAnOsrepFile)
        );
    }

    #[test]
    fn name_lookup_is_case_insensitive() {
        assert_eq!(hash_by_name("VMAC").unwrap().num, 4);
        assert_eq!(hash_by_name("Sha512").unwrap().num, 3);
        assert_eq!(hash_by_name("").unwrap().num, 1);
        assert!(hash_by_name("nope").is_none());
        assert_eq!(hash_by_num(4).unwrap().name, "vmac");
        assert!(hash_by_num(9).is_none());
    }

    #[test]
    fn trailer_sniffing() {
        assert_eq!(split_trailer(b"tiny"), Ok(Trailer::Plain));
        // A bare ODUP magic with a bogus meta is rejected, not ignored.
        let mut v = vec![0u8; 32];
        v.extend_from_slice(&4u64.to_le_bytes());
        v.extend_from_slice(b"ODUP");
        assert_eq!(split_trailer(&v), Err(ContainerError::DupMetaNotDupr));
        // A real trailer splits the body off.
        let mut v = vec![0xEEu8; 40];
        v.extend_from_slice(b"DUPR");
        v.extend_from_slice(&[0u8; 4]);
        v.extend_from_slice(&8u64.to_le_bytes());
        v.extend_from_slice(b"ODUP");
        match split_trailer(&v).unwrap() {
            Trailer::Odup { body_len, meta } => {
                assert_eq!(body_len, 40);
                assert_eq!(meta, b"DUPR\x00\x00\x00\x00");
            }
            other => panic!("expected ODUP, got {other:?}"),
        }
    }
}
