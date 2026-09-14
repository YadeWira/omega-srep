//! Omega SREP command line -- Rust port.
//!
//! Only the pieces that exist are wired up; everything else exits with a
//! clear message instead of pretending to work. The C++ binary remains
//! the shipping implementation while modules are ported, and
//! `osrep-conformance` diffs the two.

use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.is_empty() {
        print_help();
        return ExitCode::from(2);
    }

    match args[0].as_str() {
        "--version" | "-V" => {
            println!("osrep (Rust) {VERSION} -- port in progress");
            ExitCode::SUCCESS
        }
        "--help" | "-h" | "-?" => {
            print_help();
            ExitCode::SUCCESS
        }
        other => {
            eprintln!(
                "osrep (Rust): '{other}' is not ported yet.\n\
                 The C++ build in bin/osrep is still the shipping binary; \
                 see docs/rust-port.md for the porting plan."
            );
            ExitCode::from(2)
        }
    }
}

fn print_help() {
    println!(
        "Omega SREP (Rust port, incomplete)\n\
         \n\
         Usage: osrep [options] <input> <output>\n\
         \n\
         Ported so far:\n\
         \x20 --version, --help\n\
         \n\
         Not yet ported: compression, decompression, -dup.\n\
         The C++ bin/osrep remains the shipping implementation."
    );
}
