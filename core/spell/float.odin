package spell

// Floats as the shortest decimal that reads back as the same bits, in jq 1.8.2's layout: plain from `0.0001` up to
// `1e15`, else with an exponent of two digits at least (`1e+16`, `1e-05`). An integral value has no `.0`, and negative
// zero is `-0`.
//
// Past the sign at `p`, the digits d1..d17 are stored first at p[1..18), '0' past the last significant one. `layout`
// then moves them into place with whole 8- and 16-byte stores, which reach past the text but stay within `F64_ROOM`.

import "base:intrinsics"

// The room `f64_text` and `f32_text` need at `dst`: the sign, then the farthest store, 16 bytes at p[17].
F64_ROOM :: 1 + 17 + 16

// `0.000000`, low byte first.
@(private)
ZERO_POINT8 :: u64(0x3030_3030_3030_2e30)

// Writes finite `f` at `dst`, which has room for `F64_ROOM` bytes. Returns the count written. The caller refuses an
// infinity or a NaN before this.
f64_text :: proc "contextless" (dst: [^]u8, f: f64) -> int #no_bounds_check {
	bits := transmute(u64)f
	neg := int(bits >> 63)
	dst[0] = '-'
	p := dst[neg:]
	k, n := f64_digits(p, bits)
	return neg + layout(p, k, n)
}

// `f64_text` followed by `point` when the text reads as an integer, for a format that tells floats from integers.
// `dst` has room for `F64_ROOM` and `point`.
f64_point_text :: proc "contextless" (dst: [^]u8, f: f64, point: string) -> int #no_bounds_check {
	n := f64_text(dst, f)
	for c in dst[:n] {
		if c == '.' || c == 'e' {
			return n
		}
	}
	intrinsics.mem_copy_non_overlapping(dst[n:], raw_data(point), len(point))
	return n + len(point)
}

// Writes finite `f` at `dst`, which has room for `F64_ROOM` bytes, with the shortest digits that read back as the same
// binary32. Returns the count written.
f32_text :: proc "contextless" (dst: [^]u8, f: f32) -> int #no_bounds_check {
	bits := transmute(u32)f
	neg := int(bits >> 31)
	dst[0] = '-'
	p := dst[neg:]
	k, n := f32_digits(p, bits)
	return neg + layout(p, k, n)
}

// Stores the digits of finite `bits`, sign ignored, at p[1..18), '0' past the last significant one. Returns their count `k` and the place `n` of the
// decimal point: the value is 0.d1..dk × 10^n. Zero is k = 0.
@(private)
f64_digits :: #force_inline proc "contextless" (p: [^]u8, bits: u64) -> (k, n: int) #no_bounds_check {
	bin_sig := bits & (1 << DOUBLE_MANTISSA_BITS - 1)
	raw_exp := bits >> DOUBLE_MANTISSA_BITS & 0x7ff
	sig, last: u64
	dec_exp: i32
	has_last: bool
	if raw_exp != 0 {
		sig, dec_exp, last, has_last = to_decimal(bin_sig | 1 << DOUBLE_MANTISSA_BITS, raw_exp, bin_sig != 0)
	} else {
		// Zero is tested on the subnormal arm, so a normal double does not pay for it.
		if bin_sig == 0 {
			return 0, 0
		}
		sig, dec_exp, last, has_last = subnormal_decimal(bin_sig)
	}
	// `sig` has 16 digits when `extra` is set, else 15. Either way d1 lands at p[1].
	extra := int(sig >= 1_000_000_000_000_000)
	high := sig / 100_000_000
	low := sig - high * 100_000_000
	sixteen_text(&p[extra], high, low)
	intrinsics.unaligned_store((^u16)(&p[extra + 16]), u16('0' + (last if has_last else 0)) | u16('0') << 8)
	// No branch on `has_last`, which random input does not predict. The caller's next store waits on `k`, so `k` comes
	// from a scalar `bcd8` of the half the digits end in, not from the vector.
	tail := low if low != 0 else high
	tail_bytes := int(8 - intrinsics.count_leading_zeros(bcd8(tail)) / 8)
	k = extra - 1 + max(8 * int(low != 0) + tail_bytes, 17 * int(has_last))
	return k, int(dec_exp) + 16 + extra
}

