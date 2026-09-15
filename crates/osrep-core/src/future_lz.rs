//! Future-LZ / Index-LZ decoding (format v3/v4) -- the Rust port of
//! `decompress.cpp:52-380` and the v3/v4 arms of the block loop in
//! `srep.cpp:1048-1230`.
//!
//! v3 (`-mNf`, Future-LZ) keeps every block's match list inline and hoists each
//! match into the block that owns its **source**; v4 (`-mN`, Index-LZ, the
//! default) writes one concatenated match list after all the blocks and indexes
//! it with the footer's per-block size table. Both are driven by the same
//! routine, `decompress_FUTURE_LZ`, so they port together.
//!
//! The difference from the I/O-LZ decoder is that a match no longer has to
//! point backwards into already-emitted output: it points *forwards*, from bytes
//! the current block is producing to a destination in a later block. The data
//! has to be held until that later block arrives, which is what `MemoryManager`
//! does, spilling the largest-destination matches to `VirtualMemory` when the
//! budget runs out.
//!
//! Spilling is a transparent re-encoding -- only the decoded bytes are
//! observable -- so the memory budget only decides *when* a match is held in
//! RAM versus a scratch buffer, never what comes out. What it does affect is the
//! error path: if a match cannot be stored and nothing can be evicted to make
//! room, the C++ fails the decode instead of looping, and this port keeps that
//! contract (`save_to_disk` returning 0).

use std::collections::{BTreeMap, HashMap};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::container::{
    ArchiveHeader, BlockHeader, ContainerError, FooterHead, ARCHIVE_HEADER_SIZE,
    BLOCK_HEADER_SIZE, INDEX_LZ_FOOTER_SIZE,
};
use crate::decompress::{
    read_exact_or_eof, DecodeError, DecodeStats, Digest, lz_copy,
};
use crate::util::TempFile;

/// `MEMORY_MANAGER::INVALID_INDEX` (`decompress.cpp:137`): chunk 0 is reserved
/// as the "no data" sentinel, so the first allocatable chunk is 1.
const INVALID_INDEX: u32 = 0;
/// `CHUNK_SIZE` (`decompress.cpp:133`).
const CHUNK_SIZE: u64 = 64;
/// `USEFUL_CHUNK_SPACE = CHUNK_SIZE - sizeof(INDEX)` (`decompress.cpp:133`).
const USEFUL_CHUNK_SPACE: u64 = CHUNK_SIZE - 4;
/// `aBLOCK_SIZE` (`decompress.cpp:134`): chunks are carved from 1 MiB blocks.
const A_BLOCK_SIZE: u64 = 1 << 20;

// --------------------------------------------------------- MEMORY_MANAGER --

/// One allocated chunk: its payload followed by the `next` link. The C++ stores
/// the link in the chunk's first four bytes (`decompress.cpp:103-107`) and the
/// payload after it; splitting them into two fields is the same structure with
/// the packing made explicit.
struct Chunk {
    data: Vec<u8>,
    next: u32,
}

/// `MEMORY_MANAGER` (`decompress.cpp:52-143`): a free-listed chunk allocator
/// whose only job is to account for held match bytes so that `available_space`
/// can decide when to spill.
///
/// `mem_limit` is a *budget*, not a hard cap: `available_space()` reports how
/// much of it is left and drives eviction, but allocation itself always
/// succeeds, exactly as `allocate_block()` growing its `block_addr` vector does.
pub(crate) struct MemoryManager {
    useful_memory: u64,
    used_chunks: u64,
    free: Vec<u32>,
    next_index: u32,
    chunks: HashMap<u32, Chunk>,
}

impl MemoryManager {
    /// `MEMORY_MANAGER(size_t)` (`decompress.cpp:138`). The `wrapping_*`
    /// arithmetic mirrors the C++'s unsigned `size_t` when `mem_limit` is
    /// smaller than one block, which the callers never actually do.
    pub(crate) fn new(mem_limit: u64) -> MemoryManager {
        let chunks = mem_limit / A_BLOCK_SIZE * A_BLOCK_SIZE / CHUNK_SIZE;
        MemoryManager {
            useful_memory: chunks.wrapping_sub(1).wrapping_mul(USEFUL_CHUNK_SPACE),
            used_chunks: 0,
            // Chunk 0 is INVALID_INDEX, so allocation starts at 1.
            next_index: 1,
            free: Vec::new(),
            chunks: HashMap::new(),
        }
    }

    /// `available_space()` (`decompress.cpp:141`).
    pub(crate) fn available_space(&self) -> u64 {
        let used = self.used_chunks.wrapping_mul(USEFUL_CHUNK_SPACE);
        if self.useful_memory > used {
            self.useful_memory - used
        } else {
            0
        }
    }

    /// `current_mem()` (`decompress.cpp:139`). Only the tests need it; the
    /// decode path itself is driven entirely by `available_space`.
    #[cfg(test)]
    pub(crate) fn current_mem(&self) -> u64 {
        self.used_chunks * CHUNK_SIZE
    }

    fn allocate(&mut self) -> u32 {
        let index = match self.free.pop() {
            Some(i) => i,
            None => {
                let i = self.next_index;
                self.next_index += 1;
                i
            }
        };
        self.used_chunks += 1;
        index
    }

    /// `save(ptr, len)` (`decompress.cpp:59-72`): split `data` across as many
    /// chunks as it needs and return the head of the chain. An empty slice is
    /// `INVALID_INDEX` -- the C++ loop body never runs and the initial value
    /// survives.
    pub(crate) fn save(&mut self, data: &[u8]) -> u32 {
        if data.is_empty() {
            return INVALID_INDEX;
        }
        let mut indices: Vec<u32> = Vec::new();
        let mut off = 0usize;
        while off < data.len() {
            let n = (data.len() - off).min(USEFUL_CHUNK_SPACE as usize);
            let index = self.allocate();
            self.chunks.insert(
                index,
                Chunk {
                    data: data[off..off + n].to_vec(),
                    next: INVALID_INDEX,
                },
            );
            indices.push(index);
            off += n;
        }
        for pair in indices.windows(2) {
            self.chunks.get_mut(&pair[0]).unwrap().next = pair[1];
        }
        indices[0]
    }

