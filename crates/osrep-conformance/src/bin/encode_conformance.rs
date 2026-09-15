//! Rust mirror of the C++ `osrep` encoder, narrowed to what the differential
//! harness drives: for the same arguments it must produce the same archive
//! bytes, so `tests/encode_conformance.sh` can diff the two.
//!
//!   encode_conformance <mode> [--seed=N] [-dN] [-bN] [-lN] [-cN] [-hash=NAME] <in> <out>
//!
//! Modes not ported yet exit with status 3, which the harness reports as "not
//! ported" rather than as a failure. The seed is required for keyed hashes:
//! without `--seed=N` the C++ draws the key from Fortuna, which no port can
//! reproduce.

use std::fs::File;
use std::io::{BufReader, BufWriter};
use std::process::ExitCode;

use osrep_core::encoder::{self, EncodeOptions, DEFAULT_DICTSIZE};

const NOT_PORTED: u8 = 3;

/// `parseMem` (`Common.h`), narrowed to the suffixes the harness uses. The
/// two-letter forms ("16mb") are the ones the tests write, so they must be
/// stripped before the single-letter ones.
fn parse_mem(s: &str) -> u64 {
    let lower = s.to_ascii_lowercase();
    let (digits, mul) = if let Some(x) = lower.strip_suffix("gb") {
        (x, 1024 * 1024 * 1024)
    } else if let Some(x) = lower.strip_suffix("mb") {
        (x, 1024 * 1024)
    } else if let Some(x) = lower.strip_suffix("kb") {
        (x, 1024)
    } else if let Some(x) = lower.strip_suffix('g') {
        (x, 1024 * 1024 * 1024)
    } else if let Some(x) = lower.strip_suffix('m') {
        (x, 1024 * 1024)
    } else if let Some(x) = lower.strip_suffix('k') {
        (x, 1024)
    } else {
        (lower.as_str(), 1)
    };
    digits.parse::<u64>().unwrap_or(0).saturating_mul(mul)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!(
            "usage: {} <mode> [--seed=N] [-dN] [-bN] [-lN] [-cN] [-hash=NAME] <in> <out>",
            args[0]
        );
        return ExitCode::from(2);
    }
    let mode = args[1].clone();

    let mut opts = EncodeOptions::default();
    let mut files: Vec<String> = Vec::new();
    for a in &args[2..] {
        if let Some(v) = a.strip_prefix("--seed=") {
            match v.parse::<u64>() {
                Ok(n) => opts.seed = Some(n),
                Err(_) => {
                    eprintln!("bad --seed value: {v}");
                    return ExitCode::from(2);
                }
            }
        } else if let Some(v) = a.strip_prefix("-dh") {
            opts.dict_hashsize = parse_mem(v);
        } else if let Some(v) = a.strip_prefix("-dl") {
            opts.dict_min_match = parse_mem(v) as usize;
        } else if let Some(v) = a.strip_prefix("-dc") {
            opts.dict_chunk = parse_mem(v) as usize;
        } else if let Some(v) = a.strip_prefix("-d") {
            opts.dictsize = parse_mem(v);
        } else if let Some(v) = a.strip_prefix("-b") {
            opts.bufsize = parse_mem(v) as usize;
        } else if let Some(v) = a.strip_prefix("-l") {
            opts.min_match = parse_mem(v) as usize;
        } else if let Some(v) = a.strip_prefix("-c") {
            opts.l = parse_mem(v) as usize;
        } else if let Some(v) = a.strip_prefix("-hash=") {
            opts.hash = v.to_string();
        } else if a == "-hash-" {
            opts.hash = String::new();
        } else if !a.starts_with('-') {
            files.push(a.clone());
        } else {
            eprintln!("unknown option: {a}");
            return ExitCode::from(2);
        }
    }
    if files.len() != 2 {
        eprintln!("need exactly <in> <out>");
        return ExitCode::from(2);
    }

    // `-m0` without `-d` uses the 512 MiB default (`srep.cpp:445`); the other
    // modes leave `dictsize` at zero, which is what "no dictionary" means for
    // them.
    if mode.starts_with("m0") && opts.dictsize == 0 {
        opts.dictsize = DEFAULT_DICTSIZE;
    }

    let mut input = match File::open(&files[0]) {
        Ok(f) => BufReader::new(f),
        Err(e) => {
            eprintln!("{}: {e}", files[0]);
            return ExitCode::from(1);
        }
    };
    let output = match File::create(&files[1]) {
        Ok(f) => BufWriter::new(f),
        Err(e) => {
            eprintln!("{}: {e}", files[1]);
            return ExitCode::from(1);
        }
    };
    let mut output = output;

    let result = match mode.as_str() {
        "m0o" => encoder::encode_io_lz(&mut input, &mut output, &opts, encoder::Mode::Inmem).map(|_| ()),
        "m4o" => encoder::encode_io_lz(&mut input, &mut output, &opts, encoder::Mode::Fixed).map(|_| ()),
        "m5o" => {
            encoder::encode_io_lz(&mut input, &mut output, &opts, encoder::Mode::FixedExhaustive)
                .map(|_| ())
        }
        other => {
            eprintln!("{other}: not ported to Rust yet");
            return ExitCode::from(NOT_PORTED);
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ERROR! {e:?}");
            ExitCode::from(1)
        }
    }
}
