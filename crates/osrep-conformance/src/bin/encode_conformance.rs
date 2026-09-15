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
            "usage: {} <mode> [--seed=N] [--dup] [-dN] [-bN] [-lN] [-cN] [-hash=NAME] <in> <out>",
            args[0]
        );
        return ExitCode::from(2);
    }
    let mode = args[1].clone();

    let mut opts = EncodeOptions::default();
    let mut files: Vec<String> = Vec::new();
    // `-dup`: run the dedup pre-pass and let its meta travel with the archive.
    // Checked before the `-d` prefix below, which would otherwise swallow it.
    let mut dup = false;
    for a in &args[2..] {
        if let Some(v) = a.strip_prefix("--seed=") {
            match v.parse::<u64>() {
                Ok(n) => opts.seed = osrep_core::encoder::Seed::Value(n),
                Err(_) => {
                    eprintln!("bad --seed value: {v}");
                    return ExitCode::from(2);
                }
            }
        } else if a == "--dup" {
            dup = true;
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

    if dup {
        // The handles above are for the plain path; `dup::encode` opens its
        // own, and on Windows the output cannot be held open twice.
        drop(input);
        drop(output);
        let dup_mode = match parsed.container {
            encoder::Container::V5 => osrep_core::dup::DupMode::V5,
            // The ODUP trailer is defined against the default Index-LZ archive
            // and nothing else.
            encoder::Container::IndexLz => osrep_core::dup::DupMode::V4,
            _ => {
                eprintln!("{mode}: -dup needs the v5 (`v`) or the default (no suffix) container");
                return ExitCode::from(NOT_PORTED);
            }
        };
        if let Err(e) = osrep_core::dup::encode(
            std::path::Path::new(&files[0]),
            std::path::Path::new(&files[1]),
            &opts,
            parsed,
            osrep_core::dup::DupParams::default(),
            dup_mode,
            None,
        ) {
            eprintln!("ERROR! {e:?}");
            return ExitCode::from(1);
        }
        if let Err(e) = dup_round_trip(&files[0], &files[1]) {
            eprintln!("ERROR! -dup round-trip: {e}");
            return ExitCode::from(1);
        }
        return ExitCode::SUCCESS;
    }

    let result = encoder::encode(&mut input, &mut output, &opts, parsed, None).map(|_| ());

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
        if let Err(e) = v5_round_trip(&files[0], &files[1]) {
            eprintln!("ERROR! v5 round-trip: {e}");
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

/// `encode -> decode == input` for a `-dup` archive, through the same wrapper
/// the CLI would call: the dedup post-pass included, which is the part that
/// reads the meta blob back out.
fn dup_round_trip(input: &str, archive: &str) -> Result<(), String> {
    let original = std::fs::read(input).map_err(|e| e.to_string())?;
    let out = format!("{archive}.dec");
    let opts = osrep_core::future_lz::FutureLzOptions::default();
    let ran = osrep_core::dup::decode(
        std::path::Path::new(archive),
        std::path::Path::new(&out),
        &opts,
    )
    .map_err(|e| format!("{e:?}"))?;
    if !ran {
        return Err("the archive was not recognised as a -dup one".into());
    }
    let decoded = std::fs::read(&out).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(&out);
    if decoded != original {
        return Err(format!(
            "decoded {} bytes, expected {}",
            decoded.len(),
            original.len()
        ));
    }
    Ok(())
}

/// `encode -> decode == input`, through the real v5 decoder: the one that
/// resolves source-anchored matches with the VM, like v3/v4.
fn v5_round_trip(input: &str, archive: &str) -> Result<(), String> {
    let original = std::fs::read(input).map_err(|e| e.to_string())?;
    let bytes = std::fs::read(archive).map_err(|e| e.to_string())?;
    let opts = osrep_core::future_lz::FutureLzOptions::default();
    let decoded =
        osrep_core::future_lz::decode_v5_to_vec(&bytes, &opts).map_err(|e| e.to_string())?;
    if decoded != original {
        return Err(format!(
            "decoded {} bytes, expected {}",
            decoded.len(),
            original.len()
        ));
    }
    Ok(())
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
        encoder::encode(&mut fin, &mut fout, opts, f_mode, None).map_err(|e| format!("{e:?}"))?;
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
