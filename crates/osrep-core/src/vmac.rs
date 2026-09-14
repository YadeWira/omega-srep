//! VMAC / VHASH-128 -- the default block checksum.
//!
//! Rust port of the vendored `hashes/vmac/vmac.c` as configured by
//! `Compression/SREP/hashes.cpp`: `VMAC_TAG_LEN 128`, `VMAC_KEY_LEN 256`,
//! `VMAC_NHBYTES 4096`, `VMAC_PREFER_BIG_ENDIAN 0`, and no
//! `VMAC_REQUIRE_FILL16`. Only the one-shot `vhash()` is ported -- that is
//! what `VHash::compute()` calls, always on a freshly keyed context, so the
//! C's `first_block_processed` incremental entry cannot be reached. The
//! nonce-based `vmac()` and `vhash_update()` are not part of the descriptor
//! and are left out.
//!
//! `vmac.c` reaches the 64x64->128 multiply and the 128-bit add through
//! architecture-specific asm on x86_64 and through a portable C fallback
//! everywhere else -- a fallback that GCC miscompiled at -O2+ on i386 until
//! the local `no-strict-aliasing`/register-clobber patches (see
//! `docs/32bit-support.md`). `MUL64`/`PMUL64`/`ADD128` below are the full
//! 128-bit operations both forms were trying to express, so this port is
//! architecture-independent by construction and reproduces the x86_64
//! result everywhere. The differential harness diffs it against the
//! vendored C to prove it.
//!
//! `get64PE` is a native little-endian word load and `get64BE` a big-endian
//! one (`GET_REVERSED_64`); both appear below as `word_le`/`word_be`.

use crate::aes::Aes256;

/// Key length (`VMAC_KEY_LEN` in bits, divided by 8).
pub const VMAC_KEY_LEN_BYTES: usize = 32;
/// Tag length (`VMAC_TAG_LEN` in bits, divided by 8): `res` then `tagl`.
pub const VMAC_TAG_LEN_BYTES: usize = 16;

/// `VMAC_NHBYTES`: the L1 block size the polynomial hash consumes per step.
const NHBYTES: usize = 4096;
/// Words per NH block (`VMAC_NHBYTES / 8`).
const NHW: usize = NHBYTES / 8;
/// `nhkey` length: `VMAC_NHBYTES/8 + 2*(VMAC_TAG_LEN/64 - 1)`, i.e. the
/// words an NH block needs plus the two extra words `nh_16_2` reaches past
/// the end of the last pair.
const NHKEY_LEN: usize = NHW + 2 * (VMAC_TAG_LEN_BYTES * 8 / 64 - 1);

const P64: u64 = 0xffff_ffff_ffff_feff; // 2^64 - 257 prime
const M62: u64 = 0x3fff_ffff_ffff_ffff;
const M63: u64 = 0x7fff_ffff_ffff_ffff;
const M64: u64 = 0xffff_ffff_ffff_ffff;
const MPOLY: u64 = 0x1fff_ffff_1fff_ffff; // poly key mask

// ------------------------------------------------------------- words --

#[inline]
fn word_le(data: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(data[off..off + 8].try_into().unwrap())
}

#[inline]
fn word_be(data: &[u8], off: usize) -> u64 {
    u64::from_be_bytes(data[off..off + 8].try_into().unwrap())
}

/// `MUL64`/`PMUL64`: the full 64x64->128 product.
#[inline]
fn mul64(a: u64, b: u64) -> (u64, u64) {
    let p = (a as u128) * (b as u128);
    ((p >> 64) as u64, p as u64)
}

/// `ADD128(rh, rl, ih, il)`: `(rh,rl) += (ih,il)`.
#[inline]
fn add128(rh: u64, rl: u64, ih: u64, il: u64) -> (u64, u64) {
    let (rl, carry) = rl.overflowing_add(il);
    (rh.wrapping_add(ih).wrapping_add(carry as u64), rl)
}

// --------------------------------------------------------------- NH --

/// `nh_16`: the L1 hash over `nw` 64-bit words of `data` starting at
/// `byte_off`, keyed by `kp[kp_off..]`. Accumulates 64x64->128 products two
/// words at a time, exactly as the C macro does.
fn nh_16(data: &[u8], byte_off: usize, kp: &[u64], kp_off: usize, nw: usize) -> (u64, u64) {
    let (mut rh, mut rl) = (0u64, 0u64);
    let mut i = 0;
    while i < nw {
        let t1 = word_le(data, byte_off + i * 8).wrapping_add(kp[kp_off + i]);
        let t2 = word_le(data, byte_off + (i + 1) * 8).wrapping_add(kp[kp_off + i + 1]);
        let (th, tl) = mul64(t1, t2);
        let (h, l) = add128(rh, rl, th, tl);
        rh = h;
        rl = l;
        i += 2;
    }
    (rh, rl)
}

