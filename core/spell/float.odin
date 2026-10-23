package spell

// Writes a binary64 as the shortest decimal that reads back as the same bits: zmij's digits in ECMAScript's
// Number::toString layout, except that -0 is `-0` (ECMAScript prints `0` and loses the sign bit).
//
// The digits d1..d17 are stored at p[1..18) behind the sign, '0' past the last significant one. Each layout
// then moves them with whole-word stores, which is why the caller's room exceeds the longest output.

import "base:intrinsics"

// Room `spell_f64` needs at `dst`: the sign, then the farthest store, a 16-byte one at p[17].
F64_ROOM :: 1 + 17 + 16

@(private)
F64_EXPONENT_MASK :: u64(0x7ff) << DOUBLE_MANTISSA_BITS

// Reports whether `f` is an infinity or a NaN, which this layout cannot write.
is_non_finite :: #force_inline proc "contextless" (f: f64) -> bool {
	return transmute(u64)f & F64_EXPONENT_MASK == F64_EXPONENT_MASK
}

@(private)
ZEROS8 :: u64(0x3030_3030_3030_3030)
// `0.000000`, low byte first.
@(private)
ZERO_POINT8 :: u64(0x3030_3030_3030_2e30)

// The shortest digits of finite `f`, its sign ignored: d1..dk at p[1..], '0' past dk through p[18), so `p` has
// room for 19 bytes. The value is 0.d1..dk * 10^n: the decimal point sits after digit n. A zero is k = 0.
shortest_digits :: proc "contextless" (p: [^]u8, f: f64) -> (k, n: int) #no_bounds_check {
	return decimal_digits(p, transmute(u64)f)
}

@(private)
decimal_digits :: #force_inline proc "contextless" (p: [^]u8, bits: u64) -> (k, n: int) #no_bounds_check {
	bin_sig := bits & (1 << DOUBLE_MANTISSA_BITS - 1)
	raw_exp := bits >> DOUBLE_MANTISSA_BITS & 0x7ff
	sig, last: u64
	dec_exp: i32
	has_last: bool
	if raw_exp != 0 {
		sig, dec_exp, last, has_last = to_decimal(bin_sig | 1 << DOUBLE_MANTISSA_BITS, raw_exp, bin_sig != 0)
	} else {
		// On the subnormal arm, so a normal double pays no test for zero.
		if bin_sig == 0 {
			return 0, 0
		}
		sig, dec_exp, last, has_last = subnormal_decimal(bin_sig)
	}
	// 16 digits when set, else 15. The first significant digit lands at p[1] either way.
	extra := int(sig >= 1_000_000_000_000_000)
	hi8 := sig / 100_000_000
	lo8 := sig - hi8 * 100_000_000
	intrinsics.unaligned_store((^#simd[16]u8)(&p[extra]), bcd16(hi8, lo8) | 0x30)
	intrinsics.unaligned_store((^u16)(&p[extra + 16]), u16('0' + (last if has_last else 0)) | u16('0') << 8)
	// k significant digits, d1 at p[1]. Branch-free: `has_last` is a coin flip on random input. k is the
	// count written, which the caller's next store waits on, so it comes from a scalar bcd8 of the half
	// that ends the digits, not off the vector.
	tail := lo8 if lo8 != 0 else hi8
	k = extra - 1 + max(8 * int(lo8 != 0) + nonzero_bytes(bcd8(tail)), 17 * int(has_last))
	// The decimal point sits after digit n.
	return k, int(dec_exp) + 16 + extra
}

// Write finite `f` at `dst`, which has room for `F64_ROOM` bytes. Returns the count written.
spell_f64 :: proc "contextless" (dst: [^]u8, f: f64) -> int #no_bounds_check {
	bits := transmute(u64)f
	neg := int(bits >> 63)
	dst[0] = '-'
	p := dst[neg:]
	k, n := decimal_digits(p, bits)
	if k == 0 {
		p[0] = '0'
		return neg + 1
	}
	if -6 < n && n <= 21 {
		digits := intrinsics.unaligned_load((^u128)(&p[1]))
		d17 := p[17]
		if n <= 0 {
			// 0.000ddd
			intrinsics.unaligned_store((^u64)(p), ZERO_POINT8)
			intrinsics.unaligned_store((^u128)(&p[2 - n]), digits)
			p[18 - n] = d17
			return neg + 2 - n + k
		}
		intrinsics.unaligned_store((^u128)(p), digits)
		if k <= n {
			// ddd000: the digits past k are already '0'.
			p[16] = d17
			intrinsics.unaligned_store((^u128)(&p[17]), u128(ZEROS8) << 64 | u128(ZEROS8))
			return neg + n
		}
		// ddd.ddd: d1..dn moved left, d(n+1).. put back where they were.
		intrinsics.unaligned_store((^u128)(&p[n + 1]), digits >> (8 * uint(n)))
		p[n] = '.'
		p[17] = d17
		return neg + k + 1
	}
	// d.ddde±x, or de±x for one digit.
	p[0] = p[1]
	p[1] = '.'
	return neg + spell_exponent(p, k + int(k > 1), n - 1)
}

// A subnormal's digits normalized to the form `to_decimal` gives a normal: 15 digits in `sig` and the
// 16th in `last`.
@(private)
subnormal_decimal :: proc "contextless" (bin_sig: u64) -> (sig: u64, exp: i32, last: u64, has_last: bool) {
	s, e, l, hl := to_decimal(bin_sig, 1, true)
	dec_sig := s * 10 + (l if hl else 0)
	for dec_sig < 1_000_000_000_000_000 {
		dec_sig *= 10
		e -= 1
	}
	sig = dec_sig / 10
	last = dec_sig - sig * 10
	return sig, e, last, last != 0
}

// `e±x` at p[w:] with no leading zeros in x, for -324 <= e <= 308. Returns the offset past it. The 8-byte store
// carries the table entry's length bytes past the output, inside the caller's room.
@(private)
spell_exponent :: #force_inline proc "contextless" (p: [^]u8, w: int, e: int) -> int #no_bounds_check {
	s := EXP_STRING[e - EXP_STRING_MIN]
	intrinsics.unaligned_store((^u64)(&p[w]), s)
	return w + int(s >> 48)
}

// `x` < 10^8 as eight digit values 0..9, the most significant in the low byte.
@(private)
bcd8 :: #force_inline proc "contextless" (x: u64) -> u64 {
	// Split into 4-digit halves, then 2-digit quarters, then digits, each by a multiply-shift division done
	// in all lanes at once.
	abcd_efgh := x + (1 << 32 - 10000) * ((x * ((1 << 40) / 10000 + 1)) >> 40)
	ab_cd_ef_gh := abcd_efgh + (1 << 16 - 100) * ((abcd_efgh * ((1 << 19) / 100 + 1)) >> 19 & 0x7f_0000_007f)
	a_b_c_d_e_f_g_h := ab_cd_ef_gh + (1 << 8 - 10) * ((ab_cd_ef_gh * ((1 << 10) / 10 + 1)) >> 10 & 0xf_000f_000f_000f)
	return intrinsics.byte_swap(a_b_c_d_e_f_g_h)
}

// Bytes of `x` up to and including its highest nonzero byte, for nonzero `x`.
@(private)
nonzero_bytes :: #force_inline proc "contextless" (x: u64) -> int {
	return int(8 - intrinsics.count_leading_zeros(x) / 8)
}
