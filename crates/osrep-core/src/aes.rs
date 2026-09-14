//! AES-256 block encryption -- the primitive `vmac` is built on.
//!
//! Rust port of the `LTC_RIJNDAEL` + `ENCRYPT_ONLY` build of the vendored
//! LibTomCrypt `ciphers/aes/aes.c` (`Compression/_Encryption/ciphers/aes/`).
//! That is exactly how the C++ reaches AES: `hashes.cpp` sets
//! `VMAC_USE_LIB_TOM_CRYPT`, so `vmac.c` calls
//! `aes_enc_setup(key, 32, 0, skey)` + `aes_enc_ecb_encrypt(pt, ct, skey)`
//! with `VMAC_KEY_LEN == 256`. Only that path is ported -- no decryption, no
//! 128/192-bit schedules, no cipher modes.
//!
//! The T-tables are *derived* here instead of transcribing the 1280 hand-typed
//! constants of `aes_tab.c`. The vendored header documents the same
//! definitions (`Te0[x] = S[x].[02,01,01,03]`, `Te1/Te2/Te3` are the byte
//! rotations of `Te0`, `Te4[x] = S[x].[01,01,01,01]`), so the derivation is
//! what those tables encode; the `aes` mode of the differential harness diffs
//! this against the vendored C to prove it bit for bit.

/// Key length of the only schedule VMAC uses (`VMAC_KEY_LEN == 256`).
pub const AES256_KEY_LEN: usize = 32;
/// AES block size in bytes.
pub const AES_BLOCK_SIZE: usize = 16;

// ------------------------------------------------------------- S-box --

/// The AES S-box, generated from its definition -- the multiplicative inverse
/// in GF(2^8) followed by the affine transform -- so there is no 256-entry
/// table to mistranscribe.
const SBOX: [u8; 256] = make_sbox();

/// Carry-less multiply in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1 (0x11b).
const fn gf_mul(a: u8, b: u8) -> u8 {
    let mut a = a;
    let mut b = b;
    let mut p: u8 = 0;
    let mut i = 0;
    while i < 8 {
        if b & 1 != 0 {
            p ^= a;
        }
        let hi = a & 0x80;
        a <<= 1;
        if hi != 0 {
            a ^= 0x1b;
        }
        b >>= 1;
        i += 1;
    }
    p
}

/// Multiplicative inverse in GF(2^8), with `0` mapped to `0`. x^254 == x^-1
/// for every non-zero x, evaluated by repeated squaring.
const fn gf_inv(x: u8) -> u8 {
    if x == 0 {
        return 0;
    }
    let x2 = gf_mul(x, x);
    let x4 = gf_mul(x2, x2);
    let x8 = gf_mul(x4, x4);
    let x16 = gf_mul(x8, x8);
    let x32 = gf_mul(x16, x16);
    let x64 = gf_mul(x32, x32);
    let x128 = gf_mul(x64, x64);
    let mut r = gf_mul(x2, x4);
    r = gf_mul(r, x8);
    r = gf_mul(r, x16);
    r = gf_mul(r, x32);
    r = gf_mul(r, x64);
    r = gf_mul(r, x128);
    r
}

const fn make_sbox() -> [u8; 256] {
    let mut s = [0u8; 256];
    let mut x = 0usize;
    while x < 256 {
        let inv = gf_inv(x as u8);
        // Affine transform: b_i = inv_i ^ inv_{i+4} ^ inv_{i+5} ^ inv_{i+6}
        // ^ inv_{i+7} ^ c_i, with c = 0x63 (indices mod 8).
        let mut y: u8 = 0;
        let mut bit = 0;
        while bit < 8 {
            let v = ((inv >> bit) & 1)
                ^ ((inv >> ((bit + 4) % 8)) & 1)
                ^ ((inv >> ((bit + 5) % 8)) & 1)
                ^ ((inv >> ((bit + 6) % 8)) & 1)
                ^ ((inv >> ((bit + 7) % 8)) & 1)
                ^ ((0x63u8 >> bit) & 1);
            y |= v << bit;
            bit += 1;
        }
        s[x] = y;
        x += 1;
    }
    s
}

// ----------------------------------------------------------- T-tables --

/// Multiply by 2 in GF(2^8) (i.e. `Te0`'s `.02` factor).
const fn xtime(x: u8) -> u8 {
    let r = x << 1;
    if x & 0x80 != 0 {
        r ^ 0x1b
    } else {
        r
    }
}

/// `TE0[x] = S[x].[02,01,01,03]`, packed big-endian exactly like `aes_tab.c`.
const fn make_te0() -> [u32; 256] {
    let mut t = [0u32; 256];
    let mut x = 0usize;
    while x < 256 {
        let s = SBOX[x];
        let s2 = xtime(s);
        let s3 = s2 ^ s;
        t[x] = ((s2 as u32) << 24) | ((s as u32) << 16) | ((s as u32) << 8) | (s3 as u32);
        x += 1;
    }
    t
}

