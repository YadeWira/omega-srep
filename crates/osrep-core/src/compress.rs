//! The single-block compressor for `-m3`/`-m4`/`-m5` (`compress.cpp`).
//!
//! The C++ is templated over `ACCELERATOR` (0,1,2,…,64) with three
//! hand-unrolled loops, `bitarr` prefiltering and prefetches. The 4c-0
//! `-a0`/`-a16` byte-identity run proved every variant produces the same
//! archive, so this port transcribes the `ACCELERATOR == 0` shape -- the
//! simplest one, and the only one whose control flow can be read without
//! untangling the batch machinery -- and reproduces the details that *are*
//! output-visible:
//!
//! * matches are only probed at positions in `[last_match_end, match_start)`,
//!   i.e. not inside the previous match nor inside the pending input match
//!   (`prefetch_and_store_match`, compress.cpp:28-35);
//! * the scan can jump forward to `last_match_end` rounded down to a
//!   4-position boundary and re-syncs the rolling hash there
//!   (compress.cpp:124-132), which is why the per-batch advance of four can
//!   overshoot the `next_chunk` boundary and shift the `add_hash` position;
//! * `add_hash` runs once per outer iteration with `hash1`'s *current* value,
//!   whatever the batch left it at (compress.cpp:209);
//! * the input-match list (`in_statbuf`: the in-memory pass's matches followed
//!   by the `len+1` fence, srep.cpp:722-724) is decoded lazily and its matches
//!   are spliced in exactly where the scan reaches them.

use crate::hash_table::{read_at, HashTable, ReadSeek, NOT_FOUND};
use crate::lz;
use crate::rolling::{PolynomialRollingHash, PRIME1};

/// `LOOKAHEAD` for `ACCELERATOR == 0` (compress.cpp:134).
const LOOKAHEAD: usize = 128;
/// `X = max(CYCLES, 4)` for `ACCELERATOR == 0` (compress.cpp:124).
const X: usize = 4;

/// `record_match` (`compress.cpp:8-26`): measure the match at chunk `k`
/// against position `i`, and emit it if it reaches `MIN_MATCH`.
#[allow(clippy::too_many_arguments)]
fn record_match<R: ReadSeek>(
    h: &HashTable,
    dict: &[u8],
    buf_off: usize,
    block_size: usize,
    block_start: u64,
    round_matches: bool,
    l: usize,
    min_match: usize,
    base_len: u32,
    reread: &mut R,
    stat: &mut Vec<u32>,
    last_match_end: usize,
    match_end: &mut usize,
    literal_bytes: &mut u32,
    i: usize,
    k: u32,
) -> Result<bool, lz::EncodeError> {
    let mut add_len = 0u32;
    let match_len = h.match_len(
        k as usize,
        dict,
        buf_off,
        buf_off + last_match_end,
        buf_off + i,
        buf_off + block_size,
        block_start,
        round_matches,
        reread,
        &mut add_len,
    );

    if match_len as usize >= min_match {
        let mut match_start = i - add_len as usize;
        // `if (ROUND_MATCHES) match_len = match_len/L*L` (compress.cpp:15-16).
        let mut match_len = if round_matches {
            match_len / l as u32 * l as u32
        } else {
            match_len
        };
        let match_offset = block_start + i as u64 - k as u64 * l as u64;
        if round_matches {
            // A rounded record stores the offset and the length in units of
            // BASE_LEN, not of L (`ENCODE_LZ_MATCH`'s `L1`, srep.cpp:117), and
            // the decoder rebuilds the source as `dest/BASE_LEN*BASE_LEN -
            // offset/BASE_LEN*BASE_LEN` and the length as a whole number of
            // BASE_LENs. That is exact when the source (`k*L`) and the length
            // are multiples of BASE_LEN -- always so when BASE_LEN divides L,
            // the default (BASE_LEN = min(-l, 512), L = -l). With `-c` below
            // BASE_LEN (`-m3 -c8 -l16`), or a BASE_LEN that does not divide L
            // (`-m3 -c8 -l17`, `-m3 -dl17`), the C++ wrote archives that do not
            // decode (exit 0: silent data loss) or stopped with "match len too
            // small" (exit 4), and the port did the same.
            //
            // A record that will not decode to these bytes is now moved up to
            // the next source on the BASE_LEN grid and cut to whole units --
            // still inside the verified match, so the bytes are the same -- or
            // not taken when less than one unit is left. One that decodes
            // right as it is (an exact one, or an inexact source that happens
            // to hold the same bytes, as on all-zero input) is written exactly
            // as before, so every archive that used to decode keeps its bytes.
            let b = base_len as u64;
            let src = k as u64 * l as u64;
            let len = match_len as u64;
            if !(src % b == 0 && len % b == 0 && len >= b)
                && !decodes_as_is(dict, buf_off, block_start, match_start, src, match_len, b, reread)
            {
                let skip = (b - src % b) % b;
                let cut = (match_len as u64).saturating_sub(skip) / b * b;
                if cut < b {
                    return Ok(false);
                }
                match_start += skip as usize;
                match_len = cut as u32;
            }
        }
        lz::encode_lz_match(
            stat,
            round_matches,
            base_len,
            (match_start - last_match_end) as u32,
            match_offset,
            match_len,
        )?;
        *match_end = match_start + match_len as usize;
        *literal_bytes -= match_len;
        return Ok(true);
    }
    Ok(false)
}

