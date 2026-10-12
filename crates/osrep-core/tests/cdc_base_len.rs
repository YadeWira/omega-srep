//! CDC (`-m1`/`-m2`) match records count their length from the archive's
//! BASE_LEN (`min(min_match, dict_min_match)`, the base the decoder adds back),
//! not from CDC's own minimum match raised to 16. Up to 2.2.0 (and in the C++
//! 1.0.7) the two differed whenever `-c` came with an `-l` above 512, a `-dl`
//! was below the CDC minimum, or `-l` was below 16, and every such archive with
//! a CDC match failed to decode ("literal run does not fill the block").

use std::io::Cursor;

use osrep_core::archive;
use osrep_core::encoder::{encode, Container, EncodeOptions, Kind, Mode, Seed};
use osrep_core::future_lz::FutureLzOptions;

fn decode(archive_bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut sink = Cursor::new(Vec::new());
    archive::decode(
        &mut Cursor::new(archive_bytes),
        &mut sink,
        &FutureLzOptions::default(),
        None,
        None,
    )
    .map_err(|e| format!("{e:?}"))?;
    Ok(sink.into_inner())
}

/// A random unit repeated: every copy after the first is a CDC match.
fn repeated(unit: usize, copies: usize, seed: u64) -> Vec<u8> {
    let mut s = seed;
    let u: Vec<u8> = (0..unit)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect();
    u.repeat(copies)
}

fn round_trip(data: &[u8], kind: Kind, min_match: usize, l: usize, dict_min_match: usize) {
    let opts = EncodeOptions {
        min_match,
        l,
        dict_min_match,
        seed: Seed::Value(7),
        ..EncodeOptions::default()
    };
    for container in [
        Container::V5,
        Container::IndexLz,
        Container::IoLz,
        Container::FutureLz,
    ] {
        let mode = Mode { kind, container };
        let mut out = Vec::new();
        encode(&mut Cursor::new(data), &mut out, &opts, mode, None, None).unwrap_or_else(|e| {
            panic!("{kind:?} {container:?} -l{min_match} -c{l} -dl{dict_min_match}: {e:?}")
        });
        let back = decode(&out).unwrap_or_else(|e| {
            panic!("{kind:?} {container:?} -l{min_match} -c{l} -dl{dict_min_match}: decode failed: {e:?}")
        });
        assert!(
            back == data,
            "{kind:?} {container:?} -l{min_match} -c{l} -dl{dict_min_match}: round trip differs"
        );
    }
}

#[test]
fn cdc_with_an_l_below_16_decodes() {
    // -c64 -l8: BASE_LEN 8, CDC min match 16.
    let data = repeated(300, 4, 1);
    round_trip(&data, Kind::Cdc, 8, 64, 0);
    round_trip(&data, Kind::CdcZpaq, 8, 64, 0);
}

#[test]
fn cdc_with_a_dl_below_its_min_match_decodes() {
    // -dl16: BASE_LEN 16, CDC min match 32 (the default).
    let data = repeated(20000, 3, 2);
    round_trip(&data, Kind::Cdc, 0, 0, 16);
    round_trip(&data, Kind::CdcZpaq, 0, 0, 24);
    // -c64 -l100 -dl64: BASE_LEN 64, CDC min match 100.
    round_trip(&repeated(300, 4, 3), Kind::Cdc, 100, 64, 64);
}

#[test]
fn cdc_with_c_and_an_l_above_512_decodes() {
    // -c64 -l600: BASE_LEN min(600, 512) = 512, CDC min match 600.
    let data = repeated(2000, 3, 4);
    round_trip(&data, Kind::Cdc, 600, 64, 0);
    round_trip(&data, Kind::CdcZpaq, 600, 64, 0);
    // -c512 -l1536 on zeros.
    round_trip(&vec![0u8; 1 << 20], Kind::CdcZpaq, 1536, 512, 0);
}

#[test]
fn cdc_where_base_len_was_already_the_min_match_still_decodes() {
    let data = repeated(2000, 3, 5);
    round_trip(&data, Kind::Cdc, 0, 0, 0);
    round_trip(&data, Kind::CdcZpaq, 512, 64, 0);
    round_trip(&data, Kind::Cdc, 768, 64, 768);
}
