//! The Future-LZ / Index-LZ second pass (`srep.cpp:820-970`).
//!
//! The first pass leaves every block's match list in the *first pass's* record
//! shape (`ROUND_MATCHES` / `BASE_LEN`), which is temporary: this pass collects
//! all of them, sorts by source position, and re-emits each block's list with
//! the matches that start inside it — truncated to the block and with
//! `FUTURELZ_BASE_LEN` (0 for v3/v4) as the record base.
//!
//! That re-emission is what makes the format's two tail shapes differ:
//! Future-LZ writes `header → match list → literals` per block, Index-LZ has
//! the first pass write `header → literals` and puts every match list after the
//! last block, followed by the block-size table and the footer.
//!
//! The `lz_match_heap` and `ram`/`max_ram` accounting in the C++ only feed the
//! progress report, so they are not modelled.

use std::io::{Read, Seek, SeekFrom, Write};

use crate::container::IndexFooter;
use crate::encoder::EncodeError;
use crate::lz;

/// One block as the first pass captured it (`COMPRESSED_BLOCK`,
/// `srep.cpp:172-179`).
pub struct CompressedBlock {
    pub start: u64,
    pub end: u64,
    pub size: usize,
    /// `header_size` bytes: the three `STAT`s plus the block digest.
    pub header: Vec<u8>,
    /// The first pass's match records for this block.
    pub stat: Vec<u32>,
}

