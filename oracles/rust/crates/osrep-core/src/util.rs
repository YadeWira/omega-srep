//! Small helpers ported from `oracles/cxx/Compression/Common.h`, plus the
//! scratch-file guard the `-dup` wrapper and the CLI's stdin/stdout spooling
//! both need, and the files of one run: what it reads, what it writes, and the
//! outputs a failed run removes.

use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

/// A scratch file, removed when it goes out of scope.
///
/// The C++ unlinks its temporaries on every path it remembers to, and leaks
/// them on the rest (its signal handler never calls `removeTemporaryFiles`).
/// A `Drop` cannot forget, which is the point.
///
/// It is one of the files the run writes (see `Files`) for as long as it
/// exists: created exclusively it is never a file that was there before, but
/// a name on the command line can still lead to it while it is open
/// (`/proc/self/fd/N`), and an output opened that way is refused.
pub struct TempFile {
    path: PathBuf,
    id: Option<FileId>,
}

impl TempFile {
    /// `osrep_make_unique_tempfile_path(prefix)` (`Common.cpp`): a unique path
    /// under `$TMPDIR`/`%TEMP%`, created up front so two concurrent runs can
    /// never land on the same one and a leftover file is an error rather than
    /// something silently appended to.
    pub fn new(prefix: &str) -> io::Result<TempFile> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let name = format!(
            "{prefix}-{}-{nanos}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let path = std::env::temp_dir().join(name);
        let file = OpenOptions::new().write(true).create_new(true).open(&path)?;
        let id = files().note_scratch(&file);
        Ok(TempFile { path, id })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        if let Some(id) = self.id {
            files().forget(id);
        }
    }
}

// ------------------------------------------------- the files of one run --

/// Device and inode on Unix; volume serial number and file index on Windows.
#[derive(Debug, Clone, Copy)]
struct FileId(u64, u64);

impl PartialEq for FileId {
    #[cfg(unix)]
    fn eq(&self, o: &FileId) -> bool {
        self.0 == o.0 && self.1 == o.1
    }
    /// The file index decides; a volume serial of 0 is unknown and matches any
    /// (wine reports 0 for the standard handles and for a file reached through
    /// Z:, and the drive's serial for the same file reached through C:).
    #[cfg(windows)]
    fn eq(&self, o: &FileId) -> bool {
        self.1 == o.1 && (self.0 == o.0 || self.0 == 0 || o.0 == 0)
    }
}

/// The files one run of the CLI reads and writes, by identity, and the one
/// rule they follow: **no file the run writes is a file it reads, or another
/// file it writes.**
///
/// Names cannot answer that. `x`, `./x`, a hard link or a symlink to it,
/// `/dev/stdin`, `/proc/self/fd/3`, `X` on Windows, and the file a shell
/// redirection opened (`< x`, `>> x`, `1<> x`) can all be one file, and
/// through 2.3.0 each of them could make an output of the input: `osrep x.bin
/// ./x.bin` truncated the input and exited 0 with an archive of nothing. So:
///
/// * what the run reads is noted before anything is opened: the named input
///   or stdin's file, and `-index=` when decompressing (`note_read`);
/// * stdout's file, when the output is `-`, is compared like any output and
///   noted as written, but never truncated (`note_stdout`); so is stderr's
///   file when the run writes there on success (the progress and summary
///   lines, `-bar`, the warnings: `note_stderr`), since those lines land in it;
/// * the names the run will write that already exist are compared before the
///   first open (`check_names`), so two names of one existing file are
///   refused before either has been truncated;
/// * every file is then opened for writing **without truncation**, its
///   identity taken from the open handle, and refused if the run reads it or
///   already writes it; a refused file that this open created is removed,
///   one that existed is left as it was. Only then is it truncated and noted
///   as written (`Files::open`): the archive, the decoded file, `-index=`
///   when compressing, the `-dup` post-pass's output (`create_output`), the
///   `-temp=` spool and the `-vmfile=` spill (`NamedScratch`), and the
///   scratch files (`TempFile`).
///
/// A refusal is "Input and output files should have different names", exit 3,
/// whatever the caller made of the failed open (`refused`). Only regular files
/// count: a terminal, a pipe, a FIFO or a device (`/dev/null`, `NUL`) is no
/// file to lose, and `/dev/null` as input and output still runs.
///
/// Nothing is kept until the CLI calls `begin_run`: a library caller opens its
/// outputs as before, and the unit tests that share this process never see
/// each other's files.
struct Files {
    armed: bool,
    reads: Vec<FileId>,
    /// Every file open for writing, and the scratch files while they exist.
    writes: Vec<FileId>,
    /// The outputs to remove if the run fails (`remove_claimed_outputs`).
    claimed: Vec<OpenedName>,
    refused: bool,
}

