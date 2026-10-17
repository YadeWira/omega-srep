//! The three standard streams, when they are closed, full or missing.
//!
//! Three rules, kept identical in the Pascal (`pascal/src/stdfds.pas`):
//!
//! * **Messages never fail the program.** Text for stderr (and `--help` /
//!   `--version` for stdout) goes out with [`ewrite!`]/[`ewriteln!`] and
//!   [`out_text`], which drop write errors. `eprint!`/`print!` panic on any
//!   error other than EBADF: `osrep x x.osr 2>/dev/full` died with exit 101
//!   after writing 60 bytes of the archive. The C++ and the Pascal ignore it.
//! * **A file never lands on fd 0, 1 or 2.** If the program is started with
//!   one of them closed, the first `open` reuses that number, and every
//!   message meant for stderr went into the archive (`osrep x x.osr 2>&- <&-`
//!   in the C++ and the Pascal). Rust's runtime already reopens a closed fd on
//!   `/dev/null` before `main`; [`reserve_std_fds`] runs before that and does
//!   it itself, so it can put them somewhere else:
//! * **Data for a closed stdout is an error, not a discard.** `/dev/null`
//!   accepts everything, so `osrep -delete x - >&-` wrote the archive
//!   nowhere, exited 0 and deleted `x`. A closed fd 1 or 2 is reopened on
//!   the directory `/`, read-only, so writing to it fails with EBADF, which
//!   is what writing to a closed fd does; the archive and the decoded data
//!   go through [`data_stdout`], a plain handle that reports that error
//!   instead of swallowing it as `std::io::stdout()` does. The result is the
//!   same as any other stdout write failure (a reader that went away): "Io"
//!   or "Can't write to stdout", and nothing deleted. A directory and not a
//!   read-only `/dev/null` because the output can also be named
//!   `/dev/stdout`, `/dev/stderr` or `/proc/self/fd/N`: opening that for
//!   writing opens the file behind the fd again, and `/dev/null` would take
//!   it (`osrep -delete x /dev/stdout >&-` deleted `x`); a directory fails
//!   with EISDIR, "Can't open /dev/stdout for write". A closed stdin is
//!   reserved on `/` too, but with `O_PATH`: reading it gives EBADF, which
//!   `std::io::stdin()` takes as end of file (the Pascal's `StdinRead` does
//!   the same), so it reads as empty, as in Rust, the C++ and the Pascal
//!   before. Not `/dev/null`: the output can also be named `/dev/stdin` or
//!   `/proc/self/fd/0`, and `osrep -delete x /dev/stdin <&-` wrote the
//!   archive into `/dev/null` and deleted `x`; on a directory that open
//!   fails with EISDIR as for fds 1 and 2. The runtime then sees POLLNVAL
//!   on fd 0 and opens one more `/dev/null`, on fd 3; [`reserve`] closes it
//!   again first thing in `main`. Left open it shifted every later fd by
//!   one from the Pascal's, and was a `/dev/null` a name could reach:
//!   `osrep -d -delete y.osr /proc/self/fd/3 <&-` decoded into it, exited 0
//!   and deleted `y.osr`. The same goes for an O_PATH fd 0, 1 or 2 the
//!   parent passed down: the runtime opens a `/dev/null` for each, and those
//!   are closed too.
//!
//! On Windows nothing is reopened: handles are not numbered like fds, and a
//! missing std handle is null. [`data_stdout`] fails on a null handle with
//! `ERROR_INVALID_HANDLE`, and on a handle that is there but not writable
//! (wine gives one when the Unix fd is closed) with the error `WriteFile`
//! gives; `std::io::stdout()` swallowed both.

use std::fs::File;
use std::io::{LineWriter, Write};
use std::mem::ManuallyDrop;

/// `eprint!` that ignores write errors instead of panicking.
macro_rules! ewrite {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        let _ = write!(std::io::stderr(), $($arg)*);
    }};
}

/// `eprintln!` that ignores write errors instead of panicking.
macro_rules! ewriteln {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stderr(), $($arg)*);
    }};
}

/// `print!` of a text (`--help`, `--version`) that ignores write errors.
pub fn out_text(s: &str) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(s.as_bytes());
    let _ = out.flush();
}

/// Runs from `.init_array`, before the Rust runtime's own check of fds 0-2
/// (`sys::pal::unix::init`, which would reopen a closed fd 1 or 2 read-write
/// on `/dev/null`). Same order as the runtime, so each open lands on the fd
/// it replaces: fd 0 on `/` with `O_PATH` (reads give EBADF, an empty
/// input), fds 1 and 2 on `/` read-only (see the module comment). If the
/// open fails the runtime aborts, and so does this.
#[cfg(target_os = "linux")]
pub mod reserve {
    use std::os::raw::{c_char, c_int};
    use std::sync::atomic::{AtomicI32, Ordering};

