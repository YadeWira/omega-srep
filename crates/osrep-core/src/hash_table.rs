//! The match finder (`hash_table.cpp`).
//!
//! This is the core of `-m3`/`-m4`/`-m5`: a hash table over L-byte chunks
//! where each `chunkarr` slot packs hash bits and a chunk number into one
//! `uint32`, probed through a bounded chain. Both halves of the 64-bit chunk
//! hash are used — `chunkarr` keeps the low 32 (masked by `hash_mask`) and
//! `hasharr` the high 32 — so a port that mixes them up finds the "right"
//! matches at the wrong places.
//!
//! Only what the fixed-size-chunk modes use is ported so far; the CDC path
//! (`find_match_CDC`, `startarr`) lands with phase 4c-6 and the digest
//! comparison with 4c-4.
//!
//! Deliberately not ported: `bitarr` and the `prefetch*` helpers. The 4c-0
//! `-a0`/`-a16` byte-identity run proved they are output-neutral, and
//! `speed_opt` (hash_table.cpp:248) is what makes `find_match0` give up on a
//! candidate after one failed slice check — that one *is* semantics and is
//! kept.

use std::io::{Read, Seek};

use crate::util::roundup_to_power_of_two;

/// `MAX_HASH_CHAIN` (`hash_table.cpp:13`).
pub const MAX_HASH_CHAIN: u32 = 12;
/// `NOT_FOUND` (`hash_table.cpp:12`): chunk 0 doubles as "no match", which is
/// why the table refuses to store chunk 0.
pub const NOT_FOUND: u32 = 0;

/// `min_hash_size(n)` (`hash_table.cpp:15`).
pub fn min_hash_size(n: u64) -> u64 {
    (n / 4 + 1) * 5
}

/// `next_hash_slot` (`hash_table.cpp:241`). Despite taking `index`, the C++
/// macro only uses `h`.
#[inline]
fn next_hash_slot(h: u64) -> u64 {
    h.wrapping_mul(123456791)
        .wrapping_add(h >> 16)
        .wrapping_add(462782923)
}

/// The `SliceHash` filter (`hash_table.cpp:19-112`): 4-bit fingerprints of the
/// slices around a candidate chunk, used by `-m5` to reject ~90% of the
/// positions that cannot extend to `MIN_MATCH`. `-m4` leaves it empty
/// (`memreq == 0`), which makes `check` always true.
pub struct SliceHash {
    /// `memreq != 0`: `-m4` leaves the filter empty and `check` always true.
    active: bool,
    h: Vec<u32>,
    l: usize,
    slices_in_block: usize,
    slice_size: usize,
    check_slices: i64,
}

impl SliceHash {
    /// `SliceHash::SliceHash` (`hash_table.cpp:29-38`).
    pub fn new(filesize: u64, l: usize, min_match: usize, io_accelerator: i32) -> SliceHash {
        let slices_in_block = (32 / 4) as usize; // sizeof(entry)*CHAR_BIT/BITS
        let slice_size = l / slices_in_block;
        let check_slices = (min_match as i64 - l as i64) / slice_size as i64 - io_accelerator as i64;
        let memreq = if io_accelerator < 0 || check_slices <= 0 {
            0
        } else {
            filesize / l as u64
        };
        // One extra entry: `check` reads `h[chunk + 1]`, and the scanner can
        // reach the last chunk of the file (the per-batch advance overshoots
        // `next_chunk` by up to three positions, which shifts the `add_hash`
        // chunk index). The C++ reads one `entry` past its `BigAlloc` there,
        // which lands in the allocation's page padding -- zero on the fresh
        // mmap this size produces -- so the port keeps that entry, zeroed.
        SliceHash {
            active: memreq != 0,
            h: vec![0u32; memreq as usize + 1],
            l,
            slices_in_block,
            slice_size,
            check_slices,
        }
    }

    pub fn is_empty(&self) -> bool {
        !self.active
    }

    /// `SliceHash::hash` (`hash_table.cpp:50-56`).
    fn hash(buf: &[u8], off: usize, size: usize) -> u32 {
        let mut hash: u32 = 111222341;
        for b in &buf[off..off + size] {
            hash = hash.wrapping_mul(123456791).wrapping_add(*b as u32);
        }
        hash.wrapping_mul(123456791) >> (32 - 4)
    }

