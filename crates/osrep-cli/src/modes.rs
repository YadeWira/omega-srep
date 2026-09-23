//! Compress, decompress, and `-i`.
//!
//! This is `srep_main`'s front end (`srep.cpp:565-640`, `:1009-1160`) plus the
//! `-dup` wrapper's pipeline: the filename rules, the stdin/stdout spooling,
//! `-delete`, and the option defaults the encoder is built from.

use std::fs::{File, OpenOptions};
use std::io::{IsTerminal, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use osrep_core::archive;
use osrep_core::container;
use osrep_core::dup::{self, DupMode, DupParams};
use osrep_core::encoder::{Container, EncodeOptions, Kind, Mode, Seed};
use osrep_core::future_lz::FutureLzOptions;
use osrep_core::util::TempFile;

use crate::args::{self, CmdMode, Format, Lz, Options};
use crate::report;

// Program exit codes (`srep.cpp:45-51`).
pub const NO_ERRORS: i32 = 0;
pub const WARNINGS: i32 = 1;
pub const ERROR_CMDLINE: i32 = 2;
pub const ERROR_IO: i32 = 3;
pub const ERROR_COMPRESSION: i32 = 4;

/// A failure that `main` prints in the C++'s `error()` shape.
#[derive(Debug)]
pub struct RunError {
    pub code: i32,
    pub msg: String,
}

fn err(code: i32, msg: impl Into<String>) -> RunError {
    RunError {
        code,
        msg: msg.into(),
    }
}

/// `srep.cpp:477`: no input at all prints the synopsis on stdout and succeeds.
pub fn wants_help(o: &Options) -> bool {
    o.files.is_empty() && (std::io::stdin().is_terminal() || std::io::stdout().is_terminal())
}

pub fn run(o: &Options) -> Result<i32, RunError> {
    // `-index=` moves the per-block match lists out of the archive into a
    // second file (`fstat`, `srep.cpp:606`); the block headers, literals,
    // block-size table and footer stay in the archive. Only the two containers
    // that emit their lists from the second pass can do that.
    //
    // The C++ accepts the option for the other containers too and then writes
    // an archive that it cannot read back -- `-m3 -index=x` exits 0 and the
    // resulting file fails with "broken compressed data". That is silent data
    // loss, so this refuses the combination instead of reproducing it.
    if !o.index_file.is_empty() && o.cmdmode == CmdMode::Compress {
        if o.format == Format::V5 {
            return Err(err(
                ERROR_CMDLINE,
                "-index= is a v4 feature: the v5 footer locates everything by \
                 offset, so the lists cannot move out. Use --format=v4",
            ));
        }
        // Measured against the 1.0.7 C++, not assumed: with Index-LZ -- which
        // is the *default*, the no-suffix mode -- `-index=` compresses with
        // exit 0 and the archive then fails to decompress, because that
        // container's decoder reads the lists by seeking in the archive and
        // never consults the index. Future-LZ (`f`) and I/O-LZ (`o`) both
        // round-trip correctly.
        if o.lz == Lz::Index {
            return Err(err(
                ERROR_CMDLINE,
                "-index= needs -mNf or -mNo: the default (Index-LZ) container \
                 reads its match lists from the archive, so an archive written \
                 with an index could not be decompressed",
            ));
        }
    }
    if o.dup && o.seed_invalid {
        return Err(err(
            ERROR_CMDLINE,
            "--seed= needs an integer (decimal or 0x-prefixed hex)",
        ));
    }
    if o.dup && o.method == 0 {
        return Err(err(
            ERROR_CMDLINE,
            "-dup is incompatible with -m0; use -m3/-m4/-m5",
        ));
    }

    let (finame, foutname) = resolve_names(o)?;

    match o.cmdmode {
        CmdMode::Info => info(o, &finame),
        CmdMode::Verify => verify(o, &finame),
        // `resolve_names` always derives an output for these two.
        CmdMode::Compress => compress(o, &finame, foutname.as_deref().unwrap_or("-")),
        CmdMode::Decompress => decompress(o, &finame, foutname.as_deref().unwrap_or("-")),
    }
}

/// The filename rules (`srep.cpp:569-583`).
///
/// With one name, the `.osr` extension decides the direction and the other name
/// is derived from it; with none, and both ends redirected, there is nothing to
/// derive and the pair is stdin/stdout.
fn resolve_names(o: &Options) -> Result<(String, Option<String>), RunError> {
    let mut files = o.files.clone();
    if files.is_empty() && !std::io::stdin().is_terminal() && !std::io::stdout().is_terminal() {
        files = vec!["-".to_string(), "-".to_string()];
    }

    if matches!(o.cmdmode, CmdMode::Info | CmdMode::Verify) && files.len() > 1 {
        return Err(err(
            ERROR_CMDLINE,
            format!("Too much filenames: {} {}", files[0], files[1]),
        ));
    }
    if files.len() > 2 {
        return Err(err(
            ERROR_CMDLINE,
            format!("Too much filenames: {} {} {}", files[0], files[1], files[2]),
        ));
    }
    if files.is_empty() {
        return Err(err(ERROR_CMDLINE, "No input file"));
    }

    let finame = files[0].clone();
    let mut foutname = files.get(1).cloned();
    if matches!(o.cmdmode, CmdMode::Info | CmdMode::Verify) {
        foutname = None;
    }
    if foutname.is_none() {
        foutname = Some(match finame.strip_suffix(".osr") {
            Some(stripped) => stripped.to_string(),
            None => format!("{finame}.osr"),
        });
    }

    if finame != "-" && foutname.as_deref() == Some(finame.as_str()) {
        return Err(err(
            ERROR_IO,
            "Input and output files should have different names",
        ));
    }
    Ok((finame, foutname))
}

// ---------------------------------------------------------- compression --

fn mode_of(o: &Options) -> Mode {
    let kind = match o.method {
        0 => Kind::Inmem,
        1 => Kind::Cdc,
        2 => Kind::CdcZpaq,
        3 => Kind::Digest,
        4 => Kind::Fixed,
        _ => Kind::FixedExhaustive,
    };
    let container = match o.format {
        Format::V5 => Container::V5,
        Format::V4 => match o.lz {
            Lz::Index => Container::IndexLz,
            Lz::Future => Container::FutureLz,
            Lz::Io => Container::IoLz,
        },
    };
    Mode { kind, container }
}

fn encode_options(o: &Options, declared_size: Option<u64>) -> EncodeOptions {
    // `srep.cpp:445`: `-m0` with no `-d` takes the 512 mb default.
    let dictsize = if o.method == 0 && o.dictsize == 0 {
        512 * args::MB
    } else {
        o.dictsize
    };
    let hash = o
        .hash
        .clone()
        .unwrap_or_else(|| container::DEFAULT_HASH_NAME.to_string());
    EncodeOptions {
        bufsize: o.bufsize as usize,
        dictsize,
        dict_hashsize: o.dict_hashsize,
        min_match: o.min_match,
        dict_min_match: o.dict_min_match,
        dict_chunk: o.dict_chunk,
        l: o.l,
        seed: resolve_seed(o, &hash),
        declared_size,
        hash,
        dup_meta: None,
    }
}

/// Where the archive's hash key comes from, in the C++'s order
/// (`srep.cpp:646-652`): `OSREP_SEED_HEX` first, then `--seed=N`, then a
/// per-run draw.
///
/// `OSREP_SEED_HEX` is a debug hook that replays the exact key an archive
/// recorded; a malformed value is ignored rather than fatal, which is how the
/// C++ treats it.
fn resolve_seed(o: &Options, hash: &str) -> Seed {
    let size = container::hash_by_name(hash)
        .map(|h| h.seed_size as usize)
        .unwrap_or(0);
    // Unkeyed hashes (md5/sha1/sha512, `-hash-`) carry no seed at all.
    if size == 0 {
        return o.seed.clone();
    }
    if let Ok(hex) = std::env::var("OSREP_SEED_HEX") {
        if hex.len() == size * 2 {
            if let Some(bytes) = decode_hex(&hex) {
                return Seed::Bytes(bytes);
            }
        }
    }
    match &o.seed {
        Seed::Random => Seed::Bytes(osrep_core::util::random_bytes(size)),
        given => given.clone(),
    }
}

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    let b = s.as_bytes();
    if b.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(b.len() / 2);
    for pair in b.chunks_exact(2) {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push((hi * 16 + lo) as u8);
    }
    Some(out)
}

