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
    // `-index=`: where the match lists go when they are not kept in the
    // archive (`fstat`, `srep.cpp:606`). Only the lists move -- the block
    // headers, the literals, the block-size table and the footer stay in
    // `output`, which is why the archive still decodes its own structure.
    mut index: Option<&mut dyn Write>,
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

    // 2. Sort by source (`srep.cpp:899`). The comparator looks at `src` only,
    //    and matches with equal `src` are common (every copy of a block that
    //    the match finder resolves to the same earlier occurrence), so the
    //    order of those ties is part of the archive. The C++ gets it from
    //    libstdc++'s `std::sort`; `libstdcxx_sort` reproduces it exactly.
    //    (Up to 2.2.1 this was a stable sort, on the false premise that the
    //    encoder never emits two matches with the same source: about one real
    //    file in ten came out with different bytes than the C++.)
    libstdcxx_sort(&mut matches, |a, b| a.src < b.src);

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

        // The list is built once and then sent to whichever sink owns it, so
        // the two destinations cannot drift apart.
        let list_bytes: Vec<u8> = if v5 {
            stat_bytes.clone()
        } else {
            let mut v = Vec::with_capacity(stat.len() * 4);
            for word in &stat {
                v.extend_from_slice(&word.to_le_bytes());
            }
            v
        };
        match index.as_deref_mut() {
            Some(ix) => ix.write_all(&list_bytes).map_err(|_| EncodeError::Io)?,
            None => output.write_all(&list_bytes)?,
        }
        // `compsize` counts the list either way: the C++ reports the archive
        // and its index as one total (`srep.cpp:939` feeds the same counter).
        compsize += list_bytes.len() as u64;

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

// ---------------------------------------------------------------------------
// libstdc++'s `std::sort`, transcribed (GCC `bits/stl_algo.h` `__sort`,
// `__introsort_loop`, `__final_insertion_sort`; `bits/stl_heap.h` for the
// depth-limit fallback). It is not stable, and which way it breaks ties is a
// pure function of the input order, so following it step by step is what makes
// the second pass emit equal-`src` matches in the C++ encoder's order. The
// algorithm has been the same in every libstdc++ that built a C++ release
// (Linux g++, MinGW-w64 for Windows, 32 and 64 bit).

const SORT_THRESHOLD: usize = 16; // `_S_threshold`

fn libstdcxx_sort<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], less: F) {
    let n = v.len();
    if n == 0 {
        return;
    }
    // `std::__lg(n) * 2`
    let depth = 2 * (usize::BITS - 1 - n.leading_zeros()) as usize;
    introsort_loop(v, 0, n, depth, &less);
    // `__final_insertion_sort`
    if n > SORT_THRESHOLD {
        insertion_sort(v, 0, SORT_THRESHOLD, &less);
        for i in SORT_THRESHOLD..n {
            unguarded_linear_insert(v, i, &less);
        }
    } else {
        insertion_sort(v, 0, n, &less);
    }
}

fn introsort_loop<T: Copy, F: Fn(&T, &T) -> bool>(
    v: &mut [T],
    first: usize,
    mut last: usize,
    mut depth: usize,
    less: &F,
) {
    while last - first > SORT_THRESHOLD {
        if depth == 0 {
            heap_sort(v, first, last, less);
            return;
        }
        depth -= 1;
        // `__unguarded_partition_pivot`
        let mid = first + (last - first) / 2;
        move_median_to_first(v, first, first + 1, mid, last - 1, less);
        let cut = unguarded_partition(v, first + 1, last, first, less);
        introsort_loop(v, cut, last, depth, less);
        last = cut;
    }
}

fn move_median_to_first<T: Copy, F: Fn(&T, &T) -> bool>(
    v: &mut [T],
    result: usize,
    a: usize,
    b: usize,
    c: usize,
    less: &F,
) {
    let pick = if less(&v[a], &v[b]) {
        if less(&v[b], &v[c]) {
            b
        } else if less(&v[a], &v[c]) {
            c
        } else {
            a
        }
    } else if less(&v[a], &v[c]) {
        a
    } else if less(&v[b], &v[c]) {
        c
    } else {
        b
    };
    v.swap(result, pick);
}

