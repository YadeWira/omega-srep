//! Small helpers ported from `Compression/Common.h`, plus the scratch-file
//! guard the `-dup` wrapper and the CLI's stdin/stdout spooling both need.

use std::fs::OpenOptions;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
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
