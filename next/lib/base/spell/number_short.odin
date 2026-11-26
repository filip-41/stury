package spell

import "base:intrinsics"
import "stury:lib/base/kernel"

// The value of `src[lo:hi]` when it is a short RFC 8259 number with no exponent: at most 16 bytes past its sign, digits
// with at most one point between two of them, and with 16 bytes of `src` from its first digit. False for any other
// span, which `number_strict` reads. The span is judged in two words, with no loop over its bytes.
@(require_results)
number_short :: #force_inline proc "contextless" (src: []u8, lo, hi: u64) -> (num: Number, ok: bool) #no_bounds_check {
	base := raw_data(src)
	if lo >= u64(len(src)) {
		return
	}
	neg := base[lo] == '-'
	p := lo + u64(neg)
	m := hi - p
	if m - 1 >= 16 {
		return
	}
	if m <= 8 && p + 8 <= u64(len(src)) {
		return short_word(base[p:], m, neg)
	}
	if p + 16 > u64(len(src)) {
		return
	}
	// `m` is in `9..=16` here (`m <= 8` returned above or failed `p + 16 <= len(src)`).
	// The bytes past the span in `w1` read as `0` digits.
	w0 := kernel.load8(base[p:])
	w1 := short_pad(kernel.load8(base[p + 8:]), m - 8)
	k := short_nondigit(w0, w1)
	if k >= m {
		if base[p] == '0' {
			return
		}
		return integer_number(digits8_value(w0) * POW10_U64[m - 8] + digits8_value(w1 << (8 * (16 - m))), neg)
	}
	if base[p + k] != '.' || k == 0 || k == m - 1 || k > 1 && base[p] == '0' {
		return
	}
	// The point read as a `0` digit, which no other non-digit may follow, then spliced out across the two words.
	m0, m1: u64
	if k < 8 {
		s := 8 * k
		w0 = w0 &~ (u64(0xFF) << s) | u64(0x30) << s
		if non_digit_bytes(w0) | non_digit_bytes(w1) != 0 {
			return
		}
		low := u64(1) << s - 1
		m0 = w0 & low | w0 >> 8 &~ low | w1 << 56
		m1 = w1 >> 8
	} else {
		s := 8 * (k - 8)
		w1 = w1 &~ (u64(0xFF) << s) | u64(0x30) << s
		if non_digit_bytes(w1) != 0 {
			return
		}
		low := u64(1) << s - 1
		m0 = w0
		m1 = w1 & low | w1 >> 8 &~ low
	}
	sig := digits8_value(m0)
	if m > 9 {
		sig = sig * POW10_U64[m - 9] + digits8_value(m1 << (8 * (17 - m)))
	}
	v := f64(sig) / POW10_F64[m - k - 1]
	return {transmute(u64)(-v if neg else v), .Float}, true
}

// The value of `src[lo:hi]` when it is an RFC 8259 integer of at most 16 digits with 8 bytes of `src` from its first
// digit, read in one or two words. False for any other span, which `number_short` or `number_strict` reads.
@(require_results)
integer_short :: #force_inline proc "contextless" (src: []u8, lo, hi: u64) -> (v: i64, ok: bool) #no_bounds_check {
	base := raw_data(src)
	if lo >= u64(len(src)) {
		return
	}
	neg := base[lo] == '-'
	p := lo + u64(neg)
	m := hi - p
	if m - 1 >= 16 || max(p + 8, hi) > u64(len(src)) || m > 1 && base[p] == '0' {
		return
	}
	// Each byte less `0` is a digit when it and it plus 6 keep their high nibble clear.
	ZEROS :: 0x3030_3030_3030_3030
	mag: u64
	if m <= 8 {
		x := (kernel.load8(base[p:]) ~ ZEROS) << (8 * (8 - m))
		if ((x + 0x0606_0606_0606_0606) | x) & 0xF0F0_F0F0_F0F0_F0F0 != 0 {
			return
		}
		mag = digits8_nibbles(x)
	} else {
		x := (kernel.load8(base[p:]) ~ ZEROS) << (8 * (16 - m))
		y := kernel.load8(base[p + m - 8:]) ~ ZEROS
		if ((x + 0x0606_0606_0606_0606) | x | (y + 0x0606_0606_0606_0606) | y) & 0xF0F0_F0F0_F0F0_F0F0 != 0 {
			return
		}
		mag = digits8_nibbles(x) * 100_000_000 + digits8_nibbles(y)
	}
	return -i64(mag) if neg else i64(mag), true
}