/// Spool stdin when the encoder needs a seekable input, and return the path to
/// read it from.
///
/// The C++ reads stdin directly and only *copies* to a tempfile for its
/// re-reads; the port has one input handle, so it spools first. The bytes read
/// are the same, and `filesize` still comes from `-s` (or the 25 gb default),
/// which is what keeps the archive identical.
fn spool_stdin(o: &Options) -> Result<(String, Option<TempFile>), RunError> {
    match o.tempfile.as_deref() {
        Some("") => Err(err(
            ERROR_IO,
            "Reading data to compress from stdin without tempfile isn't supported for this method",
        )),
        Some(p) => {
            let mut f = File::create(p).map_err(|_| err(ERROR_IO, "Can't open tempfile"))?;
            copy_stdin(&mut f)?;
            Ok((p.to_string(), None))
        }
        None => {
            let t = TempFile::new("osrep-data").map_err(|_| {
                err(
                    ERROR_IO,
                    "Can't allocate a unique tempfile under $TMPDIR/%TEMP%",
                )
            })?;
            let path = t.path().to_string_lossy().into_owned();
            let mut f = File::create(t.path()).map_err(|_| err(ERROR_IO, "Can't open tempfile"))?;
            copy_stdin(&mut f)?;
            Ok((path, Some(t)))
        }
    }
}

