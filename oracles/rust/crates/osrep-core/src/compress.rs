//! The single-block compressor for `-m3`/`-m4`/`-m5` (`compress.cpp`).
//!
//! The C++ is templated over `ACCELERATOR` (0,1,2,…,64) with three
//! hand-unrolled loops, `bitarr` prefiltering and prefetches. The variants
//! are NOT output-neutral (the 4c-0 `-a0`/`-a16` run only covered the default
//! `-l`): `find_match` accepts a chunk whose hash differs from the probe's in
//! the chunk-number bits of its `chunkarr` slot -- a window that differs only
//! in its last byte or two by a small amount -- and `-m4`/`-m5` keep it when
//! the reread bytes, with the backward extension, still reach `MIN_MATCH`
//! (always possible when `MIN_MATCH == L`: `L - 1` forward plus one back).
//! The accelerated scan only probes positions whose hash passes `bitarr`,
//! which filters most of those out, and the C++ picks it by default
//! (`accel = min(max(L/32, 1), 4)`). So `compress` runs `compress_accel`
//! for the variants the C++ instantiates, and `compress<0>` for `-a-`/`-a0`
//! and for the values where the C++ has no defined behaviour (`encoder.rs`
//! lists them). With the default `-l` the filter almost never decides
//! anything and both give the same archive. In `compress<0>` this port
//! reproduces the details that *are* output-visible:
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
        let match_start = i - add_len as usize;
        // `if (ROUND_MATCHES) match_len = match_len/L*L` (compress.cpp:15-16).
        let rounded_len = if round_matches {
            match_len / l as u32 * l as u32
        } else {
            match_len
        };
        let b = base_len as u64;
        let grid_src = k as u64 * l as u64;
        let mut match_offset = block_start + i as u64 - grid_src;

        // First the record 2.2.0 wrote, which assumes chunk `k` sits at `k*L`.
        let Some((old_start, old_len)) = fit_base_len_grid(
            dict, buf_off, block_start, round_matches, b, grid_src, match_start, rounded_len,
            reread,
        ) else {
            return Ok(false);
        };

        // `k*L` is where chunk `k`'s bytes really are only while every block
        // started on the `L` grid: one that starts at a `block_start` that is
        // not a multiple of `L` (any `-b` that is not a multiple of `L`)
        // numbers its chunks from `block_start / L` but digests and hashes
        // them at `block_start + m*L`. `-m4`/`-m5` reread the bytes at `k*L`,
        // so for them that only loses matches; `-m3` trusts the digests and
        // never rereads, so the record went out with a source off by
        // `block_start % L` (exit 0, `-d` fails or returns other bytes). The
        // digest walk can also cross from a block on the grid into the next,
        // shifted one, whose chunks are not contiguous with it. And when `L`
        // is not a multiple of 4 the scan probes windows that end up to three
        // bytes past the block, and `match_len` counts that first chunk
        // whole, so the record ran past the block (exit 4, BadBlockRecord).
        //
        // Such a record is checked against the bytes the decoder will copy.
        // If it decodes to these bytes and fits in the block it is written
        // exactly as before, so every archive that decoded keeps its bytes;
        // otherwise it is rebuilt from the chunk's true source, cut to the
        // bytes that really match. Archives where every block starts on the
        // `L` grid and no record overruns take the first branch untouched.
        let overrun = old_start + old_len as usize > block_size;
        let shifted = h.compare_digests && h.any_shifted;
        let keep_old = if !shifted && !overrun {
            true
        } else if overrun {
            false
        } else {
            let dest = block_start + old_start as u64;
            let decoded_src = if round_matches {
                (dest / b * b).wrapping_sub(match_offset / b * b)
            } else {
                dest.wrapping_sub(match_offset)
            };
            common_prefix(dict, buf_off, old_start, decoded_src, dest, old_len, reread) == old_len
        };

        let (match_start, match_len) = if keep_old {
            (old_start, old_len)
        } else {
            let true_src = if h.compare_digests {
                h.chunk_pos(k as usize)
            } else {
                grid_src
            };
            // Measured from the true source up to the end of the block, not
            // capped by `match_len`: in a shifted block that came from the
            // digests of the wrong (grid) chunks, so it is usually a single
            // chunk, and a record cut to it left most of a long repeat to be
            // probed again chunk by chunk (period-69 text with `-m3
            // -b1000001b`: 12.7 s and 2.9 MB of 4 MB, against 0.02 s and 4 KB
            // with `-b1mb`). The record only covers bytes that equal the
            // source, so it decodes whatever its length.
            let dest = block_start + match_start as u64;
            let mut len = common_prefix(
                dict,
                buf_off,
                match_start,
                true_src,
                dest,
                (block_size - match_start) as u32,
                reread,
            );
            if round_matches {
                len = len / l as u32 * l as u32;
            }
            if len == 0 || (len as usize) < min_match {
                return Ok(false);
            }
            match_offset = dest - true_src;
            match fit_base_len_grid(
                dict, buf_off, block_start, round_matches, b, true_src, match_start, len, reread,
            ) {
                Some(r) => r,
                None => return Ok(false),
            }
        };
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

