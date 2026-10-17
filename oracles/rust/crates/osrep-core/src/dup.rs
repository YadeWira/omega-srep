//! The `-dup` wrapper: the dedup pre-pass glued to the archive encoder, the way
//! `oracles/cxx/Compression/SREP/dup_wrapper.cpp` glues them at the CLI.
//!
//! `-dup` is two passes. The dedup pass rewrites the input into a *body* (the
//! unique chunks, in order of first appearance) plus a meta blob that says how
//! to put the original back; the archive encoder then compresses the body,
//! which is where the ratio comes from. The meta never goes through the
//! encoder.
//!
//! Where the meta lives is the one thing v4 and v5 disagree on. v4 appends it
//! as an ODUP trailer and finds it by sniffing the last four bytes -- which
//! mis-handles `osrep -d archive.osr` (stdin), which the C++'s own `-i`
//! reads as a broken footer (`archive::inspect` looks behind it after 2.3.0),
//! and which a plain Future-LZ/I/O LZ archive of a file that ends in "ODUP"
//! also matches (`decode_odup`); v5 embeds it between the blocks and the
//! footer, which points at it.
//!
//! The C++ writes the body to a tempfile and runs `srep_main` over it with the
//! input filename substituted. This does the same, minus the subprocess: the
//! encoder reads the body as the `Read + Seek` it already takes.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use crate::archive;
use crate::container;
use crate::dedup::{self, Params};
use crate::decompress::DecodeError;
use crate::encoder::{self, Container, EncodeError, EncodeOptions, Kind, Mode};
use crate::future_lz::{self, FutureLzOptions};
use crate::util::TempFile;
use crate::v5;

/// `"ODUP"`: the magic v4 closes a `-dup` archive with.
const ODUP_MAGIC: [u8; 4] = *b"ODUP";
/// The trailer's `meta_size` (u64) plus `ODUP_MAGIC`.
const ODUP_TRAILER_SIZE: u64 = 12;

/// Where the `-dup` meta goes (`--format=`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DupMode {
    /// Embedded in the v5 container, located by the footer.
    V5,
    /// Appended as the v4 ODUP trailer, which is what the 1.0.x binaries read.
    V4,
}

/// The dedup pass's own tunables (`--chunk-*`, `--dup-paranoid`).
#[derive(Debug, Clone, Copy)]
pub struct DupParams {
    pub chunking: Params,
    pub paranoid: bool,
}

impl Default for DupParams {
    fn default() -> Self {
        DupParams {
            chunking: Params::default(),
            paranoid: false,
        }
    }
}

#[derive(Debug)]
pub enum DupError {
    Io,
    /// The file ended before a field the framing needs.
    Truncated,
    /// `-dup` is meaningless for `-m0`: the in-memory pass has no chunk table
    /// to dedup against (`dup_wrapper.cpp:202-205`).
    IncompatibleMethod,
    /// The v4 ODUP trailer is only defined for a default (Index-LZ) archive.
    UnsupportedContainer,
    /// The archive says it carries a meta blob but it is missing or corrupt.
    BadDup,
    /// The dedup pass rejected the input, or the meta it was handed.
    Dedup(i32),
    Encode(EncodeError),
    Decode(DecodeError),
}

impl From<std::io::Error> for DupError {
    fn from(_: std::io::Error) -> Self {
        DupError::Io
    }
}

impl From<EncodeError> for DupError {
    fn from(e: EncodeError) -> Self {
        DupError::Encode(e)
    }
}

// --------------------------------------------------------------- encode --