fn copy_stdin(f: &mut File) -> Result<(), RunError> {
    f.flush().map_err(|_| err(ERROR_IO, "Can't write to tempfile"))?;
    let mut stdin = std::io::stdin().lock();
    std::io::copy(&mut stdin, f).map_err(|_| err(ERROR_IO, "Can't read from input file"))?;
    f.flush().map_err(|_| err(ERROR_IO, "Can't write to tempfile"))
}

fn compress(o: &Options, finame: &str, foutname: &str) -> Result<i32, RunError> {
    if o.dup && (o.method == 1 || o.method == 2) {
        eprintln!(
            "  WARNING: -dup with -m{} does CDC twice; -m3/-m4/-m5 recommended",
            o.method
        );
    }
    if o.dup && (finame == "-" || foutname == "-") {
        return Err(err(ERROR_CMDLINE, "-dup mode does not support stdin/stdout"));
    }
    // `srep.cpp:446`: content-defined chunking and the in-memory dictionary do
    // not mix.
    if (o.method == 1 || o.method == 2) && o.dictsize != 0 {
        return Err(err(
            ERROR_CMDLINE,
            format!(
                "Incompatible options: -m{} -d{}",
                o.method,
                report::show_mem(o.dictsize, true)
            ),
        ));
    }

    // `srep.cpp:459-462`: the match window has to be a power of two or the
    // archive may be corrupt, which the C++ turns into the exit code rather
    // than a printed line alone. The window is `-c` when it is given and `-l`
    // otherwise -- and CDC takes `-l` as the window only to discard it, while
    // `-m5` halves and rounds, so neither can ever fail the test
    // (`srep.cpp:448-454`).
    let mut warnings = 0;
    let window = match o.method {
        1 | 2 | 5 => None,
        _ if o.l != 0 => Some(o.l),
        _ if o.min_match != 0 => Some(o.min_match),
        _ => None,
    };
    if let Some(l) = window {
        if !l.is_power_of_two() {
            eprintln!(
                "Warning: -l parameter should be power of 2, otherwise compressed file may be corrupt"
            );
            warnings += 1;
        }
    }

    let mode = mode_of(o);
    let (input_path, spool) = if finame == "-" {
        spool_stdin(o)?
    } else {
        (finame.to_string(), None)
    };
    // With `-` the size cannot be measured at read time, so the declared value
    // (or the default) stands in -- exactly the C++'s `finame == "-"` branch.
    let declared = if finame == "-" {
        Some(o.declared_size.unwrap_or(args::DEFAULT_STDIN_FILESIZE))
    } else {
        None
    };
    let enc = encode_options(o, declared);

    let mut bar = report::Bar::new(o.bar);
    let mut stats = report::Stats::new(o.verbosity > 0);
    let read = if o.dup {
        file_size(&input_path)
    } else {
        declared.unwrap_or_else(|| file_size(&input_path))
    };

    // `srep.cpp:606`: the index is opened before the run, so a bad path fails
    // before any work is done rather than after the archive is written.
    let mut index_file = if o.index_file.is_empty() {
        None
    } else {
        Some(File::create(&o.index_file).map_err(|_| {
            err(
                ERROR_IO,
                format!("Can't open index file {} for write", o.index_file),
            )
        })?)
    };

    let written = {
        let mut progress = |done: u64, total: u64| {
            bar.tick(done, total);
            stats.tick(done, total);
        };
        let index = index_file.as_mut().map(|f| f as &mut dyn Write);
        if o.dup {
            let dup_mode = if o.format == Format::V5 {
                DupMode::V5
            } else {
                DupMode::V4
            };
            let params = DupParams {
                chunking: o.chunk,
                paranoid: o.dup_paranoid,
            };
            dup::encode(
                Path::new(&input_path),
                Path::new(foutname),
                &enc,
                mode,
                params,
                dup_mode,
                Some(&mut progress),
                index,
            )
            .map_err(dup_error)?
        } else {
            let mut input = File::open(&input_path)
                .map_err(|_| err(ERROR_IO, format!("Can't open {finame} for read")))?;
            // `-` means stdout, not a file called "-".
            if foutname == "-" {
                let stdout = std::io::stdout();
                let mut out = CountWriter::new(stdout.lock());
                osrep_core::encoder::encode(
                    &mut input,
                    &mut out,
                    &enc,
                    mode,
                    Some(&mut progress),
                    index,
                )
                .map_err(|e| err(ERROR_COMPRESSION, format!("{e:?}")))?;
                out.flush().map_err(|_| err(ERROR_IO, "Can't write to stdout"))?;
                out.written()
            } else {
                let mut out = File::create(foutname)
                    .map_err(|_| err(ERROR_IO, format!("Can't open {foutname} for write")))?;
                osrep_core::encoder::encode(
                    &mut input,
                    &mut out,
                    &enc,
                    mode,
                    Some(&mut progress),
                    index,
                )
                .map_err(|e| err(ERROR_COMPRESSION, format!("{e:?}")))?;
                out.seek(SeekFrom::End(0))
                    .map_err(|_| err(ERROR_IO, "Can't write the archive"))?
            }
        }
    };

    stats.finish(read, written);
    drop(spool);
    if warnings == 0 && o.delete_input {
        let _ = std::fs::remove_file(finame);
    }
    Ok(if warnings > 0 { WARNINGS } else { NO_ERRORS })
}

