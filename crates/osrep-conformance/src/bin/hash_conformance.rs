//! Rust mirror of `tests/hash_test.cpp`.
//!
//!   hash_conformance <algo> <seed-hex|none> <input-file>
//!
//! Prints the digest as lowercase hex, exactly like the C++ tool, so
//! `tests/rust_conformance.sh` can diff the two. Algorithms that are not
//! ported yet exit with status 3 and a message on stderr, which the
//! harness reports as "not ported" rather than as a failure.

use std::fs;
use std::process::ExitCode;

use osrep_core::aes;
use osrep_core::hashes;
use osrep_core::hashes_keyed;
use osrep_core::vmac;

const NOT_PORTED: u8 = 3;

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: {} <algo> <seed-hex|none> <input-file>", args[0]);
        return ExitCode::from(2);
    }
    let algo = args[1].as_str();

    let seed_len = match algo {
        "md5" | "sha1" | "sha512" => 0usize,
        "vmac" => 32,
        "siphash" => 16,
        "aes" => 32,
        other => {
            eprintln!("unknown hash: {other} (want vmac(default)/siphash/md5/sha1/sha512)");
            return ExitCode::from(2);
        }
    };

    // Parse the seed the same way the C++ tool does, so a mismatch in the
    // harness is always a digest mismatch and never a parsing difference.
    let seed = if args[2] == "none" {
        Vec::new()
    } else {
        let h = args[2].as_bytes();
        if h.len() % 2 != 0 {
            eprintln!("seed hex must have an even length");
            return ExitCode::from(2);
        }
        let mut v = Vec::with_capacity(h.len() / 2);
        let nib = |c: u8| -> Option<u8> {
            match c {
                b'0'..=b'9' => Some(c - b'0'),
                b'a'..=b'f' => Some(c - b'a' + 10),
                b'A'..=b'F' => Some(c - b'A' + 10),
                _ => None,
            }
        };
        for pair in h.chunks_exact(2) {
            match (nib(pair[0]), nib(pair[1])) {
                (Some(hi), Some(lo)) => v.push((hi << 4) | lo),
                _ => {
                    eprintln!("bad hex in seed");
                    return ExitCode::from(2);
                }
            }
        }
        v
    };
    if seed.len() != seed_len {
        eprintln!("{algo} needs a {seed_len}-byte seed, got {}", seed.len());
        return ExitCode::from(2);
    }

    let data = match fs::read(&args[3]) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{}: {e}", args[3]);
            return ExitCode::from(1);
        }
    };

    let digest: String = match algo {
        "md5" => hex(&hashes::md5(&data)),
        "sha1" => hex(&hashes::sha1(&data)),
        "sha512" => hex(&hashes::sha512(&data)),
        "siphash" => {
            let mut key = [0u8; hashes_keyed::SIPHASH_KEY_LEN_BYTES];
            key.copy_from_slice(&seed);
            hex(&hashes_keyed::siphash(&key, &data))
        }
        "vmac" => {
            let mut key = [0u8; vmac::VMAC_KEY_LEN_BYTES];
            key.copy_from_slice(&seed);
            hex(&vmac::Vmac::new(&key).compute(&data))
        }
        "aes" => {
            // AES-256 ECB over the whole input, block by block, mirroring the
            // `aes` mode of tests/hash_test.cpp (the key is the seed).
            if data.len() % aes::AES_BLOCK_SIZE != 0 {
                eprintln!(
                    "aes input must be a multiple of 16 bytes, got {}",
                    data.len()
                );
                return ExitCode::from(2);
            }
            let mut key = [0u8; aes::AES256_KEY_LEN];
            key.copy_from_slice(&seed);
            let cipher = aes::Aes256::new(&key);
            let mut out = Vec::with_capacity(data.len());
            let mut ct = [0u8; aes::AES_BLOCK_SIZE];
            for chunk in data.chunks_exact(aes::AES_BLOCK_SIZE) {
                let pt: [u8; aes::AES_BLOCK_SIZE] = chunk.try_into().unwrap();
                cipher.encrypt_block(&pt, &mut ct);
                out.extend_from_slice(&ct);
            }
            hex(&out)
        }
        other => {
            eprintln!("{other}: not ported to Rust yet");
            return ExitCode::from(NOT_PORTED);
        }
    };
    println!("{digest}");
    ExitCode::SUCCESS
}
