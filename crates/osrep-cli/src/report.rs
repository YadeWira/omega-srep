//! Everything the program writes to stderr.
//!
//! Two audiences live here. `-bar` is machine-parseable and its format is a
//! contract (`PROGRESS <done> <total>`, plain digits, every ~0.5s plus a
//! guaranteed final line), so it is reproduced exactly. The human progress and
//! summary lines are reproduced in shape with the port's own numbers: the C++
//! reports CPU vs real time and resident memory, which this port does not
//! measure.
//!
//! This used to add "and nothing — no test, no wrapper — reads those", which
//! was false. ytool scraped the literal `"Decompression memory is "` out of
//! the C++'s stderr to fill a field it shows its users; the port emits no such
//! line in the compression path, so the scrape would have silently found
//! nothing. Worse, that literal had already stopped matching at 1.0.6 without
//! anyone editing the text: `print_info` (`srep.cpp:185`) appends
//! `" with -m<N>"` only when `maximum_save` is set, and the 1.0.6 fix that
//! made `-vmblock=` reachable is what started setting it. An interface moved
//! because a bug three layers away was fixed.
//!
//! The conclusion kept here is not that these lines must now match — they were
//! never meant to, and the consumer agreed the format was never an interface
//! and removed its scrape. It is that *what gets reported* is observable, and
//! observable output is contract whether or not anyone declared it. So
//! `tests/stderr_conformance.sh` records which facts each binary mentions and
//! fails when that changes, making a gain or loss a visible decision instead
//! of something a consumer discovers years later.

use std::io::Write;
use std::time::{Duration, Instant};

const KB: u64 = 1024;
const MB: u64 = 1024 * 1024;
const GB: u64 = 1024 * 1024 * 1024;

/// `show3` (`Common.h:777`): thousands separators, for humans.
pub fn show3(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// `show_plain` (`Common.h:796`): plain digits, for the machine-parseable line.
pub fn show_plain(n: u64) -> String {
    n.to_string()
}

/// `showMem` (`Common.cpp:268`): a size in the largest unit that divides it.
pub fn show_mem(mem: u64, add_b: bool) -> String {
    let b = if add_b { "b" } else { "" };
    if mem == 0 {
        format!("0{b}")
    } else if mem % GB == 0 {
        format!("{}g{b}", mem / GB)
    } else if mem % MB == 0 {
        format!("{}m{b}", mem / MB)
    } else if mem % KB == 0 {
        format!("{}k{b}", mem / KB)
    } else {
        format!("{mem}{b}")
    }
}

/// The `-bar` emitter (`srep.cpp:800-810`, `:1260-1268`).
///
/// The core calls back once per block; this decides which of those become
/// lines. The C++ ticks on a fixed 0.5s timer and forces a line whenever the
/// operation is finished, which is what a consumer needs to see `done ==
/// total` exactly once at the end.
pub struct Bar {
    enabled: bool,
    last: Instant,
    last_done: u64,
}

impl Bar {
    pub fn new(enabled: bool) -> Bar {
        Bar {
            enabled,
            last: Instant::now() - Duration::from_secs(1),
            last_done: u64::MAX,
        }
    }

    /// One tick from the core. `finished` forces the line out regardless of the
    /// timer.
    pub fn tick(&mut self, done: u64, total: u64) {
        if !self.enabled {
            return;
        }
        let finished = total > 0 && done >= total;
        if !finished && (self.last.elapsed().as_secs_f64() < 0.5 || done == self.last_done) {
            return;
        }
        self.last = Instant::now();
        self.last_done = done;
        // The leading newline is the C++'s: the human progress line ends with
        // backspaces, never a newline, so without it a naive \n-splitting
        // consumer would glue "PROGRESS ..." onto stale text.
        eprint!("\nPROGRESS {} {}\n", show_plain(done), show_plain(total));
        let _ = std::io::stderr().flush();
    }
}

/// The human progress line (`srep.cpp:832`).
///
/// The C++ also reports CPU time against real time, the ratio mid-flight and an
/// ETA; the port tracks none of those, so this reports the percentage, the
/// bytes moved and the throughput, and leaves the ratio to `finish`.
pub struct Stats {
    enabled: bool,
    started: Instant,
    last: Instant,
    last_done: u64,
}

impl Stats {
    pub fn new(enabled: bool) -> Stats {
        Stats {
            enabled,
            started: Instant::now(),
            last: Instant::now() - Duration::from_secs(1),
            last_done: u64::MAX,
        }
    }

    pub fn tick(&mut self, done: u64, total: u64) {
        if !self.enabled || done == self.last_done {
            return;
        }
        let finished = total > 0 && done >= total;
        if !finished && self.last.elapsed().as_secs_f64() < 0.2 {
            return;
        }
        self.last = Instant::now();
        self.last_done = done;
        let secs = self.started.elapsed().as_secs_f64();
        let percents = if total > 0 { done * 100 / total } else { 100 };
        let mbps = if secs > 0.0 {
            done as f64 / secs / MB as f64
        } else {
            0.0
        };
        eprint!(
            "\r{percents}%: {} of {}: real {mbps:.0} mb/s ({secs:.3} sec)",
            show3(done),
            show3(total)
        );
        let _ = std::io::stderr().flush();
    }

    /// Replace the in-flight line with the finished one.
    pub fn finish(&mut self, read: u64, written: u64) {
        if !self.enabled {
            return;
        }
        let ratio = if read > 0 {
            written as f64 * 100.0 / read as f64
        } else {
            0.0
        };
        let secs = self.started.elapsed().as_secs_f64();
        eprintln!(
            "\r{} -> {}: {ratio:.2}%.  {secs:.3} sec",
            show3(read),
            show3(written)
        );
    }
}

/// `print_info` (`srep.cpp:182-190`), the decompression summary.
#[allow(clippy::too_many_arguments)]
pub fn print_info(
    prefix: &str,
    max_ram: u64,
    maximum_save: Option<u64>,
    stat_size: u64,
    round_matches: bool,
    filesize: u64,
) {
    let with_maximum_save = match maximum_save {
        Some(v) => format!(" with -m{}", show_mem(v, false)),
        None => String::new(),
    };
    let per_match = if round_matches { 3 } else { 4 } * 4;
    let pct = if filesize > 0 {
        stat_size as f64 * 100.0 / filesize as f64
    } else {
        0.0
    };
    eprint!(
        "{prefix}Decompression memory{with_maximum_save} is {} mb.  {} matches = {} bytes = {pct:.2}% of file",
        max_ram.div_ceil(MB),
        show3(stat_size / per_match),
        show3(stat_size),
    );
}