impl Files {
    const fn new() -> Files {
        Files {
            armed: false,
            reads: Vec::new(),
            writes: Vec::new(),
            claimed: Vec::new(),
            refused: false,
        }
    }

    fn taken(&self, id: FileId) -> bool {
        self.reads.contains(&id) || self.writes.contains(&id)
    }

    fn note_read(&mut self, id: Option<FileId>) {
        if let Some(id) = id.filter(|_| self.armed) {
            self.reads.push(id);
        }
    }

    /// A scratch file this run has just created.
    fn note_scratch(&mut self, file: &File) -> Option<FileId> {
        let id = file_id::of_handle(file).filter(|_| self.armed)?;
        self.writes.push(id);
        Some(id)
    }

    /// A file that is no longer one this run writes: once it is removed its
    /// number can come back as another file.
    fn forget(&mut self, id: FileId) {
        if let Some(i) = self.writes.iter().position(|w| *w == id) {
            self.writes.swap_remove(i);
        }
    }

    /// Open `path` for writing (and reading, with `read`) under the rule:
    /// without truncation, refused if it is a file the run reads or writes,
    /// and only then truncated. Its identity, if it is a regular file.
    fn open(&mut self, path: &Path, read: bool) -> io::Result<(File, Option<FileId>)> {
        let (file, existed) = file_id::open_no_truncate(path, read)?;
        let id = file_id::of_handle(&file);
        if let Some(id) = id.filter(|id| self.armed && self.taken(*id)) {
            self.refused = true;
            drop(file);
            if !existed && file_id::of_name(path) == Some(id) {
                let _ = std::fs::remove_file(path);
            }
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "a file this run reads or writes",
            ));
        }
        if existed {
            file_id::truncate(&file, id.is_some())?;
        }
        if let Some(id) = id.filter(|_| self.armed) {
            self.writes.push(id);
        }
        Ok((file, id))
    }

    /// See `check_names`.
    fn check_names(&mut self, ids: &[FileId]) -> bool {
        for (i, id) in ids.iter().enumerate() {
            if self.taken(*id) || ids[..i].contains(id) {
                self.refused = true;
                return false;
            }
        }
        true
    }
}

static FILES: Mutex<Files> = Mutex::new(Files::new());

fn files() -> MutexGuard<'static, Files> {
    FILES.lock().unwrap_or_else(|e| e.into_inner())
}

/// Start keeping this run's files (see `Files`). The CLI calls it once, before
/// it opens anything.
pub fn begin_run() {
    files().armed = true;
}

/// A file the run reads, by name: the input, `-index=` when decompressing.
pub fn note_read(path: &Path) {
    let id = file_id::of_path_regular(path);
    files().note_read(id);
}

/// The file stdin is read from (`< x`), when the input is `-`.
pub fn note_read_stdin() {
    let id = file_id::of_std(Std::In);
    files().note_read(id);
}

/// The file stderr goes to (`2> x`, `2>&1`), when the run writes there on
/// success (`writes_stderr` in the CLI): the run's messages land in it, so it
/// is written, never truncated, like stdout's. `false` if the run reads it or
/// already writes it: refused (and the refusal's message still lands there).
pub fn note_stderr() -> bool {
    note_std_written(Std::Err)
}