    /// `restore(index, ptr, len)` (`decompress.cpp:73-81`).
    pub(crate) fn restore(&self, mut index: u32, out: &mut [u8]) {
        let mut off = 0usize;
        while off < out.len() && index != INVALID_INDEX {
            let chunk = &self.chunks[&index];
            let n = (out.len() - off).min(chunk.data.len());
            out[off..off + n].copy_from_slice(&chunk.data[..n]);
            off += n;
            index = chunk.next;
        }
    }

    /// `free(index)` (`decompress.cpp:82-88`).
    pub(crate) fn free(&mut self, mut index: u32) {
        while index != INVALID_INDEX {
            let chunk = self
                .chunks
                .remove(&index)
                .expect("free of an unallocated chunk index");
            self.used_chunks -= 1;
            self.free.push(index);
            index = chunk.next;
        }
    }
}

// -------------------------------------------------- VIRTUAL_MEMORY_MANAGER --

/// Where a spilled block goes (`vmfile_name`, `decompress.cpp:219`).
///
/// A block is only ever written and read by this same process within one
/// decode, so the file is scratch -- but it has to be a *file*: keeping the
/// blocks in memory would make the `-mem` budget meaningless, which is exactly
/// what the C++ uses them for.
enum VmPath {
    /// A scratch file this decode allocated under `$TMPDIR`.
    Temp(TempFile),
    /// `-vmfile=`. The C++ removes it when the decode ends regardless of who
    /// asked for it (`decompress.cpp:233`), and so does this.
    Given(PathBuf),
}

impl VmPath {
    fn path(&self) -> &Path {
        match self {
            VmPath::Temp(t) => t.path(),
            VmPath::Given(p) => p,
        }
    }
}

impl Drop for VmPath {
    fn drop(&mut self) {
        if let VmPath::Given(p) = self {
            let _ = std::fs::remove_file(p);
        }
    }
}

/// `VIRTUAL_MEMORY_MANAGER` (`decompress.cpp:217-306`): the spill area, one
/// `VMBLOCK_SIZE` slot per block index.
pub(crate) struct VirtualMemory {
    vm_block: u64,
    free_blocks: Vec<u32>,
    new_block: u32,
    /// `-vmfile=`, if the caller named one.
    vmfile: Option<PathBuf>,
    /// The block file, opened on the first spill -- the C++ allocates the name
    /// eagerly and `fopen`s it here (`decompress.cpp:249`), so a decode that
    /// never spills (which is most of them) touches no disk at all.
    spill: Option<(File, VmPath)>,
    pub(crate) total_read: u64,
    pub(crate) total_write: u64,
}

impl VirtualMemory {
    pub(crate) fn new(vm_block: u64, vmfile: Option<PathBuf>) -> VirtualMemory {
        VirtualMemory {
            vm_block,
            free_blocks: Vec::new(),
            new_block: 0,
            vmfile,
            spill: None,
            total_read: 0,
            total_write: 0,
        }
    }

    /// Open the block file if this is the first spill.
    fn spill_file(&mut self) -> Result<&mut File, DecodeError> {
        if self.spill.is_none() {
            let path = match &self.vmfile {
                Some(p) => VmPath::Given(p.clone()),
                None => VmPath::Temp(
                    TempFile::new("osrep-virtual-memory")
                        .map_err(|_| DecodeError::BadData("cannot allocate the VM scratch file"))?,
                ),
            };
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(true)
                .open(path.path())?;
            self.spill = Some((file, path));
        }
        Ok(&mut self.spill.as_mut().unwrap().0)
    }

    /// The byte offset of a block index (`block*VMBLOCK_SIZE`, `:276`/`:296`).
    fn offset(&self, block: u32) -> u64 {
        u64::from(block) * self.vm_block
    }

    fn alloc_block(&mut self) -> u32 {
        match self.free_blocks.pop() {
            Some(b) => b,
            None => {
                let b = self.new_block;
                self.new_block += 1;
                b
            }
        }
    }

    /// `save_to_disk` (`decompress.cpp:241-277`). Returns the number of matches
    /// evicted; 0 means no progress was possible (every remaining match is
    /// unstored, or too large for one block) and the caller must stop rather
    /// than spin.
    pub(crate) fn save_to_disk(
        &mut self,
        mm: &mut MemoryManager,
        heap: &mut MatchHeap,
    ) -> Result<usize, DecodeError> {
        let mut buf = vec![0u8; self.vm_block as usize];
        let mut p = 0u64;
        let mut evicted = 0usize;
        let mut min_dest = u64::MAX;

        // The C++ walks `rbegin()`, skipping the first element (the barrier at
        // `dest == Offset(-1)`, the largest key) before it starts looking.
        let dests: Vec<u64> = heap.dests_descending().collect();
        for dest in dests {
            if dest == u64::MAX {
                continue; // the barrier sentinel
            }
            let class = heap.class(dest);
            let Some(&m) = class.first() else { continue };
            if m.index == INVALID_INDEX {
                continue; // holds no data: nothing to spill
            }
            // `vmbuf+VMBLOCK_SIZE-p < 24+lz->len`. 24 rather than the 20 bytes
            // actually written is the C++'s own margin; kept so that the pack
            // decision matches.
            if self.vm_block - p < 24 + u64::from(m.len) {
                break;
            }
            let len = m.len as usize;
            buf[p as usize..p as usize + 4].copy_from_slice(&m.len.to_le_bytes());
            buf[p as usize + 4..p as usize + 12].copy_from_slice(&m.src.to_le_bytes());
            buf[p as usize + 12..p as usize + 20].copy_from_slice(&m.dest.to_le_bytes());
            mm.restore(m.index, &mut buf[p as usize + 20..p as usize + 20 + len]);
            p += 20 + m.len as u64;
            min_dest = m.dest;

            mm.free(m.index);
            // C++ `lz_matches.erase(*lz)` is `erase(const key_type&)`, i.e. it
            // drops *every* element equivalent to the key -- every match with
            // this dest. `take_class` reproduces that.
            heap.take_class(dest);
            evicted += 1;
        }

        if evicted == 0 {
            return Ok(0);
        }
        buf[p as usize..p as usize + 4].copy_from_slice(&0u32.to_le_bytes());

        let block = self.alloc_block();
        let offset = self.offset(block);
        let vm_block = self.vm_block;
        let file = self.spill_file()?;
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(&buf)?;
        self.total_write += vm_block;

        heap.insert(Match {
            src: u64::from(block),
            dest: min_dest,
            len: 0, // marking point
            index: INVALID_INDEX,
        });
        Ok(evicted)
    }