/// Compress `input` with the dedup pre-pass, the way `-dup` does. Returns the
/// size of the archive that was written.
///
/// `mode` says how the *body* is compressed; `container` says where the meta
/// goes. `DupMode::V4` additionally requires `mode.container` to be the default
/// Index-LZ, because that is the only archive shape the ODUP trailer is
/// defined against.
pub fn encode(
    input: &Path,
    output: &Path,
    enc: &EncodeOptions,
    mode: Mode,
    dup: DupParams,
    container: DupMode,
    progress: Option<&mut dyn FnMut(u64, u64)>,
    // `-index=`: the body is what `srep_main` compresses, so the index the
    // wrapper produces is the body's, exactly as in the C++.
    index: Option<&mut dyn std::io::Write>,
) -> Result<u64, DupError> {
    if mode.kind == Kind::Inmem {
        return Err(DupError::IncompatibleMethod);
    }
    if container == DupMode::V4 && mode.container != Container::IndexLz {
        return Err(DupError::UnsupportedContainer);
    }

    // The dedup pass: the body is the only piece worth feeding to the encoder,
    // and the meta is the only piece that never goes through it.
    let body = TempFile::new("osrep-dup-body")?;
    let meta = dedup::encode_streaming(input, body.path(), dup.chunking, dup.paranoid)
        .map_err(DupError::Dedup)?;

    let mut enc = enc.clone();
    enc.dup_meta = match container {
        DupMode::V5 => Some(meta.clone()),
        // v4 has nowhere inside the archive for it: the trailer below is what
        // carries it.
        DupMode::V4 => None,
    };

    let body_file = File::open(body.path())?;
    let mut body_file = std::io::BufReader::new(body_file);
    // An output of the run: opened under the rule of `util` ("the files of
    // one run"), and removed if the run fails.
    let mut out = crate::util::create_output(output, false)?;
    // The progress the caller sees is the encoder's, against the *body*: the
    // dedup pass has already run by the time there is anything to report, and
    // the C++ has the same shape (its `-bar` lives in srep_main, which only
    // ever sees the body).
    encoder::encode(&mut body_file, &mut out, &enc, mode, progress, index)?;

    if container == DupMode::V4 {
        // `dup_wrapper.cpp:254-262`: meta || u64_le(meta_size) || "ODUP".
        out.write_all(&meta)?;
        out.write_all(&(meta.len() as u64).to_le_bytes())?;
        out.write_all(&ODUP_MAGIC)?;
    }
    out.flush()?;
    // Measured rather than accumulated: the encoder's own return value counts
    // the body's payload, not the framing this wrapper has just added.
    Ok(out.metadata()?.len())
}

// --------------------------------------------------------------- decode --

/// Decode `input` and, if it is a `-dup` archive, run the dedup post-pass into
/// `output`.
///
/// Returns `true` when the post-pass ran, `false` when the archive is a plain
/// one -- which is a *success*, and the caller decodes it itself. That mirrors
/// the C++'s auto-detection, which sniffs the trailer even without `-dup` on
/// the command line.
pub fn decode(input: &Path, output: &Path, opts: &FutureLzOptions) -> Result<bool, DupError> {
    decode_with(input, output, opts, false)
}

/// `decode`, for a `-d` given `-index=`: a plain v1-v3 archive's match lists
/// are then in the index, which is how [`reads_as_plain`] has to walk it.
pub fn decode_with(
    input: &Path,
    output: &Path,
    opts: &FutureLzOptions,
    stats_out_of_line: bool,
) -> Result<bool, DupError> {
    let mut archive = File::open(input)?;
    let len = archive.seek(SeekFrom::End(0))?;

    // The dedup post-pass needs the body on disk: it seeks back into it to
    // expand the references, so the two halves cannot share a file.
    let meta = match v5_meta(&mut archive, len)? {
        V5Meta::Dup(meta) => meta,
        // A v5 archive that ends in its own footer keeps no ODUP trailer: its
        // last four bytes are the footer's CRC, which is "ODUP" once in 2^32
        // archives, and 2.3.0 then refused a sound archive as a broken
        // trailer.
        V5Meta::Plain => return Ok(false),
        V5Meta::Sniff => return decode_odup(&mut archive, len, output, opts, stats_out_of_line),
    };
    let body = TempFile::new("osrep-dup-body")?;
    // Read as well as write: the decoder reads back a match whose source
    // lies in an earlier block (one of `maximum_save` bytes or more) from
    // what it has already written. `File::create` alone failed those
    // archives with EBADF.
    let mut sink = create_rw(body.path())?;
    archive.seek(SeekFrom::Start(0))?;
    future_lz::decode_v5(&mut archive, &mut sink, opts, None).map_err(DupError::Decode)?;
    sink.flush()?;
    drop(sink);
    dedup::decode_streaming(&meta, body.path(), output).map_err(DupError::Dedup)?;
    Ok(true)
}