// The binary64 of `src[lo:hi]` when it is an RFC 8259 number with no exponent, at most 7 digits before a point (8
// without one), 8 after it, 15 in all, and 16 bytes of `src` from its first digit. Its digits and the power of ten are
// exact, so the one division rounds once. The words are read whatever the point's place, with no branch on it. False for
// any other span, which `number_short` or `number_strict` reads.
@(require_results)
float_short :: #force_inline proc "contextless" (src: []u8, lo, hi: u64) -> (v: f64, ok: bool) #no_bounds_check {
	base := raw_data(src)
	if lo >= u64(len(src)) {
		return
	}
	neg := base[lo] == '-'
	p := lo + u64(neg)
	m := hi - p
	if m - 1 >= 16 || p + 16 > u64(len(src)) {
		return
	}
	ZEROS :: 0x3030_3030_3030_3030
	w := kernel.load8(base[p:])
	dots := w ~ 0x2E2E_2E2E_2E2E_2E2E
	// The place of the first point in the first word, 8 for none.
	point := u64(intrinsics.count_trailing_zeros((dots - 0x0101_0101_0101_0101) &~ dots & 0x8080_8080_8080_8080)) >> 3
	frac := m - point - 1 if point < m else 0
	point = min(point, m)
	if point == 0 || point == 8 && m > 8 || frac > 8 || point + frac > 15 || point < m && frac == 0 || point > 1 && base[p] == '0' {
		return
	}
	x := (w ~ ZEROS) << (8 * (8 - point))
	y := (kernel.load8(base[p + point + 1:]) ~ ZEROS) << (8 * (8 - frac)) if frac > 0 else 0
	if ((x + 0x0606_0606_0606_0606) | x | (y + 0x0606_0606_0606_0606) | y) & 0xF0F0_F0F0_F0F0_F0F0 != 0 {
		return
	}
	v = f64(digits8_nibbles(x) * POW10_U64[frac] + digits8_nibbles(y)) / POW10_F64[frac]
	return -v if neg else v, true
}

// `number_short` of the `m` bytes at `p`, at most 8, after the sign, in one word.
@(private = "file", require_results)
short_word :: #force_inline proc "contextless" (p: [^]u8, m: u64, neg: bool) -> (num: Number, ok: bool) #no_bounds_check {
	w := short_pad(kernel.load8(p), m)
	nd := non_digit_bytes(w)
	if nd == 0 {
		if m > 1 && p[0] == '0' {
			return
		}
		return integer_number(digits8_value(w << (8 * (8 - m))), neg)
	}
	k := u64(intrinsics.count_trailing_zeros(nd)) >> 3
	if p[k] != '.' || k == 0 || k == m - 1 || k > 1 && p[0] == '0' {
		return
	}
	// The point read as a `0` digit, which no other non-digit may follow.
	w = w &~ (u64(0xFF) << (8 * k)) | u64(0x30) << (8 * k)
	if non_digit_bytes(w) != 0 {
		return
	}
	low := u64(1) << (8 * k) - 1
	merged := w & low | w >> 8 &~ low
	v := f64(digits8_value(merged << (8 * (9 - m)))) / POW10_F64[m - k - 1]
	return {transmute(u64)(-v if neg else v), .Float}, true
}

// Word `w` of a short number's span with its bytes from `k` on, `k` below 8, set to `0` digits.
@(private = "file", require_results)
short_pad :: #force_inline proc "contextless" (w: u64, k: u64) -> u64 {
	if k >= 8 {
		return w
	}
	keep := u64(1) << (8 * k) - 1
	return w & keep | 0x3030_3030_3030_3030 &~ keep
}

// The place of the first byte of the 16 in `w0` and `w1` that is no digit, 16 for none. A byte past the first such one
// may be marked by its carry, and is not read.
@(private = "file", require_results)
short_nondigit :: #force_inline proc "contextless" (w0, w1: u64) -> u64 {
	if m0 := non_digit_bytes(w0); m0 != 0 {
		return u64(intrinsics.count_trailing_zeros(m0)) >> 3
	}
	m1 := non_digit_bytes(w1)
	return 8 + (u64(intrinsics.count_trailing_zeros(m1)) >> 3) if m1 != 0 else 16
}