    /// `restore_from_disk` (`decompress.cpp:283-305`). Returns `BadData` when
    /// the memory could never be freed, which the C++ reports by returning
    /// false from the whole decode.
    pub(crate) fn restore_from_disk(
        &mut self,
        mm: &mut MemoryManager,
        heap: &mut MatchHeap,
        block: u64,
    ) -> Result<(), DecodeError> {
        while mm.available_space() < self.vm_block {
            if self.save_to_disk(mm, heap)? == 0 {
                return Err(DecodeError::BadData(
                    "cannot free enough VM space to restore a spilled block",
                ));
            }
        }

        let block = block as u32;
        let offset = self.offset(block);
        let mut data = vec![0u8; self.vm_block as usize];
        let file = self.spill_file()?;
        file.seek(SeekFrom::Start(offset))?;
        file.read_exact(&mut data)?;
        self.total_read += self.vm_block;
        self.free_blocks.push(block);

        let mut p = 0usize;
        loop {
            let len = u32::from_le_bytes(data[p..p + 4].try_into().unwrap());
            if len == 0 {
                break; // end-of-block mark
            }
            let src = u64::from_le_bytes(data[p + 4..p + 12].try_into().unwrap());
            let dest = u64::from_le_bytes(data[p + 12..p + 20].try_into().unwrap());
            let index = mm.save(&data[p + 20..p + 20 + len as usize]);
            heap.insert(Match {
                src,
                dest,
                len,
                index,
            });
            p += 20 + len as usize;
        }
        Ok(())
    }
}

// ------------------------------------------------------------ match heap --

/// One Future-LZ match (`decompress.cpp:162-199`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Match {
    src: u64,
    dest: u64,
    len: u32,
    /// Head of the `MemoryManager` chunk chain holding this match's bytes, or
    /// `INVALID_INDEX` when the match is stored elsewhere (or not at all).
    index: u32,
}

impl Match {
    /// `is_marking_point()` (`decompress.cpp:198`).
    fn is_marking_point(&self) -> bool {
        self.len == 0
    }
}

/// `LZ_MATCH_HEAP` (`decompress.cpp:201`): a `std::multiset<FUTURE_LZ_MATCH>`
/// ordered by `dest`.
///
/// The C++ erases matches with `erase(*it)`, which is the *key* overload: it
/// removes every element equivalent to that key. Since the comparator looks
/// only at `dest`, "every equivalent element" means "every match with this
/// dest", so a `dest -> Vec<Match>` map is the exact shape of that multiset's
/// equivalence classes.
pub(crate) struct MatchHeap {
    entries: BTreeMap<u64, Vec<Match>>,
    count: usize,
}

impl MatchHeap {
    /// The C++ seeds the heap with a barrier at `dest = Offset(-1)` so its
    /// `size() == 1` doubles as "drained" (`decompress.cpp:840`/`:978`).
    fn new() -> MatchHeap {
        let mut heap = MatchHeap {
            entries: BTreeMap::new(),
            count: 0,
        };
        heap.insert(Match {
            src: u64::MAX,
            dest: u64::MAX,
            len: u32::MAX,
            index: INVALID_INDEX,
        });
        heap
    }

    fn insert(&mut self, m: Match) {
        self.entries.entry(m.dest).or_default().push(m);
        self.count += 1;
    }

    fn len(&self) -> usize {
        self.count
    }

    fn min_dest(&self) -> Option<u64> {
        self.entries.keys().next().copied()
    }

    fn class(&self, dest: u64) -> &[Match] {
        self.entries.get(&dest).map_or(&[], Vec::as_slice)
    }

    fn dests_descending(&self) -> impl Iterator<Item = u64> + '_ {
        self.entries.keys().rev().copied()
    }

    /// The key-erase: drop the whole equivalence class at `dest`.
    fn take_class(&mut self, dest: u64) -> Vec<Match> {
        let class = self.entries.remove(&dest).unwrap_or_default();
        self.count -= class.len();
        class
    }
}

// -------------------------------------------------------------- decoding --

/// Tuning for [`decode_future_lz`]. The defaults never spill for ordinary
/// inputs; the harness lowers `mem_limit`/`vm_block` to force the spill path.
#[derive(Debug, Clone)]
pub struct FutureLzOptions {
    /// `MEMORY_MANAGER` budget. The C++ derives it from `-mem` minus the I/O
    /// buffers; the value changes only spill timing.
    pub mem_limit: u64,
    /// `VMBLOCK_SIZE` (`-vmblock`).
    pub vm_block: u64,
    /// `maximum_save` (`-m`): matches at least this long are read back from the
    /// sink instead of held in memory. `u32::MAX` is the C++ default.
    pub maximum_save: u32,
    /// `-vmfile=` (`vmfile_name`): where the spill goes. `None` allocates a
    /// scratch file under `$TMPDIR`, which is what the C++ does. Either way the
    /// file is removed when the decode ends.
    pub vmfile: Option<PathBuf>,
}

