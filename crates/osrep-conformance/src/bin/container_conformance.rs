//! Differential/structural check for `osrep-core::container` against archives
//! produced by the real C++ encoder.
//!
//! Usage:
//!   container_conformance dump  <archive.osr>
//!   container_conformance check <archive.osr>
//!   container_conformance trailer <archive.osr>
//!
//! `dump` prints one `key=value` per line so a shell harness can assert on
//! individual fields. `check` proves the codec is byte-exact in both
//! directions -- it re-encodes the header and the v4 footer and requires them
//! to reproduce the bytes already in the file -- and exits non-zero on any
//! disagreement. `trailer` reports whether a `-dup` ODUP trailer is present.

use std::fs;
use std::process::ExitCode;

use osrep_core::container::{split_trailer, Archive, Trailer};

fn load(path: &str) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|e| format!("{path}: {e}"))
}

fn dump(path: &str) -> Result<(), String> {
    let raw = load(path)?;
    let mut odup = 0u8;
    let bytes: &[u8] = match split_trailer(&raw).map_err(|e| e.to_string())? {
        Trailer::Plain => &raw,
        Trailer::Odup { body_len, .. } => {
            odup = 1;
            &raw[..body_len]
        }
    };
    let a = Archive::parse(bytes).map_err(|e| e.to_string())?;
    let h = a.header;
    let name = h.hash().map(|d| d.name).unwrap_or("?");
    let mode = if h.version.index_lz() {
        "index"
    } else if h.version.future_lz() {
        "future"
    } else {
        "io"
    };
    println!("version={}", h.version.code());
    println!("mode={mode}");
    println!("hash={name}");
    println!("hash_num={}", h.hash_num);
    println!("seed={}", h.hash_seed_size);
    println!("digest={}", h.hash_size);
    println!("base_len={}", h.base_len);
    println!("blocks={}", a.blocks.len());
    println!("origsize={}", a.origsize());
    println!("literal={}", a.literal_bytes());
    println!("stat_size={}", a.total_stat_size);
    println!(
        "footer_size={}",
        a.footer.as_ref().map_or(0, |f| f.footer_size())
    );
    println!("trailing={}", a.trailing_bytes);
    println!("file={}", raw.len());
    println!("odup={odup}");
    Ok(())
}

/// Re-encode and compare against the file, then require the framing to close.
fn check(path: &str) -> Result<(), String> {
    let raw = load(path)?;
    let bytes = match split_trailer(&raw).map_err(|e| e.to_string())? {
        Trailer::Plain => raw.as_slice(),
        Trailer::Odup { body_len, .. } => &raw[..body_len],
    };
    let a = Archive::parse(bytes).map_err(|e| e.to_string())?;

    // The header must re-encode to the bytes that are actually there.
    let want = a.header_bytes();
    if bytes[..want.len()] != want {
        return Err(format!(
            "header re-encode mismatch: got {:02x?}, want {:02x?}",
            &bytes[..want.len()],
            want
        ));
    }

    // The v4 footer + table must likewise reproduce the file tail exactly.
    if let Some(footer_bytes) = a.footer_bytes() {
        let tail = &bytes[bytes.len() - footer_bytes.len()..];
        if tail != footer_bytes.as_slice() {
            return Err("footer re-encode mismatch".to_string());
        }
    }

    if a.trailing_bytes != 0 {
        return Err(format!(
            "{} trailing bytes after the last block",
            a.trailing_bytes
        ));
    }

    println!(
        "ok version={} blocks={} origsize={}",
        a.header.version.code(),
        a.blocks.len(),
        a.origsize()
    );
    Ok(())
}

fn trailer(path: &str) -> Result<(), String> {
    let raw = load(path)?;
    match split_trailer(&raw).map_err(|e| e.to_string())? {
        Trailer::Plain => println!("plain"),
        Trailer::Odup { body_len, meta } => {
            println!("odup body={body_len} meta={}", meta.len())
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: container_conformance <dump|check|trailer> <archive.osr>");
        return ExitCode::from(2);
    }
    let result = match args[1].as_str() {
        "dump" => dump(&args[2]),
        "check" => check(&args[2]),
        "trailer" => trailer(&args[2]),
        other => {
            eprintln!("unknown subcommand: {other}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("container_conformance: {e}");
            ExitCode::FAILURE
        }
    }
}