/// The file stdout goes to (`> x`, `>> x`, `1<> x`), when the output is `-`:
/// written, never truncated. `false` if the run reads it: refused.
pub fn note_stdout() -> bool {
    note_std_written(Std::Out)
}

fn note_std_written(which: Std) -> bool {
    let id = file_id::of_std(which);
    let mut f = files();
    match id.filter(|_| f.armed) {
        Some(id) if f.taken(id) => {
            f.refused = true;
            false
        }
        Some(id) => {
            f.writes.push(id);
            true
        }
        None => true,
    }
}

/// The names the run will write (the output, `-index=` when compressing,
/// `-temp=`, `-vmfile=`), before any of them is opened: those that exist must
/// not be a file the run reads, stdout's file, or one another. `false`:
/// refused. Each is compared again as it is opened; this is what keeps a
/// refused run from having truncated the first of two names of one file by
/// the time it opens the second.
pub fn check_names(names: &[&Path]) -> bool {
    let ids: Vec<FileId> = names
        .iter()
        .filter_map(|p| file_id::of_path_regular(p))
        .collect();
    files().check_names(&ids)
}

/// Whether an open was refused under the rule (see `Files`). The caller
/// reports the refusal whatever error it made of the failed open: "Input and
/// output files should have different names", exit 3.
pub fn refused() -> bool {
    files().refused
}

/// An output of the run -- the archive, the decoded file, `-index=` when
/// compressing, the `-dup` post-pass's output -- opened under the rule (see
/// `Files`), and removed if the run fails (`remove_claimed_outputs`).
pub fn create_output(path: &Path, read: bool) -> io::Result<File> {
    let mut f = files();
    let (file, id) = f.open(path, read)?;
    if let Some(id) = id.filter(|_| f.armed) {
        f.claimed.push(OpenedName {
            path: path.to_path_buf(),
            id,
        });
    }
    Ok(file)
}

/// A regular file this run opened for writing under a name it was given,
/// remembered by identity, so that it can be removed later without removing
/// something else that took the name in the meantime.
#[derive(Debug)]
struct OpenedName {
    path: PathBuf,
    id: FileId,
}

impl OpenedName {
    /// Remove the name if it still refers to the file that was opened, and
    /// not through a symlink (the file a symlink leads to keeps what was
    /// written). Call it with the file's handles closed: Windows cannot
    /// delete a file that is still open without `FILE_SHARE_DELETE`.
    fn remove(&self) {
        if file_id::of_name(&self.path) == Some(self.id) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// A scratch file under a name the user gave (`-temp=`, `-vmfile=`), opened
/// under the rule (see `Files`) and removed when it goes out of scope, as the
/// C++ does (`srep.cpp:1336`, `decompress.cpp:233`) -- but only a regular
/// file, and only while the name still refers to it, not through a symlink.
/// A name whose open failed is not this run's to remove, and `-vmfile=/dev/null`
/// is not a scratch file at all.
#[derive(Debug)]
pub struct NamedScratch(Option<OpenedName>);

impl NamedScratch {
    /// `path` opened for writing (and reading, with `read`), truncated.
    pub fn create(path: &Path, read: bool) -> io::Result<(File, NamedScratch)> {
        let (file, id) = files().open(path, read)?;
        let name = id.map(|id| OpenedName {
            path: path.to_path_buf(),
            id,
        });
        Ok((file, NamedScratch(name)))
    }
}

impl NamedScratch {
    /// Whether what was opened is a regular file (one this run can read back).
    pub fn is_regular(&self) -> bool {
        self.0.is_some()
    }
}

impl Drop for NamedScratch {
    fn drop(&mut self) {
        if let Some(n) = &self.0 {
            n.remove();
            files().forget(n.id);
        }
    }
}

/// One of the two standard handles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Std {
    In,
    Out,
    Err,
}

// ------------------------------------------------- outputs of a failed run --

/// The run failed: remove the outputs it created or truncated, so no partial
/// file is left behind. Call it with their handles closed.
///
/// The C++ means to do this ("Delete output files on error", `srep.cpp:1339`)
/// but only its `goto cleanup` paths reach that code; every `error()` exits on
/// the spot, so through 2.3.0 a failed run left its output behind (an archive
/// cut short by `OutOfMemory`, the blocks decoded before a `DigestMismatch`).
/// Only regular files were claimed, and a name is removed only while it still
/// refers to the file that was opened, not through a symlink. A file the run
/// reads is never among them: it is refused before it is opened for writing.
pub fn remove_claimed_outputs() {
    let claims = std::mem::take(&mut files().claimed);
    for n in claims {
        n.remove();
    }
}

#[cfg(unix)]
mod file_id {
    use super::FileId;
    use std::fs::{File, Metadata, OpenOptions};
    use std::io;
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    fn id(m: &Metadata) -> FileId {
        FileId(m.dev(), m.ino())
    }