/// Whether a rounded (`-m3`, no `-d`) record for the match of `len` bytes from
/// file offset `src` to the block position `match_start` decodes to exactly
/// these bytes even though `src` or `len` is off the BASE_LEN (`b`) grid.
/// The decoder copies, forward and byte by byte, `len / b * b` bytes (rounded
/// down from `b` up, `DECODE_LZ_MATCH`) from `dest/b*b - offset/b*b`; that
/// reproduces the input exactly when the length is whole and the bytes at that
/// source equal the ones at the destination. They are reread from the input,
/// which `-m4`/`-m5` already reread through the same handle.
#[allow(clippy::too_many_arguments)]
fn decodes_as_is<R: ReadSeek>(
    dict: &[u8],
    buf_off: usize,
    block_start: u64,
    match_start: usize,
    src: u64,
    len: u32,
    b: u64,
    reread: &mut R,
) -> bool {
    if len as u64 % b != 0 || (len as u64) < b {
        return false;
    }
    let dest = block_start + match_start as u64;
    let decoded_src = dest / b * b - (dest - src) / b * b;
    if decoded_src >= dest {
        return false;
    }
    let mut old = vec![0u8; len as usize];
    if read_at(reread, decoded_src, &mut old) != old.len() {
        return false;
    }
    old[..] == dict[buf_off + match_start..buf_off + match_start + len as usize]
}

