package spell

import "base:intrinsics"
import "stury:lib/base/kernel"

when ODIN_ENDIAN != .Little {
	#panic("spell: the digit readers require a little-endian target")
}

// The end of the run of decimal digits at `p`, with the run's first `room` digits added to `mant`. The digits of a
// longer run past `room` are passed over, so `mant` is exact only while every digit folded in all fit `u64`.
// Caller guarantees `p <= end` with `[p, end)` readable and `room >= 0`.
@(private, require_results)
digit_fold :: #force_inline proc "contextless" (p, end: [^]u8, mant: ^u64, room: int) -> [^]u8 #no_bounds_check {
	m := mant^
	q := p
	run: {
		for intrinsics.ptr_sub(end, q) >= 8 {
			w := kernel.load8(q)
			nd := non_digit_bytes(w)
			if nd != 0 {
				tz := intrinsics.count_trailing_zeros(nd)
				k := tz >> 3
				// `tz = 8*k + 7` (`k` in `0..7`), so `~tz & 0x38 = (7 - k) * 8` in `0..56`; splitting `+ 8` keeps both shifts `< 64`.
				m = m * POW10_U64[k] + digits8_value((w << (~tz & 0x38)) << 8)
				q = q[k:]
				break run
			}
			m = m * POW10_U64[8] + digits8_value(w)
			q = q[8:]
		}
		for q < end && q[0] - '0' < 10 {
			m = m * 10 + u64(q[0] - '0')
			q = q[1:]
		}
	}
	// The fold above is unbounded, so a run past `room` digits is folded again within it.
	if intrinsics.ptr_sub(q, p) > room {
		m = mant^
		for i in 0 ..< room {
			m = m * 10 + u64(p[i] - '0')
		}
	}
	mant^ = m
	return q
}

// The high bits set for bytes of `w` that are no ASCII digit. The lowest one is exact, those above it may carry.
@(private, require_results)
non_digit_bytes :: #force_inline proc "contextless" (w: u64) -> u64 {
	return ((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
}

// The least end `fold_digits_end_words` reads at, as its loads start up to 24 bytes before it.
@(private)
FOLD_WORDS_FROM :: 24

// The value of the `k` digits ending at `end`, read one at a time below `FOLD_WORDS_FROM`.
// Caller guarantees `k <= end <= u64(len(src))`, `k <= 24` (exact in `u64` for `k <= 19`; 20..24 wrap mod `2^64`),
// and `src[end - k : end]` are ASCII digits `'0'..'9'`.
@(private, require_results)
fold_digits_end :: #force_inline proc "contextless" (src: []u8, end, k: u64) -> u64 #no_bounds_check {
	base := raw_data(src)
	if end < FOLD_WORDS_FROM {
		m := u64(0)
		for i in end - k ..< end {
			m = m * 10 + u64(base[i] - '0')
		}
		return m
	}
	return fold_digits_end_words(base, end, k)
}

// The value of the `k` digits ending at `end`, from 8-byte loads ending there masked to the run.
// Caller guarantees `end >= FOLD_WORDS_FROM`, `k <= 24` (exact in `u64` for `k <= 19`; 20..24 wrap mod `2^64`),
// `base[end - 24 : end]` is readable, and `base[end - k : end]` are ASCII digits `'0'..'9'`.
@(private, require_results)
fold_digits_end_words :: #force_inline proc "contextless" (base: [^]u8, end, k: u64) -> u64 #no_bounds_check {
	if k <= 8 {
		return digits8_nibbles(kernel.load8(base[end - 8:]) & KEEP_DIGITS[k])
	}
	low := digits8_value(kernel.load8(base[end - 8:]))
	if k <= 16 {
		return digits8_nibbles(kernel.load8(base[end - 16:]) & KEEP_DIGITS[k - 8]) * 100_000_000 + low
	}
	mid := digits8_value(kernel.load8(base[end - 16:]))
	return (digits8_nibbles(kernel.load8(base[end - 24:]) & KEEP_DIGITS[k - 16]) * 100_000_000 + mid) * 100_000_000 + low
}

// Powers of ten exact in `u64`, indexed by exponent `0..=19`.
@(private, rodata)
POW10_U64: [20]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
	10_000_000_000, 100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000,
	1_000_000_000_000_000, 10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000,
	10_000_000_000_000_000_000,
}

// Masks keeping the digit nibbles of a word's last `c` bytes, by `c`.
@(private = "file", rodata)
KEEP_DIGITS: [9]u64 = {
	0,
	0x0F << 56,
	0x0F0F << 48,
	0x0F_0F0F << 40,
	0x0F0F_0F0F << 32,
	0x0F_0F0F_0F0F << 24,
	0x0F0F_0F0F_0F0F << 16,
	0x0F_0F0F_0F0F_0F0F << 8,
	0x0F0F_0F0F_0F0F_0F0F,
}

// The value of the eight ASCII digits in `w`, its first byte the most significant.
@(private, require_results)
digits8_value :: #force_inline proc "contextless" (w: u64) -> u64 {
	return digits8_nibbles(w & 0x0F0F_0F0F_0F0F_0F0F)
}

// The value of the eight bytes in `w`, each already a decimal digit `0..9` (high nibbles cleared, unused leading bytes
// zeroed), first byte most significant.
@(private, require_results)
digits8_nibbles :: #force_inline proc "contextless" (w: u64) -> u64 {
	v := (w * 2561) >> 8
	v &= 0x00FF_00FF_00FF_00FF
	v = (v * (1 + (100 << 16))) >> 16
	return (v & 0xFFFF) * 10000 + (v >> 32)
}
