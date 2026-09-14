//! Small integer helpers ported from `Compression/Common.h`, kept separate so
//! both the container layer and the match finders can use them.

/// `lb()` — floor(log2(n)) for n >= 1; 0 for n == 0.
#[inline]
pub fn lb(n: u64) -> u32 {
    63 - (n | 1).leading_zeros()
}

/// `roundup_to_power_of(n, 2)` (`Common.h:735`): the smallest power of two
/// >= n, with the C++'s own special cases (0 -> 0, 1 -> 1). `f(13,2) == 16`.
pub fn roundup_to_power_of_two(n: u64) -> u64 {
    if n == 0 {
        return 0;
    }
    if n == 1 {
        return 1;
    }
    2u64 << lb(n - 1)
}

/// `rounddown_to_power_of(n, 2)` (`Common.h:752`): the largest power of two
/// <= n. `f(13,2) == 8`.
pub fn rounddown_to_power_of_two(n: u64) -> u64 {
    if n == 0 {
        return 1;
    }
    1u64 << lb(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundup_matches_the_c_comments() {
        assert_eq!(roundup_to_power_of_two(0), 0);
        assert_eq!(roundup_to_power_of_two(1), 1);
        assert_eq!(roundup_to_power_of_two(2), 2);
        assert_eq!(roundup_to_power_of_two(3), 4);
        assert_eq!(roundup_to_power_of_two(13), 16);
        assert_eq!(roundup_to_power_of_two(1 << 20), 1 << 20);
    }

    #[test]
    fn rounddown_matches_the_c_comments() {
        assert_eq!(rounddown_to_power_of_two(0), 1);
        assert_eq!(rounddown_to_power_of_two(1), 1);
        assert_eq!(rounddown_to_power_of_two(9), 8);
        assert_eq!(rounddown_to_power_of_two(13), 8);
        assert_eq!(rounddown_to_power_of_two(15), 8);
        assert_eq!(rounddown_to_power_of_two(16), 16);
    }
}
