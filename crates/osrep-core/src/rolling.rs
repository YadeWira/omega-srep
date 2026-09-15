//! Rolling hashes the encoder's match finders are built on.
//!
//! Ported from `Compression/SREP/hashes.cpp` (`PolynomialRollingHash`,
//! `CrcRollingHash`, `FastTableBuild`, `power`). These decide where `-m1`/`-m2`
//! cut chunks and which candidate positions `-m3`/`-m4`/`-m5` probe, so the
//! values must match the C++ exactly: any divergence moves a chunk boundary or
//! a probe, and the archive diverges from there on.
//!
//! Everything is computed with wrapping arithmetic, which is what the C++
//! relies on (unsigned overflow). The C++ also carries hand-unrolled
//! `update<N>` variants and SIMD `moveto`; those compute the same values as the
//! plain loops used here — the `-a0`/`-a16` byte-identity experiment in
//! `docs/rust-port.md` is what proves the unrolled forms are output-neutral, so
//! the port keeps the simple forms.

/// `PRIME1` (`hashes.cpp:197`), the seed of every `PolynomialRollingHash` the
/// encoder builds. Declared `uint32` in the C++ and widened on use, so the
/// constant here is the same value in `u64`.
pub const PRIME1: u64 = 153191;

/// `Crc32CastagnoliPolynom` (`hashes.cpp:307`), reflected.
pub const CRC32_CASTAGNOLI_POLYNOM: u32 = 0x82F63B78;

/// `power()` (`hashes.cpp:95`), kept in the C++'s own order so the wrapping
/// multiplies land on the same values.
pub fn power(base: u64, n: u32) -> u64 {
    let mut result: u64 = 1;
    let mut base = base;
    let mut n = n;
    while n != 0 {
        if n % 2 == 1 {
            result = result.wrapping_mul(base);
            n -= 1;
        }
        n /= 2;
        base = base.wrapping_mul(base);
    }
    result
}

/// `PolynomialRollingHash<uint64>` (`hashes.cpp:130`): the hash of an L-byte
/// window is `sum buf[i] * PRIME^(L-1-i)` mod 2^64.
///
/// The encoder builds several of these (`hash1`/`hash2` in `compress.cpp`,
/// `hash` in `compress_inmem.cpp`) and rolls them one byte at a time, so the
/// port does the same rather than recomputing each window from scratch.
#[derive(Clone)]
pub struct PolynomialRollingHash {
    pub value: u64,
    prime: u64,
    prime_l: u64,
    l: usize,
}

impl PolynomialRollingHash {
    /// The `PolynomialRollingHash(int _L, ValueT seed)` constructor. `PRIME` is
    /// `seed` itself and `PRIME_L = seed^L`; the C++ also derives
    /// `PRIME2..PRIME8` and `PRIME_L1..L3`, which only the hand-unrolled
    /// `update<N>` variants consume, so they are not modelled here.
    pub fn new(l: usize, seed: u64) -> Self {
        PolynomialRollingHash {
            value: 0,
            prime: seed,
            prime_l: power(seed, l as u32),
            l,
        }
    }

    /// `moveto` (`hashes.cpp:183`): the hash of `buf[0..L]`. The C++ walks L in
    /// 16-byte groups through a 4-byte STEP; that unrolling multiplies out to
    /// exactly the byte-at-a-time loop below.
    pub fn moveto(&mut self, buf: &[u8]) {
        self.value = 0;
        for i in 0..self.l {
            self.value = self
                .value
                .wrapping_mul(self.prime)
                .wrapping_add(buf[i] as u64);
        }
    }

    /// `update` (`hashes.cpp:151`): slide the window forward by one byte,
    /// dropping `sub` (the byte leaving) and taking in `add` (the byte
    /// entering).
    pub fn update(&mut self, sub: u8, add: u8) {
        self.value = self
            .value
            .wrapping_mul(self.prime)
            .wrapping_add(add as u64)
            .wrapping_sub(self.prime_l.wrapping_mul(sub as u64));
    }
}

/// `FastTableBuild` (`hashes.cpp:267`): the quarter-size table walk the C++
/// uses instead of the usual 8-iterations-per-index construction. The result
/// is the standard reflected-CRC table for `poly` seeded with `seed`, but it is
/// reproduced line for line rather than replaced with the textbook builder.
pub fn fast_table_build(table: &mut [u32; 256], seed: u32, poly: u32) {
    let mut crc = seed;
    table[0] = 0;
    table[128] = crc;
    let mut i = 64u32;
    while i != 0 {
        crc = (crc >> 1) ^ (poly & !((crc & 1).wrapping_sub(1)));
        table[i as usize] = crc;
        i /= 2;
    }
    let mut i = 2u32;
    while i < 256 {
        let mut j = 1u32;
        while j < i {
            table[(i + j) as usize] = table[i as usize] ^ table[j as usize];
            j += 1;
        }
        i *= 2;
    }
}

/// One `update_CRC` step. The C++ normal build uses the `crc32b` instruction
/// (`hashes.cpp:221`) and the fallback build the byte table (`hashes.cpp:235`);
/// both are the same reflected CRC-32C over one byte, so the port keeps the
/// table form and stays portable.
fn update_crc(crc: u32, table: &[u32; 256], byte: u8) -> u32 {
    table[((crc ^ byte as u32) & 0xFF) as usize] ^ (crc >> 8)
}

/// `CrcRollingHash<uint32>` (`hashes.cpp:241`): a CRC-32C over the L-byte
/// window, rolled by XOR-ing out the byte that leaves through
/// `RollingCRCTab`.
#[derive(Clone)]
pub struct CrcRollingHash {
    pub value: u32,
    crc_tab: [u32; 256],
    rolling_crc_tab: [u32; 256],
    l: usize,
}

