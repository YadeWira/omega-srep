//! The command line.
//!
//! Two parsers, in the C++'s order: `dup_wrapper`'s pre-pass
//! (`dup_wrapper.cpp:88-155`) first, because its flags (`-dup`, `--chunk-*`,
//! `--seed=`) are ones `srep_main` would reject as invalid options, and then
//! `srep_main`'s own loop (`srep.cpp:303-430`). The order of the tests inside
//! that loop is load-bearing and is preserved: `-vmfile=` and `-vmblock=` have
//! to be matched before `-v`, `-hash-` before `-hash=`, and `-d` before the
//! `-d…` family.

use osrep_core::dedup;
use osrep_core::encoder::Seed;

pub const KB: u64 = 1024;
pub const MB: u64 = 1024 * 1024;
pub const GB: u64 = 1024 * 1024 * 1024;

/// `srep.cpp:284`: what compression from stdin assumes when `-s` is silent.
/// `slices_in_block` (`hash_table.cpp:32`): `sizeof(entry)*CHAR_BIT/BITS`.
/// The smallest `-c` that leaves `SliceHash` a non-zero slice.
pub const SLICES_IN_BLOCK: usize = 8;

/// The largest `-l`, `-c`, `-dl` or `-dc`: the C++ keeps all four in an
/// `unsigned` (`srep.cpp:292`), so anything larger wraps there (`-l4294967296`
/// is `-l0`, the default), while the port took it whole -- and on i686
/// truncated it to 32 bits like the C++, so the same command line gave the two
/// builds different archives. Values past 2^63 also overflowed the match
/// finder's `2 * L` (a panic in 2.1.2; an access violation in the Pascal) and
/// `-m5`'s `-l + 1`.
pub const MAX_LENGTH_OPTION: u64 = u32::MAX as u64;

pub const DEFAULT_STDIN_FILESIZE: u64 = 25 * GB;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmdMode {
    Compress,
    Decompress,
    Info,
    /// `--verify`: check an archive's integrity without reconstructing it.
    /// Only v5 can answer this -- v4 carries no checksum anywhere.
    Verify,
}

/// `--format=`, the one option the C++ does not have. v5 is the default since
/// phase 5c-2; `--format=v4` writes the container the 1.0.x C++ binaries read,
/// and stays supported permanently as the interoperability escape hatch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    V4,
    V5,
}

/// Where an archive's match lists go, i.e. the `f`/`o` suffix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lz {
    Index,
    Future,
    Io,
}

#[derive(Debug, Clone)]
pub struct Options {
    pub cmdmode: CmdMode,
    pub format: Format,
    pub method: u8,
    pub lz: Lz,
    pub dictsize: u64,
    pub dict_hashsize: u64,
    pub dict_chunk: usize,
    pub dict_min_match: usize,
    pub min_match: usize,
    pub l: usize,
    pub maximum_save: u32,
    pub bufsize: u64,
    pub num_threads: u64,
    pub accel: u32,
    pub accelerator: u32,
    pub io_accelerator: i32,
    /// `-hash=NAME`; `None` keeps the default, `Some("")` is `-hash-`.
    pub hash: Option<String>,
    pub vm_mem: u64,
    pub vm_block: u64,
    pub vmfile: Option<String>,
    pub tempfile: Option<String>,
    pub index_file: String,
    pub delete_input: bool,
    pub verbosity: i32,
    pub bar: bool,
    /// `-s` with no size: the human progress cadence (`""`/`-`/`+`/seconds).
    pub stats_cadence: String,
    /// `-sBYTES`: the size to compress as.
    pub declared_size: Option<u64>,
    pub use_mmap: bool,
    pub dup: bool,
    pub dup_paranoid: bool,
    pub chunk: dedup::Params,
    pub seed: Seed,
    /// `--seed=` was given but did not parse.
    pub seed_invalid: bool,
    pub files: Vec<String>,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            cmdmode: CmdMode::Compress,
            format: Format::V5,
            method: 3,
            lz: Lz::Index,
            dictsize: 0,
            dict_hashsize: 0,
            dict_chunk: 0,
            dict_min_match: 0,
            min_match: 0,
            l: 0,
            maximum_save: u32::MAX,
            bufsize: 8 * MB,
            num_threads: 0,
            accel: 9000,
            accelerator: 9000,
            io_accelerator: 1,
            hash: None,
            vm_mem: parse_mem_option("75%", Unit::M).unwrap_or(0),
            vm_block: 8 * MB,
            vmfile: None,
            tempfile: None,
            index_file: String::new(),
            delete_input: false,
            verbosity: 2,
            bar: false,
            stats_cadence: "+".to_string(),
            declared_size: None,
            use_mmap: false,
            dup: false,
            dup_paranoid: false,
            chunk: dedup::Params::default(),
            seed: Seed::Random,
            seed_invalid: false,
            files: Vec::new(),
        }
    }
}

