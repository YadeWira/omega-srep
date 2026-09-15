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

/// `-m<0|3|4|5>[f|o]` -> the compressor and the container shape. Anything else
/// is "not ported".
fn parse_mode(s: &str) -> Option<encoder::Mode> {
    let b = s.as_bytes();
    if b.len() < 2 || b[0] != b'm' {
        return None;
    }
    let kind = match b[1] {
        b'0' => encoder::Kind::Inmem,
        b'1' => encoder::Kind::Cdc,
        b'2' => encoder::Kind::CdcZpaq,
        b'3' => encoder::Kind::Digest,
        b'4' => encoder::Kind::Fixed,
        b'5' => encoder::Kind::FixedExhaustive,
        _ => return None,
    };
    let container = match &s[2..] {
        "o" => encoder::Container::IoLz,
        "" => encoder::Container::IndexLz,
        "f" => encoder::Container::FutureLz,
        "v" => encoder::Container::V5,
        _ => return None,
    };
    Some(encoder::Mode { kind, container })
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

    let parsed = match parse_mode(&mode) {
        Some(m) => m,
        None => {
            eprintln!("{mode}: not ported to Rust yet");
            return ExitCode::from(NOT_PORTED);
        }
    };

    let result = encoder::encode(&mut input, &mut output, &opts, parsed).map(|_| ());

    if result.is_ok() && parsed.container == encoder::Container::V5 {
        // v5 has no byte-for-byte oracle (the C++ cannot emit it), so every v5
        // case is checked against the *same* encoding written as Future-LZ,
        // which is byte-verified. `docs/format-spec-v5.md` §6 layer 2: the two
        // archives must carry the same matches, triple by triple.
        drop(output);
        if let Err(e) = v5_stream_equivalence(&parsed, &opts, &files[0], &files[1]) {
            eprintln!("ERROR! v5 stream equivalence: {e}");
            return ExitCode::from(1);
        }
    }

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ERROR! {e:?}");
            ExitCode::from(1)
        }
    }
}

/// Compare a v5 archive's matches against the same encoding written as
/// Future-LZ (v4). Both come from the same match finder, so if the records
/// agree the only thing v5 changed is the framing -- which is the whole point.
fn v5_stream_equivalence(
    mode: &encoder::Mode,
    opts: &EncodeOptions,
    input: &str,
    v5_archive: &str,
) -> Result<(), String> {
    // 1. Write the reference: the same kind, Future-LZ, into a sibling file.
    let reference = format!("{v5_archive}.f");
    {
        let mut fin = File::open(input).map_err(|e| e.to_string())?;
        let mut fout = BufWriter::new(File::create(&reference).map_err(|e| e.to_string())?);
        let f_mode = encoder::Mode {
            kind: mode.kind,
            container: encoder::Container::FutureLz,
        };
        encoder::encode(&mut fin, &mut fout, opts, f_mode).map_err(|e| format!("{e:?}"))?;
    }

    // 2. Both archives' per-block triples.
    let v5_bytes = std::fs::read(v5_archive).map_err(|e| e.to_string())?;
    let parsed = osrep_core::v5::parse(&v5_bytes).map_err(|e| format!("{e:?}"))?;
    let v5_triples: Vec<Vec<(u64, u64, u64)>> = parsed
        .blocks
        .iter()
        .map(|b| {
            b.records
                .iter()
                .map(|r| (r.lit_len, r.match_len, r.distance))
                .collect()
        })
        .collect();

    let ref_bytes = std::fs::read(&reference).map_err(|e| e.to_string())?;
    let ref_triples = future_lz_triples(&ref_bytes)?;

    let _ = std::fs::remove_file(&reference);

    // 3. Same blocks, same matches, in the same order.
    if v5_triples.len() != ref_triples.len() {
        return Err(format!(
            "block count differs: v5 {} vs future-lz {}",
            v5_triples.len(),
            ref_triples.len()
        ));
    }
    for (b, (a, r)) in v5_triples.iter().zip(ref_triples.iter()).enumerate() {
        if a != r {
            let at = a
                .iter()
                .zip(r.iter())
                .position(|(x, y)| x != y)
                .unwrap_or(a.len().min(r.len()));
            return Err(format!(
                "block {b} match {at} differs: v5 {:?} vs future-lz {:?} ({} vs {} matches)",
                a.get(at),
                r.get(at),
                a.len(),
                r.len()
            ));
        }
    }
    Ok(())
}

/// Walk a Future-LZ (v4 `f`) archive and return each block's
/// `(lit_len, match_len, distance)` triples. The records there are the four
/// `STAT`s v4 uses, with base 0 and no rounding (`srep.cpp:458`), so the triple
/// is read straight out of the words.
fn future_lz_triples(bytes: &[u8]) -> Result<Vec<Vec<(u64, u64, u64)>>, String> {
    let header = osrep_core::container::ArchiveHeader::decode(bytes)
        .map_err(|e| format!("{e:?}"))?;
    let hash = osrep_core::container::hash_by_num(header.hash_num)
        .ok_or_else(|| format!("unknown hash {}", header.hash_num))?;
    let hash_size = header.hash_size as usize;
    let mut pos = osrep_core::container::ARCHIVE_HEADER_SIZE + header.hash_seed_size as usize;
    let block_header_size = osrep_core::container::BLOCK_HEADER_SIZE;
    let mut out = Vec::new();
    while pos + block_header_size + hash_size <= bytes.len() {
        let literal_bytes =
            u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
        let _origsize = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap());
        let statsize = u32::from_le_bytes(bytes[pos + 8..pos + 12].try_into().unwrap()) as usize;
        pos += block_header_size + hash_size;
        if pos + statsize + literal_bytes > bytes.len() {
            return Err("truncated future-lz block".into());
        }
        let words = &bytes[pos..pos + statsize];
        pos += statsize + literal_bytes;
        let mut triples = Vec::new();
        let mut w = 0usize;
        while w + 16 <= words.len() {
            let lit = u32::from_le_bytes(words[w..w + 4].try_into().unwrap()) as u64;
            let lo = u32::from_le_bytes(words[w + 4..w + 8].try_into().unwrap()) as u64;
            let hi = u32::from_le_bytes(words[w + 8..w + 12].try_into().unwrap()) as u64;
            let len = u32::from_le_bytes(words[w + 12..w + 16].try_into().unwrap()) as u64;
            triples.push((lit, len, lo | (hi << 32)));
            w += 16;
        }
        out.push(triples);
        let _ = hash;
    }
    Ok(out)
}