/// Run the second pass and write the tail of the archive. Returns the number
/// of bytes written.
///
/// `round_matches`/`base_len` describe the *first* pass's records (what `stat`
/// holds). The re-emitted records use `futurelz_base_len` instead --
/// `FUTURELZ_BASE_LEN` (`srep.cpp:458`), which is 0 for v3/v4, the same value
/// the decoder reads out of `header[3]`.
#[allow(clippy::too_many_arguments)]
pub fn second_pass<R: Read + Seek, W: Write>(
    blocks: &[CompressedBlock],
    input: &mut R,
    output: &mut W,
    round_matches: bool,
    base_len: u32,
    futurelz_base_len: u32,
    future_lz: bool,
    index_lz: bool,
    v5: bool,
    base_offset: u64,
    meta: Option<&[u8]>,
) -> Result<u64, EncodeError> {
    // 1. Collect every block's matches (`srep.cpp:863-878`).
    let mut matches: Vec<lz::LzMatch> = Vec::new();
    for b in blocks {
        let mut block_pos = b.start;
        let mut rest = &b.stat[..];
        while rest.len() >= lz::stats_per_match(round_matches) {
            let (m, used) = lz::decode_lz_match(rest, round_matches, false, base_len, block_pos)
                .map_err(|_| EncodeError::BadBlockRecord)?;
            matches.push(m);
            block_pos += m.lit_len as u64 + m.len as u64;
            rest = &rest[used..];
        }
    }

    // 2. Sort by source (`srep.cpp:882`). The C++ uses `std::sort`, which is
    //    unstable; the comparator is strict on `src` and the encoder never
    //    emits two matches with the same source, so a stable sort is the
    //    reproducible choice.
    matches.sort_by(|a, b| a.src.cmp(&b.src));

    // 3. Walk the blocks, re-emitting the matches whose source starts in each
    //    (`srep.cpp:894-961`).
    let mut compsize = 0u64;
    let mut statsize_table: Vec<u32> = Vec::with_capacity(blocks.len());
    let mut total_stat_size = 0u64;
    let mut stat: Vec<u32> = Vec::new();
    let mut i = 0usize;

    // The literals of a Future-LZ block are re-read from the input, in order.
    input.seek(SeekFrom::Start(0))?;
    let mut block_buf: Vec<u8> = Vec::new();

    for b in blocks {
        stat.clear();
        let mut block_pos = b.start;
        let mut saved_i = i;
        while i < matches.len() && matches[i].src < b.end {
            let m = matches[i];
            if m.src + m.len as u64 <= b.start {
                // Entirely owned by an earlier block: remember where to resume
                // for the next one.
                saved_i = i;
                i += 1;
                continue;
            }
            let src = m.src.max(b.start);
            let mut len = m.len as u64 - (src - m.src);
            len = len.min(b.end - src);
            lz::encode_lz_match(
                &mut stat,
                false,
                futurelz_base_len,
                (src - block_pos) as u32,
                m.dest - m.src,
                len as u32,
            )?;
            block_pos = src;
            i += 1;
        }
        i = saved_i;

        // v5 replaces the fixed 4-word records with raw LEB128 triples, so the
        // list is rebuilt from the very words just emitted (which already carry
        // raw lengths: their base is 0 and nothing is rounded).
        //
        // `at` is the *source* the next record is anchored at -- what
        // `encode_lz_match` was given above -- which is the v5 record's own
        // anchor (`docs/format-spec-v5.md` §3). Decoding with the destination
        // anchor instead (`future_lz = false`) still yields the right
        // `distance` through wrapping arithmetic, but drives `src` below zero
        // on any match whose offset exceeds the source position, which is a
        // panic in a debug build.
        let mut stat_bytes: Vec<u8> = Vec::new();
        if v5 {
            let mut rest = &stat[..];
            let mut at = b.start;
            while rest.len() >= lz::stats_per_match(round_matches) {
                let (m, used) = lz::decode_lz_match(rest, false, true, 0, at)
                    .map_err(|_| EncodeError::BadBlockRecord)?;
                crate::v5::Record {
                    lit_len: m.lit_len as u64,
                    match_len: m.len as u64,
                    distance: m.dest - m.src,
                }
                .encode(&mut stat_bytes);
                at += m.lit_len as u64 + m.len as u64;
                rest = &rest[used..];
            }
        }
        let stat_size = if v5 {
            stat_bytes.len() as u32
        } else {
            (stat.len() * 4) as u32
        };
        if future_lz || v5 {
            // `block->header[2] = stat_size` (`srep.cpp:934`) -- the first pass
            // left it zero because it wrote nothing.
            let mut header = b.header.clone();
            header[8..12].copy_from_slice(&stat_size.to_le_bytes());
            output.write_all(&header)?;
            compsize += header.len() as u64;
        }

        if v5 {
            output.write_all(&stat_bytes)?;
            compsize += stat_bytes.len() as u64;
        } else {
            for word in &stat {
                output.write_all(&word.to_le_bytes())?;
            }
            compsize += stat.len() as u64 * 4;
        }

        statsize_table.push(stat_size);
        total_stat_size += stat_size as u64;

        if future_lz || v5 {
            // Copy the literal bytes the block's own (first pass) records leave
            // uncovered (`srep.cpp:945-961`).
            block_buf.resize(b.size, 0);
            input
                .read_exact(&mut block_buf)
                .map_err(|_| EncodeError::Io)?;
            let mut out: Vec<u8> = Vec::with_capacity(b.size);
            let mut in_pos = 0usize;
            let mut rest = &b.stat[..];
            while rest.len() >= lz::stats_per_match(round_matches) {
                let (m, used) = lz::decode_lz_match(rest, round_matches, false, base_len, 0)
                    .map_err(|_| EncodeError::BadBlockRecord)?;
                let lit = m.lit_len as usize;
                if lit > b.size - in_pos {
                    return Err(EncodeError::BadBlockRecord);
                }
                out.extend_from_slice(&block_buf[in_pos..in_pos + lit]);
                in_pos += lit + m.len as usize;
                if in_pos > b.size {
                    return Err(EncodeError::BadBlockRecord);
                }
                rest = &rest[used..];
            }
            out.extend_from_slice(&block_buf[in_pos..]);
            compsize += out.len() as u64;
            output.write_all(&out)?;
        }
    }

    if index_lz {
        let footer = IndexFooter::new(total_stat_size, statsize_table);
        let bytes = footer.encode();
        compsize += bytes.len() as u64;
        output.write_all(&bytes)?;
    }
    if v5 {
        // The `-dup` payload, if any, goes here: after the blocks, before the
        // footer that locates it. `base_offset` is where this pass's output
        // starts, so the footer can name an absolute offset.
        let (meta_offset, meta_size) = match meta {
            Some(payload) => {
                let blob = crate::v5::encode_meta(payload).map_err(|_| EncodeError::BadDupMeta)?;
                let at = base_offset + compsize;
                output.write_all(&blob)?;
                compsize += blob.len() as u64;
                (at, blob.len() as u32)
            }
            None => (0, 0),
        };
        let footer = crate::v5::Footer {
            block_count: blocks.len() as u32,
            stat_size: total_stat_size,
            meta_offset,
            meta_size,
        };
        let bytes = footer.encode();
        compsize += bytes.len() as u64;
        output.write_all(&bytes)?;
    }
    Ok(compsize)
}