fn unguarded_partition<T: Copy, F: Fn(&T, &T) -> bool>(
    v: &mut [T],
    mut first: usize,
    mut last: usize,
    pivot: usize,
    less: &F,
) -> usize {
    loop {
        while less(&v[first], &v[pivot]) {
            first += 1;
        }
        last -= 1;
        while less(&v[pivot], &v[last]) {
            last -= 1;
        }
        if first >= last {
            return first;
        }
        v.swap(first, last);
        first += 1;
    }
}

/// `std::__partial_sort(first, last, last)`: `__make_heap` + `__sort_heap`.
fn heap_sort<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], first: usize, last: usize, less: &F) {
    #[cfg(test)]
    tests::HEAP_FALLBACKS.with(|c| c.set(c.get() + 1));
    let len = last - first;
    if len >= 2 {
        let mut parent = (len - 2) / 2;
        loop {
            let value = v[first + parent];
            adjust_heap(v, first, parent, len, value, less);
            if parent == 0 {
                break;
            }
            parent -= 1;
        }
    }
    let mut end = last;
    while end - first > 1 {
        end -= 1;
        // `__pop_heap(first, end, end)`
        let value = v[end];
        v[end] = v[first];
        adjust_heap(v, first, 0, end - first, value, less);
    }
}

fn adjust_heap<T: Copy, F: Fn(&T, &T) -> bool>(
    v: &mut [T],
    base: usize,
    mut hole: usize,
    len: usize,
    value: T,
    less: &F,
) {
    let top = hole;
    let mut second = hole;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if less(&v[base + second], &v[base + second - 1]) {
            second -= 1;
        }
        v[base + hole] = v[base + second];
        hole = second;
    }
    if len & 1 == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        v[base + hole] = v[base + second - 1];
        hole = second - 1;
    }
    // `__push_heap`
    while hole > top {
        let parent = (hole - 1) / 2;
        if !less(&v[base + parent], &value) {
            break;
        }
        v[base + hole] = v[base + parent];
        hole = parent;
    }
    v[base + hole] = value;
}

fn insertion_sort<T: Copy, F: Fn(&T, &T) -> bool>(
    v: &mut [T],
    first: usize,
    last: usize,
    less: &F,
) {
    if first == last {
        return;
    }
    for i in first + 1..last {
        if less(&v[i], &v[first]) {
            let val = v[i];
            v.copy_within(first..i, first + 1);
            v[first] = val;
        } else {
            unguarded_linear_insert(v, i, less);
        }
    }
}

/// `__unguarded_linear_insert`: no lower bound check. Every caller guarantees
/// an element no greater than `v[last]` somewhere before it (the insertion sort
/// tests `v[first]` first; the final pass runs after the first 16 elements,
/// which hold the minimum, are sorted).
fn unguarded_linear_insert<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], mut last: usize, less: &F) {
    let val = v[last];
    while less(&val, &v[last - 1]) {
        v[last] = v[last - 1];
        last -= 1;
    }
    v[last] = val;
}

#[cfg(test)]
mod tests {
    use super::libstdcxx_sort;
    use std::cell::Cell;

    thread_local! {
        /// How many times the introsort depth limit sent a range to the heap
        /// sort, so the test can show that the fixture reaches that path.
        pub(super) static HEAP_FALLBACKS: Cell<usize> = const { Cell::new(0) };
    }