fn file_size(path: &str) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// Counts what it forwards, so the summary line knows how big an archive sent
/// to stdout was. A file can be measured after the fact; a pipe cannot.
struct CountWriter<W: Write> {
    inner: W,
    written: u64,
}

impl<W: Write> CountWriter<W> {
    fn new(inner: W) -> CountWriter<W> {
        CountWriter { inner, written: 0 }
    }

    fn written(&self) -> u64 {
        self.written
    }
}

impl<W: Write> Write for CountWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.written += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

fn dup_error(e: dup::DupError) -> RunError {
    match e {
        dup::DupError::IncompatibleMethod => {
            err(ERROR_CMDLINE, "-dup is incompatible with -m0; use -m3/-m4/-m5")
        }
        dup::DupError::UnsupportedContainer => {
            err(ERROR_CMDLINE, "-dup needs the default (Index-LZ) or v5 container")
        }
        dup::DupError::Dedup(rc) => err(ERROR_COMPRESSION, format!("dedup failed, rc={rc}")),
        dup::DupError::BadDup => err(ERROR_COMPRESSION, "the -dup meta is missing or corrupt"),
        other => err(ERROR_IO, format!("{other:?}")),
    }
}

// -------------------------------------------------------- decompression --

/// `srep.cpp:475`: the stored-match cap is itself capped, so an oversized match
/// takes the "read back from the output file" path instead of defeating the
/// spill's eviction.
fn decode_options(o: &Options) -> FutureLzOptions {
    let maximum_save = if o.vm_block > 24 && u64::from(o.maximum_save) > o.vm_block - 24 {
        (o.vm_block - 24) as u32
    } else {
        o.maximum_save
    };
    FutureLzOptions {
        mem_limit: o.vm_mem,
        vm_block: o.vm_block,
        maximum_save,
        vmfile: o.vmfile.as_ref().map(PathBuf::from),
    }
}

