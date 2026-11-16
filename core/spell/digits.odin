package spell

// Decimal digit runs read eight bytes at a time, as a little-endian word whose first byte is its low byte.

import "base:intrinsics"

when ODIN_ENDIAN != .Little {
	#panic("spell: the digit readers require a little-endian target")
}

// Returns the end of the digit run at `p`. With `$fold` it also adds the digits to `mant`.
digit_end :: #force_inline proc "contextless" (p, end: [^]u8, mant: ^u64, $fold: bool) -> [^]u8 {
	q := p
	#no_bounds_check {
		for intrinsics.ptr_sub(end, q) >= 8 {
			w := u64(intrinsics.unaligned_load((^u64le)(q)))
			// The first byte below '0' or above '9' sets its high bit in one of the two.
			gap := (w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)
			m := gap & 0x8080_8080_8080_8080
			if m != 0 {
				tz := intrinsics.count_trailing_zeros(m)
				k := tz >> 3
				when fold {
					mant^ = mant^ * POW10_U64[k] + digits8_value((w << (~tz & 0x38)) << 8)
				}
				return q[k:]
			}
			when fold {
				mant^ = mant^ * POW10_U64[8] + digits8_value(w)
			}
			q = q[8:]
		}
		for q < end {
			d := q[0]
			if d < '0' || d > '9' {
				break
			}
			when fold {
				mant^ = mant^ * 10 + u64(d - '0')
			}
			q = q[1:]
		}
	}
	return q
}

// Returns the value of the `k` digits, at most 24, that end at `end`. The loads end at `end` and are masked to the run.
// Below 24 a load could start before `src`, so the digits are read one at a time.
@(private)
fold_digits_end :: #force_inline proc(src: []u8, end, k: u64) -> u64 {
	base := raw_data(src)
	if end < 24 {
		m := u64(0)
		for i in end - k ..< end {
			m = m * 10 + u64(base[i] - '0')
		}
		return m
	}
	low := digits8_value(load8_le(src, end - 8))
	if k <= 8 {
		return digits8_value(load8_le(src, end - 8) & KEEP_DIGITS_MASK[k])
	}
	if k <= 16 {
		return digits8_value(load8_le(src, end - 16) & KEEP_DIGITS_MASK[k - 8]) * 10000_0000 + low
	}
	mid := digits8_value(load8_le(src, end - 16))
	return (digits8_value(load8_le(src, end - 24) & KEEP_DIGITS_MASK[k - 16]) * 10000_0000 + mid) * 10000_0000 + low
}

// Parses an optional sign followed by 1 to 16 digits, and returns false for anything else. It may read up to 8 bytes
// past the span.
short_integer :: #force_inline proc "contextless" (p: [^]u8, n: u64) -> (v: i64, ok: bool) {
	skip := u64(1) if p[0] == '-' || p[0] == '+' else 0
	digits := n - skip
	if digits - 1 >= 16 {
		return
	}
	mag: u64
	if digits <= 8 {
		mag, ok = short_digits(p[skip:], digits)
	} else {
		high, high_ok := short_digits(p[skip:], digits - 8)
		low, low_ok := short_digits(p[skip + digits - 8:], 8)
		mag, ok = high * 100_000_000 + low, high_ok && low_ok
	}
	return -i64(mag) if p[0] == '-' else i64(mag), ok
}

// Parses an optional sign, up to 8 digits, an optional point and up to 8 more digits, with at most 15 digits in total.
// Returns false for anything else. The digits and the power of ten both fit an f64 exactly, so the one division is
// correctly rounded. It may read up to 9 bytes past the span.
short_decimal :: #force_inline proc "contextless" (p: [^]u8, n: u64) -> (v: f64, ok: bool) {
	skip := u64(1) if p[0] == '-' || p[0] == '+' else 0
	q := p[skip:]
	chars := n - skip
	if chars - 1 >= 16 {
		return
	}
	dots := intrinsics.unaligned_load((^u64)(q)) ~ 0x2e2e_2e2e_2e2e_2e2e
	point := intrinsics.count_trailing_zeros((dots - 0x0101_0101_0101_0101) & ~dots & 0x8080_8080_8080_8080) / 8
	frac: u64
	if point >= chars {
		point = chars
	} else {
		frac = chars - point - 1
	}
	if frac > 8 || point > 8 || point + frac > 15 || point + frac == 0 || (point < chars && q[point] != '.') {
		return
	}
	whole, whole_ok := short_digits(q, point)
	part, part_ok := short_digits(q[point + 1:], frac)
	v = f64(whole * POW10_U64[frac] + part) / POW10_F64[frac]
	return -v if p[0] == '-' else v, whole_ok && part_ok
}

// The value of `s`, ASCII decimal digits only and at least one, saturated at `cap`, which is below 2^60 so a run of
// any length cannot overflow.
digits_u64 :: proc "contextless" (s: string, cap: u64) -> (n: u64, ok: bool) {
	for c in transmute([]u8)s {
		if c - '0' > 9 {
			return 0, false
		}
		n = min(n * 10 + u64(c - '0'), cap)
	}
	return n, s != ""
}

// Parses the first `n` bytes at `p`, at most 8, and reports whether all are digits. Always loads 8 bytes.
@(private = "file")
short_digits :: #force_inline proc "contextless" (p: [^]u8, n: u64) -> (v: u64, ok: bool) {
	x := (intrinsics.unaligned_load((^u64)(p)) ~ 0x3030_3030_3030_3030) << ((8 - n) * 8)
	ok = ((x + 0x0606_0606_0606_0606) | x) & 0xf0f0_f0f0_f0f0_f0f0 == 0
	return digits8_value(x), ok
}

// `KEEP_DIGITS_MASK[c]` keeps the digit nibbles of the last `c` bytes of a word.
@(rodata, private = "file")
KEEP_DIGITS_MASK: [9]u64 = {
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

// Requires `p + 8 <= len(src)`.
@(private = "file")
load8_le :: #force_inline proc "contextless" (src: []u8, p: u64) -> u64 {
	#no_bounds_check {
		return intrinsics.unaligned_load((^u64)(&src[p]))
	}
}

// Returns the value of the 8 ASCII digits in `w`, first byte most significant.
@(private = "file")
digits8_value :: #force_inline proc "contextless" (w: u64) -> u64 {
	v := w & 0x0F0F_0F0F_0F0F_0F0F
	v = (v * 2561) >> 8
	v &= 0x00FF_00FF_00FF_00FF
	v = (v * (1 + (100 << 16))) >> 16
	return (v & 0xFFFF) * 10000 + (v >> 32 & 0xFFFF)
}
