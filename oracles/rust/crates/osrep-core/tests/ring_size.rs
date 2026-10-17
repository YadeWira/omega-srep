//! The dictionary ring (`dictsize` rounded up to whole blocks, plus two blocks
//! of headroom) is sized with checked arithmetic. Through 2.3.0 a `-b` of 2^63
//! or a little more wrapped the headroom to 0 on 64-bit builds, the ring came
//! out as one block, and the read-ahead slot panicked out of range; a `-d`
//! within a block of 2^64 rounded up to a small ring, and the in-memory
//! dictionary's allocation aborted the process. Each is `OutOfMemory`, as the
//! Pascal port says (`CheckedRingSize`).

use std::io::Cursor;

use osrep_core::encoder::{encode, Container, EncodeError, EncodeOptions, Kind, Mode, Seed};

fn encode_with(bufsize: usize, dictsize: u64, kind: Kind) -> Result<u64, EncodeError> {
    let opts = EncodeOptions {
        bufsize,
        dictsize,
        seed: Seed::Value(7),
        ..EncodeOptions::default()
    };
    let mode = Mode {
        kind,
        container: Container::V5,
    };
    let data = vec![7u8; 4096];
    let mut out = Vec::new();
    encode(&mut Cursor::new(&data), &mut out, &opts, mode, None, None)
}

#[cfg(target_pointer_width = "64")]
#[test]
fn a_block_of_2_to_the_63_is_out_of_memory() {
    for b in [1usize << 63, (1usize << 63) + 1, usize::MAX] {
        assert_eq!(encode_with(b, 0, Kind::Digest), Err(EncodeError::OutOfMemory), "-b{b}b");
    }
}

#[test]
fn a_dictionary_that_rounds_past_u64_is_out_of_memory() {
    for kind in [Kind::Digest, Kind::Inmem] {
        assert_eq!(
            encode_with(3 << 20, u64::MAX, kind),
            Err(EncodeError::OutOfMemory),
            "{kind:?}"
        );
    }
}