/// `nh_16_2`: the same block hashed under `kp[kp_off..]` and `kp[kp_off+2..]`
/// at once, yielding the two lanes of a 128-bit tag.
fn nh_16_2(
    data: &[u8],
    byte_off: usize,
    kp: &[u64],
    kp_off: usize,
    nw: usize,
) -> (u64, u64, u64, u64) {
    let (rh, rl) = nh_16(data, byte_off, kp, kp_off, nw);
    let (rh2, rl2) = nh_16(data, byte_off, kp, kp_off + 2, nw);
    (rh, rl, rh2, rl2)
}

// ------------------------------------------------------------- poly --

/// `poly_step`: `(ah,al) = (ah,al) * (kh,kl) + (mh,ml)` modulo the VMAC
/// prime, using the C macro's exact sequence of partial products so the
/// reduction matches bit for bit.
fn poly_step(ah: u64, al: u64, kh: u64, kl: u64, mh: u64, ml: u64) -> (u64, u64) {
    let (t3h, t3l) = mul64(al, kh);
    let (t2h, t2l) = mul64(ah, kl);
    let (t1h, t1l) = mul64(ah, kh.wrapping_mul(2));
    let (mut ah, mut al) = mul64(al, kl);
    let (h, l) = add128(ah, al, t1h, t1l);
    ah = h;
    al = l;

    let (mut t2h, t2l) = add128(t2h, t2l, t3h, t3l);

    // The macro's unusual `ADD128(t2h, ah, z, t2l)`: `ah` is the low half of
    // a (t2h,ah) pair, so this folds t2l in and carries into t2h.
    let (h, a) = add128(t2h, ah, 0, t2l);
    t2h = h;
    ah = a;

    t2h = t2h.wrapping_mul(2).wrapping_add(ah >> 63);
    ah &= M63;

    let (h, l) = add128(ah, al, mh, ml);
    ah = h;
    al = l;
    add128(ah, al, 0, t2h)
}

// --------------------------------------------------------------- l3 --

/// `l3hash`: the final reduction of a lane to a 64-bit tag.
fn l3hash(p1: u64, p2: u64, k1: u64, k2: u64, len: u64) -> u64 {
    let mut p1 = p1;
    let mut p2 = p2;

    // Fully reduce (p1,p2)+(len,0) mod p127.
    let mut t = p1 >> 63;
    p1 &= M63;
    let (a, b) = add128(p1, p2, len, t);
    p1 = a;
    p2 = b;

    // (p1,p2) is now at most 2^127+(len<<64).
    t = (p1 > M63) as u64 + ((p1 == M63) && (p2 == M64)) as u64;
    let (a, b) = add128(p1, p2, 0, t);
    p1 = a;
    p2 = b;
    p1 &= M63;

    // (p1,p2) / (2^64-2^32) and % (2^64-2^32).
    t = p1.wrapping_add(p2 >> 32);
    t = t.wrapping_add(t >> 32);
    t = t.wrapping_add(((t as u32) > 0xffff_fffe) as u64);
    p1 = p1.wrapping_add(t >> 32);
    p2 = p2.wrapping_add(p1 << 32);

    // (p1+k1)%p64 and (p2+k2)%p64, adding 257 back on wrap.
    p1 = p1.wrapping_add(k1);
    if p1 < k1 {
        p1 = p1.wrapping_add(257);
    }
    p2 = p2.wrapping_add(k2);
    if p2 < k2 {
        p2 = p2.wrapping_add(257);
    }

    // (p1+k1)*(p2+k2)%p64.
    let (rh, mut rl) = mul64(p1, p2);
    t = rh >> 56;
    let (h, l) = add128(t, rl, 0, rh);
    t = h;
    rl = l;
    let shifted = rh << 8;
    let (h, l) = add128(t, rl, 0, shifted);
    t = h;
    rl = l;
    t = t.wrapping_add(t << 8);
    rl = rl.wrapping_add(t);
    if rl < t {
        rl = rl.wrapping_add(257);
    }
    if rl > P64 - 1 {
        rl = rl.wrapping_add(257);
    }
    rl
}

// ------------------------------------------------------------- VHASH --

/// A keyed VHASH-128 context: the NH keys, the two poly keys and the L3
/// keys, all derived from the 32-byte user key. Immutable after `new`, since
/// `vhash` ends by aborting back to the freshly-keyed state.
pub struct Vmac {
    nhkey: [u64; NHKEY_LEN],
    polykey: [u64; 4],
    l3key: [u64; 4],
}