/// The v4 half of [`decode_with`]: the ODUP trailer.
///
/// The trailer is sniffed, and a plain Future-LZ or I/O LZ archive ends in
/// its last literals, so one of a file that itself ends in "ODUP" -- any v4
/// `-dup` archive -- ends in what looks like a trailer, meta and all. 2.3.0
/// and the C++ 1.0.7 cut it off and failed on what was left, so `-d archive
/// out` failed on it (`-d - out < archive` restored it: the trailer is only
/// sniffed when input and output are both named files). So the trailer is
/// taken only when the archive behind it holds up (it walks as a whole
/// archive, and the meta fits what its blocks decode to); when it does not,
/// and the whole file walks as a plain archive, the file is decoded as one --
/// whose blocks then pass their own checks, digests included. When neither
/// holds, it is the `-dup` path that runs and fails, with the same error as
/// before: a damaged `-dup` archive is not decoded to its body. Neither walk
/// accepts the zero-length terminator block no encoder writes, or a v1-v3
/// `-dup` archive (the C++ writes those) whose meta had its first bytes
/// zeroed would read as its own body.
///
/// The meta itself is read only once the archive in front of it has walked,
/// or, on the failing `-dup` path, once the body has decoded. In a plain
/// archive the trailer's `meta_size` is the input's own bytes, anything up to
/// the file's length: reading the meta first cost that much memory, and in
/// the win32 Pascal build overran the buffer allocated for it.
fn decode_odup(
    archive: &mut File,
    len: u64,
    output: &Path,
    opts: &FutureLzOptions,
    stats_out_of_line: bool,
) -> Result<bool, DupError> {
    let sniffed = odup_trailer(archive, len);
    if let Ok(None) = sniffed {
        return Ok(false);
    }
    // The `-dup` reading: the archive in front of the meta walks as a whole
    // one, and the meta asks for no more body than its blocks decode to
    // (`archive::with_dup`'s rule, which `-i` applies too).
    let mut meta = None;
    let mut holds = false;
    if let Ok(Some(meta_size)) = sniffed {
        let body_len = len - ODUP_TRAILER_SIZE - meta_size;
        if let Some(origsize) = reads_as_plain(archive, body_len, stats_out_of_line) {
            let m = read_meta(archive, len, meta_size)?;
            holds = matches!(dedup::summarize_meta(&m), Ok(s) if s.body_size <= origsize);
            meta = Some(m);
        }
    }
    if !holds && reads_as_plain(archive, len, stats_out_of_line).is_some() {
        return Ok(false);
    }
    let Some(meta_size) = sniffed? else {
        return Ok(false);
    };

    // v4 keeps the body in the archive but hidden behind the trailer; the
    // C++ carves it out to a tempfile before handing it to srep_main, and
    // so does this.
    let body = TempFile::new("osrep-dup-body-osr")?;
    let body_len = len - ODUP_TRAILER_SIZE - meta_size;
    {
        let mut trimmed = File::create(body.path())?;
        archive.seek(SeekFrom::Start(0))?;
        std::io::copy(&mut (&mut *archive).take(body_len), &mut trimmed)?;
    }
    let decoded = TempFile::new("osrep-dup-body-dec")?;
    {
        // closed before the post-pass, as in the Pascal: the fds after it match
        let mut body_file = File::open(body.path())?;
        let mut sink = create_rw(decoded.path())?;
        // The wrapper decodes the body it just carved out; `-index=` on the
        // decompress side is handled by the CLI, which opens the index and
        // hands it to `archive::decode` directly.
        archive::decode(&mut body_file, &mut sink, opts, None, None).map_err(DupError::Decode)?;
        sink.flush()?;
    }
    // On the failing path the meta is read last: a body that does not decode
    // fails as it always did, without a `meta_size` worth of memory first.
    let meta = match meta {
        Some(meta) => meta,
        None => read_meta(archive, len, meta_size)?,
    };
    dedup::decode_streaming(&meta, decoded.path(), output).map_err(DupError::Dedup)?;
    Ok(true)
}

/// The first `len` bytes walk as a v1-v4 archive that ends where its blocks
/// (or its footer) say, with no terminator block: its original size, or
/// `None`.
fn reads_as_plain(archive: &mut File, len: u64, stats_out_of_line: bool) -> Option<u64> {
    match container::walk(archive, len, stats_out_of_line) {
        Ok(w) if !w.terminated => Some(w.origsize),
        _ => None,
    }
}

/// What the head (and tail) of an archive say about a v5 `-dup` payload.
enum V5Meta {
    /// Not a v5 archive, or a v5 one without the `-dup` flag that does not end
    /// in a v5 footer: the ODUP trailer is sniffed. (A v5 body under an ODUP
    /// trailer is what the F5.3a tooling writes, `tests/dup_native_roundtrip.sh`.)
    Sniff,
    /// A v5 archive without the `-dup` flag, ending in a valid v5 footer.
    Plain,
    Dup(Vec<u8>),
}