    /// `fstat`: a regular file only.
    pub(super) fn of_handle(f: &File) -> Option<FileId> {
        f.metadata()
            .ok()
            .filter(|m| m.file_type().is_file())
            .map(|m| id(&m))
    }

    /// `lstat`: the name itself is a regular file (a symlink is not).
    pub(super) fn of_name(p: &Path) -> Option<FileId> {
        std::fs::symlink_metadata(p)
            .ok()
            .filter(|m| m.file_type().is_file())
            .map(|m| id(&m))
    }

    /// `stat`: the name leads to a regular file.
    pub(super) fn of_path_regular(p: &Path) -> Option<FileId> {
        std::fs::metadata(p)
            .ok()
            .filter(|m| m.file_type().is_file())
            .map(|m| id(&m))
    }

    /// `fstat` on fd 0 or 1, through a duplicate (a closed fd fails the
    /// `dup`, and is no file): a regular file only.
    pub(super) fn of_std(which: super::Std) -> Option<FileId> {
        use std::os::fd::AsFd;
        let fd = match which {
            super::Std::In => std::io::stdin().as_fd().try_clone_to_owned(),
            super::Std::Out => std::io::stdout().as_fd().try_clone_to_owned(),
            super::Std::Err => std::io::stderr().as_fd().try_clone_to_owned(),
        }
        .ok()?;
        of_handle(&File::from(fd))
    }

    /// `open(O_CREAT)` without `O_TRUNC`, and whether the file was there
    /// before: an exclusive create first (`O_EXCL`), and if the name exists,
    /// a plain open. A dangling symlink fails both, and the third open creates
    /// what it names, as `File::create` does; any other failure of the
    /// exclusive create gets the error `File::create` gave.
    pub(super) fn open_no_truncate(path: &Path, read: bool) -> io::Result<(File, bool)> {
        let mut o = OpenOptions::new();
        o.read(read).write(true);
        match o.clone().create_new(true).open(path) {
            Ok(f) => return Ok((f, false)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => match o.open(path) {
                Ok(f) => return Ok((f, true)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    return o.create(true).open(path).map(|f| (f, false));
                }
                Err(e) => return Err(e),
            },
            Err(_) => {}
        }
        o.create(true).open(path).map(|f| (f, true))
    }

    /// `O_TRUNC` after the fact: on a regular file, and on nothing else (a
    /// FIFO, a terminal or `/dev/null` ignore `O_TRUNC`, and `ftruncate`
    /// fails on them).
    pub(super) fn truncate(f: &File, regular: bool) -> io::Result<()> {
        if regular {
            f.set_len(0)
        } else {
            Ok(())
        }
    }
}

#[cfg(windows)]
mod file_id {
    use super::FileId;
    use std::ffi::c_void;
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use std::path::Path;

    const FILE_TYPE_DISK: u32 = 1;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const FILE_SHARE_DELETE: u32 = 4;
    const OPEN_ALWAYS: u32 = 4;
    const ERROR_ALREADY_EXISTS: u32 = 183;

    /// `BY_HANDLE_FILE_INFORMATION`; the three `FILETIME`s as two words each.
    #[repr(C)]
    #[derive(Default)]
    struct Info {
        attributes: u32,
        times: [u32; 6],
        volume_serial: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileType(h: *mut c_void) -> u32;
        fn GetFileInformationByHandle(h: *mut c_void, info: *mut Info) -> i32;
        fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            security: *mut c_void,
            disposition: u32,
            flags: u32,
            template: *mut c_void,
        ) -> *mut c_void;
        fn GetLastError() -> u32;
    }