/// A command-line error, ready to print in the C++'s `error()` shape.
#[derive(Debug)]
pub struct CmdLineError(pub String);

fn bad(msg: impl Into<String>) -> CmdLineError {
    CmdLineError(msg.into())
}

// --------------------------------------------------------------- sizes --

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    B,
    K,
    M,
    G,
    Pow,
}

/// `parseMem64` (`Common.cpp:245-260`).
///
/// An optional leading `=`, then digits, then an optional single-character
/// suffix (`b`/`k`/`m`/`g`, or `^` for a power of two); with no suffix the
/// caller's `spec` applies. Whatever follows a recognised suffix is ignored,
/// which is why `-b8mb` and `-b8m` both mean eight megabytes.
pub fn parse_mem(s: &str, spec: Unit) -> Option<u64> {
    let b = s.as_bytes();
    let mut i = usize::from(b.first() == Some(&b'='));
    if !matches!(b.get(i), Some(c) if c.is_ascii_digit()) {
        return None;
    }
    let mut n: u64 = 0;
    while let Some(c) = b.get(i) {
        if !c.is_ascii_digit() {
            break;
        }
        n = n.checked_mul(10)?.checked_add(u64::from(c - b'0'))?;
        i += 1;
    }
    let unit = match b.get(i) {
        None => spec,
        Some(b'b') => Unit::B,
        Some(b'k') => Unit::K,
        Some(b'm') => Unit::M,
        Some(b'g') => Unit::G,
        Some(b'^') => Unit::Pow,
        Some(_) => return None,
    };
    match unit {
        Unit::B => Some(n),
        Unit::K => n.checked_mul(KB),
        Unit::M => n.checked_mul(MB),
        Unit::G => n.checked_mul(GB),
        Unit::Pow => {
            if n < 64 {
                Some(1u64 << n)
            } else {
                None
            }
        }
    }
}

/// `parse_mem_option` (`srep.cpp:192-222`): `-mem100mb`, `-mem75%`, `-mem75p`,
/// `-mem75%-600mb`. The percentage form resolves against physical RAM, so this
/// needs a reading of it; `physical_memory` supplies one.
pub fn parse_mem_option(s: &str, spec: Unit) -> Option<u64> {
    if let Some(n) = parse_mem(s, spec) {
        return Some(n);
    }
    let b = s.as_bytes();
    let mut i = 0usize;
    let mut percent: u64 = 0;
    while let Some(c) = b.get(i) {
        if !c.is_ascii_digit() {
            break;
        }
        percent = percent * 10 + u64::from(c - b'0');
        i += 1;
    }
    if !matches!(b.get(i), Some(b'%') | Some(b'p')) {
        return None;
    }
    i += 1;
    // `-mem75%` takes nothing after the sign; `-mem75%-600mb` subtracts.
    let minus = match s[i..].strip_prefix('-') {
        Some(rest) => parse_mem(rest, spec)?,
        None if i == s.len() => 0,
        None => return None,
    };
    Some((percent * (physical_memory() / 100)).saturating_sub(minus))
}