impl CrcRollingHash {
    /// `init` (`hashes.cpp:291`): build the CRC table, then derive the rolling
    /// table from `CRC-32C(0x80) followed by L zero bytes` — the value that
    /// cancels a byte that has travelled the whole window.
    pub fn new(l: usize, poly: u32) -> Self {
        let mut crc_tab = [0u32; 256];
        fast_table_build(&mut crc_tab, poly, poly);
        let mut crc = update_crc(0, &crc_tab, 128);
        for _ in 0..l {
            crc = update_crc(crc, &crc_tab, 0);
        }
        let mut rolling_crc_tab = [0u32; 256];
        fast_table_build(&mut rolling_crc_tab, crc, poly);
        CrcRollingHash {
            value: 0,
            crc_tab,
            rolling_crc_tab,
            l,
        }
    }

    /// `moveto` (`hashes.cpp:253`): the hash of `buf[0..L]`.
    pub fn moveto(&mut self, buf: &[u8]) {
        self.value = 0;
        for i in 0..self.l {
            self.update(0, buf[i]);
        }
    }

    /// `update` (`hashes.cpp:259`): slide the window forward by one byte.
    pub fn update(&mut self, sub: u8, add: u8) {
        self.value =
            update_crc(self.value, &self.crc_tab, add) ^ self.rolling_crc_tab[sub as usize];
    }
}

/// Whether the CPU has SSE4.2, i.e. what `crc32c()` (`hashes.cpp:226`) reports.
///
/// This decides which of the two `-m1`/`-m2` boundary hashes the C++ encoder
/// dispatches to (`compress_cdc.cpp:136`), so the port has to ask the same
/// question to produce the same boundaries. It does *not* change how CRC values
/// are computed here — the table form above already matches the instruction.
pub fn crc32c() -> bool {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        std::arch::is_x86_feature_detected!("sse4.2")
    }
    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Deterministic xorshift-ish fill so the assertions cover every byte
    // value without depending on an external PRNG.
    fn fill(buf: &mut [u8], seed: u64) {
        let mut x = seed | 1;
        for b in buf.iter_mut() {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            *b = (x >> 33) as u8;
        }
    }

    fn direct_poly(buf: &[u8], l: usize, prime: u64) -> u64 {
        let mut v: u64 = 0;
        for i in 0..l {
            v = v.wrapping_mul(prime).wrapping_add(buf[i] as u64);
        }
        v
    }

    #[test]
    fn poly_rolling_matches_the_direct_hash_at_every_position() {
        let mut buf = [0u8; 512];
        fill(&mut buf, 0x1234_5678);
        for l in [1usize, 15, 16, 17, 31, 48, 64, 512] {
            let mut h = PolynomialRollingHash::new(l, PRIME1);
            h.moveto(&buf);
            assert_eq!(h.value, direct_poly(&buf, l, PRIME1), "moveto, l={l}");
            for i in 1..=(buf.len() - l) {
                h.update(buf[i - 1], buf[i - 1 + l]);
                assert_eq!(
                    h.value,
                    direct_poly(&buf[i..], l, PRIME1),
                    "update, l={l} i={i}"
                );
            }
        }
    }

    #[test]
    fn crc_rolling_matches_a_plain_crc_of_the_window() {
        let mut buf = [0u8; 512];
        fill(&mut buf, 0xdead_beef);
        let l = 48usize;
        let mut table = [0u32; 256];
        fast_table_build(&mut table, CRC32_CASTAGNOLI_POLYNOM, CRC32_CASTAGNOLI_POLYNOM);

        let plain = |win: &[u8]| -> u32 {
            let mut crc: u32 = 0;
            for b in win {
                crc = update_crc(crc, &table, *b);
            }
            crc
        };

        let mut h = CrcRollingHash::new(l, CRC32_CASTAGNOLI_POLYNOM);
        h.moveto(&buf);
        assert_eq!(h.value, plain(&buf[..l]), "moveto");
        for i in 1..=(buf.len() - l) {
            h.update(buf[i - 1], buf[i - 1 + l]);
            assert_eq!(h.value, plain(&buf[i..i + l]), "update, i={i}");
        }
    }

    // `FastTableBuild` must produce the same table the textbook 8-iteration
    // reflected-CRC construction gives, because the C++ hardware path skips
    // the table entirely and relies on that equivalence.
    #[test]
    fn crc_table_matches_the_standard_construction() {
        let mut table = [0u32; 256];
        fast_table_build(&mut table, CRC32_CASTAGNOLI_POLYNOM, CRC32_CASTAGNOLI_POLYNOM);

        let mut standard = [0u32; 256];
        for (i, slot) in standard.iter_mut().enumerate() {
            let mut crc = i as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ CRC32_CASTAGNOLI_POLYNOM
                } else {
                    crc >> 1
                };
            }
            *slot = crc;
        }
        assert_eq!(table[..], standard[..]);
    }
}

/// CRC-32C over a whole buffer, unkeyed. `docs/format-spec-v5.md` uses it for
/// the v5 header, footer and `-dup` meta: a corruption check, not a MAC, chosen
/// because its table is already here.
pub fn crc32c_of(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    fast_table_build(&mut table, CRC32_CASTAGNOLI_POLYNOM, CRC32_CASTAGNOLI_POLYNOM);
    let mut crc: u32 = 0;
    for b in data {
        crc = update_crc(crc, &table, *b);
    }
    crc
}