const fn rotate_table(src: [u32; 256], n: u32) -> [u32; 256] {
    let mut t = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        t[i] = src[i].rotate_right(n);
        i += 1;
    }
    t
}

const TE0: [u32; 256] = make_te0();
const TE1: [u32; 256] = rotate_table(TE0, 8);
const TE2: [u32; 256] = rotate_table(TE0, 16);
const TE3: [u32; 256] = rotate_table(TE0, 24);

// -------------------------------------------------------------- words --

/// `byte(x, n)` from `tomcrypt_macros.h`: the n-th least significant byte.
#[inline]
fn byte0(x: u32) -> usize {
    (x & 0xff) as usize
}
#[inline]
fn byte1(x: u32) -> usize {
    ((x >> 8) & 0xff) as usize
}
#[inline]
fn byte2(x: u32) -> usize {
    ((x >> 16) & 0xff) as usize
}
#[inline]
fn byte3(x: u32) -> usize {
    ((x >> 24) & 0xff) as usize
}

/// `LOAD32H`: big-endian word load (the vendored macro is `movl`+`bswap`, i.e.
/// big-endian on every target).
#[inline]
fn load32h(b: &[u8]) -> u32 {
    ((b[0] as u32) << 24) | ((b[1] as u32) << 16) | ((b[2] as u32) << 8) | (b[3] as u32)
}

#[inline]
fn store32h(v: u32, b: &mut [u8]) {
    b[0] = (v >> 24) as u8;
    b[1] = (v >> 16) as u8;
    b[2] = (v >> 8) as u8;
    b[3] = v as u8;
}

/// `setup_mix()`: the key-schedule SubWord, which is
/// `Te4_3[byte(t,2)] ^ Te4_2[byte(t,1)] ^ Te4_1[byte(t,0)] ^ Te4_0[byte(t,3)]`.
/// Since `Te4_n[v]` is `S[v]` shifted into byte `n`, the four terms occupy
/// disjoint bytes and the XOR is a plain combine.
#[inline]
fn setup_mix(t: u32) -> u32 {
    ((SBOX[byte2(t)] as u32) << 24)
        | ((SBOX[byte1(t)] as u32) << 16)
        | ((SBOX[byte0(t)] as u32) << 8)
        | (SBOX[byte3(t)] as u32)
}

/// The last round's byte substitution:
/// `Te4_3[a] ^ Te4_2[b] ^ Te4_1[c] ^ Te4_0[d]` again as disjoint bytes.
#[inline]
fn te4_mix(a: usize, b: usize, c: usize, d: usize) -> u32 {
    ((SBOX[a] as u32) << 24) | ((SBOX[b] as u32) << 16) | ((SBOX[c] as u32) << 8) | (SBOX[d] as u32)
}

// ---------------------------------------------------------- the cipher --

/// An expanded AES-256 key schedule (`Nr == 14`, 60 words of `eK`).
#[derive(Clone, Copy)]
pub struct Aes256 {
    ek: [u32; 60],
}

impl Aes256 {
    /// The `ENCRYPT_ONLY` branch of `SETUP()` for `keylen == 32`,
    /// i.e. `aes_enc_setup(key, 32, 0, skey)`.
    pub fn new(key: &[u8; AES256_KEY_LEN]) -> Aes256 {
        let mut ek = [0u32; 60];
        for w in 0..8 {
            ek[w] = load32h(&key[4 * w..4 * w + 4]);
        }

        // rcon[0..7] as in `aes_tab.c`; AES-256's schedule needs seven.
        const RCON: [u32; 7] = [
            0x0100_0000,
            0x0200_0000,
            0x0400_0000,
            0x0800_0000,
            0x1000_0000,
            0x2000_0000,
            0x4000_0000,
        ];

        let mut i = 0;
        let mut base = 0;
        loop {
            let t = ek[base + 7];
            ek[base + 8] = ek[base] ^ setup_mix(t) ^ RCON[i];
            ek[base + 9] = ek[base + 1] ^ ek[base + 8];
            ek[base + 10] = ek[base + 2] ^ ek[base + 9];
            ek[base + 11] = ek[base + 3] ^ ek[base + 10];
            i += 1;
            if i == 7 {
                break;
            }
            // The second half of a 256-bit round uses no rotation, which the
            // C writes as `setup_mix(RORc(temp, 8))`.
            let t = ek[base + 11];
            ek[base + 12] = ek[base + 4] ^ setup_mix(t.rotate_right(8));
            ek[base + 13] = ek[base + 5] ^ ek[base + 12];
            ek[base + 14] = ek[base + 6] ^ ek[base + 13];
            ek[base + 15] = ek[base + 7] ^ ek[base + 14];
            base += 8;
        }

        Aes256 { ek }
    }