/// `GetPhysicalMemory()`. Only used to resolve `-memNN%`, and the value it
/// feeds (the spill budget) changes *when* matches are held in memory, never
/// what comes out -- so a platform this cannot read falls back rather than
/// failing.
fn physical_memory() -> u64 {
    #[cfg(target_os = "linux")]
    {
        if let Ok(text) = std::fs::read_to_string("/proc/meminfo") {
            for line in text.lines() {
                if let Some(rest) = line.strip_prefix("MemTotal:") {
                    if let Some(kb) = rest.split_whitespace().next() {
                        if let Ok(kb) = kb.parse::<u64>() {
                            return kb * KB;
                        }
                    }
                }
            }
        }
    }
    4 * GB
}

// --------------------------------------------------------------- parse --

/// `-l`, `-c`, `-dl` and `-dc`, bounded by `MAX_LENGTH_OPTION`.
fn length_option(a: &str, n: u64, what: &str) -> Result<usize, CmdLineError> {
    if n > MAX_LENGTH_OPTION {
        return Err(bad(format!(
            "Invalid option: {a} -- the {what} must be at most {MAX_LENGTH_OPTION} bytes"
        )));
    }
    Ok(n as usize)
}

/// `parseInt` (`Common.cpp:234-242`), the parser of `-v`, `-t` and `-da`: an
/// optional leading `=`, then one or more decimal digits and nothing else. No
/// sign, no `0x`, no suffix: the C++ refuses `-t+4`, `-v-1` and `-t0x10`,
/// which the port accepted until 2.3.0. A leading zero is just a zero
/// (`-t010` is 10). The C++ wraps a value past 2^64; that stays an invalid
/// option here, as does anything past `i64::MAX`.
fn parse_dec_int(s: &str) -> Option<i64> {
    let s = s.strip_prefix('=').unwrap_or(s);
    if s.is_empty() || !s.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    s.parse::<i64>().ok()
}

/// What C's `strtol(s, &end, 0)` / `strtoull(s, &end, 0)` read: leading
/// white space (`isspace` in the "C" locale), an optional sign, then a base
/// picked by the prefix -- `0x`/`0X` followed by a hex digit is hex, any
/// other leading `0` is octal, the rest decimal -- and the longest run of
/// digits of that base. `end` is the byte index `end` would point at; with
/// no digits at all nothing is converted and `end` is 0, as `strtol` sets it
/// back to the start of the string. `magnitude` is `None` past `u64::MAX`.
///
/// glibc 2.38 also reads a `0b` binary prefix (C23) in a C++ build; MinGW's
/// runtime does not, so 1.0.7 itself disagrees between Linux and Windows
/// there, and this reads `0b101` as `0` followed by junk, like Windows.
struct CNumber {
    negative: bool,
    magnitude: Option<u64>,
    end: usize,
}

