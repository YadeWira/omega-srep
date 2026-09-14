//! The `-m0` in-memory REP match finder (`compress_inmem.cpp`).
//!
//! The input is fed through a rotating dictionary (`dict` in `io.cpp`), and
//! for every L-byte window the compressor looks for the *previous* window with
//! the same "local maximum hash". Matches may reach back into blocks that were
//! read earlier, which is why the dictionary arithmetic is modular.
//!
//! Two C++ details the port keeps faithfully:
//!
//! * `TIndex` is `size_t`, so `PolynomialRollingHash<TIndex>` is 64-bit on the
//!   64-bit builds but 32-bit on i686. The port is always 64-bit, i.e. it
//!   matches the x86_64 oracle (a 32-bit C++ build produces different `-m0`
//!   bytes; that is a pre-existing cross-arch divergence, not corruption,
//!   since decoding never re-runs the hash).
//! * `find_match_start`/`find_match_end` walk the dictionary with the same
//!   bounds the C++ derives (`LowBound`/`HighBound`), which is what keeps both
//!   pointers inside the ring.

use crate::lz;
use crate::rolling::{PolynomialRollingHash, PRIME1};
use crate::util::roundup_to_power_of_two;

/// `INMEM_PREFETCH` (`compress_inmem.cpp:5`): how many cycles ahead the hash
/// table is prefetched. Its output-visible effect is the padding of zeroes
/// appended to every block's hash list.
pub const INMEM_PREFETCH: usize = 100;

/// `min_hash_size(n)` (`hash_table.cpp:15`).
fn min_hash_size(n: u64) -> u64 {
    (n / 4 + 1) * 5
}

pub struct DictionaryCompressor {
    l: usize,
    min_match: usize,
    base_len: usize,
    /// `MAX_DIST`: matches never reach further back than this.
    max_dist: u64,
    /// `hashmask`: index mask over `hasharr`.
    hashmask: u64,
    hasharr: Vec<u64>,
}

impl DictionaryCompressor {
    /// `DictionaryCompressor::DictionaryCompressor` (`compress_inmem.cpp:23`).
    ///
    /// `hashsize_hint` is the `-dh` value; when zero the table is sized from
    /// the dictionary itself. `hashsize` counts *bytes* in the C++, and the
    /// table is `TIndex` (8-byte) elements inside it.
    pub fn new(
        inmem_dictsize: u64,
        hashsize_hint: u64,
        min_match: usize,
        l: usize,
        base_len: usize,
    ) -> Self {
        let mut hasharr: Vec<u64> = Vec::new();
        let mut hashmask: u64 = 0;
        if inmem_dictsize != 0 {
            let hint = if hashsize_hint != 0 {
                hashsize_hint
            } else {
                min_hash_size(8 * (inmem_dictsize / l as u64))
            };
            let hashsize = roundup_to_power_of_two(hint);
            hashmask = hashsize / 8 - 1;
            // `BigAllocZero(hashsize)` zeroes hashsize bytes, i.e. hashsize/8
            // elements.
            hasharr = vec![0u64; (hashsize / 8) as usize];
        }
        DictionaryCompressor {
            l,
            min_match,
            base_len,
            max_dist: inmem_dictsize,
            hashmask,
            hasharr,
        }
    }

    /// `DictionaryCompressor::prepare_buffer` (`compress_inmem.cpp:56`): for
    /// every L-byte block of `buf`, record the local maximum of the rolling
    /// hash and where it occurred. The two values are what `compress` walks.
    pub fn prepare_buffer(&self, hashptr: &mut Vec<u64>, buf: &[u8]) {
        if self.max_dist == 0 {
            return;
        }
        let l = self.l;
        let num_blocks = buf.len() / l; // whole blocks only
        if num_blocks <= 1 {
            return;
        }
        let mut hash = PolynomialRollingHash::new(l, PRIME1);
        hash.moveto(buf);
        let mut ptr = 0usize;
        for _block in 1..num_blocks {
            let mut maxhash = hash.value;
            let mut maxi = 0usize;
            for i in 0..l {
                if hash.value > maxhash {
                    maxhash = hash.value;
                    maxi = i;
                }
                hash.update(buf[ptr], buf[ptr + l]);
                ptr += 1;
            }
            hashptr.push(maxhash & self.hashmask);
            hashptr.push(maxi as u64);
        }
        for _ in 0..INMEM_PREFETCH * 2 {
            hashptr.push(0);
        }
    }