impl Default for FutureLzOptions {
    fn default() -> Self {
        FutureLzOptions {
            mem_limit: 1 << 30,
            vm_block: 8 << 20,
            maximum_save: u32::MAX,
            vmfile: None,
        }
    }
}

/// One decoded match record. `lit_len` is the literal run preceding it,
/// `offset` the source-to-destination distance.
struct Record {
    lit_len: u64,
    offset: u64,
    len: u32,
}

/// `DECODE_LZ_MATCH` for the Future-LZ case (`srep.cpp:125-139`): four `STAT`s
/// -- literal length, offset low/high, length. `L` (`BASE_LEN`) is 0 for v3/v4.
#[inline]
fn decode_record(stat: &[u32], l: u32) -> Record {
    Record {
        lit_len: u64::from(stat[0]),
        offset: u64::from(stat[1]) | (u64::from(stat[2]) << 32),
        len: stat[3].wrapping_add(l),
    }
}

/// Decode one v3/v4 block, mirroring `decompress_FUTURE_LZ`
/// (`decompress.cpp:315-380`).
///
/// `outbuf` is filled with the block's `origsize` bytes; `sink` supplies the
/// earlier output that a `maximum_save`-length match reads back from.
#[allow(clippy::too_many_arguments)]
fn decompress_block<S: Read + Write + Seek>(
    l: u32,
    sink: &mut S,
    block_start: u64,
    stats: &[u32],
    literals: &[u8],
    outbuf: &mut [u8],
    mm: &mut MemoryManager,
    vm: &mut VirtualMemory,
    heap: &mut MatchHeap,
    maximum_save: u32,
) -> Result<(), DecodeError> {
    let block_end = block_start + outbuf.len() as u64;

    // 1. Insert matches whose destination lands in this block.
    let mut block_pos = block_start;
    for stat in stats.chunks_exact(4) {
        let rec = decode_record(stat, l);
        let src = block_pos + rec.lit_len;
        let dest = src + rec.offset;
        if src < block_pos
            || src >= block_end
            || u64::from(rec.len) > block_end - src
            || dest <= src
        {
            return Err(DecodeError::BadData("future-lz record out of range"));
        }
        if dest < block_end {
            heap.insert(Match {
                src,
                dest,
                len: rec.len,
                index: INVALID_INDEX,
            });
        }
        block_pos = src;
    }

    // 2. Emit literals and matches until the block is filled.
    let mut in_pos = 0usize;
    let mut out_pos = 0usize;
    loop {
        let Some(dest) = heap.min_dest() else { break };
        if dest >= block_end {
            break;
        }
        let class = heap.take_class(dest);
        let m = class[0];

        if m.is_marking_point() {
            // `mark.src` is the VM block number to restore.
            vm.restore_from_disk(mm, heap, m.src)?;
            continue;
        }

        // `int lit_len = (dest - block_start) - (out - outbuf)`.
        let lit_len = (m.dest - block_start) as usize - out_pos;
        if m.dest < block_start + out_pos as u64
            || lit_len > literals.len() - in_pos
            || out_pos + lit_len + m.len as usize > outbuf.len()
        {
            return Err(DecodeError::BadData("future-lz match does not fit the block"));
        }
        outbuf[out_pos..out_pos + lit_len].copy_from_slice(&literals[in_pos..in_pos + lit_len]);
        in_pos += lit_len;
        out_pos += lit_len;

        if m.len >= maximum_save && m.src < block_start {
            sink.seek(SeekFrom::Start(m.src))?;
            sink.read_exact(&mut outbuf[out_pos..out_pos + m.len as usize])?;
        } else if m.index != INVALID_INDEX {
            mm.restore(m.index, &mut outbuf[out_pos..out_pos + m.len as usize]);
        } else {
            // `memcpy_lz_match(ptr, buf + (src - buf_start), len)`.
            let src = (m.src - block_start) as usize;
            lz_copy(outbuf, src, out_pos, m.len as usize);
        }
        out_pos += m.len as usize;
        mm.free(m.index);
    }

    // Whatever literals remain must exactly fill the block.
    if literals.len() - in_pos != outbuf.len() - out_pos {
        return Err(DecodeError::BadData("future-lz literal run does not fill the block"));
    }
    outbuf[out_pos..].copy_from_slice(&literals[in_pos..]);

    // 3. Hoist matches whose destination is in a later block.
    block_pos = block_start;
    for stat in stats.chunks_exact(4) {
        let rec = decode_record(stat, l);
        let src = block_pos + rec.lit_len;
        let dest = src + rec.offset;
        if dest >= block_end {
            let index = if rec.len >= maximum_save {
                INVALID_INDEX // too large to hold: re-read from the sink instead
            } else {
                while u64::from(rec.len) > mm.available_space() {
                    if vm.save_to_disk(mm, heap)? == 0 {
                        return Err(DecodeError::BadData(
                            "cannot free enough memory to store a match",
                        ));
                    }
                }
                let start = (src - block_start) as usize;
                mm.save(&outbuf[start..start + rec.len as usize])
            };
            heap.insert(Match {
                src,
                dest,
                len: rec.len,
                index,
            });
        }
        block_pos = src;
    }

    Ok(())
}

/// Turn a byte slice into little-endian `STAT`s, rejecting a trailing partial
/// word (`srep.cpp`'s statsize is always a multiple of `sizeof(STAT)`).
fn stats_from_bytes(b: &[u8]) -> Result<Vec<u32>, DecodeError> {
    if b.len() % 4 != 0 {
        return Err(DecodeError::BadData(
            "match list is not a whole number of STATs",
        ));
    }
    Ok(b.chunks_exact(4)
        .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
        .collect())
}