    /// The attributes and the identity of an open handle.
    fn info(f: &File) -> Option<(u32, FileId)> {
        let mut i = Info::default();
        // SAFETY: a live handle owned by `f`, and an `Info` laid out as the
        // Windows structure it is written into.
        if unsafe { GetFileInformationByHandle(f.as_raw_handle(), &mut i) } == 0 {
            return None;
        }
        let index = (u64::from(i.index_high) << 32) | u64::from(i.index_low);
        Some((i.attributes, FileId(u64::from(i.volume_serial), index)))
    }

    /// A disk file that is not a directory: `NUL`, `CON` and pipes are not
    /// `FILE_TYPE_DISK`.
    pub(super) fn of_handle(f: &File) -> Option<FileId> {
        // SAFETY: a live handle owned by `f`.
        if unsafe { GetFileType(f.as_raw_handle()) } != FILE_TYPE_DISK {
            return None;
        }
        info(f)
            .filter(|(a, _)| a & FILE_ATTRIBUTE_DIRECTORY == 0)
            .map(|(_, id)| id)
    }

    /// The name itself, not what a reparse point (a symlink, a junction)
    /// leads to; the handle is closed before this returns.
    pub(super) fn of_name(p: &Path) -> Option<FileId> {
        let f = OpenOptions::new()
            .access_mode(0)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(p)
            .ok()?;
        info(&f)
            .filter(|(a, _)| a & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0)
            .map(|(_, id)| id)
    }

    /// The name leads to a regular file (a disk file, not a directory).
    pub(super) fn of_path_regular(p: &Path) -> Option<FileId> {
        let f = OpenOptions::new()
            .access_mode(0)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(p)
            .ok()?;
        of_handle(&f)
    }

    /// `GetStdHandle(STD_INPUT_HANDLE / STD_OUTPUT_HANDLE)`, then `of_handle`
    /// (`GetFileType == FILE_TYPE_DISK`, `GetFileInformationByHandle`). The
    /// handle is only borrowed: `ManuallyDrop` never closes it. No handle at
    /// all (std maps `INVALID_HANDLE_VALUE` to null) is no file.
    pub(super) fn of_std(which: super::Std) -> Option<FileId> {
        use std::mem::ManuallyDrop;
        use std::os::windows::io::FromRawHandle;
        let h = match which {
            super::Std::In => std::io::stdin().as_raw_handle(),
            super::Std::Out => std::io::stdout().as_raw_handle(),
            super::Std::Err => std::io::stderr().as_raw_handle(),
        };
        if h.is_null() {
            return None;
        }
        // SAFETY: the process's own standard handle, open for as long as the
        // process is; wrapped only to query it, and never closed.
        let f = ManuallyDrop::new(unsafe { File::from_raw_handle(h) });
        of_handle(&f)
    }

    /// `CreateFileW` with `OPEN_ALWAYS`, the disposition the `OpenOptions` of
    /// Rust 1.77 uses for create + truncate, but without its truncation, and
    /// whether the file was there before (`ERROR_ALREADY_EXISTS`). The same
    /// access and share mode as `OpenOptions` (`pascal/src/streamio.pas`,
    /// `RustOpen`, is the same call).
    pub(super) fn open_no_truncate(path: &Path, read: bool) -> io::Result<(File, bool)> {
        use std::os::windows::ffi::OsStrExt;
        use std::os::windows::io::FromRawHandle;
        let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let access = GENERIC_WRITE | if read { GENERIC_READ } else { 0 };
        // SAFETY: a NUL-terminated wide string that outlives the call; the
        // other arguments are plain values and null pointers it accepts.
        let h = unsafe {
            CreateFileW(
                name.as_ptr(),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                std::ptr::null_mut(),
                OPEN_ALWAYS,
                0,
                std::ptr::null_mut(),
            )
        };
        if h as isize == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: no call between CreateFileW and this one.
        let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        // SAFETY: a handle CreateFileW just returned, owned by the File from
        // here on.
        Ok((unsafe { File::from_raw_handle(h) }, existed))
    }