    extern "C" {
        fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
        fn open(path: *const c_char, flags: c_int, ...) -> c_int;
        fn abort() -> !;
        fn __errno_location() -> *mut c_int;
    }

    const F_GETFD: c_int = 1;
    const O_RDONLY: c_int = 0;
    // x86, x86_64, arm and aarch64 alike (asm-generic/fcntl.h)
    const O_PATH: c_int = 0o10000000;
    const EBADF: c_int = 9;

    extern "C" fn reserve_std_fds() {
        for fd in 0..3 {
            // SAFETY: plain libc calls on integers and a NUL-terminated
            // literal; nothing else is running yet.
            unsafe {
                if fcntl(fd, F_GETFD) == -1 && *__errno_location() == EBADF {
                    let r = if fd == 0 {
                        open(b"/\0".as_ptr().cast(), O_PATH)
                    } else {
                        open(b"/\0".as_ptr().cast(), O_RDONLY)
                    };
                    if r == -1 {
                        abort();
                    }
                }
            }
        }
        // The runtime opens /dev/null on the lowest free fd for every fd 0-2
        // it sees POLLNVAL on: the O_PATH fd 0 above, and any O_PATH fd 0, 1
        // or 2 the parent passed (a program can hand one down). So up to
        // three, on the three lowest fds free now: remembered, for
        // `drop_runtime_null`. Through r231-files only the one for a closed
        // fd 0 was, and an inherited O_PATH fd left a /dev/null on fd 3 that
        // `/proc/self/fd/3` reached: `osrep -delete t /proc/self/fd/3` wrote
        // the archive there and deleted `t` (the Pascal refuses).
        let mut n: c_int = 3;
        for slot in &RUNTIME_NULL {
            // SAFETY: as above
            while unsafe { fcntl(n, F_GETFD) } != -1 {
                n += 1;
            }
            slot.store(n, Ordering::Relaxed);
            n += 1;
        }
    }

    pub static RUNTIME_NULL: [AtomicI32; 3] = [AtomicI32::new(-1), AtomicI32::new(-1), AtomicI32::new(-1)];

    /// Closes the `/dev/null`s the runtime opened for an O_PATH fd 0, 1 or 2
    /// (`reserve_std_fds`), so the fds after 2 are numbered as in the Pascal
    /// (the input on fd 3), and no `/proc/self/fd/N` leads to a `/dev/null`
    /// the Pascal does not have. Only the fds that were free before the
    /// runtime ran, and only those that are `/dev/null` now (character device
    /// 1:3); first thing in `main`, before the program opens anything.
    pub fn drop_runtime_null() {
        use std::os::fd::FromRawFd;
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        for slot in &RUNTIME_NULL {
            let n = slot.swap(-1, Ordering::Relaxed);
            if n < 3 {
                continue;
            }
            // SAFETY: n was free before the runtime ran; only a /dev/null it
            // opened there is closed, anything else (or nothing) is left alone
            let f = unsafe { std::fs::File::from_raw_fd(n) };
            match f.metadata() {
                Ok(m) if m.file_type().is_char_device() && m.rdev() == 0x103 => drop(f),
                _ => std::mem::forget(f),
            }
        }
    }

    #[used]
    #[link_section = ".init_array"]
    static RESERVE_STD_FDS: extern "C" fn() = reserve_std_fds;
}

/// stdout as a plain file handle, never closed by us.
pub struct RawStdout(Option<ManuallyDrop<File>>);

impl Write for RawStdout {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match &mut self.0 {
            Some(f) => f.write(buf),
            // ERROR_INVALID_HANDLE: no std handle at all
            None => Err(std::io::Error::from_raw_os_error(6)),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Where the archive or the decoded data goes when the output is `-`.
///
/// The same `LineWriter` of 1024 bytes as `std::io::stdout()`, so a failure
/// is reported at the same point as before (`tests/rust_cli_conformance.sh`
/// pins when that is "Io" and when "Can't write to stdout"), but over the
/// handle itself: a write error is an error, also EBADF.
pub fn data_stdout() -> LineWriter<RawStdout> {
    #[cfg(unix)]
    let f = {
        use std::os::fd::FromRawFd;
        // SAFETY: fd 1 is open (reserve_std_fds / the runtime saw to it),
        // and ManuallyDrop keeps it from being closed.
        Some(ManuallyDrop::new(unsafe { File::from_raw_fd(1) }))
    };
    #[cfg(windows)]
    let f = {
        use std::os::windows::io::{AsRawHandle, FromRawHandle};
        // null when the handle is missing or INVALID_HANDLE_VALUE
        let h = std::io::stdout().as_raw_handle();
        if h.is_null() {
            None
        } else {
            // SAFETY: a handle the process holds; ManuallyDrop keeps it
            // from being closed.
            Some(ManuallyDrop::new(unsafe { File::from_raw_handle(h) }))
        }
    };
    LineWriter::new(RawStdout(f))
}