/// What a Future/Index-LZ decode did, including how much the spill path ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FutureLzStats {
    pub decode: DecodeStats,
    /// Bytes written to the spill store. Zero means the memory budget was never
    /// exhausted, so the spill path never executed on this input.
    pub vm_bytes_written: u64,
    /// Bytes read back from the spill store.
    pub vm_bytes_read: u64,
}

/// Decode a v3/v4 archive. `sink` receives the decompressed bytes at their
/// final offsets and must allow reading them back, exactly like the C++'s
/// single read/write `FILE*`.
pub fn decode_future_lz<R: Read + Seek, S: Read + Write + Seek>(
    input: &mut R,
    sink: &mut S,
    opts: &FutureLzOptions,
    progress: Option<&mut dyn FnMut(u64, u64)>,
) -> Result<FutureLzStats, DecodeError> {
    // `-bar` counts the archive; only measured when someone is listening.
    let (mut progress, total) = match progress {
        Some(p) => {
            let n = input.seek(SeekFrom::End(0))?;
            input.seek(SeekFrom::Start(0))?;
            (Some(p), n)
        }
        None => (None, 0),
    };

    let mut header_bytes = [0u8; ARCHIVE_HEADER_SIZE];
    if !read_exact_or_eof(input, &mut header_bytes)? {
        return Err(ContainerError::Truncated.into());
    }
    let header = ArchiveHeader::decode(&header_bytes)?;
    if header.version.io_lz() {
        return Err(DecodeError::NotFutureLz(header.version));
    }

    let mut seed = vec![0u8; header.hash_seed_size as usize];
    if !read_exact_or_eof(input, &mut seed)? {
        return Err(ContainerError::Truncated.into());
    }
    let digest = Digest::for_archive(&header, &seed);
    let verified = digest.enabled();

    // `srep.cpp:459`: `if (vm_block > 24 && maximum_save > vm_block-24)
    // maximum_save = vm_block-24`. Both sides apply it, and it is what keeps
    // every *stored* match small enough to fit one VM block, which
    // `restore_from_disk` relies on. The archive does not record the value, so
    // encoder and decoder must agree through the default `-vmblock`.
    let maximum_save = if opts.vm_block > 24 {
        opts.maximum_save.min((opts.vm_block - 24) as u32)
    } else {
        opts.maximum_save
    };

    let block_header_size = BLOCK_HEADER_SIZE + header.hash_size as usize;
    let full_archive_header_size =
        (ARCHIVE_HEADER_SIZE + header.hash_seed_size as usize) as u64;
    let mut consumed = full_archive_header_size;

    // v4 stores the whole match list out of line, before the footer, and sizes
    // each block's share with a per-block table (`srep.cpp:1052-1094`).
    let (stats, table) = if header.version.index_lz() {
        let filesize = input.seek(SeekFrom::End(0))?;
        if filesize < INDEX_LZ_FOOTER_SIZE as u64 {
            return Err(ContainerError::Truncated.into());
        }
        input.seek(SeekFrom::Start(filesize - INDEX_LZ_FOOTER_SIZE as u64))?;
        let mut footer_bytes = [0u8; INDEX_LZ_FOOTER_SIZE];
        input.read_exact(&mut footer_bytes)?;
        let head = FooterHead::decode(&footer_bytes)?;

        let footer_size = u64::from(head.footer_size);
        let stat_size = head.total_stat_size;
        // `if (compsize > filesize) error("Broken ... footer")`.
        if full_archive_header_size + footer_size + stat_size > filesize {
            return Err(ContainerError::FooterExceedsFile.into());
        }
        let table_size = footer_size
            .checked_sub(INDEX_LZ_FOOTER_SIZE as u64)
            .ok_or(ContainerError::FooterExceedsFile)?;

        input.seek(SeekFrom::Start(filesize - footer_size))?;
        let mut table_bytes = vec![0u8; table_size as usize];
        input.read_exact(&mut table_bytes)?;
        let table = crate::container::IndexFooter::decode_table(&table_bytes)?;

        input.seek(SeekFrom::Start(filesize - footer_size - stat_size))?;
        let mut stat_bytes = vec![0u8; stat_size as usize];
        input.read_exact(&mut stat_bytes)?;
        let stats = stats_from_bytes(&stat_bytes)?;

        input.seek(SeekFrom::Start(full_archive_header_size))?;
        (stats, Some(table))
    } else {
        (Vec::new(), None)
    };

    let mut mm = MemoryManager::new(opts.mem_limit);
    let mut vm = VirtualMemory::new(opts.vm_block, opts.vmfile.clone());
    let mut heap = MatchHeap::new();

    let mut block_buf = vec![0u8; block_header_size];
    let mut block_start = 0u64;
    let mut blocks = 0usize;
    let mut stat_cursor = 0usize;
    // v4 knows its block count from the footer table and stops there
    // (`finished = (statsize_ptr == statsize_end)`, `srep.cpp:1171`); v3 runs
    // until the EOF marker (`srep.cpp:1146-1148`).
    let total_blocks = table.as_ref().map(|t| t.len());

    loop {
        if Some(blocks) == total_blocks {
            break;
        }
        let got = read_exact_or_eof(input, &mut block_buf)?;
        if !got {
            // `len==0 && lz_matches.size()==1` ends a v3 stream; otherwise it is
            // an unexpected EOF.
            if total_blocks.is_none() && heap.len() == 1 {
                break;
            }
            return Err(ContainerError::Truncated.into());
        }
        let bh = BlockHeader::decode(&block_buf[..BLOCK_HEADER_SIZE])?;
        // A zero-length block header is the v3 EOF marker, but only once the
        // heap has drained to just its barrier.
        if total_blocks.is_none() && bh.literal_bytes == 0 && bh.origsize == 0 && heap.len() == 1 {
            break;
        }

        let block_end = block_start + u64::from(bh.origsize);

        // This block's match list: from the out-of-line index for v4, from the
        // stream itself for v3.
        let block_stats: Vec<u32> = if let Some(table) = &table {
            let size = *table.get(blocks).ok_or(ContainerError::TableMismatch)? as usize;
            if size % 4 != 0 || stat_cursor + size / 4 > stats.len() {
                return Err(ContainerError::TableMismatch.into());
            }
            let s = stats[stat_cursor..stat_cursor + size / 4].to_vec();
            stat_cursor += size / 4;
            s
        } else {
            let mut stat_bytes = vec![0u8; bh.statsize as usize];
            if !read_exact_or_eof(input, &mut stat_bytes)? {
                return Err(ContainerError::Truncated.into());
            }
            stats_from_bytes(&stat_bytes)?
        };

        let mut literals = vec![0u8; bh.literal_bytes as usize];
        if !read_exact_or_eof(input, &mut literals)? {
            return Err(ContainerError::Truncated.into());
        }

        let mut outbuf = vec![0u8; bh.origsize as usize];
        decompress_block(
            header.base_len,
            sink,
            block_start,
            &block_stats,
            &literals,
            &mut outbuf,
            &mut mm,
            &mut vm,
            &mut heap,
            maximum_save,
        )?;

        if verified {
            let want = digest.compute(&outbuf);
            let got = &block_buf[BLOCK_HEADER_SIZE..BLOCK_HEADER_SIZE + want.len()];
            if got != want.as_slice() {
                return Err(DecodeError::DigestMismatch { block: blocks });
            }
        }

        sink.seek(SeekFrom::Start(block_start))?;
        sink.write_all(&outbuf)?;

        block_start = block_end;
        blocks += 1;

        // v4 keeps the match list out of line, so `bh.statsize` is zero there
        // and only the literals count; the forced tick below closes the gap
        // either way.
        consumed += block_header_size as u64 + u64::from(bh.statsize) + u64::from(bh.literal_bytes);
        if let Some(p) = progress.as_deref_mut() {
            p(consumed, total);
        }
    }

    // A guaranteed final tick, so a consumer always sees `done == total`.
    if let Some(p) = progress.as_deref_mut() {
        p(total, total);
    }

    Ok(FutureLzStats {
        decode: DecodeStats {
            blocks,
            origsize: block_start,
            verified,
        },
        vm_bytes_written: vm.total_write,
        vm_bytes_read: vm.total_read,
    })
}