/// The `-dup` payload of a v5 archive.
fn v5_meta(archive: &mut File, len: u64) -> Result<V5Meta, DupError> {
    if len < (v5::HEADER_SIZE + v5::FOOTER_SIZE) as u64 {
        return Ok(V5Meta::Sniff);
    }
    let mut head = [0u8; v5::HEADER_SIZE];
    read_exact_at(archive, 0, &mut head)?;
    if u32::from_le_bytes(head[..4].try_into().unwrap()) != v5::MAGIC {
        return Ok(V5Meta::Sniff);
    }
    let header =
        v5::Header::decode(&head).map_err(|_| DupError::BadDup)?;
    let mut tail = [0u8; v5::FOOTER_SIZE];
    read_exact_at(archive, len - v5::FOOTER_SIZE as u64, &mut tail)?;
    if header.flags & v5::FLAG_HAS_DUP == 0 {
        return Ok(match v5::Footer::decode(&tail) {
            Ok(_) => V5Meta::Plain,
            Err(_) => V5Meta::Sniff,
        });
    }
    let footer = v5::Footer::decode(&tail).map_err(|_| DupError::BadDup)?;

    let blob_len = u64::from(footer.meta_size);
    let end = footer.meta_offset.checked_add(blob_len).ok_or(DupError::BadDup)?;
    // Past `isize::MAX` (a 32-bit build) no buffer here can hold it.
    if blob_len == 0 || end > len || blob_len > isize::MAX as u64 {
        return Err(DupError::BadDup);
    }
    let mut blob = vec![0u8; blob_len as usize];
    read_exact_at(archive, footer.meta_offset, &mut blob)?;
    let payload = v5::decode_meta(&blob).map_err(|_| DupError::BadDup)?;
    Ok(V5Meta::Dup(payload.to_vec()))
}

/// The ODUP trailer of a v4 archive, checked without reading the meta: its
/// `meta_size`, or `None` when the last four bytes are not `ODUP`. Of the
/// meta only the first four bytes are read, for the `DUPR` tag.
fn odup_trailer(archive: &mut File, len: u64) -> Result<Option<u64>, DupError> {
    if len < ODUP_TRAILER_SIZE {
        return Ok(None);
    }
    let mut magic = [0u8; 4];
    read_exact_at(archive, len - 4, &mut magic)?;
    if magic != ODUP_MAGIC {
        return Ok(None);
    }
    let mut size_bytes = [0u8; 8];
    read_exact_at(archive, len - ODUP_TRAILER_SIZE, &mut size_bytes)?;
    let meta_size = u64::from_le_bytes(size_bytes);
    if meta_size > len - ODUP_TRAILER_SIZE || meta_size < 4 {
        return Err(DupError::BadDup);
    }
    // `dup_wrapper.cpp:330-338`: an ODUP trailer whose meta is not a `.dupref`
    // blob is refused (unless the whole file reads as a plain archive, which
    // `decode_odup` decides).
    let mut tag = [0u8; 4];
    read_exact_at(archive, len - ODUP_TRAILER_SIZE - meta_size, &mut tag)?;
    if tag != *b"DUPR" {
        return Err(DupError::BadDup);
    }
    Ok(Some(meta_size))
}

/// The meta of a trailer [`odup_trailer`] passed.
fn read_meta(archive: &mut File, len: u64, meta_size: u64) -> Result<Vec<u8>, DupError> {
    // Past `isize::MAX` (a 32-bit build) is a meta no buffer here can hold,
    // and `as usize` would cut its length.
    if meta_size > isize::MAX as u64 {
        return Err(DupError::BadDup);
    }
    let mut meta = vec![0u8; meta_size as usize];
    read_exact_at(archive, len - ODUP_TRAILER_SIZE - meta_size, &mut meta)?;
    Ok(meta)
}

/// `odup_trailer` over an archive already in memory, for `-i` and `--verify`:
/// the length of the archive the trailer hides, and the meta, or `None` when
/// the last four bytes are not `ODUP`. The checks are `odup_trailer`'s, so what
/// `-i` describes as a `-dup` archive is what `-d` would undo as one.
pub fn split_odup(bytes: &[u8]) -> Result<Option<(usize, &[u8])>, DupError> {
    let len = bytes.len() as u64;
    if len < ODUP_TRAILER_SIZE || bytes[bytes.len() - 4..] != ODUP_MAGIC {
        return Ok(None);
    }
    let at = bytes.len() - ODUP_TRAILER_SIZE as usize;
    let meta_size = u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap());
    if meta_size > len - ODUP_TRAILER_SIZE || meta_size < 4 {
        return Err(DupError::BadDup);
    }
    let body_len = at - meta_size as usize;
    let meta = &bytes[body_len..at];
    if meta[..4] != *b"DUPR" {
        return Err(DupError::BadDup);
    }
    Ok(Some((body_len, meta)))
}

/// A decoder sink: created like `File::create`, but readable too.
fn create_rw(path: &Path) -> std::io::Result<File> {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)
}

