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

fn parse_int(s: &str) -> Option<i64> {
    let s = s.strip_prefix('=').unwrap_or(s);
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        i64::from_str_radix(hex, 16).ok()
    } else {
        s.parse::<i64>().ok()
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
            // `-aN` or `-aN/M`; both are output-neutral (docs/rust-port.md, the
            // phase 4c pre-port experiments), so only the syntax is checked.
            let body = &a[2..];
            let (accel, rest) = match body.split_once('/') {
                Some((l, r)) => (l, Some(r)),
                None => (body, None),
            };
            parse_int(accel).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
            if let Some(r) = rest {
                parse_int(r).ok_or_else(|| bad(format!("Invalid option: {a}")))?;
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
            o.verbosity = parse_int(v).ok_or_else(|| bad(format!("Invalid option: {a}")))? as i32;
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
            o.min_match =
                parse_mem(v, Unit::B).ok_or_else(|| bad(format!("Invalid option: {a}")))? as usize;
        } else if let Some(v) = a.strip_prefix("-c") {
            o.l = parse_mem(v, Unit::B).ok_or_else(|| bad(format!("Invalid option: {a}")))? as usize;
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
                let (head, tail) = part.split_at(part.len().min(1));
                let parsed = match head {
                    "a" => parse_int(tail).map(|_| ()),
                    "c" => parse_mem(tail, Unit::B).map(|n| o.dict_chunk = n as usize),
                    "l" => parse_mem(tail, Unit::B).map(|n| o.dict_min_match = n as usize),
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
                parse_int(v).ok_or_else(|| bad(format!("Invalid option: {a}")))? as u64;
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

/// `--seed=N` accepts decimal or `0x`-prefixed hex (`dup_wrapper.cpp:117-132`).
fn parse_seed(v: &str) -> Option<u64> {
    if v.is_empty() {
        return None;
    }
    parse_int(v).and_then(|n| u64::try_from(n).ok())
}