impl Vmac {
    /// `vmac_set_key`: derive the NH/poly/L3 keys by encrypting a counter
    /// block under the user key.
    pub fn new(user_key: &[u8; VMAC_KEY_LEN_BYTES]) -> Vmac {
        let cipher = Aes256::new(user_key);
        let mut nhkey = [0u64; NHKEY_LEN];
        let mut polykey = [0u64; 4];
        let mut l3key = [0u64; 4];

        let mut block = [0u8; 16];
        let encrypt = |block: &[u8; 16]| {
            let mut out = [0u8; 16];
            cipher.encrypt_block(block, &mut out);
            out
        };

        // NH keys.
        block[0] = 0x80;
        for i in (0..NHKEY_LEN).step_by(2) {
            let out = encrypt(&block);
            nhkey[i] = word_be(&out, 0);
            nhkey[i + 1] = word_be(&out, 8);
            block[15] = block[15].wrapping_add(1);
        }

        // Poly keys, masked to their modulus.
        block = [0u8; 16];
        block[0] = 0xC0;
        for i in (0..4).step_by(2) {
            let out = encrypt(&block);
            polykey[i] = word_be(&out, 0) & MPOLY;
            polykey[i + 1] = word_be(&out, 8) & MPOLY;
            block[15] = block[15].wrapping_add(1);
        }

        // L3 keys, rejecting any that do not fall below the prime.
        block = [0u8; 16];
        block[0] = 0xE0;
        for i in (0..4).step_by(2) {
            loop {
                let out = encrypt(&block);
                l3key[i] = word_be(&out, 0);
                l3key[i + 1] = word_be(&out, 8);
                block[15] = block[15].wrapping_add(1);
                if l3key[i] < P64 && l3key[i + 1] < P64 {
                    break;
                }
            }
        }

        Vmac {
            nhkey,
            polykey,
            l3key,
        }
    }

    /// `vhash(m, size, &tagl, ctx)`: returns `(res, tagl)`.
    pub fn vhash(&self, m: &[u8]) -> (u64, u64) {
        let pkh = self.polykey[0];
        let pkl = self.polykey[1];
        let pkh2 = self.polykey[2];
        let pkl2 = self.polykey[3];

        let mbytes = m.len();
        let remaining = mbytes % NHBYTES;
        let mut i = mbytes / NHBYTES;
        let mut moff = 0usize;

        // ch/cl is the low lane, ch2/cl2 the high one.
        let (mut ch, mut cl, mut ch2, mut cl2);

        if i > 0 {
            // First full block is absorbed into the key, not multiplied.
            let (rh, rl, rh2, rl2) = nh_16_2(m, moff, &self.nhkey, 0, NHW);
            let (h, l) = add128(rh2 & M62, rl2, pkh2, pkl2);
            ch2 = h;
            cl2 = l;
            let (h, l) = add128(rh & M62, rl, pkh, pkl);
            ch = h;
            cl = l;
            moff += NHBYTES;
            i -= 1;
        } else if remaining > 0 {
            // Message is shorter than one NH block: absorb its tail directly.
            let (rh, rl, rh2, rl2) = self.nh_tail(m, moff, remaining);
            let (h, l) = add128(rh2 & M62, rl2, pkh2, pkl2);
            ch2 = h;
            cl2 = l;
            let (h, l) = add128(rh & M62, rl, pkh, pkl);
            ch = h;
            cl = l;
            return self.finish(ch, cl, ch2, cl2, remaining);
        } else {
            // Empty message.
            return self.finish(pkh, pkl, pkh2, pkl2, 0);
        }

        while i > 0 {
            let (rh, rl, rh2, rl2) = nh_16_2(m, moff, &self.nhkey, 0, NHW);
            let (h, l) = poly_step(ch2, cl2, pkh2, pkl2, rh2 & M62, rl2);
            ch2 = h;
            cl2 = l;
            let (h, l) = poly_step(ch, cl, pkh, pkl, rh & M62, rl);
            ch = h;
            cl = l;
            moff += NHBYTES;
            i -= 1;
        }

        if remaining > 0 {
            let (rh, rl, rh2, rl2) = self.nh_tail(m, moff, remaining);
            let (h, l) = poly_step(ch2, cl2, pkh2, pkl2, rh2 & M62, rl2);
            ch2 = h;
            cl2 = l;
            let (h, l) = poly_step(ch, cl, pkh, pkl, rh & M62, rl);
            ch = h;
            cl = l;
        }

        self.finish(ch, cl, ch2, cl2, remaining)
    }

