//! Differential harness: a Rust mirror of `tests/dedup_test.cpp`'s CLI.
//!
//! It deliberately reproduces the C++ tool's command names, options and
//! stdout/stderr text, so `tests/rust_conformance.sh` can run both on the
//! same inputs and `cmp` the produced files (and diff the messages).
//! Passing means the Rust port agrees with the shipped C++ byte-for-byte,
//! not merely that it round-trips.

use std::fs;
use std::path::Path;
use std::process::ExitCode;

use osrep_core::dedup::{self, Params};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!(
            "usage: {} {{selftest|encode|decode|split-encode|split-decode|decode-streaming|encode-streaming}} ...",
            args[0]
        );
        return ExitCode::from(2);
    }
    let rc = match args[1].as_str() {
        "selftest" => selftest(),
        "encode" => cmd_encode(&args),
        "decode" => cmd_decode(&args),
        "split-encode" => cmd_split_encode(&args),
        "split-decode" => cmd_split_decode(&args),
        "decode-streaming" => cmd_decode_streaming(&args),
        "encode-streaming" => cmd_encode_streaming(&args),
        other => {
            eprintln!("unknown command: {other}");
            2
        }
    };
    ExitCode::from(rc as u8)
}

fn read_file(path: &str) -> Result<Vec<u8>, i32> {
    fs::read(path).map_err(|e| {
        eprintln!("{path}: {e}");
    })
    .map_err(|_| 1)
}

fn write_file(path: &str, buf: &[u8]) -> i32 {
    match fs::write(path, buf) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("{path}: {e}");
            1
        }
    }
}

/// xorshift64 -- deterministic, locale-independent (matches dedup_test.cpp).
fn xorshift64(s: &mut u64) -> u64 {
    let mut x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *s = x;
    x
}

fn fill_random(n: usize, seed: u64) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    let mut s = if seed != 0 { seed } else { 1 };
    for b in buf.iter_mut() {
        *b = (xorshift64(&mut s) & 0xFF) as u8;
    }
    buf
}

fn parse_hash(v: &str) -> Option<i32> {
    match v {
        "fnv" => Some(dedup::CDC_HASH_FNV),
        "gear" => Some(dedup::CDC_HASH_GEAR),
        _ => None,
    }
}

/// Parse the shared `--avg/--min/--max/--buf/--hash` tail starting at
/// `from`. Returns (params, paranoid, consumed_to_end).
fn parse_opts(args: &[String], from: usize, usage: &str) -> Result<(Params, bool), i32> {
    let mut p = Params::default();
    let mut paranoid = false;
    let mut i = from;
    while i < args.len() {
        // --paranoid takes no value, so it must be handled before the
        // "missing value" check below (it would otherwise trip on itself
        // when it is the last argument).
        if args[i] == "--paranoid" {
            paranoid = true;
            i += 1;
            continue;
        }
        if i + 1 >= args.len() {
            eprintln!("missing value for {}", args[i]);
            return Err(2);
        }
        let val = &args[i + 1];
        match args[i].as_str() {
            "--avg" => p.avg = val.parse().unwrap_or(0),
            "--min" => p.min_chunk = val.parse().unwrap_or(0),
            "--max" => p.max_chunk = val.parse().unwrap_or(0),
            "--buf" => p.buf_size = val.parse().unwrap_or(0),
            "--hash" => match parse_hash(val) {
                Some(h) => p.hash_algo = h,
                None => {
                    eprintln!("bad --hash value: {val} (want fnv|gear)");
                    return Err(2);
                }
            },
            other => {
                eprintln!("unknown flag: {other}\n{usage}");
                return Err(2);
            }
        }
        i += 2;
    }
    Ok((p, paranoid))
}

fn selftest() -> i32 {
    let mut cases: Vec<(&str, Vec<u8>)> = Vec::new();
    cases.push(("empty", Vec::new()));
    cases.push(("zeros-64k", vec![0u8; 65536]));
    {
        let unit = b"Omega SREP dup test payload ";
        let mut data = vec![0u8; 1_000_000];
        for (i, b) in data.iter_mut().enumerate() {
            *b = unit[i % unit.len()];
        }
        cases.push(("text-1m", data));
    }
    {
        let mut data = Vec::with_capacity(819200);
        for _ in 0..100 {
            data.extend_from_slice(&[b'A'; 4096]);
            data.extend_from_slice(&[b'B'; 4096]);
        }
        cases.push(("dup-pattern", data));
    }
    cases.push(("random-256k", fill_random(262144, 42)));
    {
        let half = fill_random(131072, 7);
        let mut data = Vec::with_capacity(262144);
        data.extend_from_slice(&half);
        data.extend_from_slice(&half);
        cases.push(("doubled-random-256k", data));
    }

    println!("{:<22} {:>8} {:>9} {:>8}", "case", "in_size", "enc_size", "enc_pct");
    for (name, data) in &cases {
        match dedup::encode(data, Params::default()) {
            Ok(enc) => match dedup::decode(&enc) {
                Ok(dec) => {
                    if dec != *data {
                        eprintln!("{name}: round-trip mismatch (in={} out={})", data.len(), dec.len());
                        return 1;
                    }
                    let pct = if data.is_empty() {
                        0
                    } else {
                        (100 * enc.len()) / data.len()
                    };
                    println!("{:<22} {:>8} {:>9} {:>7}%", name, data.len(), enc.len(), pct);
                }
                Err(rc) => {
                    eprintln!("{name}: decode failed rc={rc}");
                    return 1;
                }
            },
            Err(rc) => {
                eprintln!("{name}: encode failed rc={rc}");
                return 1;
            }
        }
    }
    println!("all round-trips OK");
    0
}