    /// The truncation of Rust 1.77's create + truncate (#115745): the end of
    /// file at 0 whatever the handle is, and a failure fails the open (`NUL`
    /// or a pipe: "Can't open NUL for write", as before).
    pub(super) fn truncate(f: &File, _regular: bool) -> io::Result<()> {
        f.set_len(0)
    }
}

/// `cryptographic_prng` (`srep.cpp:652`): the per-run hash key the C++ draws
/// when no seed is given.
///
/// The port cannot reproduce Fortuna and does not need to. The key is written
/// into the archive in the clear -- `OSREP_SEED_HEX` exists precisely to read
/// it back -- so its only job is to make two runs differ. The OS random source
/// is used where there is one, and a time/pid/ASLR mix otherwise.
pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    if n == 0 {
        return out;
    }
    #[cfg(unix)]
    {
        use std::io::Read;
        if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
            if f.read_exact(&mut out).is_ok() {
                return out;
            }
        }
    }
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut s = nanos
        ^ (u64::from(std::process::id())).wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ (&out as *const Vec<u8> as u64);
    for b in out.iter_mut() {
        // splitmix64
        s = s.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = s;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        *b = (z ^ (z >> 31)) as u8;
    }
    out
}

/// `vec![0u8; n]` that reports an allocation failure instead of aborting.
/// It keeps `vec!`'s lazy zeroed pages (`alloc_zeroed`, calloc), so a huge
/// `-b` on a 64-bit build still costs only what is written.
pub fn zeroed_vec(n: usize) -> Option<Vec<u8>> {
    if n == 0 {
        return Some(Vec::new());
    }
    let layout = std::alloc::Layout::array::<u8>(n).ok()?;
    // SAFETY: `layout` is non-zero-sized; the pointer comes from the global
    // allocator with exactly this layout, which is what `Vec::from_raw_parts`
    // requires for a `Vec<u8>` of capacity `n`, and the bytes are initialized
    // (zeroed).
    unsafe {
        let p = std::alloc::alloc_zeroed(layout);
        if p.is_null() {
            None
        } else {
            Some(Vec::from_raw_parts(p, n, n))
        }
    }
}

/// A type whose all-zero bytes are a value, for `zeroed_vec_of`.
///
/// # Safety
/// Implement it only for types where every byte being zero is a valid value.
pub unsafe trait AllZero: Copy {}
// SAFETY: integers and byte arrays are valid as all zeros.
unsafe impl AllZero for u32 {}
// SAFETY: as above.
unsafe impl AllZero for u64 {}
// SAFETY: as above.
unsafe impl<const N: usize> AllZero for [u8; N] {}

/// `vec![zero; n]` that reports an allocation failure instead of aborting,
/// for the match finder's and the dictionary's tables. Through 2.3.0 they
/// were plain `vec!`s: `osrep - x.osr < in` under a 1 GiB address space (the
/// table sized for stdin's 25 GiB default) aborted with exit 134 and left the
/// archive's header on disk, where the Pascal said "Out of memory". Both say
/// `OutOfMemory` now, exit 4, and the archive is removed.
pub fn zeroed_vec_of<T: AllZero>(n: usize) -> Option<Vec<T>> {
    if n == 0 || std::mem::size_of::<T>() == 0 {
        return Some(Vec::new());
    }
    let layout = std::alloc::Layout::array::<T>(n).ok()?;
    // SAFETY: `layout` is non-zero-sized; the pointer comes from the global
    // allocator with exactly this layout, which `Vec::from_raw_parts` needs
    // for a `Vec<T>` of capacity `n`, and every element is a valid `T`
    // (all zeros, `AllZero`).
    unsafe {
        let p = std::alloc::alloc_zeroed(layout) as *mut T;
        if p.is_null() {
            None
        } else {
            Some(Vec::from_raw_parts(p, n, n))
        }
    }
}