/// One `read` at an explicit offset, into a buffer the caller sized.
fn read_exact_at<R: Read + Seek>(r: &mut R, off: u64, buf: &mut [u8]) -> Result<(), DupError> {
    r.seek(SeekFrom::Start(off))?;
    r.read_exact(buf).map_err(|_| DupError::Truncated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoder::Seed;

    /// 5 MiB of a repeated 512 KiB pseudo-random block. CDC only finds
    /// duplicates where there is real repetition and `tests/corpus` has none
    /// (documented in `docs/rust-port.md`), so the tests make their own.
    fn dup_friendly() -> Vec<u8> {
        let mut block = vec![0u8; 1 << 19];
        let mut s = 0x243F_6A88_85A3_08D3u64;
        for b in block.iter_mut() {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            *b = (s & 0xFF) as u8;
        }
        let mut out = Vec::new();
        for _ in 0..10 {
            out.extend_from_slice(&block);
        }
        out.extend_from_slice(b"a tail that is not a whole chunk");
        out
    }

    fn scratch(data: Option<&[u8]>) -> TempFile {
        let f = TempFile::new("osrep-dup-test").unwrap();
        if let Some(d) = data {
            std::fs::write(f.path(), d).unwrap();
        }
        f
    }

    fn v5_mode() -> Mode {
        Mode {
            kind: Kind::Digest,
            container: Container::V5,
        }
    }

    fn options() -> EncodeOptions {
        EncodeOptions {
            seed: Seed::Value(7),
            ..EncodeOptions::default()
        }
    }

    /// `encode` without progress reporting, which is all the tests want.
    fn encode_dup(
        input: &Path,
        output: &Path,
        enc: &EncodeOptions,
        mode: Mode,
        dup: DupParams,
        container: DupMode,
    ) -> Result<u64, DupError> {
        encode(input, output, enc, mode, dup, container, None, None)
    }

    #[test]
    fn v5_dup_embeds_the_dedup_payload_verbatim_and_round_trips() {
        let original = dup_friendly();
        let input = scratch(Some(&original));
        let archive = scratch(None);
        let restored = scratch(None);

        let written = encode_dup(
            input.path(),
            archive.path(),
            &options(),
            v5_mode(),
            DupParams::default(),
            DupMode::V5,
        )
        .unwrap();

        let bytes = std::fs::read(archive.path()).unwrap();
        assert_eq!(written, bytes.len() as u64);
        let parsed = v5::parse(&bytes).unwrap();
        assert_eq!(parsed.header.flags & v5::FLAG_HAS_DUP, v5::FLAG_HAS_DUP);
        let embedded = v5::dup_meta(&bytes, &parsed.footer, &parsed.header)
            .unwrap()
            .unwrap();

        // The payload the archive carries is the one the dedup pass produces --
        // the writer adds the CRC around it and nothing else.
        let body = scratch(None);
        let payload =
            dedup::encode_streaming(input.path(), body.path(), Params::default(), false).unwrap();
        assert_eq!(embedded, &payload[..]);

        assert!(decode(archive.path(), restored.path(), &FutureLzOptions::default()).unwrap());
        assert_eq!(std::fs::read(restored.path()).unwrap(), original);
    }

    #[test]
    fn v4_dup_appends_the_odup_trailer_and_round_trips() {
        let original = dup_friendly();
        let input = scratch(Some(&original));
        let archive = scratch(None);
        let restored = scratch(None);

        let written = encode_dup(
            input.path(),
            archive.path(),
            &options(),
            Mode {
                kind: Kind::Digest,
                container: Container::IndexLz,
            },
            DupParams::default(),
            DupMode::V4,
        )
        .unwrap();

        let bytes = std::fs::read(archive.path()).unwrap();
        assert_eq!(written, bytes.len() as u64);
        let n = bytes.len();
        assert_eq!(&bytes[n - 4..], b"ODUP");
        let meta_size = u64::from_le_bytes(bytes[n - 12..n - 4].try_into().unwrap()) as usize;
        assert!(meta_size >= 24 && meta_size <= n - 12);
        assert_eq!(&bytes[n - 12 - meta_size..n - 8 - meta_size], b"DUPR");

        assert!(decode(archive.path(), restored.path(), &FutureLzOptions::default()).unwrap());
        assert_eq!(std::fs::read(restored.path()).unwrap(), original);
    }

    #[test]
    fn inspect_reads_through_the_odup_trailer() {
        let original = dup_friendly();
        let input = scratch(Some(&original));
        let archive = scratch(None);
        // Gear, so that the pass really drops chunks (the default FNV chunker
        // finds no repeat in `dup_friendly`).
        let params = DupParams {
            chunking: crate::dedup::Params {
                hash_algo: crate::dedup::CDC_HASH_GEAR,
                ..crate::dedup::Params::default()
            },
            paranoid: false,
        };
        let mode = Mode {
            kind: Kind::Digest,
            container: Container::IndexLz,
        };
        encode_dup(input.path(), archive.path(), &options(), mode, params, DupMode::V4).unwrap();
        let bytes = std::fs::read(archive.path()).unwrap();
        let n = bytes.len();

        // The size `-d` restores, the archive behind the trailer, and a meta
        // that dropped chunks.
        let info = archive::inspect(&bytes).unwrap();
        assert_eq!(info.mode, "Index-LZ");
        assert_eq!(info.origsize, original.len() as u64);
        assert_eq!(info.compsize, n as u64);
        let d = info.dup.unwrap();
        assert!(d.unique < d.chunks && d.body_size < original.len() as u64);
        // A meta_size past the file is refused, as `odup_trailer` refuses it.
        let mut bad = bytes.clone();
        bad[n - 12..n - 4].copy_from_slice(&(n as u64).to_le_bytes());
        assert!(archive::inspect(&bad).is_err());
    }

    #[test]
    fn a_plain_archive_is_not_touched() {
        let original = dup_friendly();
        let input = scratch(Some(&original));
        let archive = scratch(None);
        let restored = scratch(None);

        let mut file = File::open(input.path()).unwrap();
        let mut out = File::create(archive.path()).unwrap();
        encoder::encode(&mut file, &mut out, &options(), v5_mode(), None, None).unwrap();
        drop(out);

        // No payload, so the post-pass does not run -- and says so.
        assert!(!decode(archive.path(), restored.path(), &FutureLzOptions::default()).unwrap());
    }

    #[test]
    fn m0_and_the_v4_container_are_refused() {
        let input = scratch(Some(b"x"));
        let archive = scratch(None);
        assert!(matches!(
            encode_dup(
                input.path(),
                archive.path(),
                &options(),
                Mode {
                    kind: Kind::Inmem,
                    container: Container::V5,
                },
                DupParams::default(),
                DupMode::V5,
            ),
            Err(DupError::IncompatibleMethod)
        ));
        assert!(matches!(
            encode_dup(
                input.path(),
                archive.path(),
                &options(),
                Mode {
                    kind: Kind::Digest,
                    container: Container::FutureLz,
                },
                DupParams::default(),
                DupMode::V4,
            ),
            Err(DupError::UnsupportedContainer)
        ));
    }

    #[test]
    fn a_corrupt_v5_payload_is_refused() {
        let input = scratch(Some(&dup_friendly()));
        let archive = scratch(None);
        encode_dup(
            input.path(),
            archive.path(),
            &options(),
            v5_mode(),
            DupParams::default(),
            DupMode::V5,
        )
        .unwrap();

        let mut bytes = std::fs::read(archive.path()).unwrap();
        let meta_offset = v5::parse(&bytes).unwrap().footer.meta_offset as usize;
        // Flip a byte of the payload: the meta CRC has to catch it.
        bytes[meta_offset + 8] ^= 0x01;
        std::fs::write(archive.path(), &bytes).unwrap();

        let restored = scratch(None);
        assert!(matches!(
            decode(archive.path(), restored.path(), &FutureLzOptions::default()),
            Err(DupError::BadDup)
        ));
    }

    /// A plain archive of `data` in `container`, as bytes.
    fn plain(data: &[u8], container: Container, hash: &str) -> Vec<u8> {
        let mut out = Vec::new();
        let opts = EncodeOptions {
            hash: hash.to_string(),
            bufsize: 1 << 16,
            ..options()
        };
        let mode = Mode {
            kind: Kind::Digest,
            container,
        };
        encoder::encode(&mut std::io::Cursor::new(data), &mut out, &opts, mode, None, None)
            .unwrap();
        out
    }

    /// A v4 `-dup` archive of `dup_friendly()`, as bytes.
    fn v4_dup() -> Vec<u8> {
        let input = scratch(Some(&dup_friendly()));
        let archive = scratch(None);
        let mode = Mode {
            kind: Kind::Digest,
            container: Container::IndexLz,
        };
        encode_dup(input.path(), archive.path(), &options(), mode, DupParams::default(), DupMode::V4)
            .unwrap();
        std::fs::read(archive.path()).unwrap()
    }

    /// What `-d` writes for `bytes`: the post-pass, or the plain decoder when
    /// `decode` hands the file back.
    fn restore(bytes: &[u8]) -> Result<Vec<u8>, DupError> {
        let archive = scratch(Some(bytes));
        let restored = scratch(None);
        if !decode(archive.path(), restored.path(), &FutureLzOptions::default())? {
            let mut input = File::open(archive.path()).unwrap();
            let mut sink = create_rw(restored.path()).unwrap();
            archive::decode(&mut input, &mut sink, &FutureLzOptions::default(), None, None)
                .map_err(DupError::Decode)?;
        }
        Ok(std::fs::read(restored.path()).unwrap())
    }

    #[test]
    fn walk_agrees_with_parse() {
        let mut data = dup_friendly();
        data.truncate(300_000);
        for container in [Container::IndexLz, Container::FutureLz, Container::IoLz] {
            let bytes = plain(&data, container, "vmac");
            let mut mutated = vec![bytes.clone()];
            for at in [0, 9, 16 + 32, 16 + 32 + 4, bytes.len() - 20, bytes.len() - 1] {
                let mut m = bytes.clone();
                m[at] ^= 0x40;
                mutated.push(m);
            }
            for b in &mutated {
                for len in (0..=b.len()).step_by(7).chain([b.len()]) {
                    let want = container::Archive::parse(&b[..len])
                        .map(|a| (a.blocks.len() as u64, a.origsize(), a.terminated));
                    let got = container::walk(&mut std::io::Cursor::new(b), len as u64, false)
                        .map(|w| (w.blocks, w.origsize, w.terminated));
                    assert_eq!(got, want, "{container:?} len {len}");
                }
            }
        }
    }

    #[test]
    fn a_plain_archive_of_an_odup_tailed_file_round_trips() {
        // Any v4 `-dup` archive ends in a real trailer; a Future-LZ or I/O LZ
        // archive of it ends in its last literals, which are that trailer.
        let inner = v4_dup();
        for container in [Container::FutureLz, Container::IoLz, Container::IndexLz] {
            for hash in ["vmac", ""] {
                let outer = plain(&inner, container, hash);
                if container != Container::IndexLz {
                    assert_eq!(&outer[outer.len() - 4..], b"ODUP", "{container:?}");
                }
                assert_eq!(restore(&outer).unwrap(), inner, "{container:?} {hash:?}");
            }
        }
        // A file that merely ends in "ODUP", with no meta in front of it.
        let mut tail = dup_friendly();
        tail.truncate(5000);
        tail.extend_from_slice(b"ODUP");
        let outer = plain(&tail, Container::FutureLz, "vmac");
        assert_eq!(restore(&outer).unwrap(), tail);
    }

    #[test]
    fn a_damaged_dup_archive_is_still_refused() {
        // A v1-v3 body, which the C++ writes under `-dup` and these ports do
        // not: the whole file then has a chance of walking as plain blocks.
        let original = dup_friendly();
        let body_file = scratch(None);
        let meta = dedup::encode_streaming(
            scratch(Some(&original)).path(),
            body_file.path(),
            Params::default(),
            false,
        )
        .unwrap();
        let body = std::fs::read(body_file.path()).unwrap();
        for hash in ["vmac", ""] {
            let mut good = plain(&body, Container::FutureLz, hash);
            let at = good.len();
            good.extend_from_slice(&meta);
            good.extend_from_slice(&(meta.len() as u64).to_le_bytes());
            good.extend_from_slice(b"ODUP");
            assert_eq!(restore(&good).unwrap(), original);

            // The meta's first block-header's worth of bytes zeroed: the
            // whole file reads as the body's blocks plus a terminator block,
            // which would restore the body, not the original.
            let mut zeroed = good.clone();
            zeroed[at..at + 12 + 16].fill(0);
            assert!(matches!(restore(&zeroed), Err(DupError::BadDup)), "{hash:?}");
            // A meta that asks for more body than there is.
            let mut cut = plain(&body[..body.len() / 2], Container::FutureLz, hash);
            cut.extend_from_slice(&good[at..]);
            assert!(restore(&cut).is_err(), "{hash:?}");
            // The body damaged: the block digests catch it (with `-hash-`
            // nothing does, `-dup` or not).
            if !hash.is_empty() {
                let mut hurt = good.clone();
                hurt[at / 2] ^= 0x01;
                assert!(restore(&hurt).is_err(), "{hash:?}");
            }
        }
        // The same for the Index-LZ body these ports write.
        let good = v4_dup();
        let n = good.len();
        let meta_size = u64::from_le_bytes(good[n - 12..n - 4].try_into().unwrap()) as usize;
        let mut zeroed = good.clone();
        zeroed[n - 12 - meta_size..n - 12 - meta_size + 4].fill(0);
        assert!(matches!(restore(&zeroed), Err(DupError::BadDup)));
    }

    #[test]
    fn a_v5_archive_is_never_read_as_a_trailer() {
        // A v5 archive whose footer CRC happens to spell "ODUP" (one in 2^32)
        // was sniffed as a v4 trailer and refused. Make one: the high half of
        // `meta_offset`, which nothing reads without a meta, is chosen so that
        // the footer's CRC comes out "ODUP" -- a valid footer, a sound archive.
        let original = dup_friendly();
        let mut bytes = plain(&original, Container::V5, "vmac");
        let n = bytes.len();
        let f = n - v5::FOOTER_SIZE;
        let target = u32::from_le_bytes(*b"ODUP");
        // The CRC is linear (init 0, no final xor): solve for the 32 bits.
        let crc = |b: &[u8]| crate::rolling::crc32c_of(b);
        let mut base = bytes[f..f + 28].to_vec();
        base[20..24].fill(0);
        let mut cols: Vec<(u32, u32)> = (0..32)
            .map(|i| {
                let mut unit = vec![0u8; 28];
                unit[20 + i / 8] = 1 << (i % 8);
                (crc(&unit), 1u32 << i)
            })
            .collect();
        let mut want = target ^ crc(&base);
        let mut pick = 0u32;
        for bit in (0..32).rev() {
            let Some(row) = (0..cols.len()).find(|&r| cols[r].0 >> bit & 1 == 1) else {
                continue;
            };
            let (v, m) = cols.remove(row);
            for c in cols.iter_mut() {
                if c.0 >> bit & 1 == 1 {
                    c.0 ^= v;
                    c.1 ^= m;
                }
            }
            if want >> bit & 1 == 1 {
                want ^= v;
                pick ^= m;
            }
        }
        assert_eq!(want, 0);
        base[20..24].copy_from_slice(&pick.to_le_bytes());
        bytes[f..f + 28].copy_from_slice(&base);
        bytes[n - 4..].copy_from_slice(&crc(&base).to_le_bytes());
        assert_eq!(&bytes[n - 4..], b"ODUP");
        v5::Footer::decode(&bytes[f..]).unwrap();
        assert_eq!(restore(&bytes).unwrap(), original);
    }

    /// The largest single allocation this thread has asked for, so a test can
    /// say what `-d` did *not* allocate.
    mod alloc_probe {
        use std::alloc::{GlobalAlloc, Layout, System};
        use std::cell::Cell;

        thread_local! {
            static LARGEST: Cell<usize> = const { Cell::new(0) };
        }

        fn note(size: usize) {
            let _ = LARGEST.try_with(|c| c.set(c.get().max(size)));
        }

        pub struct Probe;

        unsafe impl GlobalAlloc for Probe {
            unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
                note(layout.size());
                System.alloc(layout)
            }
            unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
                note(layout.size());
                System.alloc_zeroed(layout)
            }
            unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
                System.dealloc(ptr, layout)
            }
            unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
                note(new_size);
                System.realloc(ptr, layout, new_size)
            }
        }

        #[global_allocator]
        static PROBE: Probe = Probe;

        pub fn reset() {
            LARGEST.with(|c| c.set(0));
        }

        pub fn largest() -> usize {
            LARGEST.with(|c| c.get())
        }
    }

    #[test]
    fn a_fake_meta_size_is_not_allocated() {
        // The 8 bytes in front of "ODUP" at the end of a plain Future-LZ or
        // I/O LZ archive are the input's: here a `meta_size` of 3 MB, which
        // `-d` read (and allocated) before it walked anything. Once with
        // "DUPR" where that meta would start, once without.
        const META_SIZE: usize = 3_000_000;
        let mut data = vec![0u8; 4_000_000];
        let mut s = 0x9E37_79B9_7F4A_7C15u64;
        for b in data.iter_mut() {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            *b = (s & 0xFF) as u8;
        }
        let n = data.len();
        data[n - 12..n - 4].copy_from_slice(&(META_SIZE as u64).to_le_bytes());
        data[n - 4..].copy_from_slice(b"ODUP");
        for tagged in [false, true] {
            if tagged {
                data[n - 12 - META_SIZE..n - 8 - META_SIZE].copy_from_slice(b"DUPR");
            }
            for container in [Container::FutureLz, Container::IoLz] {
                // One block, all literals: the archive ends in the input.
                let mut bytes = Vec::new();
                let opts = EncodeOptions {
                    bufsize: 8 << 20,
                    ..options()
                };
                let mode = Mode {
                    kind: Kind::Digest,
                    container,
                };
                encoder::encode(&mut std::io::Cursor::new(&data), &mut bytes, &opts, mode, None, None)
                    .unwrap();
                let len = bytes.len();
                assert_eq!(bytes[len - 12 - META_SIZE..], data[n - 12 - META_SIZE..]);
                let archive = scratch(Some(&bytes));
                let restored = scratch(None);
                alloc_probe::reset();
                let undone = decode(archive.path(), restored.path(), &FutureLzOptions::default());
                let largest = alloc_probe::largest();
                assert!(matches!(undone, Ok(false)), "{container:?} {tagged}");
                assert!(largest < META_SIZE / 2, "{container:?} {tagged}: {largest}");
                assert_eq!(restore(&bytes).unwrap(), data, "{container:?} {tagged}");
            }
        }
    }
}
