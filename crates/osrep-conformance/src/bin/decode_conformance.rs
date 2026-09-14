//! End-to-end check for the Rust I/O-LZ decoder against archives written by
//! the real C++ encoder.
//!
//! Usage:
//!   decode_conformance io-lz <archive.osr> <output>
//!
//! Decodes the archive and writes the result to `<output>`, printing
//! `ok blocks=N origsize=M verified=0|1`. Exits non-zero on any error, so a
//! shell harness can diff the output against the original input.

use std::fs::File;
use std::io::BufReader;
use std::process::ExitCode;

use osrep_core::decompress::decode_io_lz;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 || args[1] != "io-lz" {
        eprintln!("usage: decode_conformance io-lz <archive.osr> <output>");
        return ExitCode::from(2);
    }

    let input = match File::open(&args[2]) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{}: {e}", args[2]);
            return ExitCode::FAILURE;
        }
    };
    // Read AND write: the decoder seeks back into the output to resolve matches
    // that start in an earlier block, so this mirrors the C++'s `fopen(..., "w+b")`
    // (`srep.cpp:586`). A write-only file fails with EBADF on the first back-read.
    let mut sink = match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&args[3])
    {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{}: {e}", args[3]);
            return ExitCode::FAILURE;
        }
    };

    match decode_io_lz(&mut BufReader::new(input), &mut sink) {
        Ok(stats) => {
            println!(
                "ok blocks={} origsize={} verified={}",
                stats.blocks,
                stats.origsize,
                u8::from(stats.verified)
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("decode_conformance: {e}");
            ExitCode::FAILURE
        }
    }
}