    /// `ECB_ENC` / `aes_enc_ecb_encrypt`: encrypt one 16-byte block.
    pub fn encrypt_block(&self, pt: &[u8; AES_BLOCK_SIZE], ct: &mut [u8; AES_BLOCK_SIZE]) {
        let ek = &self.ek;

        let (mut s0, mut s1, mut s2, mut s3) = (
            load32h(&pt[0..4]) ^ ek[0],
            load32h(&pt[4..8]) ^ ek[1],
            load32h(&pt[8..12]) ^ ek[2],
            load32h(&pt[12..16]) ^ ek[3],
        );

        // 14 rounds: `Nr >> 1` iterations of the two-round body.
        let mut base = 0usize;
        let mut r = 14usize >> 1;
        let (mut t0, mut t1, mut t2, mut t3);
        loop {
            t0 = TE0[byte3(s0)] ^ TE1[byte2(s1)] ^ TE2[byte1(s2)] ^ TE3[byte0(s3)] ^ ek[base + 4];
            t1 = TE0[byte3(s1)] ^ TE1[byte2(s2)] ^ TE2[byte1(s3)] ^ TE3[byte0(s0)] ^ ek[base + 5];
            t2 = TE0[byte3(s2)] ^ TE1[byte2(s3)] ^ TE2[byte1(s0)] ^ TE3[byte0(s1)] ^ ek[base + 6];
            t3 = TE0[byte3(s3)] ^ TE1[byte2(s0)] ^ TE2[byte1(s1)] ^ TE3[byte0(s2)] ^ ek[base + 7];

            base += 8;
            r -= 1;
            if r == 0 {
                break;
            }

            s0 = TE0[byte3(t0)] ^ TE1[byte2(t1)] ^ TE2[byte1(t2)] ^ TE3[byte0(t3)] ^ ek[base];
            s1 = TE0[byte3(t1)] ^ TE1[byte2(t2)] ^ TE2[byte1(t3)] ^ TE3[byte0(t0)] ^ ek[base + 1];
            s2 = TE0[byte3(t2)] ^ TE1[byte2(t3)] ^ TE2[byte1(t0)] ^ TE3[byte0(t1)] ^ ek[base + 2];
            s3 = TE0[byte3(t3)] ^ TE1[byte2(t0)] ^ TE2[byte1(t1)] ^ TE3[byte0(t2)] ^ ek[base + 3];
        }

        // Last round: SubBytes/ShiftRows without MixColumns, then the final
        // round key (`base` now points at eK[56]).
        let n0 = te4_mix(byte3(t0), byte2(t1), byte1(t2), byte0(t3)) ^ ek[base];
        let n1 = te4_mix(byte3(t1), byte2(t2), byte1(t3), byte0(t0)) ^ ek[base + 1];
        let n2 = te4_mix(byte3(t2), byte2(t3), byte1(t0), byte0(t1)) ^ ek[base + 2];
        let n3 = te4_mix(byte3(t3), byte2(t0), byte1(t1), byte0(t2)) ^ ek[base + 3];

        store32h(n0, &mut ct[0..4]);
        store32h(n1, &mut ct[4..8]);
        store32h(n2, &mut ct[8..12]);
        store32h(n3, &mut ct[12..16]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn sbox_anchors() {
        // The generated S-box vs. the published table.
        assert_eq!(SBOX[0x00], 0x63);
        assert_eq!(SBOX[0x01], 0x7c);
        assert_eq!(SBOX[0x53], 0xed);
        assert_eq!(SBOX[0xff], 0x16);
    }

    #[test]
    fn t_table_anchors() {
        // First entries of `aes_tab.c`'s TE0/TE1/TE2/TE3.
        assert_eq!(TE0[0], 0xc66363a5);
        assert_eq!(TE0[1], 0xf87c7c84);
        assert_eq!(TE1[0], 0xa5c66363);
        assert_eq!(TE2[0], 0x63a5c663);
        assert_eq!(TE3[0], 0x6363a5c6);
    }

    #[test]
    fn fips197_aes256_vector() {
        // FIPS-197 Appendix C.3, also the 32-byte case of the vendored
        // `rijndael_test()` self-test in `aes.c`.
        let key: [u8; 32] = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b,
            0x1c, 0x1d, 0x1e, 0x1f,
        ];
        let pt: [u8; 16] = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ];
        let mut ct = [0u8; 16];
        Aes256::new(&key).encrypt_block(&pt, &mut ct);
        assert_eq!(hex(&ct), "8ea2b7ca516745bfeafc49904b496089");
    }

    #[test]
    fn repeating_the_block_is_deterministic() {
        // ECB with no chaining: the same key + block must re-encrypt to the
        // same ciphertext, and separate schedules must agree.
        let key = [0x42u8; 32];
        let pt = [0xa5u8; 16];
        let a = Aes256::new(&key);
        let b = Aes256::new(&key);
        let mut c1 = [0u8; 16];
        let mut c2 = [0u8; 16];
        a.encrypt_block(&pt, &mut c1);
        b.encrypt_block(&pt, &mut c2);
        assert_eq!(c1, c2);
    }
}
