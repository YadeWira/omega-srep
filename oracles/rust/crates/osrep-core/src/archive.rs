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
    /// (which the C++ has no name for, since it cannot write one). For a v4
    /// `-dup` archive it is the mode of the archive behind the ODUP trailer.
    pub mode: &'static str,
    pub hash_name: &'static str,
    /// `header[3]`: nonzero only for v1/v2.
    pub base_len: u32,
    /// v1: three `STAT`s per match record instead of four.
    pub round_matches: bool,
    pub blocks: usize,
    /// The uncompressed size: what `-d` writes. Both parsers derive it from
    /// the framing alone: for v1-v4 that is the sum of the block headers,
    /// which is the number the C++ arrives at through the footer arithmetic
    /// plus a walk of the match lists. For a `-dup` archive it is the size
    /// the meta restores, not the size of the body the blocks hold.
    pub origsize: u64,
    /// The archive's size on disk, trailer and meta included.
    pub compsize: u64,
    /// Match-list bytes: what the `-i` summary counts matches out of.
    pub stat_size: u64,
    /// The `-dup` pass, when the archive carries its meta (embedded in v5,
    /// as the ODUP trailer in v4).
    pub dup: Option<DupInfo>,
}

/// The `-dup` side of [`Info`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DupInfo {
    pub chunks: u64,
    pub unique: u64,
    /// What the dedup pass handed the match search: the size the blocks
    /// decode to.
    pub body_size: u64,
}

/// Take an archive apart far enough to describe it.
pub fn inspect(bytes: &[u8]) -> Result<Info, DecodeError> {
    inspect_with(bytes, false)
}

/// `inspect`, for an archive whose v1-v3 match lists were written to an
/// `-index=` file when `stats_out_of_line` is set
/// (`container::Archive::parse_with`).
pub fn inspect_with(bytes: &[u8], stats_out_of_line: bool) -> Result<Info, DecodeError> {
    if bytes.len() >= v5::HEADER_SIZE
        && u32::from_le_bytes(bytes[..4].try_into().unwrap()) == v5::MAGIC
    {
        let parsed = v5::parse(bytes).map_err(|_| DecodeError::BadData("v5 archive"))?;
        let hash = parsed
            .header
            .hash()
            .map_err(|_| DecodeError::BadData("v5 hash descriptor"))?;
        let meta = v5::dup_meta(bytes, &parsed.footer, &parsed.header)
            .map_err(|_| DecodeError::BadData("v5 -dup meta"))?;
        let info = Info {
            mode: "v5",
            hash_name: hash.name,
            base_len: 0,
            round_matches: false,
            blocks: parsed.blocks.len(),
            origsize: parsed.header.original_size,
            compsize: bytes.len() as u64,
            stat_size: parsed.footer.stat_size,
            dup: None,
        };
        return with_dup(info, meta);
    }

    // v4 `-dup` hides its archive behind the meta and the ODUP trailer
    // (`dup_wrapper.cpp:254-262`); the C++'s own `-i` reads the trailer as
    // a footer and gives up. The trailer is only sniffed, though: a plain
    // Future-LZ/I/O LZ archive ends in its last literals, so one of a file
    // that ends in "ODUP" (another v4 `-dup` archive, say) carries what looks
    // like a trailer. When the archive behind it does not hold up, the whole
    // file is read as a plain archive, as 2.3.0 and the C++ `-i` read it --
    // the same rule `-d` follows (`dup::decode`), and like it, without the
    // zero-length terminator block no encoder writes: a `-dup` archive
    // whose meta was zeroed would otherwise read as its own body.
    match crate::dup::split_odup(bytes) {
        Ok(None) => inspect_v14(bytes, bytes.len(), stats_out_of_line, false),
        sniffed => {
            if let Ok(Some((n, meta))) = sniffed {
                if let Ok(info) = inspect_v14(&bytes[..n], bytes.len(), stats_out_of_line, true)
                    .and_then(|info| with_dup(info, Some(meta)))
                {
                    return Ok(info);
                }
            }
            inspect_v14(bytes, bytes.len(), stats_out_of_line, true)
        }
    }
}

/// A v1-v4 archive occupying `body`, in a file of `total` bytes. `strict`
/// refuses one that ends in a terminator block.
fn inspect_v14(
    body: &[u8],
    total: usize,
    stats_out_of_line: bool,
    strict: bool,
) -> Result<Info, DecodeError> {
    let parsed = container::Archive::parse_with(body, stats_out_of_line)?;
    if strict && parsed.terminated {
        return Err(DecodeError::BadData("terminator block"));
    }
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
        round_matches: parsed.header.version.round_matches(),
        blocks: parsed.blocks.len(),
        origsize: parsed.origsize(),
        compsize: total as u64,
        // v4 keeps the whole list at the tail and records its size in the
        // footer; v1-v3 carry each block's own list inline.
        stat_size: if parsed.total_stat_size > 0 {
            parsed.total_stat_size
        } else {
            parsed.blocks.iter().map(|b| b.header.statsize as u64).sum()
        },
        dup: None,
    })
}

/// Fold a `-dup` meta into what the blocks say: the original size becomes
/// the one the meta restores. A meta that needs more body than the blocks
/// decode to is one `-d` would fail on (`DEDUP_ERR_TRUNCATED`).
fn with_dup(mut info: Info, meta: Option<&[u8]>) -> Result<Info, DecodeError> {
    if let Some(meta) = meta {
        let s = crate::dedup::summarize_meta(meta)
            .map_err(|_| DecodeError::BadData("-dup meta"))?;
        if s.body_size > info.origsize {
            return Err(DecodeError::BadData("-dup meta"));
        }
        info.dup = Some(DupInfo {
            chunks: s.chunks,
            unique: s.unique,
            body_size: info.origsize,
        });
        info.origsize = s.output_size;
    }
    Ok(info)
}