    /// `prepare_buffer_range` (`hash_table.cpp:63-72`): one fingerprint word
    /// per chunk, built from the `slices_in_block` slice hashes.
    pub fn prepare_buffer_range(&mut self, buf: &[u8], buf_off: usize, chunk_start: usize, chunk_end: usize) {
        if !self.active {
            return;
        }
        let mut p = buf_off;
        for curchunk in chunk_start..chunk_end {
            let mut checksum: u32 = 0;
            for i in 0..self.slices_in_block {
                checksum += Self::hash(buf, p, self.slice_size) << (i * 4);
                p += self.slice_size;
            }
            self.h[curchunk] = checksum;
        }
    }

    /// `SliceHash::check` (`hash_table.cpp:89-111`): true if the match *may*
    /// be large enough. `buf` is the block's containing buffer and `buf_off`
    /// the offset of the block inside it, matching the C++'s pointer arithmetic.
    pub fn check(&self, chunk: usize, buf: &[u8], buf_off: usize, i: usize, block_size: usize) -> bool {
        if !self.active {
            return true;
        }
        if i < self.l || block_size - i < 2 * self.l {
            return true;
        }
        // The C++ indexes `h[chunk+1]`/`h[chunk-1]` -- the slices *around* the
        // candidate, in the neighbouring chunks.
        let p = buf_off + i; // offset of the candidate position in `buf`
        let mut checksum = self.h[chunk + 1];
        let mut j = 0usize;
        loop {
            if j as i64 == self.check_slices {
                return true;
            }
            if (checksum >> (j * 4)) & 0xF != Self::hash(buf, p + self.l + j * self.slice_size, self.slice_size) {
                break;
            }
            j += 1;
        }
        checksum = self.h[chunk - 1];
        let mut k = 0usize;
        loop {
            if (j + k) as i64 == self.check_slices {
                return true;
            }
            let slice = p - (k + 1) * self.slice_size;
            if (checksum >> ((self.slices_in_block - (k + 1)) * 4)) & 0xF
                != Self::hash(buf, slice, self.slice_size)
            {
                break;
            }
            k += 1;
        }
        false
    }
}

/// The match search engine (`hash_table.cpp:116-405`), narrowed to the
/// fixed-size-chunk, non-digest path that `-m4`/`-m5` drive.
pub struct HashTable {
    pub round_matches: bool,
    pub compare_digests: bool,
    pub l: usize,
    pub filesize: u64,
    pub total_chunks: u64,
    chunknum_mask: u32,
    hash_mask: u32,
    hashsize1: u64,
    /// `Chunk` (uint32) slots, zeroed (`BigAllocZero`).
    chunkarr: Vec<u32>,
    /// `StoredHashValue` (uint32) slots. The C++ allocates these *uninitialized*
    /// (`BigAlloc`), but every chunk reachable through `chunkarr` had its entry
    /// written first, so zeroing is equivalent.
    hasharr: Vec<u32>,
    slicehash: SliceHash,
}

impl HashTable {
    /// `HashTable::HashTable` (`hash_table.cpp:142-169`) for the non-CDC,
    /// non-in-memory modes. `ERRCODE`-style allocation failures cannot happen
    /// with owned vectors, so the constructor is infallible.
    pub fn new(
        round_matches: bool,
        compare_digests: bool,
        l: usize,
        min_match: usize,
        io_accelerator: i32,
        filesize: u64,
    ) -> HashTable {
        let filesize = filesize.max(l as u64);
        let total_chunks = filesize / l as u64;
        // (The CDC variant adds 10% headroom here; that lands with 4c-6.)
        let chunknum_mask = (roundup_to_power_of_two(total_chunks + 2) - 1) as u32;
        let hash_mask = !chunknum_mask;
        let hashsize = roundup_to_power_of_two(min_hash_size(total_chunks));
        let slicehash = SliceHash::new(filesize, l, min_match, io_accelerator);
        HashTable {
            round_matches,
            compare_digests,
            l,
            filesize,
            total_chunks,
            chunknum_mask,
            hash_mask,
            hashsize1: hashsize - 1,
            chunkarr: vec![0u32; hashsize as usize],
            hasharr: vec![0u32; total_chunks as usize],
            slicehash,
        }
    }