fn decompress(o: &Options, finame: &str, foutname: &str) -> Result<i32, RunError> {
    let opts = decode_options(o);

    // `-dup` first: the C++ auto-detects it on every decompression, with or
    // without the flag on the command line. It rewrites the archive's tail, so
    // it needs both names to be real files.
    if finame != "-" && foutname != "-" {
        match dup::decode(Path::new(finame), Path::new(foutname), &opts) {
            Ok(true) => {
                if o.delete_input {
                    let _ = std::fs::remove_file(finame);
                }
                return Ok(NO_ERRORS);
            }
            Ok(false) => {}
            Err(e) => return Err(dup_error(e)),
        }
    }

    // `-` means stdin, and the decoder seeks its input (v4 reads the footer
    // first, v5 the same), so stdin is spooled before anything is parsed --
    // the C++ gets away without this only because it copies to a tempfile for
    // its re-reads instead of seeking.
    let stdin_spool = if finame == "-" {
        let t = TempFile::new("osrep-data").map_err(|_| {
            err(
                ERROR_IO,
                "Can't allocate a unique tempfile under $TMPDIR/%TEMP%",
            )
        })?;
        let mut f = File::create(t.path()).map_err(|_| err(ERROR_IO, "Can't open tempfile"))?;
        copy_stdin(&mut f)?;
        Some(t)
    } else {
        None
    };
    let input_path: PathBuf = stdin_spool
        .as_ref()
        .map(|t| t.path().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(finame));

    let mut input = File::open(&input_path)
        .map_err(|_| err(ERROR_IO, format!("Can't open {finame} for read")))?;
    let total = input.metadata().map(|m| m.len()).unwrap_or(0);

    let mut bar = report::Bar::new(o.bar);
    let mut stats = report::Stats::new(o.verbosity > 0);

    // The decoder seeks back into what it has written, so the sink is a file
    // either way; when the real output is stdout, the file is a scratch one
    // that gets copied out at the end (`srep.cpp:1150-1162`, same idea).
    let spool = if foutname == "-" {
        Some(TempFile::new("osrep-data").map_err(|_| {
            err(
                ERROR_IO,
                "Can't allocate a unique tempfile under $TMPDIR/%TEMP%",
            )
        })?)
    } else {
        None
    };
    let sink_path: PathBuf = spool
        .as_ref()
        .map(|t| t.path().to_path_buf())
        .unwrap_or_else(|| PathBuf::from(foutname));

    let mut sink = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&sink_path)
        .map_err(|_| err(ERROR_IO, format!("Can't open {foutname} for write")))?;

    // `-index=` on the way back: the match lists come from the named file
    // instead of the archive (`srep.cpp:606` opens it "rb" for decompression).
    let mut index_file = if o.index_file.is_empty() {
        None
    } else {
        Some(File::open(&o.index_file).map_err(|_| {
            err(
                ERROR_IO,
                format!("Can't open index file {} for read", o.index_file),
            )
        })?)
    };

    {
        let mut progress = |done: u64, total: u64| {
            bar.tick(done, total);
            stats.tick(done, total);
        };
        let index = index_file.as_mut().map(|f| f as &mut dyn Read);
        // A rejection is a clean non-zero exit -- never a crash, never a hang,
        // which is what the corruption tests assert.
        if let Err(e) = archive::decode(&mut input, &mut sink, &opts, Some(&mut progress), index) {
            return Err(err(ERROR_COMPRESSION, format!("{e:?}: {finame}")));
        }
    }
    sink.flush().map_err(|_| err(ERROR_IO, "Can't write the output"))?;
    let decoded = sink
        .seek(SeekFrom::End(0))
        .map_err(|_| err(ERROR_IO, "Can't write the output"))?;
    drop(sink);

    if let Some(t) = &spool {
        let mut f = File::open(t.path()).map_err(|_| err(ERROR_IO, "tempfile"))?;
        let mut stdout = std::io::stdout().lock();
        std::io::copy(&mut f, &mut stdout).map_err(|_| err(ERROR_IO, "Can't write to stdout"))?;
        stdout.flush().map_err(|_| err(ERROR_IO, "Can't write to stdout"))?;
    }

    stats.finish(total, decoded);
    drop(spool);
    if o.delete_input && finame != "-" {
        let _ = std::fs::remove_file(finame);
    }
    Ok(NO_ERRORS)
}

// ------------------------------------------------------------------ info --

