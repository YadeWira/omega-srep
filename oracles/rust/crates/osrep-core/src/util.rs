//! Small helpers ported from `oracles/cxx/Compression/Common.h`, plus the
//! scratch-file guard the `-dup` wrapper and the CLI's stdin/stdout spooling
//! both need, and the list of outputs a failed run removes.

use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// A scratch file, removed when it goes out of scope.
///
/// The C++ unlinks its temporaries on every path it remembers to, and leaks
/// them on the rest (its signal handler never calls `removeTemporaryFiles`).
/// A `Drop` cannot forget, which is the point.
pub struct TempFile {
    path: PathBuf,
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
        OpenOptions::new().write(true).create_new(true).open(&path)?;
        Ok(TempFile { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

// ------------------------------------------- files named by the command line --

/// Device and inode on Unix; volume serial number and file index on Windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileId(u64, u64);

/// A regular file this run opened for writing under a name it was given,
/// remembered by identity, so that it can be removed later without removing
/// something else that took the name in the meantime.
///
/// Only a regular file is ever recorded: stdout, a pipe, a FIFO or a device
/// (`/dev/null`, `NUL`, `CON`) never is, so none of them is ever removed --
/// not even by root, for whom removing `/dev/null` would succeed.
#[derive(Debug)]
pub struct OpenedName {
    path: PathBuf,
    id: FileId,
}

impl OpenedName {
    /// `file`, just opened for writing as `path`; `None` when it is not a
    /// regular file.
    pub fn of(path: &Path, file: &File) -> Option<OpenedName> {
        file_id::of_handle(file).map(|id| OpenedName {
            path: path.to_path_buf(),
            id,
        })
    }

    /// Remove the name if it still refers to the file that was opened, and
    /// not through a symlink (the file a symlink leads to keeps what was
    /// written). Call it with the file's handles closed: Windows cannot
    /// delete a file that is still open without `FILE_SHARE_DELETE`.
    pub fn remove(&self) {
        if file_id::of_name(&self.path) == Some(self.id) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// A scratch file under a name the user gave (`-temp=`, `-vmfile=`), removed
/// when it goes out of scope, as the C++ does (`srep.cpp:1336`,
/// `decompress.cpp:233`) -- but only when this run did open it for writing,
/// only when it is a regular file, and only while the name still refers to
/// that file (see `OpenedName`). A name whose open failed is not this run's
/// to remove, and `-vmfile=/dev/null` is not a scratch file at all.
#[derive(Debug)]
pub struct NamedScratch(Option<OpenedName>);

impl NamedScratch {
    pub fn new(path: &Path, file: &File) -> NamedScratch {
        NamedScratch(OpenedName::of(path, file))
    }
}

impl Drop for NamedScratch {
    fn drop(&mut self) {
        if let Some(n) = &self.0 {
            n.remove();
        }
    }
}

/// Whether two names lead to the same regular file (following symlinks): a
/// hard link, `./x` for `x`, a symlink to it. A name that does not exist, or
/// that is a directory, a FIFO or a device, is the same as nothing -- writing
/// over `/dev/null` while reading it loses nothing.
pub fn same_file(a: &Path, b: &Path) -> bool {
    match file_id::of_path_regular(a) {
        Some(id) => file_id::of_path_regular(b) == Some(id),
        None => false,
    }
}

// ------------------------------------------------- outputs of a failed run --

/// The files this run created or truncated under a name it was given -- the
/// archive, the decoded file, `-index=` -- so that a run that fails can take
/// them back instead of leaving a partial file on disk.
///
/// The C++ means to do this ("Delete output files on error", `srep.cpp:1339`)
/// but only its `goto cleanup` paths reach that code; every `error()` exits on
/// the spot, so through 2.3.0 a failed run left its output behind (an archive
/// cut short by `OutOfMemory`, the blocks decoded before a `DigestMismatch`).
///
/// Only what was opened as a regular file is ever claimed (`OpenedName`), and
/// the removal goes through only if the name still refers to that same file,
/// not through a symlink, and not to an input of the run. Scratch files are
/// not here: `TempFile` and `NamedScratch` remove those whatever happens.
static CLAIMED: Mutex<Vec<OpenedName>> = Mutex::new(Vec::new());

/// Record `file`, just opened for writing as `path`, as an output to remove if
/// the run fails. Not a regular file: nothing to take back, nothing recorded.
pub fn claim_output(path: &Path, file: &File) {
    if let Some(n) = OpenedName::of(path, file) {
        if let Ok(mut v) = CLAIMED.lock() {
            v.push(n);
        }
    }
}

/// The run failed: remove every claimed output, after its handle is closed.
/// A claimed output that is the same file as one of `inputs` -- the archive or
/// the file being compressed, and `-index=` when decompressing -- is never
/// removed, under whatever name it was also opened for writing.
pub fn remove_claimed_outputs(inputs: &[&Path]) {
    let claims = match CLAIMED.lock() {
        Ok(mut v) => std::mem::take(&mut *v),
        Err(_) => return,
    };
    remove_unless_input(claims, inputs);
}

fn remove_unless_input(claims: Vec<OpenedName>, inputs: &[&Path]) {
    let keep: Vec<FileId> = inputs.iter().filter_map(|p| file_id::of_path(p)).collect();
    for n in claims {
        if !keep.contains(&n.id) {
            n.remove();
        }
    }
}


#[cfg(unix)]
mod file_id {
    use super::FileId;
    use std::fs::{File, Metadata};
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

    /// `stat`: whatever the name leads to.
    pub(super) fn of_path(p: &Path) -> Option<FileId> {
        std::fs::metadata(p).ok().map(|m| id(&m))
    }

    /// `stat`: the name leads to a regular file.
    pub(super) fn of_path_regular(p: &Path) -> Option<FileId> {
        std::fs::metadata(p)
            .ok()
            .filter(|m| m.file_type().is_file())
            .map(|m| id(&m))
    }
}

#[cfg(windows)]
mod file_id {
    use super::FileId;
    use std::ffi::c_void;
    use std::fs::{File, OpenOptions};
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use std::path::Path;

    const FILE_TYPE_DISK: u32 = 1;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;

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

    /// Whatever the name leads to.
    pub(super) fn of_path(p: &Path) -> Option<FileId> {
        let f = OpenOptions::new()
            .access_mode(0)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(p)
            .ok()?;
        info(&f).map(|(_, id)| id)
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

    // A claimed output that is the same file as an input of the run -- under
    // another name, through a hard link -- is never removed; the others are.
    // (Not through `remove_claimed_outputs`: its list is the whole process's.)
    #[test]
    fn claimed_outputs_spare_the_inputs() {
        let d = Dir::new("osrep-claims");
        let input = d.0.join("k.ix");
        std::fs::write(&input, b"index").unwrap();
        let other = d.0.join("o.out");
        let claims = vec![
            OpenedName::of(&d.0.join("./k.ix"), &File::options().write(true).open(&input).unwrap())
                .unwrap(),
            OpenedName::of(&other, &File::create(&other).unwrap()).unwrap(),
        ];
        remove_unless_input(claims, &[&input]);
        assert_eq!(std::fs::read(&input).unwrap(), b"index");
        assert!(!other.exists());

        #[cfg(unix)]
        {
            let link = d.0.join("hard.ix");
            std::fs::hard_link(&input, &link).unwrap();
            let claims = vec![OpenedName::of(&link, &File::options().write(true).open(&link).unwrap())
                .unwrap()];
            remove_unless_input(claims, &[&input]);
            assert!(link.exists());
            let claims = vec![OpenedName::of(&link, &File::options().write(true).open(&link).unwrap())
                .unwrap()];
            remove_unless_input(claims, &[]);
            assert!(!link.exists() && input.exists());
        }
    }

    // `same_file` sees through spellings and links, and only for regular files.
    #[test]
    fn same_file_is_identity_of_regular_files() {
        let d = Dir::new("osrep-same");
        let a = d.0.join("a");
        std::fs::write(&a, b"x").unwrap();
        let b = d.0.join("b");
        std::fs::write(&b, b"x").unwrap();
        assert!(same_file(&a, &d.0.join("./a")));
        assert!(!same_file(&a, &b));
        assert!(!same_file(&a, &d.0.join("missing")));
        assert!(!same_file(&d.0, &d.0));
        #[cfg(unix)]
        {
            std::fs::hard_link(&a, d.0.join("h")).unwrap();
            assert!(same_file(&a, &d.0.join("h")));
            std::os::unix::fs::symlink(&a, d.0.join("s")).unwrap();
            assert!(same_file(&d.0.join("s"), &a));
            assert!(!same_file(Path::new("/dev/null"), Path::new("/dev/../dev/null")));
        }
    }

    // A named scratch file goes when it is dropped -- not a symlink named as
    // it, and not a name the run never opened.
    #[test]
    fn named_scratch_removes_only_what_it_opened() {
        let d = Dir::new("osrep-scratch");
        let p = d.0.join("t.tmp");
        drop(NamedScratch::new(&p, &File::create(&p).unwrap()));
        assert!(!p.exists());
        #[cfg(unix)]
        {
            let target = d.0.join("target");
            let link = d.0.join("l.tmp");
            std::os::unix::fs::symlink(&target, &link).unwrap();
            drop(NamedScratch::new(&link, &File::create(&link).unwrap()));
            assert!(std::fs::symlink_metadata(&link).is_ok() && target.exists());
            drop(NamedScratch::new(
                Path::new("/dev/null"),
                &File::options().write(true).open("/dev/null").unwrap(),
            ));
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