    pub fn slicehash_is_empty(&self) -> bool {
        self.slicehash.is_empty()
    }

    /// `HashTable::prepare_buffer` (`hash_table.cpp:208-213`) minus the digest
    /// precompute, which lands with 4c-4: fill the slice fingerprints for the
    /// `block_len / L` whole chunks the block starts at `offset`.
    pub fn prepare_buffer(&mut self, buf: &[u8], buf_off: usize, block_len: usize, offset: u64) {
        let curchunk = (offset / self.l as u64) as usize;
        let nchunks = block_len / self.l;
        self.slicehash
            .prepare_buffer_range(buf, buf_off, curchunk, curchunk + nchunks);
    }

    /// `chunkarr_value` (`hash_table.cpp:244`).
    #[inline]
    fn chunkarr_value(&self, hash: u64, chunk: u32) -> u32 {
        ((hash as u32) & self.hash_mask).wrapping_add(chunk)
    }

    /// `get_hash` (`hash_table.cpp:245`).
    #[inline]
    fn get_hash(&self, value: u32) -> u32 {
        value & self.hash_mask
    }

    /// `get_chunk` (`hash_table.cpp:246`).
    #[inline]
    fn get_chunk(&self, value: u32) -> u32 {
        value & self.chunknum_mask
    }

    /// `hash_index` (`hash_table.cpp:242`).
    #[inline]
    fn hash_index(&self, h: u64) -> usize {
        (h & self.hashsize1) as usize
    }

    /// `add_hash0<false>` (`hash_table.cpp:252-282`) with `speed_opt == true`
    /// and no digests: scan the chain for an equivalent chunk (there is none to
    /// verify here, so the first hash-bits + `hasharr` hit wins), then insert.
    ///
    /// The C++ caller discards the returned chunk -- `add_hash` exists to
    /// insert -- but the scan still decides *where* the chunk lands, because a
    /// hit breaks the loop and the insert overwrites that very slot.
    pub fn add_hash(&mut self, index: u64, stored_value: u32, curchunk: usize) -> u32 {
        self.hasharr[curchunk] = stored_value;
        if curchunk as u32 == NOT_FOUND {
            return NOT_FOUND; // chunk 0 is reserved as the "no match" value
        }
        let saved_hash = self.chunkarr_value(index, 0);
        let index64 = index;
        let mut h = index64;
        let mut limit = MAX_HASH_CHAIN;
        let mut found = NOT_FOUND;
        loop {
            let value = self.chunkarr[self.hash_index(h)];
            if value == NOT_FOUND {
                break;
            }
            limit -= 1;
            if limit == 0 {
                break;
            }
            if self.get_hash(value) == saved_hash {
                let chunk = self.get_chunk(value);
                if self.hasharr[chunk as usize] == stored_value {
                    found = chunk;
                    break;
                }
            }
            h += 1;
            if limit & 3 == 0 {
                h = next_hash_slot(h);
            }
        }
        let value = self.chunkarr_value(index64, curchunk as u32);
        let slot = self.hash_index(h);
        self.chunkarr[slot] = value;
        found
    }

    /// `find_match0` (`hash_table.cpp:292-329`) for `!COMPARE_DIGESTS`:
    /// a candidate is accepted on the stored 32-bit hash plus, for `-m5`, the
    /// slice check; with `speed_opt` a failed check ends the probe outright.
    pub fn find_match(
        &self,
        buf: &[u8],
        buf_off: usize,
        i: usize,
        block_size: usize,
        index: u64,
        stored_value: u32,
    ) -> u32 {
        let saved_hash = self.chunkarr_value(index, 0);
        let mut h = index;
        let mut limit = MAX_HASH_CHAIN;
        loop {
            let value = self.chunkarr[self.hash_index(h)];
            if value == NOT_FOUND {
                break;
            }
            limit -= 1;
            if limit == 0 {
                break;
            }
            if self.get_hash(value) == saved_hash {
                let chunk = self.get_chunk(value);
                if self.hasharr[chunk as usize] == stored_value {
                    if self.slicehash.check(chunk as usize, buf, buf_off, i, block_size) {
                        return chunk;
                    } else {
                        // `speed_opt`: do not walk the rest of the chain.
                        return NOT_FOUND;
                    }
                }
            }
            h += 1;
            if limit & 3 == 0 {
                h = next_hash_slot(h);
            }
        }
        NOT_FOUND
    }

