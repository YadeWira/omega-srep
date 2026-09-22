//! "Open an archive" — the entry points the CLI needs and the harnesses get
//! away without.
//!
//! Everything below the container is shared, but *which* decoder to run is
//! decided by the first four bytes: a v5 archive starts with its own magic,
//! everything else with the 16-byte archive header whose selector word names
//! the version. The C++ decides the same way, one `if` per version
//! (`srep.cpp:1020-1072`), and `tests/decode_conformance.sh` drives the same
//! split by hand.

use std::io::{Read, Seek, SeekFrom, Write};

use crate::container::{self, ArchiveHeader};
use crate::decompress::{decode_io_lz, read_exact_or_eof, DecodeError};
use crate::future_lz::{self, FutureLzOptions, FutureLzStats};
use crate::v5;

/// Decode any archive into `sink`: v1/v2 through the I/O-LZ decoder, v3/v4
/// through the Future/Index-LZ one, v5 through its own framing (which shares
/// the decoder below it).
pub fn decode<R: Read + Seek, S: Read + Write + Seek>(
    input: &mut R,
    sink: &mut S,
    opts: &FutureLzOptions,
    progress: Option<&mut dyn FnMut(u64, u64)>,
    // `-index=`: the match lists live in a separate file, so the two
    // containers that read them sequentially take their bytes from here.
    index: crate::decompress::IndexSource,
) -> Result<FutureLzStats, DecodeError> {
    let file_len = input.seek(SeekFrom::End(0))?;
    input.seek(SeekFrom::Start(0))?;

    if file_len >= v5::HEADER_SIZE as u64 {
        let mut head = [0u8; v5::HEADER_SIZE];
        read_exact_or_eof(input, &mut head)?;
        input.seek(SeekFrom::Start(0))?;
        if u32::from_le_bytes(head[..4].try_into().unwrap()) == v5::MAGIC {
            return future_lz::decode_v5(input, sink, opts, progress);
        }
    }

    let mut head = [0u8; container::ARCHIVE_HEADER_SIZE];
    if !read_exact_or_eof(input, &mut head)? {
        return Err(container::ContainerError::Truncated.into());
    }
    input.seek(SeekFrom::Start(0))?;
    let header = ArchiveHeader::decode(&head)?;

    if header.version.io_lz() {
        // I/O-LZ carries no match lists across blocks, so nothing spills and
        // the VM counters stay zero.
        let stats = decode_io_lz(input, sink, progress, index)?;
        Ok(FutureLzStats {
            decode: stats,
            vm_bytes_written: 0,
            vm_bytes_read: 0,
        })
    } else {
        future_lz::decode_future_lz(input, sink, opts, progress, index)
    }
}

/// What `-i` reports about an archive (`srep.cpp:1074-1144`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Info {
    /// The C++'s mode word: `"I/O LZ"`, `"Future-LZ"`, `"Index-LZ"`, or `"v5"`
    /// (which the C++ has no name for, since it cannot write one).
    pub mode: &'static str,
    pub hash_name: &'static str,
    /// `header[3]`: nonzero only for v1/v2.
    pub base_len: u32,
    pub blocks: usize,
    /// The uncompressed size. Both parsers derive it from the framing alone:
    /// for v1-v4 that is the sum of the block headers, which is the number the
    /// C++ arrives at through the footer arithmetic plus a walk of the match
    /// lists.
    pub origsize: u64,
    /// The archive's size on disk.
    pub compsize: u64,
    /// Match-list bytes: what the `-i` summary counts matches out of.
    pub stat_size: u64,
}

/// Take an archive apart far enough to describe it.
pub fn inspect(bytes: &[u8]) -> Result<Info, DecodeError> {
    if bytes.len() >= v5::HEADER_SIZE
        && u32::from_le_bytes(bytes[..4].try_into().unwrap()) == v5::MAGIC
    {
        let parsed = v5::parse(bytes).map_err(|_| DecodeError::BadData("v5 archive"))?;
        let hash = parsed
            .header
            .hash()
            .map_err(|_| DecodeError::BadData("v5 hash descriptor"))?;
        return Ok(Info {
            mode: "v5",
            hash_name: hash.name,
            base_len: 0,
            blocks: parsed.blocks.len(),
            origsize: parsed.header.original_size,
            compsize: bytes.len() as u64,
            stat_size: parsed.footer.stat_size,
        });
    }

    let parsed = container::Archive::parse(bytes)?;
    let hash = parsed
        .header
        .hash()
        .ok_or(DecodeError::BadData("unknown hash descriptor"))?;
    Ok(Info {
        mode: if parsed.header.version.index_lz() {
            "Index-LZ"
        } else if parsed.header.version.future_lz() {
            "Future-LZ"
        } else {
            "I/O LZ"
        },
        hash_name: hash.name,
        base_len: parsed.header.base_len,
        blocks: parsed.blocks.len(),
        origsize: parsed.origsize(),
        compsize: bytes.len() as u64,
        // v4 keeps the whole list at the tail and records its size in the
        // footer; v1-v3 carry each block's own list inline.
        stat_size: if parsed.total_stat_size > 0 {
            parsed.total_stat_size
        } else {
            parsed.blocks.iter().map(|b| b.header.statsize as u64).sum()
        },
    })
}