/// Convenience wrapper for a whole in-memory archive.
pub fn decode_future_lz_to_vec(
    bytes: &[u8],
    opts: &FutureLzOptions,
) -> Result<Vec<u8>, DecodeError> {
    let mut input = io::Cursor::new(bytes);
    let mut sink = io::Cursor::new(Vec::new());
    decode_future_lz(&mut input, &mut sink, opts, None)?;
    Ok(sink.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_manager_round_trips_across_chunks() {
        let mut mm = MemoryManager::new(1 << 30);
        // 200 bytes spans ceil(200/60) = 4 chunks.
        let data: Vec<u8> = (0..200).map(|i| (i * 7) as u8).collect();
        let index = mm.save(&data);
        assert_ne!(index, INVALID_INDEX);
        assert_eq!(mm.current_mem(), 4 * 64);
        let mut out = vec![0u8; 200];
        mm.restore(index, &mut out);
        assert_eq!(out, data);
        mm.free(index);
        assert_eq!(mm.current_mem(), 0);
    }

    #[test]
    fn memory_manager_reuses_freed_chunks() {
        let mut mm = MemoryManager::new(1 << 30);
        let a = mm.save(&[1u8; 10]);
        let b = mm.save(&[2u8; 10]);
        assert_ne!(a, b);
        mm.free(a);
        // The LIFO free list hands `a` back out.
        let c = mm.save(&[3u8; 10]);
        assert_eq!(c, a);
    }

    #[test]
    fn memory_manager_empty_save_is_invalid() {
        let mut mm = MemoryManager::new(1 << 30);
        assert_eq!(mm.save(&[]), INVALID_INDEX);
        assert_eq!(mm.current_mem(), 0);
    }

    #[test]
    fn heap_orders_by_dest_and_erases_the_whole_class() {
        let mut heap = MatchHeap::new();
        assert_eq!(heap.len(), 1); // the barrier
        heap.insert(Match {
            src: 0,
            dest: 5,
            len: 3,
            index: 7,
        });
        heap.insert(Match {
            src: 1,
            dest: 9,
            len: 4,
            index: 8,
        });
        // A second match sharing a dest lands in the same class.
        heap.insert(Match {
            src: 2,
            dest: 5,
            len: 1,
            index: 9,
        });
        assert_eq!(heap.len(), 4);
        assert_eq!(heap.min_dest(), Some(5));
        // Erasing by key drops both dest==5 matches, exactly like
        // std::multiset::erase(const key_type&).
        let class = heap.take_class(5);
        assert_eq!(class.len(), 2);
        assert_eq!(heap.len(), 2);
        assert_eq!(heap.min_dest(), Some(9));
    }

    /// The blocks have to leave RAM, or the `-mem` budget the manager enforces
    /// is a fiction: the evicted bytes would sit in the heap regardless.
    #[test]
    fn the_spill_lands_in_the_named_file_and_is_removed_with_it() {
        let path = std::env::temp_dir().join(format!("osrep-vm-test-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);

        let mut mm = MemoryManager::new(1 << 30);
        let mut heap = MatchHeap::new();
        let data: Vec<u8> = (0..100).map(|i| i as u8).collect();
        heap.insert(Match {
            src: 10,
            dest: 1000,
            len: 100,
            index: mm.save(&data),
        });

        {
            let mut vm = VirtualMemory::new(4096, Some(path.clone()));
            assert!(!path.exists(), "nothing may be created before the first spill");
            let evicted = vm.save_to_disk(&mut mm, &mut heap).unwrap();
            assert!(evicted >= 1, "the match must be evicted");
            assert!(path.exists(), "the spill must land in the named file");
            // One whole `-vmblock` slot, at block index 0.
            assert_eq!(std::fs::metadata(&path).unwrap().len(), 4096);

            // And it comes back byte-for-byte.
            let mark_dest = heap
                .dests_descending()
                .find(|d| *d != u64::MAX)
                .expect("a marking point");
            let mark = heap.class(mark_dest)[0];
            vm.restore_from_disk(&mut mm, &mut heap, mark.src).unwrap();
        }
        // `-vmfile=` names a scratch file; the C++ removes it when the decode
        // ends and so does this.
        assert!(!path.exists(), "the spill file must be removed");

        let mut out = vec![0u8; 100];
        for (_, class) in heap.entries.iter() {
            for m in class {
                if m.index != INVALID_INDEX && m.len == 100 {
                    mm.restore(m.index, &mut out);
                    assert_eq!(out, data);
                }
            }
        }
    }

    #[test]
    fn spill_moves_matches_out_and_back() {
        let mut mm = MemoryManager::new(1 << 30);
        let mut heap = MatchHeap::new();
        // Two matches whose data is held in the memory manager.
        let d0: Vec<u8> = (0..100).map(|i| i as u8).collect();
        let d1: Vec<u8> = (0..80).map(|i| (i ^ 0xAA) as u8).collect();
        heap.insert(Match {
            src: 10,
            dest: 1000,
            len: 100,
            index: mm.save(&d0),
        });
        heap.insert(Match {
            src: 20,
            dest: 2000,
            len: 80,
            index: mm.save(&d1),
        });
        let mut vm = VirtualMemory::new(1 << 16, None);

        let evicted = vm.save_to_disk(&mut mm, &mut heap).unwrap();
        assert!(evicted >= 1, "the largest-dest match must be evicted");
        // The evicted data is gone from the manager and a marking point exists.
        assert!(heap.len() >= 2); // barrier + marking point (maybe + leftover)

        // Restoring the marking point brings the data back byte-for-byte.
        let mark_dest = heap
            .dests_descending()
            .find(|d| *d != u64::MAX)
            .expect("a marking point");
        // The marking point is the smallest dest among evicted matches, so it
        // sorts before the surviving match.
        let mark = heap.class(mark_dest)[0];
        assert!(mark.is_marking_point());
        vm.restore_from_disk(&mut mm, &mut heap, mark.src).unwrap();

        // Every match with data now restores to its original bytes. The
        // marking point shares dest with the match it was created from, so scan
        // whole classes rather than their first element.
        let mut found = 0;
        for (dest, class) in heap.entries.iter() {
            for m in class {
                if m.index == INVALID_INDEX {
                    continue;
                }
                let mut out = vec![0u8; m.len as usize];
                mm.restore(m.index, &mut out);
                if *dest == 1000 {
                    assert_eq!(out, d0);
                    found += 1;
                } else if *dest == 2000 {
                    assert_eq!(out, d1);
                    found += 1;
                }
            }
        }
        assert_eq!(found, 2, "both matches must round-trip through the spill");
    }

    #[test]
    fn stats_from_bytes_rejects_a_partial_word() {
        assert!(stats_from_bytes(&[0, 0, 0, 0, 1]).is_err());
        assert_eq!(stats_from_bytes(&[1, 0, 0, 0]).unwrap(), vec![1]);
    }
}

/// Turn a v5 block's LEB128 triples back into the four-word `STAT` records
/// `decompress_block` consumes. v5 stores raw lengths, so the words carry base
/// 0 and no rounding -- the same shape the v4 `f` path writes
/// (`srep.cpp:458`), which is why one decoder body serves both.
fn v5_words(list: &[u8]) -> Result<Vec<u32>, DecodeError> {
    let mut words: Vec<u32> = Vec::new();
    let mut pos = 0usize;
    while pos < list.len() {
        let lit = crate::v5::get_varint(list, &mut pos)
            .map_err(|_| DecodeError::BadData("v5 record"))?;
        let len = crate::v5::get_varint(list, &mut pos)
            .map_err(|_| DecodeError::BadData("v5 record"))?;
        let distance = crate::v5::get_varint(list, &mut pos)
            .map_err(|_| DecodeError::BadData("v5 record"))?;
        if lit > u64::from(u32::MAX) || len > u64::from(u32::MAX) {
            return Err(DecodeError::BadData("v5 record too large"));
        }
        words.push(lit as u32);
        words.push(distance as u32);
        words.push((distance >> 32) as u32);
        words.push(len as u32);
    }
    Ok(words)
}

/// Decode a v5 archive (`docs/format-spec-v5.md`).
///
/// It shares everything below the container with v3/v4: a v5 block's records
/// are anchored at their **source**, so a match's destination can lie ahead of
/// the block carrying it, and the `MemoryManager`/`VirtualMemory` pair is what
/// resolves those. The differences are only framing -- the v5 header and
/// footer, self-contained blocks, and the record codec.
pub fn decode_v5<R: Read + Seek, S: Read + Write + Seek>(
    input: &mut R,
    sink: &mut S,
    opts: &FutureLzOptions,
    progress: Option<&mut dyn FnMut(u64, u64)>,
) -> Result<FutureLzStats, DecodeError> {
    // The footer is always the last thing in the file, and when the archive
    // carries a `-dup` meta blob it is the only thing that says how big that
    // blob is: the blocks end where the blob begins. Read it up front.
    let file_len = input.seek(SeekFrom::End(0))?;
    if file_len < (crate::v5::HEADER_SIZE + crate::v5::FOOTER_SIZE) as u64 {
        return Err(ContainerError::Truncated.into());
    }
    input.seek(SeekFrom::Start(file_len - crate::v5::FOOTER_SIZE as u64))?;
    let mut footer_bytes = [0u8; crate::v5::FOOTER_SIZE];
    if !read_exact_or_eof(input, &mut footer_bytes)? {
        return Err(ContainerError::Truncated.into());
    }
    let footer =
        crate::v5::Footer::decode(&footer_bytes).map_err(|_| DecodeError::BadData("v5 footer"))?;
    input.seek(SeekFrom::Start(0))?;

    let mut header_bytes = [0u8; crate::v5::HEADER_SIZE];
    if !read_exact_or_eof(input, &mut header_bytes)? {
        return Err(ContainerError::Truncated.into());
    }
    let header =
        crate::v5::Header::decode(&header_bytes).map_err(|_| DecodeError::BadData("v5 header"))?;
    if footer.block_count != header.block_count {
        return Err(DecodeError::BadData("v5 footer disagrees with the blocks"));
    }
    // `flags.bit0` and a non-zero `meta_size` state the same fact twice; an
    // archive where only one of them holds is corrupt.
    if (header.flags & crate::v5::FLAG_HAS_DUP != 0) != (footer.meta_size != 0) {
        return Err(DecodeError::BadData("v5 -dup meta disagrees with the flags"));
    }
    let mut progress = progress;
    let hash = header
        .hash()
        .map_err(|_| DecodeError::BadData("v5 hash descriptor"))?;

    let mut seed = vec![0u8; hash.seed_size as usize];
    if !read_exact_or_eof(input, &mut seed)? {
        return Err(ContainerError::Truncated.into());
    }
    let digest = Digest::for_hash(hash, &seed);
    let verified = digest.enabled();
    let hash_size = header.hash_size as usize;

    // Same clamp the encoder applies, and the same reason: every stored match
    // must fit one VM block. v5 records it, but the spill's own bound still
    // comes from `-vmblock`.
    let maximum_save = if opts.vm_block > 24 {
        opts.maximum_save.min((opts.vm_block - 24) as u32)
    } else {
        opts.maximum_save
    };

    let mut mm = MemoryManager::new(opts.mem_limit);
    let mut vm = VirtualMemory::new(opts.vm_block, opts.vmfile.clone());
    let mut heap = MatchHeap::new();

    let mut block_start = 0u64;
    let mut total_stat: u64 = 0;
    // Counted rather than read from the reader: the caller may hand us a
    // buffered stream, whose position runs ahead of what has been consumed.
    let mut consumed: u64 = (crate::v5::HEADER_SIZE + seed.len()) as u64;

    for blocks in 0..header.block_count as usize {
        let mut bh_bytes = [0u8; BLOCK_HEADER_SIZE];
        if !read_exact_or_eof(input, &mut bh_bytes)? {
            return Err(ContainerError::Truncated.into());
        }
        let bh = BlockHeader::decode(&bh_bytes)?;

        let mut stored_digest = vec![0u8; hash_size];
        if !read_exact_or_eof(input, &mut stored_digest)? {
            return Err(ContainerError::Truncated.into());
        }

        let mut stat_bytes = vec![0u8; bh.statsize as usize];
        if !read_exact_or_eof(input, &mut stat_bytes)? {
            return Err(ContainerError::Truncated.into());
        }
        let block_stats = v5_words(&stat_bytes)?;

        let mut literals = vec![0u8; bh.literal_bytes as usize];
        if !read_exact_or_eof(input, &mut literals)? {
            return Err(ContainerError::Truncated.into());
        }

        let mut outbuf = vec![0u8; bh.origsize as usize];
        decompress_block(
            0,
            sink,
            block_start,
            &block_stats,
            &literals,
            &mut outbuf,
            &mut mm,
            &mut vm,
            &mut heap,
            maximum_save,
        )?;

        if verified {
            let want = digest.compute(&outbuf);
            if stored_digest != want {
                return Err(DecodeError::DigestMismatch { block: blocks });
            }
        }

        sink.seek(SeekFrom::Start(block_start))?;
        sink.write_all(&outbuf)?;

        block_start += u64::from(bh.origsize);
        total_stat += u64::from(bh.statsize);
        consumed += BLOCK_HEADER_SIZE as u64
            + hash_size as u64
            + u64::from(bh.statsize)
            + u64::from(bh.literal_bytes);
        if let Some(p) = progress.as_deref_mut() {
            p(consumed, file_len);
        }
    }

    // A guaranteed final tick, so a consumer always sees `done == total`.
    if let Some(p) = progress.as_deref_mut() {
        p(file_len, file_len);
    }

    // The blocks stop exactly where the meta blob starts -- or where the footer
    // does, when the archive has no blob. Nothing else can be between them, and
    // nothing was read past the last block, so the reader never has to guess
    // where the block list ends (which is the whole reason the footer is read
    // first).
    let meta_at = (file_len - crate::v5::FOOTER_SIZE as u64)
        .checked_sub(u64::from(footer.meta_size))
        .ok_or(DecodeError::BadData("v5 -dup meta runs past the file"))?;
    if consumed != meta_at {
        return Err(DecodeError::BadData("v5 blocks do not end at the footer"));
    }
    if footer.stat_size != total_stat {
        return Err(DecodeError::BadData("v5 footer disagrees with the blocks"));
    }
    // A `-dup` archive keeps its `.dupref` payload between the blocks and the
    // footer. This decoder deliberately does not read it: the dedup post-pass
    // is the one that wants it, and it takes the payload out of the archive by
    // the footer's offsets.

    Ok(FutureLzStats {
        decode: DecodeStats {
            blocks: header.block_count as usize,
            origsize: block_start,
            verified,
        },
        vm_bytes_written: vm.total_write,
        vm_bytes_read: vm.total_read,
    })
}

/// Convenience wrapper for a whole in-memory v5 archive.
pub fn decode_v5_to_vec(bytes: &[u8], opts: &FutureLzOptions) -> Result<Vec<u8>, DecodeError> {
    let mut input = io::Cursor::new(bytes);
    let mut sink = io::Cursor::new(Vec::new());
    decode_v5(&mut input, &mut sink, opts, None)?;
    Ok(sink.into_inner())
}
