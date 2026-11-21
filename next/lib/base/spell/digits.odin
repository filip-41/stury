package spell

import "base:intrinsics"

// The end of the run of decimal digits at `p`, with the run's digits added to `mant`.
@(private)
digit_fold :: #force_inline proc "contextless" (p, end: [^]u8, mant: ^u64) -> [^]u8 #no_bounds_check {
	q := p
	for intrinsics.ptr_sub(end, q) >= 8 {
		w := u64(intrinsics.unaligned_load((^u64le)(q)))
		// The first byte below '0' or above '9' sets its high bit in one of the two.
		m := ((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
		if m != 0 {
			tz := intrinsics.count_trailing_zeros(m)
			k := tz >> 3
			mant^ = mant^ * POW10_U64[k] + digits8_value((w << (~tz & 0x38)) << 8)
			return q[k:]
		}
		mant^ = mant^ * POW10_U64[8] + digits8_value(w)
		q = q[8:]
	}
	for q < end && q[0] - '0' < 10 {
		mant^ = mant^ * 10 + u64(q[0] - '0')
		q = q[1:]
	}
	return q
}

// The least end `fold_digits_end_words` reads at, as its loads start up to 24 bytes before it.
@(private)
FOLD_WORDS_FROM :: 24

// The value of the `k` digits, at most 24, that end at `end`, read one at a time below `FOLD_WORDS_FROM`.
@(private)
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

// The value of the `k` digits, at most 24, that end at `end`, from 8-byte loads that end there masked to the run. `end`
// is at least `FOLD_WORDS_FROM`.
@(private)
fold_digits_end_words :: #force_inline proc "contextless" (base: [^]u8, end, k: u64) -> u64 #no_bounds_check {
	if k <= 8 {
		return digits8_nibbles(load8(base[end - 8:]) & KEEP_DIGITS[k])
	}
	low := digits8_value(load8(base[end - 8:]))
	if k <= 16 {
		return digits8_nibbles(load8(base[end - 16:]) & KEEP_DIGITS[k - 8]) * 1_0000_0000 + low
	}
	mid := digits8_value(load8(base[end - 16:]))
	return (digits8_nibbles(load8(base[end - 24:]) & KEEP_DIGITS[k - 16]) * 1_0000_0000 + mid) * 1_0000_0000 + low
}

// Masks keeping the digit nibbles of a word's last `c` bytes, by `c`.
@(private, rodata)
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

@(private)
load8 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return u64(intrinsics.unaligned_load((^u64le)(p)))
}

// The value of the eight ASCII digits in `w`, its first byte the most significant.
@(private)
digits8_value :: #force_inline proc "contextless" (w: u64) -> u64 {
	return digits8_nibbles(w & 0x0F0F_0F0F_0F0F_0F0F)
}

// The value of the eight low nibbles (`0..9`) in `w`, high bytes already masked to `0x00` or `0x0F`.
@(private)
digits8_nibbles :: #force_inline proc "contextless" (w: u64) -> u64 {
	v := (w * 2561) >> 8
	v &= 0x00FF_00FF_00FF_00FF
	v = (v * (1 + (100 << 16))) >> 16
	return (v & 0xFFFF) * 10000 + (v >> 32 & 0xFFFF)
}