    /// `DictionaryCompressor::compress` (`compress_inmem.cpp:83`).
    ///
    /// `bufstart` is the offset of the block being compressed inside `dict`
    /// (what the C++ computes as `buf - dict`); `hashptr` is the list
    /// `prepare_buffer` just built for this block.
    ///
    /// Returns the match records appended to `out` (the C++ writes them
    /// through `stat`) and updates `literal_bytes` exactly as the C++ does:
    /// it starts at the block size and loses one match length per match.
    pub fn compress(
        &mut self,
        dict: &[u8],
        dictsize: usize,
        bufstart: usize,
        bufsize: usize,
        hashptr: &[u64],
        literal_bytes: &mut u32,
        out: &mut Vec<u32>,
    ) -> Result<(), lz::EncodeError> {
        *literal_bytes = bufsize as u32;
        if self.max_dist == 0 {
            return Ok(());
        }

        let l = self.l;
        let bufend = bufstart + bufsize;
        let mut last_match_end = bufstart;
        let data_start = (bufstart + dictsize - self.max_dist as usize) % dictsize;

        let mut hp = 0usize; // cursor over hashptr
        let mut last_i = bufstart;
        while last_i + 2 * l <= bufend {
            let hash = hashptr[hp] as usize;
            hp += 1;
            let i = last_i + hashptr[hp] as usize;
            hp += 1;

            if i >= last_match_end {
                let found = self.hasharr[hash];
                if found != 0 {
                    let found = found as usize;
                    let match_distance = if found < i {
                        i - found
                    } else {
                        dictsize - found + i
                    };
                    if match_distance as u64 > self.max_dist {
                        // no_match
                        self.hasharr[hash] = i as u64;
                        last_i += l;
                        continue;
                    }
                    let low_bound = if found >= data_start {
                        if found - data_start > i {
                            0
                        } else {
                            i - (found - data_start)
                        }
                    } else {
                        i - found
                    };
                    let high_bound = if found < i {
                        dictsize
                    } else {
                        dictsize - found + i
                    };
                    let start = find_match_start(
                        dict,
                        found,
                        i,
                        last_match_end.max(low_bound),
                    );
                    let end = find_match_end(dict, found, i, bufend.min(high_bound));
                    let match_len = end - start;
                    let lit_len = start - last_match_end;
                    if match_len >= self.min_match {
                        lz::encode_lz_match(
                            out,
                            false,
                            self.base_len as u32,
                            lit_len as u32,
                            match_distance as u64,
                            match_len as u32,
                        )?;
                        *literal_bytes -= match_len as u32;
                        last_match_end = end;
                    }
                }
            }
            // no_match label falls through here: record the window.
            self.hasharr[hash] = i as u64;
            last_i += l;
        }
        Ok(())
    }
}

/// `find_match_start` (`compress_inmem.cpp:41`): walk both positions backwards
/// while they agree and `q` has not passed `start`; the match begins at the
/// first byte of the agreed suffix.
fn find_match_start(dict: &[u8], p: usize, q: usize, start: usize) -> usize {
    let mut p = p;
    let mut q = q;
    while q > start {
        p -= 1;
        q -= 1;
        if dict[p] != dict[q] {
            return q + 1;
        }
    }
    q
}

/// `find_match_end` (`compress_inmem.cpp:48`): walk forwards while the bytes
/// agree and `q` has not passed `end`; the match ends where they diverge.
fn find_match_end(dict: &[u8], p: usize, q: usize, end: usize) -> usize {
    let mut p = p;
    let mut q = q;
    while q < end && dict[p] == dict[q] {
        p += 1;
        q += 1;
    }
    q
}