    // FNV-1a of the permutation the real libstdc++ `std::sort` produces for
    // each `stdsort_case(kind, STDSORT_SIZES[i])`, printed by
    // `oracles/cxx/tools/stdsort_fixture.cpp`. Identical output from g++ 14.2
    // (native and -m32), clang++ on libstdc++, and MinGW-w64 i686 and x86-64
    // (under wine): the toolchains the C++ releases were built with.
    // Regenerate with that program if the generator below changes.
    const STDSORT_EXPECTED: [[u32; 46]; 8] = [
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0x253381b6, 0x00732805, 0x8ea9e711, 0x70d6f495,
            0x933b6fea, 0x81540be5, 0x5b6a6385, 0xf045e5b4, 0xfee230b6, 0xe02df135, 0x9181e855,
            0x6587b17a, 0x8ef36ed5, 0x63d7dfc5, 0xcaa34594, 0xb07e1c85, 0xcdb59c55, 0x2fd1abaa,
            0xa0ba0405, 0x382c4915, 0xd7b10705, 0x2216dd4a, 0xfd8611b5, 0x71570555, 0xaa371ad5,
            0xd7f2c7da, 0x92f2b8f5, 0xdb1d563a, 0x23b320a1, 0x25a8562d, 0x0d2cfd59, 0x0e8f642d,
            0x6bdbeefb, 0x9052cd9c, 0x4cb8acb1, 0xa182ce6f, 0x6a45a075, 0xa0162b11, 0x53118171,
            0xd1f946f3, 0xb3a4f995, 0x622f3a4b, 0x7be237f5,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0x4cd2e1e6, 0x24927f55, 0xb63986e1, 0x65836a55,
            0x19707f0a, 0xe0785e75, 0x42fa0865, 0xe7d34e64, 0xc5fd0aa6, 0x572caa65, 0x4458bf45,
            0x4ae6ee9a, 0x7fce7265, 0xe47aabb5, 0xf8e88b64, 0xe8d42d75, 0xa0377af5, 0x726ad08a,
            0x28f08055, 0x728f3f35, 0xfb1249f5, 0x0e55779a, 0xf0f1a3d5, 0x324fc665, 0x97d74af5,
            0x61c53d3a, 0x150e29b5, 0x9aabf3da, 0x6403fe81, 0xb17ff465, 0x81848e99, 0x0125692d,
            0xb387ebbf, 0x626e3b1c, 0x3f6e346d, 0x3a8406cb, 0xbed6bef5, 0x158b3ab9, 0x2bc6cf75,
            0x8baaf5eb, 0x4e8267cd, 0x9ab88383, 0xd9ddcba9,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0x253381b6, 0x00732805, 0x8ea9e711, 0xb44ff9c5,
            0x0ced957a, 0x93aab7c5, 0xfa2fa025, 0xc7645754, 0xc8f16eb6, 0x8cdc56f5, 0xcb103e55,
            0x1db5ba1a, 0xdeeccea5, 0x4a6dd0e5, 0xab24d254, 0xd2b2fc65, 0x6553fec5, 0x0b10c8aa,
            0x54d15005, 0xf8d1a555, 0xd6670245, 0x8e38a05a, 0x34da1175, 0x47c51055, 0x6a367c95,
            0xd16adf3a, 0xedb731f5, 0xdf82e99a, 0x3b4abd11, 0x3dd3d821, 0xfc6d714d, 0x2bcabb71,
            0x7f262fd3, 0x02da04c0, 0x8339cc7d, 0x1ea7e35b, 0x83f31765, 0x00af5c49, 0x03a4ea61,
            0x97a994fb, 0x9cc32f5d, 0x4bd1d293, 0xd57a9335,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0x39290406, 0x540d1a05, 0x3ded8341, 0x0cd0f3d5,
            0x103492ba, 0x14f2c475, 0x6a84e825, 0xfe811e54, 0xd03d28f6, 0x2dc60015, 0x99814ff5,
            0x82e235ea, 0xd3237015, 0xe0b650f5, 0xbf9c21d4, 0x4af79205, 0x73b9e785, 0x6681d13a,
            0x17025105, 0x40100445, 0xa8526e55, 0x45b028aa, 0x6fe9b0e5, 0xccbe8bd5, 0xb1cc6325,
            0x8021119a, 0x528674f5, 0x507072ea, 0xdb227c09, 0x6940fa85, 0xe1c2d1cd, 0x9bc06721,
            0x9956112b, 0xf1f660b0, 0x6564a35d, 0xeac5cff3, 0x0fc485bd, 0xc6631df1, 0xcb8e6f51,
            0x09057f93, 0x2f3763ed, 0x645d23af, 0x12d392d9,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0x253381b6, 0x0da84815, 0xa2082081, 0x04cceda5,
            0x6c04d86a, 0x073c8905, 0x5e8f9515, 0x542144d4, 0xc4ed7116, 0xc3fba355, 0x4aab6765,
            0xf212972a, 0x7ff934c5, 0x55884b95, 0xbe1d52b4, 0x765b74e5, 0xa0a368a5, 0xbc17559a,
            0x93406a25, 0x2c82fca5, 0x634ae7b5, 0x4b6705ca, 0x5d4e5d45, 0x63c4c665, 0xf6914b65,
            0x98a8a5da, 0x989f2e85, 0x8f936a8e, 0x984a9941, 0x8d5a7061, 0x454eb555, 0xa7087c89,
            0x59f4632f, 0xd80f2544, 0x1ac52bb1, 0x2165d533, 0x09341cf9, 0x3c5ce119, 0xeed2c9c9,
            0x5af6597f, 0x8f0fbe01, 0x6c87a7ab, 0x20463485,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x3e801244, 0xc972b0c6, 0xacd93605, 0xd255e821, 0xe4cf7ac5,
            0x70c526ea, 0xf7a6cbe5, 0x07f64df5, 0xa8457084, 0xc5b98b16, 0xca981495, 0x4ffa4d35,
            0x64bc635a, 0xae9d65a5, 0xa904b5b5, 0x10d010e4, 0x3b5145e5, 0xdb89fc75, 0xa649c89a,
            0xd7eb6855, 0xff122915, 0x20d808a5, 0x21887daa, 0x76b57ae5, 0x8afec835, 0x5db18495,
            0x4a4678da, 0x0333bd65, 0x8b2f2f1a, 0x4f5c1819, 0xc4141415, 0x43b9ba09, 0x9982f555,
            0xb19236cf, 0x51fc2798, 0x4fd890a1, 0xd514d8bb, 0xa8376c59, 0x2b0df62d, 0xf1a8cce1,
            0xb756782b, 0x286af17d, 0xc98b83bb, 0x254cb475,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0x253381b6, 0x00732805, 0x8ea9e711, 0xb44ff9c5,
            0x0ced957a, 0x93aab7c5, 0x2ec81f85, 0x8013cee4, 0x53c6b6b6, 0x733d1665, 0xbc638685,
            0x786632ba, 0x9c8b0a45, 0xe8693145, 0x1e639564, 0x39b36945, 0xadaee285, 0xfa63a28a,
            0x56efd6c5, 0xf6e5b475, 0x0e3ca105, 0xd09d26da, 0x98af8fc5, 0x3325a0c5, 0x59804405,
            0xc562c04a, 0x419f41c5, 0xa56430de, 0xf665c219, 0xae261771, 0x7805f4a5, 0x525adbc5,
            0xa8a32a73, 0x17cda254, 0x421fcc15, 0x167c0d4f, 0x1ca71525, 0x47e035b5, 0xe38af8d9,
            0x78f6e547, 0x316282f1, 0xe49cada3, 0xb573f085,
        ],
        [
            0x811c9dc5, 0x4b95f515, 0x4bb53254, 0xc972b0c6, 0x0f5a6935, 0xa9500b41, 0xb4336295,
            0x338d0f3a, 0xa24269a5, 0xc3b2bac5, 0xe9bb1e04, 0x5ae67f56, 0x1c2f7995, 0x9f22c125,
            0x6fced48a, 0xe0194575, 0x8aa0a395, 0x9727d7e4, 0xe4c27a25, 0x29f2d3a5, 0xbd76480a,
            0x05dbbe65, 0x05c93595, 0x5791daf5, 0x7f0af00a, 0x87699a15, 0xa3b53d75, 0xa5624a75,
            0x33d59cfa, 0x8705ca05, 0x1d37380e, 0x6086a1dd, 0xcea222ed, 0xc2e2acf5, 0x2c260889,
            0xae26b653, 0x65b2c07c, 0x704a61e1, 0xa46d4b5b, 0x1c86a901, 0xd7109ac5, 0xde03a34d,
            0x581e9a13, 0xf373fdd1, 0x3313f763, 0x8e62f7ed,
        ],
    ];

    const STDSORT_SIZES: [u32; 46] = [
        0, 1, 2, 3, 4, 5, 8, 15, 16, 17, 18, 19, 20, 24, 31, 32, 33, 34, 40, 48, 63, 64, 65, 100,
        127, 128, 129, 200, 255, 256, 257, 300, 500, 511, 512, 513, 777, 1000, 1023, 1024, 1025,
        1500, 1999, 2000, 2047, 2048,
    ];

    fn splitmix(s: &mut u64) -> u64 {
        *s = s.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = *s;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// The keys of one test array; must match `keys_for` in the C++ fixture.
    fn stdsort_case(kind: u32, n: u32) -> Vec<u64> {
        let mut s = kind as u64 * 1_000_003 + n as u64;
        let mut k: Vec<u64> = (0..n)
            .map(|i| {
                let r = splitmix(&mut s);
                match kind {
                    0 => r % (n / 8 + 1) as u64,
                    1 => r % 3,
                    2 | 3 => r % (n + 1) as u64,
                    4 => i.min(n - i) as u64,
                    5 => r >> 24,
                    6 => 0,
                    _ => (if i % 2 == 1 { i / 2 } else { n - i / 2 } / 3) as u64,
                }
            })
            .collect();
        if kind == 2 {
            k.sort();
        }
        if kind == 3 {
            k.sort_by(|a, b| b.cmp(a));
        }
        k
    }

    fn fnv1a(ids: impl Iterator<Item = u32>) -> u32 {
        let mut h: u32 = 2_166_136_261;
        for id in ids {
            for b in id.to_le_bytes() {
                h ^= b as u32;
                h = h.wrapping_mul(16_777_619);
            }
        }
        h
    }

    #[test]
    fn libstdcxx_sort_matches_std_sort() {
        let mut mismatches = Vec::new();
        let mut differs_from_stable = 0;
        HEAP_FALLBACKS.with(|c| c.set(0));
        for (kind, expected) in STDSORT_EXPECTED.iter().enumerate() {
            for (&n, &want) in STDSORT_SIZES.iter().zip(expected) {
                let keys = stdsort_case(kind as u32, n);
                let mut v: Vec<(u64, u32)> = keys.iter().copied().zip(0u32..).collect();
                libstdcxx_sort(&mut v, |a, b| a.0 < b.0);
                assert!(
                    v.windows(2).all(|w| w[0].0 <= w[1].0),
                    "not sorted: kind {kind} n {n}"
                );
                if fnv1a(v.iter().map(|e| e.1)) != want {
                    mismatches.push((kind, n));
                }
                let mut stable: Vec<(u64, u32)> = keys.iter().copied().zip(0u32..).collect();
                stable.sort_by_key(|e| e.0);
                if stable != v {
                    differs_from_stable += 1;
                }
            }
        }
        assert!(
            mismatches.is_empty(),
            "differs from libstdc++ std::sort: {mismatches:?}"
        );
        // The fixture is only worth something if it tells the two apart and
        // reaches the depth-limit fallback.
        assert!(
            differs_from_stable > 100,
            "only {differs_from_stable} cases differ from a stable sort"
        );
        let heap = HEAP_FALLBACKS.with(|c| c.get());
        eprintln!(
            "cases differing from a stable sort: {differs_from_stable}; heap fallbacks: {heap}"
        );
        assert!(heap > 0, "no case reached the heap sort fallback");
    }
}
