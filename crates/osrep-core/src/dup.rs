//! The `-dup` wrapper: the dedup pre-pass glued to the archive encoder, the way
//! `Compression/SREP/dup_wrapper.cpp` glues them at the CLI.
//!
//! `-dup` is two passes. The dedup pass rewrites the input into a *body* (the
//! unique chunks, in order of first appearance) plus a meta blob that says how
//! to put the original back; the archive encoder then compresses the body,
//! which is where the ratio comes from. The meta never goes through the
//! encoder.
//!
//! Where the meta lives is the one thing v4 and v5 disagree on. v4 appends it
//! as an ODUP trailer and finds it by sniffing the last four bytes -- which
//! mis-handles `osrep -d archive.osr` and `-i`; v5 embeds it between the blocks
//! and the footer, which points at it.
//!
//! The C++ writes the body to a tempfile and runs `srep_main` over it with the
//! input filename substituted. This does the same, minus the subprocess: the
//! encoder reads the body as the `Read + Seek` it already takes.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use crate::archive;
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
    let mut out = File::create(output)?;
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
    let mut archive = File::open(input)?;
    let len = archive.seek(SeekFrom::End(0))?;

    // The dedup post-pass needs the body on disk: it seeks back into it to
    // expand the references, so the two halves cannot share a file.
    if let Some(meta) = v5_meta(&mut archive, len)? {
        let body = TempFile::new("osrep-dup-body")?;
        let mut sink = File::create(body.path())?;
        archive.seek(SeekFrom::Start(0))?;
        future_lz::decode_v5(&mut archive, &mut sink, opts, None).map_err(DupError::Decode)?;
        sink.flush()?;
        drop(sink);
        dedup::decode_streaming(&meta, body.path(), output).map_err(DupError::Dedup)?;
        return Ok(true);
    }

    if let Some(meta) = odup_meta(&mut archive, len)? {
        // v4 keeps the body in the archive but hidden behind the trailer; the
        // C++ carves it out to a tempfile before handing it to srep_main, and
        // so does this.
        let body = TempFile::new("osrep-dup-body-osr")?;
        let body_len = len - ODUP_TRAILER_SIZE - meta.len() as u64;
        {
            let mut trimmed = File::create(body.path())?;
            archive.seek(SeekFrom::Start(0))?;
            std::io::copy(&mut (&mut archive).take(body_len), &mut trimmed)?;
        }
        let decoded = TempFile::new("osrep-dup-body-dec")?;
        let mut body_file = File::open(body.path())?;
        let mut sink = File::create(decoded.path())?;
        // The wrapper decodes the body it just carved out; `-index=` on the
        // decompress side is handled by the CLI, which opens the index and
        // hands it to `archive::decode` directly.
        archive::decode(&mut body_file, &mut sink, opts, None, None).map_err(DupError::Decode)?;
        sink.flush()?;
        drop(sink);
        dedup::decode_streaming(&meta, decoded.path(), output).map_err(DupError::Dedup)?;
        return Ok(true);
    }

    Ok(false)
}

/// The `-dup` payload of a v5 archive, or `None` when the archive is not a v5
/// one or carries no payload.
fn v5_meta(archive: &mut File, len: u64) -> Result<Option<Vec<u8>>, DupError> {
    if len < (v5::HEADER_SIZE + v5::FOOTER_SIZE) as u64 {
        return Ok(None);
    }
    let mut head = [0u8; v5::HEADER_SIZE];
    read_exact_at(archive, 0, &mut head)?;
    if u32::from_le_bytes(head[..4].try_into().unwrap()) != v5::MAGIC {
        return Ok(None);
    }
    let header =
        v5::Header::decode(&head).map_err(|_| DupError::BadDup)?;
    if header.flags & v5::FLAG_HAS_DUP == 0 {
        return Ok(None);
    }
    let mut tail = [0u8; v5::FOOTER_SIZE];
    read_exact_at(archive, len - v5::FOOTER_SIZE as u64, &mut tail)?;
    let footer = v5::Footer::decode(&tail).map_err(|_| DupError::BadDup)?;

    let blob_len = u64::from(footer.meta_size);
    let end = footer.meta_offset.checked_add(blob_len).ok_or(DupError::BadDup)?;
    if blob_len == 0 || end > len {
        return Err(DupError::BadDup);
    }
    let mut blob = vec![0u8; blob_len as usize];
    read_exact_at(archive, footer.meta_offset, &mut blob)?;
    let payload = v5::decode_meta(&blob).map_err(|_| DupError::BadDup)?;
    Ok(Some(payload.to_vec()))
}

/// The `-dup` payload of a v4 archive: the ODUP trailer's meta, or `None` when
/// the last four bytes are not `ODUP`.
fn odup_meta(archive: &mut File, len: u64) -> Result<Option<Vec<u8>>, DupError> {
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
    let at = len - ODUP_TRAILER_SIZE - meta_size;
    let mut meta = vec![0u8; meta_size as usize];
    read_exact_at(archive, at, &mut meta)?;
    // `dup_wrapper.cpp:330-338`: an ODUP trailer whose meta is not a `.dupref`
    // blob is almost certainly a coincidence in a non-dup archive.
    if meta[..4] != *b"DUPR" {
        return Err(DupError::BadDup);
    }
    Ok(Some(meta))
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
}
