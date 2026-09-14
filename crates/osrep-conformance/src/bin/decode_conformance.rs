//! End-to-end check for the Rust decoders against archives written by the real
//! C++ encoder.
//!
//! Usage:
//!   decode_conformance io-lz <archive.osr> <output>
//!   decode_conformance future-lz <archive.osr> <output> [--mem=N] [--vmblock=N] [--maxsave=N]
//!
//! Decodes the archive and writes the result to `<output>`, printing
//! `ok blocks=N origsize=M verified=0|1`. Exits non-zero on any error, so a
//! shell harness can diff the output against the original input.
//!
//! The `future-lz` options exist to force the VM spill path: the defaults never
//! spill on ordinary inputs, so `--mem`/`--vmblock` shrink the budget until they
//! do. Spilling only changes where a held match lives, never the decoded bytes,
//! so the output must still equal the input.

use std::fs::File;
use std::io::BufReader;
use std::process::ExitCode;

use osrep_core::decompress::decode_io_lz;
use osrep_core::future_lz::{decode_future_lz, FutureLzOptions, FutureLzStats};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!(
            "usage: decode_conformance {{io-lz|future-lz}} <archive.osr> <output> [--mem=N] [--vmblock=N] [--maxsave=N]"
        );
        return ExitCode::from(2);
    }

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

    let result = match args[1].as_str() {
        "io-lz" => {
            let input = match File::open(&args[2]) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("{}: {e}", args[2]);
                    return ExitCode::FAILURE;
                }
            };
            // I/O-LZ has no memory manager, so its spill counters stay zero.
            decode_io_lz(&mut BufReader::new(input), &mut sink).map(|decode| FutureLzStats {
                decode,
                vm_bytes_written: 0,
                vm_bytes_read: 0,
            })
        }
        "future-lz" => {
            let mut opts = FutureLzOptions::default();
            for arg in &args[4..] {
                let (key, value) = match arg.split_once('=') {
                    Some(kv) => kv,
                    None => {
                        eprintln!("expected --key=value, got {arg}");
                        return ExitCode::from(2);
                    }
                };
                let parsed = match value.parse::<u64>() {
                    Ok(v) => v,
                    Err(_) => {
                        eprintln!("{arg}: not a number");
                        return ExitCode::from(2);
                    }
                };
                match key {
                    "--mem" => opts.mem_limit = parsed,
                    "--vmblock" => opts.vm_block = parsed,
                    "--maxsave" => opts.maximum_save = parsed as u32,
                    other => {
                        eprintln!("unknown option {other}");
                        return ExitCode::from(2);
                    }
                }
            }
            let input = match File::open(&args[2]) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("{}: {e}", args[2]);
                    return ExitCode::FAILURE;
                }
            };
            decode_future_lz(&mut BufReader::new(input), &mut sink, &opts)
        }
        other => {
            eprintln!("unknown mode: {other}");
            return ExitCode::from(2);
        }
    };

    match result {
        Ok(stats) => {
            print!(
                "ok blocks={} origsize={} verified={}",
                stats.decode.blocks,
                stats.decode.origsize,
                u8::from(stats.decode.verified)
            );
            // The spill counters are only meaningful for future-lz; io-lz has
            // no memory manager to report.
            if args[1] == "future-lz" {
                print!(
                    " vmw={} vmr={}",
                    stats.vm_bytes_written, stats.vm_bytes_read
                );
            }
            println!();
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("decode_conformance: {e}");
            ExitCode::FAILURE
        }
    }
}
