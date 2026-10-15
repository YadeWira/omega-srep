//! The LZ match record codec: `ENCODE_LZ_MATCH` / `DECODE_LZ_MATCH`
//! (`srep.cpp:116-139`).
//!
//! One match is `STATS_PER_MATCH(ROUND_MATCHES)` 32-bit words — 3 when
//! `ROUND_MATCHES`, 4 otherwise (the 64-bit offset split across two words).
//! Every encoder and decoder in the program goes through these two shapes, so
//! they live in one place.
//!
//! The C++ is a statement macro that splices typed locals into its caller; its
//! `L` parameter is really `BASE_LEN` (`srep.cpp:457`), the guaranteed minimum
//! match length that the encoded length is stored *minus*. Here it is an
//! explicit argument with that name.

/// `STATS_PER_MATCH` (`srep.cpp:113`).
pub fn stats_per_match(round_matches: bool) -> usize {
    if round_matches {
        3
    } else {
        4
    }
}

/// Why an `ENCODE_LZ_MATCH` call was refused. The C++ aborts through
/// `error()` (`srep.cpp:121`); the port reports instead of exiting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EncodeError {
    /// `match_len < BASE_LEN`: the record shape cannot encode a match this
    /// short.
    MatchTooSmall { match_len: u32, base_len: u32 },
    /// The input-match list (`aux_statbuf`) did not decode. Unreachable for a
    /// list the driver just built; the C++ would abort on it.
    BadInputMatch,
}

/// `ENCODE_LZ_MATCH` (`srep.cpp:116-122`): append one record to `out`.
///
/// `offset` is `LZ.dest - LZ.src`, the match distance. With `round_matches` it
/// must already be a multiple of `base_len` (the caller rounds the length, and
/// the offset follows from the chunk grid); the division below is what makes
/// the stored form divisible again on decode.
pub fn encode_lz_match(
    out: &mut Vec<u32>,
    round_matches: bool,
    base_len: u32,
    lit_len: u32,
    offset: u64,
    match_len: u32,
) -> Result<(), EncodeError> {
    let l1: u64 = if round_matches { base_len as u64 } else { 1 };
    out.push(lit_len);
    let off = offset / l1;
    out.push(off as u32); // low 32 bits
    if !round_matches {
        out.push((off >> 32) as u32); // high 32 bits
    }
    if match_len < base_len {
        return Err(EncodeError::MatchTooSmall { match_len, base_len });
    }
    out.push((((match_len - base_len) as u64) / l1) as u32);
    Ok(())
}

/// One decoded record: the literal run that precedes it, where the match
/// copies from and to, and its length.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LzMatch {
    pub lit_len: u32,
    pub src: u64,
    pub dest: u64,
    pub len: u32,
}

/// What went wrong while walking a match list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeError {
    /// The list ended mid-record.
    Truncated,
}

/// `DECODE_LZ_MATCH` (`srep.cpp:125-139`): decode one record starting at
/// `stat[0]`, returning it and how many words it consumed.
///
/// `basic_pos` is the block-relative anchor the two `LZ_MATCH` layouts differ
/// on: without `future_lz` the record gives `dest` directly (`src` follows
/// from the distance, rounded down to the `L1` grid when `round_matches`);
/// with `future_lz` it gives `src` and `dest` is ahead of it.
pub fn decode_lz_match(
    stat: &[u32],
    round_matches: bool,
    future_lz: bool,
    base_len: u32,
    basic_pos: u64,
) -> Result<(LzMatch, usize), DecodeError> {
    let l1: u32 = if round_matches { base_len } else { 1 };
    let l164: u64 = l1 as u64;
    let need = stats_per_match(round_matches);
    if stat.len() < need {
        return Err(DecodeError::Truncated);
    }
    let lit_len = stat[0];
    let mut offset = stat[1] as u64;
    let mut pos = 2;
    if !round_matches {
        offset += (stat[2] as u64) << 32;
        pos = 3;
    }
    // `lz_match_offset *= L1` runs in `Offset` (u64) and wraps.
    offset = offset.wrapping_mul(l1 as u64);
    // The C++ computes `(*stat++)*L1 + L` in `unsigned`, so the multiply wraps
    // at 32 bits; matching that keeps corrupt input rejected at the same
    // places rather than panicking or widening.
    let len = stat[pos].wrapping_mul(l1).wrapping_add(base_len);
    pos += 1;

    let (src, dest) = if !future_lz {
        let dest = basic_pos + lit_len as u64;
        // `Offset` arithmetic in the C++ wraps; a corrupt list can drive the
        // subtraction below its floor, and the port must reject that
        // downstream rather than panic here.
        let src = (dest / l164).wrapping_mul(l164).wrapping_sub(offset);
        (src, dest)
    } else {
        let src = basic_pos + lit_len as u64;
        let dest = src.wrapping_add(offset);
        (src, dest)
    };
    Ok((
        LzMatch {
            lit_len,
            src,
            dest,
            len,
        },
        pos,
    ))
}