// A subnormal's digits in the form `to_decimal` gives a normal's: 15 digits in `sig` and the 16th in `last`.
@(private)
subnormal_decimal :: proc "contextless" (bin_sig: u64) -> (sig: u64, exp: i32, last: u64, has_last: bool) {
	short_sig, e, short_last, short_has_last := to_decimal(bin_sig, 1, true)
	dec_sig := short_sig * 10 + (short_last if short_has_last else 0)
	for dec_sig < 1_000_000_000_000_000 {
		dec_sig *= 10
		e -= 1
	}
	sig = dec_sig / 10
	last = dec_sig - sig * 10
	return sig, e, last, last != 0
}

// `f64_digits` for a binary32.
@(private)
f32_digits :: #force_inline proc "contextless" (p: [^]u8, bits: u32) -> (k, n: int) #no_bounds_check {
	raw_exp := u64(bits >> 23) & 0xff
	bin_sig := u64(bits & (1 << SINGLE_MANTISSA_BITS - 1))
	if raw_exp == 0 {
		if bin_sig == 0 {
			return 0, 0
		}
		raw_exp = 1
	} else {
		bin_sig |= 1 << SINGLE_MANTISSA_BITS
	}
	sig, exp, last, has_last := to_decimal_f32(bin_sig, raw_exp, bin_sig != 1 << SINGLE_MANTISSA_BITS)
	digits := bcd8(sig)
	// `sig` is zero for the six smallest subnormals (raw_exp 1, mantissa 1..6), and `last` is then their one digit.
	start := int(intrinsics.count_trailing_zeros(digits) >> 3)
	intrinsics.unaligned_store((^u64)(&p[1]), digits >> (8 * uint(start)) | ZEROS8)
	intrinsics.unaligned_store((^u64)(&p[9]), ZEROS8)
	p[17] = '0'
	k = 8 - int(intrinsics.count_leading_zeros(digits) >> 3) - start
	if has_last && last != 0 {
		k = 9 - start
		p[9 - start] = '0' + u8(last)
	}
	return k, 9 - start + int(exp)
}

// Writes from p[0] the text of the digits d1..dk at p[1..19) with the decimal point after digit n, or of zero when
// k = 0. Returns the count.
@(private)
layout :: #force_inline proc "contextless" (p: [^]u8, k, n: int) -> int #no_bounds_check {
	if k == 0 {
		p[0] = '0'
		return 1
	}
	// One unsigned compare for -3 <= n <= k + 15, the range jq writes without an exponent.
	if u64(n + 3) <= u64(k + 18) {
		digits := intrinsics.unaligned_load((^u128)(&p[1]))
		d17 := p[17]
		if n <= 0 {
			// 0.000ddd
			intrinsics.unaligned_store((^u64)(p), ZERO_POINT8)
			intrinsics.unaligned_store((^u128)(&p[2 - n]), digits)
			p[18 - n] = d17
			return 2 - n + k
		}
		intrinsics.unaligned_store((^u128)(p), digits)
		if k <= n {
			// ddd000: the digits past k are already '0'.
			p[16] = d17
			intrinsics.unaligned_store((^u128)(&p[17]), u128(ZEROS8) << 64 | u128(ZEROS8))
			return n
		}
		// ddd.ddd: d1..dn moved left, d(n+1).. stored back where they were.
		intrinsics.unaligned_store((^u128)(&p[n + 1]), digits >> (8 * uint(n)))
		p[n] = '.'
		p[17] = d17
		return k + 1
	}
	// d.ddde+xx, or de+xx for one digit.
	p[0] = p[1]
	p[1] = '.'
	return exponent_text(p, k + int(k > 1), n - 1)
}

// Writes `e±xx` at p[at:], with two digits at least, for -324 <= e <= 308. Returns the offset past it. The 8-byte store
// reaches past the text, inside the caller's room.
@(private)
exponent_text :: #force_inline proc "contextless" (p: [^]u8, at: int, e: int) -> int #no_bounds_check {
	x := u32(e if e >= 0 else -e)
	hundreds := x / 100
	rest := x - hundreds * 100
	tens := rest / 10
	word := 'e' | u64('+' + u32(e < 0) * 2) << 8 | u64(hundreds + '0') << 16 | u64(tens + '0') << 24 | u64(rest - tens * 10 + '0') << 32
	// Below 100 the hundreds digit is dropped.
	drop := u64(x < 100)
	word = (word & 0xffff) | (word >> 16 >> (drop * 8)) << 16
	(^u64)(&p[at])^ = word
	return at + 5 - int(drop)
}
