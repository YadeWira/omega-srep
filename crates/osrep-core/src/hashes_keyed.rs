//! Keyed hashes stored per block: `siphash` (and `vmac` when ported).
//!
//! Rust port of `new_siphash` / `compute_siphash` in
//! `Compression/SREP/hashes.cpp`, which drive the vendored
//! `hashes/siphash/siphash.c`. The algorithm is SipHash-2-4, but the
//! conformance harness diffs against the vendored copy rather than
//! trusting the published vectors alone.
//!
//! The key is copied verbatim from the archive header (`--seed=`, or a
//! random one generated at encode time), so `--seed=N` stays byte-stable
//! only if this matches the C++ bit for bit.

pub const SIPHASH_TAG_LEN_BYTES: usize = 8;
pub const SIPHASH_KEY_LEN_BYTES: usize = 16;

#[inline]
fn sip_round(v: &mut [u64; 4]) {
    v[0] = v[0].wrapping_add(v[1]);
    v[2] = v[2].wrapping_add(v[3]);
    v[1] = v[1].rotate_left(13);
    v[3] = v[3].rotate_left(16);
    v[1] ^= v[0];
    v[3] ^= v[2];
    v[0] = v[0].rotate_left(32);
    v[2] = v[2].wrapping_add(v[1]);
    v[0] = v[0].wrapping_add(v[3]);
    v[1] = v[1].rotate_left(17);
    v[3] = v[3].rotate_left(21);
    v[1] ^= v[2];
    v[3] ^= v[0];
    v[2] = v[2].rotate_left(32);
}

/// SipHash-2-4 over `m`, returning the tag as it is stored in a block:
/// the 64-bit result in little-endian byte order.
pub fn siphash(key: &[u8; SIPHASH_KEY_LEN_BYTES], m: &[u8]) -> [u8; SIPHASH_TAG_LEN_BYTES] {
    let k0 = u64::from_le_bytes(key[0..8].try_into().unwrap());
    let k1 = u64::from_le_bytes(key[8..16].try_into().unwrap());

    let mut v = [
        k0 ^ 0x736f_6d65_7073_6575,
        k1 ^ 0x646f_7261_6e64_6f6d,
        k0 ^ 0x6c79_6765_6e65_7261,
        k1 ^ 0x7465_6462_7974_6573,
    ];

    let len = m.len();
    let mut last7 = ((len & 0xff) as u64) << 56;
    let blocks = len & !7;

    let mut i = 0;
    while i < blocks {
        let mi = u64::from_le_bytes(m[i..i + 8].try_into().unwrap());
        v[3] ^= mi;
        sip_round(&mut v);
        sip_round(&mut v);
        v[0] ^= mi;
        i += 8;
    }

    // The tail (0..=7 bytes) goes into the high bytes of the length word.
    for (j, &b) in m[blocks..].iter().enumerate() {
        last7 |= (b as u64) << (8 * j);
    }

    v[3] ^= last7;
    sip_round(&mut v);
    sip_round(&mut v);
    v[0] ^= last7;
    v[2] ^= 0xff;
    sip_round(&mut v);
    sip_round(&mut v);
    sip_round(&mut v);
    sip_round(&mut v);

    (v[0] ^ v[1] ^ v[2] ^ v[3]).to_le_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn reference_vectors() {
        // The SipHash reference vectors: key 00..0f, message 00..(len-1).
        let key: [u8; 16] = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        ];
        let msg: Vec<u8> = (0..15u8).collect();
        // Stored little-endian, so the hex is the byte-reversed tag.
        assert_eq!(hex(&siphash(&key, &msg[..0])), "310e0edd47db6f72");
        assert_eq!(hex(&siphash(&key, &msg[..1])), "fd67dc93c539f874");
        assert_eq!(hex(&siphash(&key, &msg[..15])), "e545be4961ca29a1");
    }
}