/// The BASE_LEN-grid adjustment of a rounded record whose source is `src`.
///
/// A rounded record stores the offset and the length in units of BASE_LEN
/// (`b`), not of L (`ENCODE_LZ_MATCH`'s `L1`, srep.cpp:117), and the decoder
/// rebuilds the source as `dest/BASE_LEN*BASE_LEN - offset/BASE_LEN*BASE_LEN`
/// and the length as a whole number of BASE_LENs. That is exact when the
/// source and the length are multiples of BASE_LEN -- always so when BASE_LEN
/// divides L, the default (BASE_LEN = min(-l, 512), L = -l). With `-c` below
/// BASE_LEN (`-m3 -c8 -l16`), or a BASE_LEN that does not divide L (`-m3 -c8
/// -l17`, `-m3 -dl17`), the C++ wrote archives that do not decode (exit 0:
/// silent data loss) or stopped with "match len too small" (exit 4), and the
/// port did the same.
///
/// A record that will not decode to these bytes is moved up to the next source
/// on the BASE_LEN grid and cut to whole units -- still inside the verified
/// match, so the bytes are the same -- or not taken (`None`) when less than
/// one unit is left. One that decodes right as it is (an exact one, or an
/// inexact source that happens to hold the same bytes, as on all-zero input)
/// is kept, so every archive that used to decode keeps its bytes. Returns the
/// record's `(match_start, match_len)`; unrounded records pass through.
#[allow(clippy::too_many_arguments)]
fn fit_base_len_grid<R: ReadSeek>(
    dict: &[u8],
    buf_off: usize,
    block_start: u64,
    round_matches: bool,
    b: u64,
    src: u64,
    match_start: usize,
    match_len: u32,
    reread: &mut R,
) -> Option<(usize, u32)> {
    if !round_matches {
        return Some((match_start, match_len));
    }
    let len = match_len as u64;
    if !(src % b == 0 && len % b == 0 && len >= b)
        && !decodes_as_is(dict, buf_off, block_start, match_start, src, match_len, b, reread)
    {
        let skip = (b - src % b) % b;
        let cut = len.saturating_sub(skip) / b * b;
        if cut < b {
            return None;
        }
        return Some((match_start + skip as usize, cut as u32));
    }
    Some((match_start, match_len))
}