/// `--verify`: say whether an archive is sound **without reconstructing it**.
///
/// This exists because v5 can answer the question and v4 cannot. v4 carries no
/// checksum anywhere, so the only way to know a v4 archive is intact is to
/// decompress the whole thing and let the per-block digests speak. v5 has
/// CRC-32C over its header, footer and `-dup` meta, self-describing framing,
/// and records that can be walked arithmetically -- enough to catch truncation,
/// trailing junk, framing damage and incoherent records in the time it takes to
/// read the file.
///
/// The output says what was not checked, deliberately. Nothing in v5
/// checksums the stored block bytes, so a bit flipped inside a literal run
/// survives this and is only caught by decoding. A verify that let someone
/// believe otherwise would be worse than not having one.
fn verify(_o: &Options, finame: &str) -> Result<i32, RunError> {
    let bytes = if finame == "-" {
        let mut buf = Vec::new();
        std::io::stdin()
            .lock()
            .read_to_end(&mut buf)
            .map_err(|_| err(ERROR_IO, "Can't read from stdin"))?;
        buf
    } else {
        std::fs::read(finame)
            .map_err(|_| err(ERROR_IO, format!("Can't open {finame} for read")))?
    };

    let is_v5 = bytes.len() >= 4
        && u32::from_le_bytes(bytes[..4].try_into().unwrap()) == osrep_core::v5::MAGIC;
    if !is_v5 {
        // Distinguish "a container that cannot be verified" from "not an
        // archive at all", because the advice differs.
        return match archive::inspect(&bytes) {
            Ok(_) => Err(err(
                ERROR_CMDLINE,
                format!(
                    "{finame} is a v1-v4 archive, which carries no checksum anywhere, \
                     so it cannot be verified without reconstructing it. Decompress it \
                     to check it (the per-block digests are verified on the way), or \
                     re-create it with --format=v5"
                ),
            )),
            Err(_) => Err(err(
                ERROR_COMPRESSION,
                format!("Not an Omega SREP compressed file (.osr): {finame}"),
            )),
        };
    }

    let report = osrep_core::v5::verify(&bytes).map_err(|e| {
        err(
            ERROR_COMPRESSION,
            format!("{finame} is damaged: {e:?}"),
        )
    })?;

    let mut out = std::io::stderr();
    let _ = writeln!(
        out,
        "{finame}: v5 archive intact. {} blocks, {} records, {} bytes of original data{}.",
        report.blocks,
        report.records,
        report.original_size,
        if report.has_dup_meta { ", -dup meta checksummed" } else { "" }
    );
    let _ = writeln!(
        out,
        "  Checked without decompressing: header, footer and meta CRC-32C, framing, \
block count, every record, and that the file ends where the footer says."
    );
    let _ = writeln!(
        out,
        "  Not checked: the stored block bytes carry no checksum, so damage inside a \
literal run needs a decompress{}.",
        if report.has_block_digests { " (where the per-block digests catch it)" } else { "" }
    );
    Ok(0)
}

fn info(o: &Options, finame: &str) -> Result<i32, RunError> {
    let opts = decode_options(o);
    let bytes = if finame == "-" {
        let mut buf = Vec::new();
        std::io::stdin()
            .lock()
            .read_to_end(&mut buf)
            .map_err(|_| err(ERROR_IO, "Can't read from stdin"))?;
        buf
    } else {
        std::fs::read(finame)
            .map_err(|_| err(ERROR_IO, format!("Can't open {finame} for read")))?
    };
    let info = archive::inspect(&bytes).map_err(|_| {
        err(
            ERROR_COMPRESSION,
            format!("Not an Omega SREP compressed file (.osr): {finame}"),
        )
    })?;

    let mut head = format!("{}:", info.mode);
    if info.base_len != 0 {
        head.push_str(&format!(" -l{}", info.base_len));
    }
    head.push_str(&format!(" -hash={}", info.hash_name));
    // Index-LZ leaves the line open for the size that follows; the others close
    // it here (`srep.cpp:1074-1075`).
    if info.mode == "Index-LZ" {
        eprint!("{head}");
    } else {
        eprintln!("{head}");
    }

    // The C++ reaches the size line only for Index-LZ, where it derives the
    // original size from the footer arithmetic. v5 carries the same answer in
    // its header, so it gets the same line.
    if info.mode == "Index-LZ" || info.mode == "v5" {
        let pct = if info.origsize > 0 {
            info.compsize as f64 * 100.0 / info.origsize as f64
        } else {
            0.0
        };
        eprintln!(
            ".  {} -> {}: {pct:.2}%",
            report::show3(info.origsize),
            report::show3(info.compsize)
        );
        // The C++ reports the peak RAM its spill would need, which it computes
        // by walking the match lists; the port does not measure a peak, so that
        // one field is a placeholder. Everything else on the line is real.
        let maximum_save = if opts.maximum_save == u32::MAX {
            None
        } else {
            Some(u64::from(opts.maximum_save))
        };
        // Only v1 stores 3-word records, and the C++ reaches this line for
        // Index-LZ (4-word) alone.
        report::print_info("", 0, maximum_save, info.stat_size, false, info.compsize);
        eprintln!();
    }
    Ok(NO_ERRORS)
}
