//! `--version` and `--help`.
//!
//! The text is the C++'s (`dup_wrapper.cpp:412-472`, which is what a user sees:
//! the wrapper answers both flags before `srep_main` ever runs). A drop-in
//! replacement that prints a different synopsis is a worse drop-in, so this is
//! reproduced rather than rewritten.

use crate::VERSION;

pub const DESCRIPTION: &str =
    "huge-dictionary LZ77 preprocessor (Omega lineage, fork of SREP by Bulat Ziganshin)";
pub const HOMEPAGE: &str = "https://github.com/YadeWira/omega-srep";
/// Release date. No longer `srep.cpp:6`'s `program_date`: the C++ is frozen at
/// 1.0.7 and its date with it (see the note in the workspace `Cargo.toml`).
pub const DATE: &str = "September 22, 2026";

/// `print_version` (`dup_wrapper.cpp:406-409`).
pub fn version() -> String {
    format!("Omega SREP {VERSION} ({DATE})")
}

/// `print_help` (`dup_wrapper.cpp:412-472`).
pub fn help() -> String {
    format!(
        "{version}\n\
         {DESCRIPTION}\n\
         {HOMEPAGE}\n\
         \n\
         Usage:\n\
         \x20 osrep [options] -mN  input  output       compress\n\
         \x20 osrep [options] -d   archive output      decompress\n\
         \x20 osrep -i archive                         show archive info\n\
         \n\
         Compression methods:\n\
         \x20 -m0       REP only (in-memory; works with -dBYTES)\n\
         \x20 -m1, -m2  Content-defined chunking (CDC)\n\
         \x20 -m3       Digest-comparison match search (default)\n\
         \x20 -m4       Full match search (best ratio for general data)\n\
         \x20 -m5       Exhaustive match search (slowest, best ratio)\n\
         \n\
         Common options:\n\
         \x20 -lN, -cN          minimum-match / chunk-size tuning\n\
         \x20 -bN               buffer size (default 8mb)\n\
         \x20 -tN               worker thread count (-m1/-m2's CDC, and -m3/-m5's\n\
         \x20                    prepare_buffer stripe pool, capped at 16 internally)\n\
         \x20 -dBYTES           dictionary size for -m0\n\
         \x20 -hash=NAME        select hash (vmac, sha1, ...)\n\
         \x20 -mmap, -nommap    enable/disable POSIX mmap reads\n\
         \x20 -temp=PATH        tempfile path override\n\
         \x20 --format=v4|v5    container to write (default v5). v4 is the\n\
         \x20                   container the 1.0.x releases read, kept for\n\
         \x20                   interoperability; both are always readable.\n\
         \x20 --seed=N          deterministic hash seed (uint64; default is\n\
         \x20                   random per-run). Same seed + same input ->\n\
         \x20                   byte-identical archive. Useful for content-\n\
         \x20                   addressed storage and reproducible builds.\n\
         \x20 -bar              emit \"PROGRESS <done> <total>\" to stderr every\n\
         \x20                   ~0.5s, plus a guaranteed final line at\n\
         \x20                   done==total. Machine-parseable, for wrapping\n\
         \x20                   osrep as a subprocess.\n\
         \n\
         Dedup pre-pass (Omega F5):\n\
         \x20 -dup              enable FA-style dedup pre-pass\n\
         \x20 --dup-paranoid    byte-compare on every dedup hit (slower, no\n\
         \x20                   silent corruption on 64-bit hash collision)\n\
         \x20 --chunk-avg=N     CDC average chunk size (default 4096)\n\
         \x20 --chunk-min=N     CDC minimum chunk size (default 1024)\n\
         \x20 --chunk-max=N     CDC maximum chunk size (default 16384)\n\
         \x20 --chunk-buf=N     buffer-bounded CDC, bytes (default 8388608)\n\
         \x20 --chunk-hash=NAME CDC boundary hash: fnv (default) or gear.\n\
         \x20                   gear = Gear-hash CDC with an implicit ~64-byte\n\
         \x20                   content window (FastCDC-style normalized\n\
         \x20                   chunking); finds non-buffer-aligned duplicates\n\
         \x20                   that fnv's unwindowed rolling hash misses.\n\
         \x20                   Opt-in; does not change the .dupref format.\n\
         \n\
         Help:\n\
         \x20 --help, -h, -?    this synopsis\n\
         \x20 --version, -V     version line\n\
         \n\
         Project page: {HOMEPAGE}\n",
        version = version(),
    )
}