/// `lb()` — floor(log2(n)) for n >= 1; 0 for n == 0.
#[inline]
pub fn lb(n: u64) -> u32 {
    63 - (n | 1).leading_zeros()
}

/// `roundup_to_power_of(n, 2)` (`Common.h:735`): the smallest power of two
/// >= n, with the C++'s own special cases (0 -> 0, 1 -> 1). `f(13,2) == 16`.
pub fn roundup_to_power_of_two(n: u64) -> u64 {
    if n == 0 {
        return 0;
    }
    if n == 1 {
        return 1;
    }
    2u64 << lb(n - 1)
}

/// `rounddown_to_power_of(n, 2)` (`Common.h:752`): the largest power of two
/// <= n. `f(13,2) == 8`.
pub fn rounddown_to_power_of_two(n: u64) -> u64 {
    if n == 0 {
        return 1;
    }
    1u64 << lb(n)
}


#[cfg(test)]
mod tests {
    use super::*;

    /// A scratch directory of this test's own, removed at the end.
    struct Dir(PathBuf);
    impl Dir {
        fn new(tag: &str) -> Dir {
            let t = TempFile::new(tag).unwrap();
            let p = t.path().with_extension("d");
            std::fs::create_dir(&p).unwrap();
            Dir(p)
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A run of its own: the process's `FILES` stays unarmed, so the tests
    /// running beside this one never see these files.
    fn run() -> Files {
        let mut f = Files::new();
        f.armed = true;
        f
    }

    fn id(p: &Path) -> FileId {
        file_id::of_path_regular(p).unwrap()
    }

    // An output under any name of a file the run reads is refused, and left
    // as it was; under any name of a file the run already writes, too. A file
    // that exists is truncated only once it has been accepted.
    #[test]
    fn outputs_are_refused_by_identity_before_truncation() {
        let d = Dir::new("osrep-rule");
        let input = d.0.join("in");
        std::fs::write(&input, b"input").unwrap();
        let mut f = run();
        f.note_read(Some(id(&input)));
        assert!(f.open(&d.0.join("./in"), false).is_err());
        assert!(f.refused);
        assert_eq!(std::fs::read(&input).unwrap(), b"input");

        let out = d.0.join("out");
        std::fs::write(&out, b"old").unwrap();
        let (file, out_id) = f.open(&out, true).unwrap();
        assert_eq!(out_id, Some(id(&out)));
        assert_eq!(file.metadata().unwrap().len(), 0);
        drop(file);
        std::fs::write(&out, b"written").unwrap();
        assert!(f.open(&d.0.join("./out"), false).is_err());
        assert_eq!(std::fs::read(&out).unwrap(), b"written");

        let (_, new_id) = f.open(&d.0.join("new"), false).unwrap();
        assert!(new_id.is_some() && new_id != out_id);
        #[cfg(unix)]
        {
            std::fs::hard_link(&input, d.0.join("hard")).unwrap();
            assert!(f.open(&d.0.join("hard"), false).is_err());
            std::os::unix::fs::symlink(&input, d.0.join("soft")).unwrap();
            assert!(f.open(&d.0.join("soft"), false).is_err());
            assert_eq!(std::fs::read(&input).unwrap(), b"input");
            // a device is no file to lose, as often as it is named
            assert_eq!(f.open(Path::new("/dev/null"), false).unwrap().1, None);
            assert_eq!(f.open(Path::new("/dev/null"), true).unwrap().1, None);
        }
        // a run that never began refuses nothing
        let mut idle = Files::new();
        idle.note_read(Some(id(&out)));
        assert!(idle.open(&d.0.join("./out"), false).is_ok());
        assert!(!idle.refused);
    }

    // The names that exist are compared before anything is opened: with one
    // another, and with what the run reads and writes.
    #[test]
    fn existing_names_are_compared_up_front() {
        let d = Dir::new("osrep-names");
        let a = d.0.join("a");
        std::fs::write(&a, b"a").unwrap();
        let b = d.0.join("b");
        std::fs::write(&b, b"b").unwrap();
        assert!(run().check_names(&[id(&a), id(&b)]));
        assert!(!run().check_names(&[id(&a), id(&d.0.join("./a"))]));
        let mut f = run();
        f.note_read(Some(id(&b)));
        assert!(!f.check_names(&[id(&a), id(&b)]));
        assert!(f.refused);
        // and what is not a regular file has no identity at all
        assert!(file_id::of_path_regular(&d.0.join("missing")).is_none());
        assert!(file_id::of_path_regular(&d.0).is_none());
        #[cfg(unix)]
        assert!(file_id::of_path_regular(Path::new("/dev/null")).is_none());
    }

    // A scratch file stops counting once it is gone: its number can come
    // back as another file.
    #[test]
    fn a_removed_scratch_file_is_forgotten() {
        let d = Dir::new("osrep-forget");
        let p = d.0.join("s");
        let mut f = run();
        let (file, sid) = f.open(&p, false).unwrap();
        drop(file);
        assert!(f.writes.contains(&sid.unwrap()));
        f.forget(sid.unwrap());
        assert!(!f.taken(sid.unwrap()));
    }

    // An output goes by the name it was opened under, and only while that
    // name is still the file: not another file that took the name, and not
    // a symlink to it.
    #[test]
    #[cfg(unix)]
    fn an_output_is_removed_only_while_its_name_is_the_file() {
        let d = Dir::new("osrep-claims");
        let out = d.0.join("o.out");
        let file = File::create(&out).unwrap();
        let n = OpenedName {
            path: out.clone(),
            id: file_id::of_handle(&file).unwrap(),
        };
        drop(file);
        let moved = d.0.join("moved");
        std::fs::rename(&out, &moved).unwrap();
        std::fs::write(&out, b"someone else's").unwrap();
        n.remove();
        assert!(out.exists());
        std::fs::remove_file(&out).unwrap();
        std::os::unix::fs::symlink(&moved, &out).unwrap();
        n.remove();
        assert!(moved.exists() && std::fs::symlink_metadata(&out).is_ok());
        std::fs::remove_file(&out).unwrap();
        std::fs::rename(&moved, &out).unwrap();
        n.remove();
        assert!(!out.exists());
    }

    // A named scratch file goes when it is dropped -- not a symlink named as
    // it, and not a name the run never opened.
    #[test]
    fn named_scratch_removes_only_what_it_opened() {
        let d = Dir::new("osrep-scratch");
        let p = d.0.join("t.tmp");
        drop(NamedScratch::create(&p, false).unwrap());
        assert!(!p.exists());
        assert!(NamedScratch::create(&d.0.join("nodir/t.tmp"), false).is_err());
        #[cfg(unix)]
        {
            let target = d.0.join("target");
            let link = d.0.join("l.tmp");
            std::os::unix::fs::symlink(&target, &link).unwrap();
            drop(NamedScratch::create(&link, true).unwrap());
            assert!(std::fs::symlink_metadata(&link).is_ok() && target.exists());
            drop(NamedScratch::create(Path::new("/dev/null"), false).unwrap());
            assert!(Path::new("/dev/null").exists());
        }
    }

    #[test]
    fn roundup_matches_the_c_comments() {
        assert_eq!(roundup_to_power_of_two(0), 0);
        assert_eq!(roundup_to_power_of_two(1), 1);
        assert_eq!(roundup_to_power_of_two(2), 2);
        assert_eq!(roundup_to_power_of_two(3), 4);
        assert_eq!(roundup_to_power_of_two(13), 16);
        assert_eq!(roundup_to_power_of_two(1 << 20), 1 << 20);
    }

    #[test]
    fn rounddown_matches_the_c_comments() {
        assert_eq!(rounddown_to_power_of_two(0), 1);
        assert_eq!(rounddown_to_power_of_two(1), 1);
        assert_eq!(rounddown_to_power_of_two(9), 8);
        assert_eq!(rounddown_to_power_of_two(13), 8);
        assert_eq!(rounddown_to_power_of_two(15), 8);
        assert_eq!(rounddown_to_power_of_two(16), 16);
    }
}