    /// `match_len` (`hash_table.cpp:332-394`) for `!COMPARE_DIGESTS`.
    ///
    /// `dict` is the buffer holding the block at `buf_off`, so indices past
    /// `buf_off + block_size` are the headroom the C++ reads through as well.
    /// `reread` is the input, seeked per read exactly like the C++'s
    /// `mmap_infile` -- which is a *second* handle on the input file there.
    #[allow(clippy::too_many_arguments)]
    pub fn match_len<R: ReadSeek>(
        &self,
        start_chunk: usize,
        dict: &[u8],
        buf_off: usize,
        min_p: usize,
        start_p: usize,
        last_p: usize,
        offset: u64,
        round_matches: bool,
        reread: &mut R,
        add_len: &mut u32,
    ) -> u32 {
        let l = self.l as u64;
        let mut old_offset = start_chunk as u64 * l;
        let mut p = start_p;
        *add_len = 0;

        // `match_len` exits through `goto stop` (`hash_table.cpp:364,375,377`),
        // which lands *after* the final in-block compare -- so every early exit
        // skips that compare, and only the fall-through reaches it. `stopped`
        // models exactly that; without it a short read leaves `old_offset`
        // below the block start and the tail's index wraps.
        let mut stopped = false;

        if !self.compare_digests && old_offset < offset {
            // -m4/-m5 with the matched chunk in a previous block: reread the
            // old data from the input file.
            let n = old_offset.min(l).min((start_p - min_p) as u64);
            if n > 0 && !round_matches {
                let mut old = vec![0u8; n as usize];
                if read_at(reread, old_offset - n, &mut old) != old.len() {
                    stopped = true;
                } else {
                    let mut i = 1usize;
                    while i <= n as usize && dict[start_p - i] == old[n as usize - i] {
                        i += 1;
                    }
                    *add_len = (i - 1) as u32;
                }
            }

            // Then the bytes after the match start, up to the block.
            if !stopped {
                const BUFSIZE: usize = 4096;
                let mut oldbuf = vec![0u8; BUFSIZE];
                while old_offset < offset {
                    if read_at(reread, old_offset, &mut oldbuf) != BUFSIZE {
                        stopped = true;
                        break;
                    }
                    let mut q = 0usize;
                    while q < BUFSIZE {
                        if p == last_p || dict[p] != oldbuf[q] {
                            stopped = true;
                            break;
                        }
                        p += 1;
                        q += 1;
                    }
                    if stopped {
                        break;
                    }
                    old_offset += BUFSIZE as u64;
                }
            }
        } else if !self.compare_digests && !round_matches {
            // Matched chunk inside the current block: compare the bytes before
            // the match start against the block itself.
            let n = (old_offset - offset).min(l).min((start_p - min_p) as u64);
            let mut i = 1usize;
            while i <= n as usize
                && dict[start_p - i] == dict[buf_off + (old_offset - offset) as usize - i]
            {
                i += 1;
            }
            *add_len = (i - 1) as u32;
        }

        if !stopped {
            // The tail, inside the current block.
            let mut q = buf_off + (old_offset - offset) as usize;
            while p < last_p && dict[p] == dict[q] {
                p += 1;
                q += 1;
            }
        }
        (p - start_p) as u32 + *add_len
    }
}

/// Anything the match finder may seek and read in: the C++ uses a second
/// handle on the input file for exactly this.
pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// One `pread`: read `buf.len()` bytes at `off` without disturbing the caller's
/// position (the C++ seeks a dedicated handle).
fn read_at<R: ReadSeek>(r: &mut R, off: u64, buf: &mut [u8]) -> usize {
    use std::io::SeekFrom;
    if r.seek(SeekFrom::Start(off)).is_err() {
        return 0;
    }
    let mut filled = 0usize;
    while filled < buf.len() {
        match r.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(_) => break,
        }
    }
    filled
}