fn c_strto_base0(s: &[u8]) -> CNumber {
    let mut i = 0usize;
    while matches!(s.get(i), Some(b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')) {
        i += 1;
    }
    let mut negative = false;
    if let Some(&c @ (b'+' | b'-')) = s.get(i) {
        negative = c == b'-';
        i += 1;
    }
    let hex = s.get(i) == Some(&b'0')
        && matches!(s.get(i + 1), Some(b'x' | b'X'))
        && s.get(i + 2).is_some_and(|c| c.is_ascii_hexdigit());
    let (radix, start) = if hex {
        (16u32, i + 2)
    } else if s.get(i) == Some(&b'0') {
        (8, i)
    } else {
        (10, i)
    };
    let mut j = start;
    let mut magnitude = Some(0u64);
    while let Some(d) = s.get(j).and_then(|&c| char::from(c).to_digit(radix)) {
        magnitude = magnitude
            .and_then(|m| m.checked_mul(u64::from(radix)))
            .and_then(|m| m.checked_add(u64::from(d)));
        j += 1;
    }
    if j == start {
        return CNumber {
            negative: false,
            magnitude: Some(0),
            end: 0,
        };
    }
    CNumber {
        negative,
        magnitude,
        end: j,
    }
}

/// `strtol` of `-aX[/Y]` (`srep.cpp:343-348`). The C++ stores it in a `long`,
/// which is 64 bits on Linux and 32 on Windows, and saturates past it; the
/// port reads the Linux width and refuses what does not fit in an `i64`
/// instead of saturating, which is what it did before.
fn c_long(n: &CNumber) -> Option<i64> {
    let m = n.magnitude?;
    if n.negative {
        // -(2^63) is i64::MIN; wrapping_neg gives it back unchanged.
        (m <= 1u64 << 63).then(|| (m as i64).wrapping_neg())
    } else {
        i64::try_from(m).ok()
    }
}

/// Parse `argv` (without the program name) into `Options`, or fail the way the
/// C++ does.
pub fn parse(args: &[String]) -> Result<Options, CmdLineError> {
    let mut o = Options::default();
    let mut i = 0usize;

    while i < args.len() {
        let a = args[i].as_str();
        if a == "--" {
            // No more options; everything left is a filename.
            o.files.extend(args[i + 1..].iter().cloned());
            break;
        }

        // ---- the `-dup` wrapper's own flags, which srep_main would reject ----
        if a == "-dup" {
            o.dup = true;
        } else if a == "--dup-paranoid" {
            o.dup_paranoid = true;
        } else if let Some(v) = a.strip_prefix("--seed=") {
            match parse_seed(v) {
                Some(n) => o.seed = Seed::Value(n),
                None => o.seed_invalid = true,
            }
        } else if let Some(v) = a.strip_prefix("--chunk-avg=") {
            o.chunk.avg = v.parse().map_err(|_| bad(format!("Invalid option: {a}")))?;
        } else if let Some(v) = a.strip_prefix("--chunk-min=") {
            o.chunk.min_chunk = v.parse().map_err(|_| bad(format!("Invalid option: {a}")))?;
        } else if let Some(v) = a.strip_prefix("--chunk-max=") {
            o.chunk.max_chunk = v.parse().map_err(|_| bad(format!("Invalid option: {a}")))?;
        } else if let Some(v) = a.strip_prefix("--chunk-buf=") {
            o.chunk.buf_size = v.parse().map_err(|_| bad(format!("Invalid option: {a}")))?;
        } else if let Some(v) = a.strip_prefix("--chunk-hash=") {
            o.chunk.hash_algo = match v {
                "fnv" => dedup::CDC_HASH_FNV,
                "gear" => dedup::CDC_HASH_GEAR,
                _ => return Err(bad("--chunk-hash must be 'fnv' or 'gear'")),
            };
        } else if let Some(v) = a.strip_prefix("--format=") {
            o.format = match v {
                "v4" => Format::V4,
                "v5" => Format::V5,
                _ => return Err(bad(format!("Invalid option: {a}"))),
            };
        } else if a == "-d" {
            o.cmdmode = CmdMode::Decompress;
        } else if a == "-i" {
            o.cmdmode = CmdMode::Info;
        } else if a == "--verify" {
            o.cmdmode = CmdMode::Verify;
        } else if a == "-delete" {
            o.delete_input = true;
        } else if a == "-mmap" {
            o.use_mmap = true;
        } else if a == "-nommap" {
            o.use_mmap = false;
        } else if a == "-s" || a == "-s-" || a == "-s+" || (a.starts_with("-s") && a.contains('.'))
        {
            o.stats_cadence = a[2..].to_string();
        } else if a.starts_with("-m") && matches!(a.as_bytes().get(2), Some(c) if c.is_ascii_digit() || *c == b'x') {
            let m = a.as_bytes()[2];
            let method = if m == b'x' { 5 } else { (m - b'0') as i32 };
            let mut ok = (0..=5).contains(&method);
            if ok {
                o.lz = match &a[3..] {
                    "" => Lz::Index,
                    "f" => Lz::Future,
                    "o" => Lz::Io,
                    _ => {
                        ok = false;
                        Lz::Index
                    }
                };
                if ok {
                    o.method = method as u8;
                }
            }
            if !ok {
                // Not a method after all: the C++ re-reads it as `-mBYTES`,
                // the "don't hold matches longer than this" option.
                o.maximum_save = parse_mem(&a[2..], Unit::B)
                    .and_then(|v| u32::try_from(v).ok())
                    .ok_or_else(|| bad(format!("Invalid option: {a}")))?;
            }
        } else if a == "-f" {
            o.lz = Lz::Future;
        } else if a == "-a-" {
            o.accel = 0;
        } else if a.starts_with("-a") && a.as_bytes().get(2).is_some_and(|c| c.is_ascii_digit()) {
            // `-aN` or `-aN/M` (`srep.cpp:343-348`): the `bitarr` size and the
            // scan variant. Not output-neutral (see compress.rs). Both numbers
            // are `strtol(.., 0)`, as in the C++: `-a010` is 8 and `-a0x10` 16,
            // `-a08` is invalid, and after the `/` white space and a sign are
            // read and an empty value is 0 (`-a4/` is `-a4/0`). Stored like
            // the C++'s `unsigned`, so `-a4/-1` wraps.
            let invalid = || bad(format!("Invalid option: {a}"));
            let body = &a.as_bytes()[2..];
            let first = c_strto_base0(body);
            o.accel = c_long(&first).ok_or_else(invalid)? as u32;
            o.accelerator = 9000;
            let mut rest = &body[first.end..];
            if let Some(after) = rest.strip_prefix(b"/") {
                let second = c_strto_base0(after);
                o.accelerator = c_long(&second).ok_or_else(invalid)? as u32;
                rest = &after[second.end..];
            }
            if !rest.is_empty() {
                return Err(invalid());
            }
        } else if a == "-ia-" {
            o.io_accelerator = -1;
        } else if a == "-ia+" {
            o.io_accelerator = 1;
        } else if a == "-slp" || a == "-slp-" || a == "-slp+" {
            // Large-page mode: a host tuning knob with no bearing on the bytes.
        } else if a == "-hash-" || a == "-nomd5" {
            o.hash = Some(String::new());
        } else if let Some(name) = a.strip_prefix("-hash=") {
            // An empty name would select the "checksums off" descriptor by
            // accident; `-hash-` is how you ask for that.
            if name.is_empty() {
                return Err(bad(format!("Invalid option: {a}")));
            }
            o.hash = Some(name.to_string());
        } else if let Some(v) = a.strip_prefix("-vmfile=") {
            o.vmfile = Some(v.to_string());
        } else if let Some(v) = a.strip_prefix("-vmblock=") {
            o.vm_block = parse_mem(v, Unit::M).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
        } else if a == "-v" {
            o.verbosity = 1;
        } else if let Some(v) = a.strip_prefix("-v") {
            o.verbosity =
                parse_dec_int(v).ok_or_else(|| bad(format!("Invalid option: {a}")))? as i32;
        } else if a.starts_with("-pc") {
            // Progress counters, a diagnostic: parsed, not reported.
            let body = &a[3..];
            if !body.is_empty() {
                parse_mem(body, Unit::M).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
            }
        } else if let Some(v) = a.strip_prefix("-index=") {
            o.index_file = v.to_string();
        } else if let Some(v) = a.strip_prefix("-temp=") {
            o.tempfile = Some(v.to_string());
        } else if let Some(v) = a.strip_prefix("-mem") {
            o.vm_mem =
                parse_mem_option(v, Unit::M).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
        } else if let Some(v) = a.strip_prefix("-l") {
            let n = parse_mem(v, Unit::B).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
            o.min_match = length_option(a, n, "match length")?;
        } else if let Some(v) = a.strip_prefix("-c") {
            let n = parse_mem(v, Unit::B).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
            o.l = length_option(a, n, "chunk length")?;
            // `SliceHash` divides by `slice_size = L / slices_in_block`, and
            // `slices_in_block` is 8 (`hash_table.cpp:32`), so any L from 1 to
            // 7 makes that zero and the next line divides by it. The C++ dies
            // with SIGFPE there and this used to panic; both are now a plain
            // command-line error, since no such L can ever describe a slice.
            // 0 means "not given" and keeps the default.
            if o.l > 0 && o.l < SLICES_IN_BLOCK {
                return Err(bad(format!(
                    "Invalid option: {a} -- the chunk length must be 0 (default) \
                     or at least {SLICES_IN_BLOCK} bytes"
                )));
            }
        } else if let Some(v) = a.strip_prefix("-s") {
            o.declared_size =
                Some(parse_mem(v, Unit::B).ok_or_else(|| bad(format!("Invalid option: {a}")))?);
        } else if a == "-bar" {
            o.bar = true;
        } else if let Some(v) = a.strip_prefix("-b") {
            o.bufsize = parse_mem(v, Unit::M).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
        } else if a == "-d-" {
            o.dictsize = 0;
        } else if a == "-d+" {
            o.dictsize = 512 * MB;
        } else if let Some(v) = a.strip_prefix("-d") {
            let mut err: Option<CmdLineError> = None;
            for part in v.split(':') {
                // Split after the first *character*: `-dñ` used to split
                // inside the two-byte `ñ` and panic (exit 101).
                let first = part.char_indices().nth(1).map_or(part.len(), |(i, _)| i);
                let (head, tail) = part.split_at(first);
                let parsed = match head {
                    "a" => parse_dec_int(tail).map(|_| ()),
                    "c" => match parse_mem(tail, Unit::B) {
                        Some(n) => {
                            o.dict_chunk =
                                length_option(&format!("-d{part}"), n, "dictionary chunk length")?;
                            Some(())
                        }
                        None => None,
                    },
                    "l" => match parse_mem(tail, Unit::B) {
                        Some(n) => {
                            o.dict_min_match =
                                length_option(&format!("-d{part}"), n, "dictionary match length")?;
                            Some(())
                        }
                        None => None,
                    },
                    "d" => parse_mem_option(tail, Unit::M).map(|n| o.dictsize = n),
                    "h" => parse_mem_option(tail, Unit::M).map(|n| o.dict_hashsize = n),
                    _ => parse_mem_option(part, Unit::M).map(|n| o.dictsize = n),
                };
                if parsed.is_none() {
                    err = Some(bad(format!("Invalid option: -d{part}")));
                    break;
                }
            }
            if let Some(e) = err {
                return Err(e);
            }
        } else if let Some(v) = a.strip_prefix("-t") {
            // Accepted and ignored: the port is single-threaded per block and
            // the thread count was shown to be output-neutral in 4c-0.
            o.num_threads =
                parse_dec_int(v).ok_or_else(|| bad(format!("Invalid option: {a}")))? as u64;
        } else if a.starts_with("-rem") {
            // Command-line remark.
        } else if a.starts_with('-') && a != "-" {
            return Err(bad(format!("Invalid option: {a}")));
        } else {
            o.files.push(a.to_string());
        }
        i += 1;
    }

    Ok(o)
}

/// `--seed=N` (`dup_wrapper.cpp:117-132`) is `strtoull(.., 0)` with the
/// whole value required to be the number: decimal, `0x` hex or, with a
/// leading `0`, octal (`--seed=010` is 8, `--seed=08` is invalid), after
/// optional white space and a sign. The whole `u64` range is a seed, and a
/// minus wraps (`--seed=-1` is 2^64-1), as `strtoull` does. Until 2.3.0 the
/// port read `010` as 10, refused seeds above `i64::MAX`, white space and a
/// minus, and took a leading `=` (`--seed==8`) that the C++ refuses.
fn parse_seed(v: &str) -> Option<u64> {
    let n = c_strto_base0(v.as_bytes());
    if v.is_empty() || n.end == 0 || n.end != v.len() {
        return None;
    }
    let m = n.magnitude?; // ERANGE
    Some(if n.negative { m.wrapping_neg() } else { m })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(args: &[&str]) -> Result<Options, CmdLineError> {
        parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    /// `-aX[/Y]` reads both numbers with `strtol(.., 0)`, as 1.0.7 does;
    /// every expectation here is what the C++ 1.0.7 Linux build did.
    #[test]
    fn accel_is_strtol_base_0() {
        let ok = |a: &str, accel: u32, accelerator: u32| {
            let o = opts(&[a]).unwrap_or_else(|e| panic!("{a}: {}", e.0));
            assert_eq!((o.accel, o.accelerator), (accel, accelerator), "{a}");
        };
        ok("-a8", 8, 9000);
        ok("-a010", 8, 9000);
        ok("-a0010", 8, 9000);
        ok("-a0x10", 16, 9000);
        ok("-a0X10/0x2", 16, 2);
        ok("-a1/010", 1, 8);
        ok("-a4/", 4, 0);
        ok("-a4/ 8", 4, 8);
        ok("-a4/\t+8", 4, 8);
        ok("-a4/-1", 4, u32::MAX);
        ok("-a4/-0", 4, 0);
        ok("-a4294967298", 2, 9000);
        for bad in [
            "-a08",
            "-a09/2",
            "-a1/08",
            "-a1/=8",
            "-a0x",
            "-a0x/2",
            "-a4/0x",
            "-a4/ ",
            "-a4/-",
            "-a4/+",
            "-a8 ",
            "-a8x",
            "-a1/2/3",
            "-a0b101",
            "-a4/0b1",
            "-a9223372036854775808",
            "-a4/-9223372036854775809",
        ] {
            assert!(opts(&[bad]).is_err(), "{bad} was accepted");
        }
        ok("-a9223372036854775807", u32::MAX, 9000);
        ok("-a4/-9223372036854775808", 4, 0);
    }

    /// `-v`, `-t` and `-da` are `parseInt`: `=`, then decimal digits only.
    #[test]
    fn parse_int_is_decimal_digits() {
        assert_eq!(opts(&["-v010"]).unwrap().verbosity, 10);
        assert_eq!(opts(&["-v=0"]).unwrap().verbosity, 0);
        assert_eq!(opts(&["-t=08"]).unwrap().num_threads, 8);
        assert!(opts(&["-da7"]).is_ok());
        for o in ["-v", "-t", "-da"] {
            for v in [
                "",
                "=",
                "==1",
                "+1",
                "-1",
                "-0",
                "0x10",
                "1 ",
                " 1",
                "1k",
                "9223372036854775808",
            ] {
                let a = format!("{o}{v}");
                if a == "-v" {
                    continue; // -v alone is verbosity 1
                }
                assert!(opts(&[&a]).is_err(), "{a} was accepted");
            }
        }
    }

    /// `--seed=` is `strtoull(.., 0)` with nothing left over.
    #[test]
    fn seed_is_strtoull_base_0() {
        let seed = |v: &str| parse_seed(v);
        assert_eq!(seed("8"), Some(8));
        assert_eq!(seed("010"), Some(8));
        assert_eq!(seed("0x10"), Some(16));
        assert_eq!(seed("0XfF"), Some(255));
        assert_eq!(seed(" 8"), Some(8));
        assert_eq!(seed("+8"), Some(8));
        assert_eq!(seed("-1"), Some(u64::MAX));
        assert_eq!(seed("-0x1"), Some(u64::MAX));
        assert_eq!(seed("18446744073709551615"), Some(u64::MAX));
        assert_eq!(seed("0xFFFFFFFFFFFFFFFF"), Some(u64::MAX));
        assert_eq!(seed("0"), Some(0));
        for bad in [
            "",
            "=8",
            "08",
            "09",
            "0x",
            "0xg",
            "8 ",
            "8x",
            "-",
            " ",
            "0b101",
            "18446744073709551616",
            "-18446744073709551616",
        ] {
            assert_eq!(seed(bad), None, "{bad:?}");
        }
    }
}