/// `compress<ACCELERATOR == 0>` (`compress.cpp:54-212`).
///
/// `dict` is the buffer holding the block at `buf_off`; reads a few bytes past
/// `buf_off + block_size` reach the next ring slot exactly like the C++'s.
/// `in_stat` is the decoded-again `aux_statbuf` list. Returns the match records
/// through `stat` and the literal count through `literal_bytes`.
#[allow(clippy::too_many_arguments)]
pub fn compress<R: ReadSeek>(
    h: &mut HashTable,
    dict: &[u8],
    buf_off: usize,
    block_size: usize,
    round_matches: bool,
    l: usize,
    min_match: usize,
    base_len: u32,
    block_start: u64,
    in_stat: &[u32],
    stat: &mut Vec<u32>,
    literal_bytes: &mut u32,
    reread: &mut R,
) -> Result<(), lz::EncodeError> {
    let mut last_match_end = 0usize;
    *literal_bytes = block_size as u32;

    // Decode the first input match (compress.cpp:62-65).
    let mut instat = in_stat;
    let decode_next = |instat: &mut &[u32],
                           basic_pos: u64|
     -> Result<(usize, u32, u64), lz::DecodeError> {
        let (m, used) = lz::decode_lz_match(instat, round_matches, false, base_len, basic_pos)?;
        *instat = &instat[used..];
        Ok((
            (m.dest - block_start) as usize,
            m.len,
            m.dest - m.src,
        ))
    };
    let (ms, ml, mo) = decode_next(&mut instat, block_start).map_err(|_| lz::EncodeError::BadInputMatch)?;
    let mut match_start = ms;
    let mut match_len = ml;
    let mut match_offset = mo;

    // `2 * l > block_size`, written so that it cannot overflow: on i686 an `-l`
    // or `-c` of 2^31 or more wrapped `2 * l` to a small number, and the scan
    // below then ran on a window longer than the ring (index out of range).
    if l > block_size / 2 {
        return Ok(());
    }

    let mut hash1 = PolynomialRollingHash::new(l, PRIME1);
    // Scratch for the (hash, position) pairs one sub-cycle batch stores.
    let mut pairs: Vec<(u64, usize)> = Vec::with_capacity(LOOKAHEAD + X);

    // --- SPECIAL HANDLING FOR FIRST L BYTES (compress.cpp:78-94) ---------- //
    // With ACCELERATOR == 0 the hash1/hash2 dance collapses: hash2 *is* the
    // hash of buf[0..L). The goto here lands on the next statement, so the
    // add_hash always runs.
    hash1.moveto(&dict[buf_off..]);
    {
        let i = 0usize;
        let hash = hash1.value;
        let k = h.find_match(dict, buf_off, i, block_size, hash, (hash >> 32) as u32);
        if k != NOT_FOUND {
            let mut match_end = 0usize;
            if record_match(
                h, dict, buf_off, block_size, block_start, round_matches, l, min_match,
                base_len, reread, stat, last_match_end, &mut match_end, literal_bytes, i, k,
            )? {
                last_match_end = match_end;
            }
        }
    }
    h.add_hash(hash1.value, (hash1.value >> 32) as u32, (block_start / l as u64) as usize);

    // --- MAIN CYCLE, PROCESSING L-BYTE BLOCK AT EVERY STEP ---------------- //
    let mut i = 0usize;
    while i + 2 * l <= block_size {
        let next_chunk = i + l;
        while i < next_chunk {
            // --- PROCESS NEXT INPUT MATCH ONCE WE'VE REACHED ITS START ----- //
            if i >= match_start {
                // Encode the input match if it still has BASE_LEN bytes left
                // after the overlap with our own (compress.cpp:107-116).
                if match_start + match_len as usize - base_len as usize >= last_match_end {
                    let cut = match_start.max(last_match_end) - match_start;
                    let match_len = match_len as usize - cut;
                    let match_start = match_start.max(last_match_end);
                    let literal_len = match_start - last_match_end;
                    lz::encode_lz_match(
                        stat,
                        round_matches,
                        base_len,
                        literal_len as u32,
                        match_offset,
                        match_len as u32,
                    )?;
                    last_match_end = match_start + match_len;
                    *literal_bytes -= match_len as u32;
                }
                // Decode the next one, anchored past the match we just took
                // (compress.cpp:119).
                let (ms, ml, mo) = decode_next(
                    &mut instat,
                    block_start + match_start as u64 + match_len as u64,
                )
                .map_err(|_| lz::EncodeError::BadInputMatch)?;
                match_start = ms;
                match_len = ml;
                match_offset = mo;
            }

            // --- UPDATE hash1 UNTIL last_match_end, ROUNDED DOWN ----------- //
            let next_i = (next_chunk - 1).min(if last_match_end > 0 {
                last_match_end - 1
            } else {
                0
            });
            if next_i >= i + l / 2 {
                i = next_i & !(X - 1);
                hash1.moveto(&dict[buf_off + i..]);
            } else {
                while i + X <= next_i {
                    for _ in 0..X {
                        hash1.update(dict[buf_off + i], dict[buf_off + i + l]);
                        i += 1;
                    }
                }
            }

            let last_i = next_chunk.min(i + LOOKAHEAD);

            // --- BATCH: hash four more positions, storing the candidates --- //
            pairs.clear();
            while i < last_i {
                for _ in 0..X {
                    // The batch runs in steps of X, so when X does not divide
                    // `L` (`-l`/`-c` not a power of two) it overshoots
                    // `next_chunk` by up to three bytes and the incoming byte
                    // lies up to three bytes past the block. That is the next
                    // ring slot -- except for a full block in the ring's last
                    // slot, where the C++ reads past its allocation and the
                    // port panicked (index out of range). Past the ring the
                    // byte reads as zero: what a page-padded allocation holds
                    // there, and what the Pascal port's ring tail holds.
                    let incoming = dict.get(buf_off + i + l).copied().unwrap_or(0);
                    hash1.update(dict[buf_off + i], incoming);
                    i += 1;
                    // prefetch_and_store_match (compress.cpp:28-35): only
                    // positions outside the previous match and before the
                    // pending input match are probed at all.
                    if i >= last_match_end && i < match_start {
                        pairs.push((hash1.value, i));
                    }
                }
            }

            // --- CHECK chunkarr TRYING TO FIND MATCH (compress.cpp:187-192) - //
            for &(hsh, pos) in &pairs {
                let k = h.find_match(dict, buf_off, pos, block_size, hsh, (hsh >> 32) as u32);
                if k != NOT_FOUND {
                    let mut match_end = 0usize;
                    if record_match(
                        h, dict, buf_off, block_size, block_start, round_matches, l, min_match,
                        base_len, reread, stat, last_match_end, &mut match_end, literal_bytes,
                        pos, k,
                    )? {
                        last_match_end = match_end;
                        // `goto match_found2`: drop the remaining pairs of this
                        // batch and let the sub-cycle condition decide.
                        break;
                    }
                }
            }
        }

        // --- add_hash at the L boundary (compress.cpp:209) ----------------- //
        // The C++ passes hash1's *current* value, which the batch may have
        // left corresponding to a window past `i` -- reproduce that verbatim.
        h.add_hash(
            hash1.value,
            (hash1.value >> 32) as u32,
            ((block_start + i as u64) / l as u64) as usize,
        );
    }
    Ok(())
}