fn cmd_encode(args: &[String]) -> i32 {
    let usage = "usage: encode <in> <out> [--avg N --min N --max N --buf N --hash fnv|gear]";
    if args.len() < 4 {
        eprintln!("{usage}");
        return 2;
    }
    let (p, _) = match parse_opts(args, 4, usage) {
        Ok(v) => v,
        Err(rc) => return rc,
    };
    let data = match read_file(&args[2]) {
        Ok(d) => d,
        Err(rc) => return rc,
    };
    match dedup::encode(&data, p) {
        Ok(enc) => {
            let ratio = if data.is_empty() {
                0.0
            } else {
                enc.len() as f64 / data.len() as f64
            };
            println!("input={} output={} ratio={:.4}", data.len(), enc.len(), ratio);
            write_file(&args[3], &enc)
        }
        Err(rc) => {
            eprintln!("encode failed rc={rc}");
            1
        }
    }
}

fn cmd_decode(args: &[String]) -> i32 {
    if args.len() < 4 {
        eprintln!("usage: decode <in> <out>");
        return 2;
    }
    let blob = match read_file(&args[2]) {
        Ok(d) => d,
        Err(rc) => return rc,
    };
    match dedup::decode(&blob) {
        Ok(dec) => {
            println!("input={} output={}", blob.len(), dec.len());
            write_file(&args[3], &dec)
        }
        Err(rc) => {
            eprintln!("decode failed rc={rc}");
            1
        }
    }
}

fn cmd_split_encode(args: &[String]) -> i32 {
    let usage = "usage: split-encode <in> <meta> <body> [--avg N --min N --max N --buf N --hash fnv|gear]";
    if args.len() < 5 {
        eprintln!("{usage}");
        return 2;
    }
    let (p, _) = match parse_opts(args, 5, usage) {
        Ok(v) => v,
        Err(rc) => return rc,
    };
    let data = match read_file(&args[2]) {
        Ok(d) => d,
        Err(rc) => return rc,
    };
    match dedup::encode_split(&data, p) {
        Ok((meta, body)) => {
            println!("input={} meta={} body={}", data.len(), meta.len(), body.len());
            let a = write_file(&args[3], &meta);
            let b = write_file(&args[4], &body);
            a | b
        }
        Err(rc) => {
            eprintln!("encode_split rc={rc}");
            1
        }
    }
}

fn cmd_split_decode(args: &[String]) -> i32 {
    if args.len() < 5 {
        eprintln!("usage: split-decode <meta> <body> <out>");
        return 2;
    }
    let meta = match read_file(&args[2]) {
        Ok(d) => d,
        Err(rc) => return rc,
    };
    let body = match read_file(&args[3]) {
        Ok(d) => d,
        Err(rc) => return rc,
    };
    match dedup::decode_split(&meta, &body) {
        Ok(out) => {
            println!("meta={} body={} output={}", meta.len(), body.len(), out.len());
            write_file(&args[4], &out)
        }
        Err(rc) => {
            eprintln!("decode_split rc={rc}");
            1
        }
    }
}

fn cmd_decode_streaming(args: &[String]) -> i32 {
    if args.len() < 5 {
        eprintln!("usage: decode-streaming <meta> <body> <out>");
        return 2;
    }
    let meta = match read_file(&args[2]) {
        Ok(d) => d,
        Err(rc) => return rc,
    };
    match dedup::decode_streaming(&meta, Path::new(&args[3]), Path::new(&args[4])) {
        Ok(()) => {
            println!("meta={} ok", meta.len());
            0
        }
        Err(rc) => {
            eprintln!("decode_streaming rc={rc}");
            1
        }
    }
}

fn cmd_encode_streaming(args: &[String]) -> i32 {
    let usage = "usage: encode-streaming <in> <meta> <body> [--avg N --min N --max N --buf N --hash fnv|gear] [--paranoid]";
    if args.len() < 5 {
        eprintln!("{usage}");
        return 2;
    }
    let (p, paranoid) = match parse_opts(args, 5, usage) {
        Ok(v) => v,
        Err(rc) => return rc,
    };
    let in_len = match fs::metadata(&args[2]) {
        Ok(m) => m.len(),
        Err(e) => {
            eprintln!("{}: {e}", args[2]);
            return 1;
        }
    };
    match dedup::encode_streaming(Path::new(&args[2]), Path::new(&args[4]), p, paranoid) {
        Ok(meta) => {
            let body_len = fs::metadata(&args[4]).map(|m| m.len()).unwrap_or(0);
            println!("input={in_len} meta={} body={body_len}", meta.len());
            write_file(&args[3], &meta)
        }
        Err(rc) => {
            eprintln!("encode_streaming rc={rc}");
            1
        }
    }
}