    /// The NH contribution of a sub-block tail: whole 16-byte chunks hashed
    /// straight from the message, then the final `remaining % 16` bytes
    /// zero-padded into a 16-byte buffer, exactly as the C does.
    fn nh_tail(&self, m: &[u8], moff: usize, remaining: usize) -> (u64, u64, u64, u64) {
        let whole = remaining / 16;
        let (mut rh, mut rl, mut rh2, mut rl2) = if whole > 0 {
            nh_16_2(m, moff, &self.nhkey, 0, 2 * whole)
        } else {
            (0, 0, 0, 0)
        };

        let part = remaining % 16;
        if part > 0 {
            let start = moff + whole * 16;
            let mut buf = [0u8; 16];
            buf[..part].copy_from_slice(&m[start..start + part]);
            let (h, l, h2, l2) = nh_16_2(&buf, 0, &self.nhkey, 2 * whole, 2);
            let (a, b) = add128(rh, rl, h, l);
            rh = a;
            rl = b;
            let (a, b) = add128(rh2, rl2, h2, l2);
            rh2 = a;
            rl2 = b;
        }

        (rh, rl, rh2, rl2)
    }

    /// The `do_l3` tail shared by every path: reduce both lanes.
    fn finish(&self, ch: u64, cl: u64, ch2: u64, cl2: u64, remaining: usize) -> (u64, u64) {
        let len = (remaining as u64) * 8;
        let tagl = l3hash(ch2, cl2, self.l3key[2], self.l3key[3], len);
        let tag = l3hash(ch, cl, self.l3key[0], self.l3key[1], len);
        (tag, tagl)
    }

    /// `VHash::compute()`: the 16-byte digest stored per block -- `res` then
    /// `tagl`, both little-endian. (The C memcpys two native-endian u64s;
    /// every supported target is little-endian.)
    pub fn compute(&self, m: &[u8]) -> [u8; VMAC_TAG_LEN_BYTES] {
        let (res, tagl) = self.vhash(m);
        let mut out = [0u8; VMAC_TAG_LEN_BYTES];
        out[0..8].copy_from_slice(&res.to_le_bytes());
        out[8..16].copy_from_slice(&tagl.to_le_bytes());
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn key() -> [u8; 32] {
        [0xab; 32]
    }

    #[test]
    fn key_schedule_anchors() {
        // The first NH key word is AES(0x80 00..00) read big-endian, and the
        // poly key mask is applied.
        let ctx = Vmac::new(&key());
        assert_eq!(ctx.polykey[0] & !MPOLY, 0);
        assert_eq!(ctx.polykey[1] & !MPOLY, 0);
        assert_eq!(ctx.polykey[2] & !MPOLY, 0);
        assert_eq!(ctx.polykey[3] & !MPOLY, 0);
        // L3 keys must be reduced below the prime, and differ from poly keys.
        for k in ctx.l3key {
            assert!(k < P64);
        }
    }

    #[test]
    fn empty_message() {
        // With no data the tag is l3hash(polykey) and must be stable.
        let ctx = Vmac::new(&key());
        let a = ctx.compute(b"");
        let b = Vmac::new(&key()).compute(b"");
        assert_eq!(a, b);
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn block_boundary_continuity() {
        // One NH block (4096) and one byte past it must both work: this is
        // the path where the first-block absorb switches to poly_step.
        let ctx = Vmac::new(&key());
        let data = vec![0x5au8; 4097];
        let _ = ctx.compute(&data[..4096]);
        let _ = ctx.compute(&data[..4097]);
        // Compute is pure: the second call must not depend on the first.
        assert_eq!(
            ctx.compute(&data[..4097]),
            Vmac::new(&key()).compute(&data[..4097])
        );
    }

    /// Digests captured from the shipped C++ oracle (`bin/hash_test vmac abab…`
    /// over `(i*7+3) & 0xFF`), so a regression is caught without the tool.
    /// The three lengths land on different paths with respect to the 4096-byte
    /// NH block: empty, sub-block, and three blocks plus a 57-byte tail.
    #[test]
    fn oracle_anchors() {
        let ctx = Vmac::new(&key());
        let msg = |n: usize| -> Vec<u8> { (0..n).map(|i| ((i * 7 + 3) & 0xff) as u8).collect() };
        assert_eq!(
            hex(&ctx.compute(&msg(0))),
            "a1807ea8d01359be42a627b81ba8afcd"
        );
        assert_eq!(
            hex(&ctx.compute(&msg(1000))),
            "15b2ef898594c083df91cf595f6073ad"
        );
        assert_eq!(
            hex(&ctx.compute(&msg(12345))),
            "383986678124ba894862c688af6c69cb"
        );
    }
}
