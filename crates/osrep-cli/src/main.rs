//! Omega SREP command line -- Rust port.
//!
//! Interchangeable with the C++ binary: same flags, same archive bytes, same
//! exit codes. `docs/rust-port.md` describes the port; `args.rs` mirrors the
//! two C++ parsers, `modes.rs` the front end that drives them, and `report.rs`
//! everything written to stderr.

mod args;
mod help;
mod modes;
mod report;

use std::process::ExitCode;

/// Kept in step with `program_version` (`srep.cpp:6`) through
/// `workspace.package.version`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();

    // `--version` / `--help` are answered before either parser runs
    // (`dup_wrapper.cpp:477-488`), because the main parser rejects anything
    // starting with `--`.
    for a in &argv {
        match a.as_str() {
            "--version" | "-V" => {
                println!("{}", help::version());
                return ExitCode::SUCCESS;
            }
            "--help" | "-h" | "-?" => {
                print!("{}", help::help());
                return ExitCode::SUCCESS;
            }
            _ => {}
        }
    }

    let opts = match args::parse(&argv) {
        Ok(o) => o,
        Err(e) => return fail(modes::ERROR_CMDLINE, &e.0),
    };

    if modes::wants_help(&opts) {
        print!("{}", help::help());
        return ExitCode::from(modes::NO_ERRORS as u8);
    }

    match modes::run(&opts) {
        Ok(code) => ExitCode::from(code as u8),
        Err(e) => fail(e.code, &e.msg),
    }
}

/// `error()` (`io.cpp:9-19`).
fn fail(code: i32, msg: &str) -> ExitCode {
    eprintln!("\n  ERROR! {msg}");
    ExitCode::from(code as u8)
}