/// How many of the `len` bytes at file offset `src` equal the block's bytes
/// at `match_start` (file offset `dest`), reread from the input; 0 unless
/// `src` comes before `dest`. The decoder copies forward byte by byte, so an
/// overlapping source (`src + len > dest`) is compared the same way.
///
/// The input is reread in pieces of 4 KiB growing to 64 KiB and the compare
/// stops at the first difference, so a probe that fails early reads one piece
/// and not the whole `len` (up to the rest of the block): reading it all
/// would make the scan quadratic in the block size.
fn common_prefix<R: ReadSeek>(
    dict: &[u8],
    buf_off: usize,
    match_start: usize,
    src: u64,
    dest: u64,
    len: u32,
    reread: &mut R,
) -> u32 {
    const FIRST_PIECE: usize = 4096;
    const MAX_PIECE: usize = 65536;
    if src >= dest {
        return 0;
    }
    let len = len as usize;
    let cur = &dict[buf_off + match_start..buf_off + match_start + len];
    let mut old = vec![0u8; FIRST_PIECE.min(len)];
    let mut piece = FIRST_PIECE;
    let mut n = 0usize;
    while n < len {
        let want = piece.min(len - n);
        if old.len() < want {
            old.resize(want, 0);
        }
        let got = read_at(reread, src + n as u64, &mut old[..want]);
        let same = old[..got].iter().zip(&cur[n..n + got]).take_while(|(a, b)| a == b).count();
        n += same;
        if same < want {
            break;
        }
        piece = (piece * 2).min(MAX_PIECE);
    }
    n as u32
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
    // Compared in pieces, like `common_prefix`: the same answer as one read
    // of `len` bytes (a short read is a difference), without a buffer as long
    // as the match.
    common_prefix(dict, buf_off, match_start, decoded_src, dest, len, reread) == len
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
    accelerator: usize,
) -> Result<(), lz::EncodeError> {
    // `switch (ACCELERATOR)` (srep.cpp:748-758). The variants are not
    // output-neutral: the accelerated ones only probe `chunkarr` at positions
    // whose hash passes the `bitarr` filter, and `find_match` can return a
    // chunk whose 64-bit hash differs from the probe's in the low bits it does
    // not compare (the chunk-number bits of the `chunkarr` slot), which
    // `-m4`/`-m5` then accept when the reread bytes reach `MIN_MATCH`.
    if accelerator != 0 && h.has_bitarr() {
        return compress_accel(
            h,
            dict,
            buf_off,
            block_size,
            round_matches,
            l,
            min_match,
            base_len,
            block_start,
            in_stat,
            stat,
            literal_bytes,
            reread,
            accelerator,
        );
    }
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

/// The byte at `idx` of the ring, zero past its end (see the batch in
/// `compress`: the scan reads up to `CYCLES - 1` bytes past a block).
#[inline]
fn byte_at(dict: &[u8], idx: usize) -> u8 {
    dict.get(idx).copied().unwrap_or(0)
}

/// `compress<ACCELERATOR>` for `ACCELERATOR` = 1, 2, 4, ..., 64
/// (`compress.cpp:54-212`), transcribed as written: `hash1` covers the last
/// `L - OFFSET` bytes of the window, `bitarr` is probed once per `CYCLES`
/// positions and, on a hit, all `CYCLES` positions are hashed in full and
/// stored; `LOOKAHEAD` is 256.
#[allow(clippy::too_many_arguments)]
fn compress_accel<R: ReadSeek>(
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
    cycles: usize,
) -> Result<(), lz::EncodeError> {
    const LOOKAHEAD_A: usize = 256;
    let offset = cycles - 1;
    let x = cycles.max(4);
    let mut last_match_end = 0usize;
    *literal_bytes = block_size as u32;

    let mut instat = in_stat;
    let decode_next =
        |instat: &mut &[u32], basic_pos: u64| -> Result<(usize, u32, u64), lz::DecodeError> {
            let (m, used) = lz::decode_lz_match(instat, round_matches, false, base_len, basic_pos)?;
            *instat = &instat[used..];
            Ok(((m.dest - block_start) as usize, m.len, m.dest - m.src))
        };
    let (ms, ml, mo) =
        decode_next(&mut instat, block_start).map_err(|_| lz::EncodeError::BadInputMatch)?;
    let mut match_start = ms;
    let mut match_len = ml;
    let mut match_offset = mo;

    if l > block_size / 2 {
        return Ok(());
    }

    let mut hash1 = PolynomialRollingHash::new(l - offset, PRIME1);
    let mut hash2 = PolynomialRollingHash::new(l, PRIME1);
    // PRIME1_powers[j] = PRIME1^(L-1-j) (compress.cpp:73-75).
    let mut powers = vec![0u64; cycles];
    powers[cycles - 1] = crate::rolling::power(PRIME1, (l - cycles) as u32);
    for j in (1..cycles).rev() {
        powers[j - 1] = powers[j].wrapping_mul(PRIME1);
    }
    let mut hashes1: Vec<u64> = Vec::with_capacity(LOOKAHEAD_A);
    let mut pairs: Vec<(u64, usize)> = Vec::with_capacity(LOOKAHEAD_A * 2);

    // --- SPECIAL HANDLING FOR FIRST L BYTES (compress.cpp:78-94) ---------- //
    hash1.moveto(&dict[buf_off..]);
    hash2.value = hash1.value;
    let mut j = 0usize;
    loop {
        h.mark_match_possibility(hash1.value);
        if j == offset {
            break;
        }
        hash1.update(dict[buf_off + j], dict[buf_off + l - offset + j]);
        hash2.update(0, dict[buf_off + l - offset + j]);
        j += 1;
    }
    {
        let i = 0usize;
        let hash = hash2.value;
        let k = h.find_match(dict, buf_off, i, block_size, hash, (hash >> 32) as u32);
        if k != NOT_FOUND {
            let mut match_end = 0usize;
            if record_match(
                h,
                dict,
                buf_off,
                block_size,
                block_start,
                round_matches,
                l,
                min_match,
                base_len,
                reread,
                stat,
                last_match_end,
                &mut match_end,
                literal_bytes,
                i,
                k,
            )? {
                last_match_end = match_end;
            }
        }
    }
    h.add_hash(
        hash2.value,
        (hash2.value >> 32) as u32,
        (block_start / l as u64) as usize,
    );

    // --- MAIN CYCLE (compress.cpp:97-210) ---------------------------------- //
    let mut i = 0usize;
    while i + 2 * l <= block_size {
        let mut saved_hash1 = 0u64;
        let next_chunk = i + l;
        while i < next_chunk {
            if i >= match_start {
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
                let (ms, ml, mo) = decode_next(
                    &mut instat,
                    block_start + match_start as u64 + match_len as u64,
                )
                .map_err(|_| lz::EncodeError::BadInputMatch)?;
                match_start = ms;
                match_len = ml;
                match_offset = mo;
            }

            // UPDATE hash1 UNTIL last_match_end (compress.cpp:124-132).
            let next_i = (next_chunk - cycles).min(if last_match_end > 0 {
                last_match_end - 1
            } else {
                0
            });
            if next_i >= i + l / 2 {
                i = next_i & !(x - 1);
                hash1.moveto(&dict[buf_off + i + offset..]);
            } else {
                while i + x <= next_i {
                    for t in 0..x {
                        let p = buf_off + i + offset + t;
                        hash1.update(dict[p], byte_at(dict, p + l - offset));
                    }
                    i += x;
                }
            }

            let last_i = next_chunk.min(i + LOOKAHEAD_A);

            // PREFETCH bitarr AND UPDATE hash1 (compress.cpp:138-149).
            hashes1.clear();
            let mut i0 = i;
            while i0 < last_i {
                hash1.update(
                    byte_at(dict, buf_off + i0 + offset),
                    byte_at(dict, buf_off + i0 + l),
                );
                hashes1.push(hash1.value);
                for t in 0..cycles - 1 {
                    let p = buf_off + i0 + 1 + offset + t;
                    hash1.update(byte_at(dict, p), byte_at(dict, p + l - offset));
                }
                i0 += cycles;
            }
            saved_hash1 = *hashes1.last().unwrap();

            // CHECK bitarr AND STORE CANDIDATES (compress.cpp:152-184).
            pairs.clear();
            let store = |pos: usize, hash: u64, pairs: &mut Vec<(u64, usize)>| {
                if pos >= last_match_end && pos < match_start {
                    pairs.push((hash, pos));
                }
            };
            let mut n1 = 0usize;
            while i < last_i {
                let hsh1 = hashes1[n1];
                n1 += 1;
                if h.check_match_possibility(hsh1) {
                    i += 1;
                    hash2.value = hsh1;
                    for (j, &power) in powers[..cycles - 1].iter().enumerate() {
                        hash2.value = hash2.value.wrapping_add(
                            (byte_at(dict, buf_off + i + j) as u64).wrapping_mul(power),
                        );
                    }
                    store(i, hash2.value, &mut pairs);
                    for _ in 0..cycles - 1 {
                        hash2.update(byte_at(dict, buf_off + i), byte_at(dict, buf_off + i + l));
                        store(i + 1, hash2.value, &mut pairs);
                        i += 1;
                    }
                } else {
                    i += cycles;
                }
            }

            // CHECK chunkarr TRYING TO FIND MATCH (compress.cpp:187-192).
            for &(hsh, pos) in &pairs {
                let k = h.find_match(dict, buf_off, pos, block_size, hsh, (hsh >> 32) as u32);
                if k != NOT_FOUND {
                    let mut match_end = 0usize;
                    if record_match(
                        h,
                        dict,
                        buf_off,
                        block_size,
                        block_start,
                        round_matches,
                        l,
                        min_match,
                        base_len,
                        reread,
                        stat,
                        last_match_end,
                        &mut match_end,
                        literal_bytes,
                        pos,
                        k,
                    )? {
                        last_match_end = match_end;
                        break;
                    }
                }
            }
        }

        // SECOND SUB-MAIN CYCLE (compress.cpp:196-208).
        hash1.value = saved_hash1;
        hash2.value = saved_hash1;
        h.mark_match_possibility(hash1.value);
        for j in 1..cycles {
            hash1.update(
                byte_at(dict, buf_off + i - cycles + j + offset),
                byte_at(dict, buf_off + i - cycles + j + l),
            );
            h.mark_match_possibility(hash1.value);
            hash2.update(0, byte_at(dict, buf_off + i - cycles + j + l));
        }
        h.add_hash(
            hash2.value,
            (hash2.value >> 32) as u32,
            ((block_start + i as u64) / l as u64) as usize,
        );
    }
    Ok(())
}
