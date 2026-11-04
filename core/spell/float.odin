package spell

// Writes a binary64 or binary32 as the shortest decimal that reads back as the same bits, in jq 1.8.2's layout: fixed
// notation from `0.0001` up to `1e15`, then `1e+16` and `1e-05`, with an exponent of at least two digits. An integral
// value has no `.0`, and negative zero is `-0`.
//
// The digits d1..d17 are stored at p[1..18) behind the sign, '0' past the last significant one. Each layout then moves
// them with whole-word stores, which is why the caller's room exceeds the longest output.

import "base:intrinsics"
import "core:strconv"

// Room `f64_text` and `f32_text` need at `dst`: the sign, then the farthest store, a 16-byte one at p[17].
F64_ROOM :: 1 + 17 + 16

@(private)
ZEROS8 :: u64(0x3030_3030_3030_3030)
// `0.000000`, low byte first.
@(private)
ZERO_POINT8 :: u64(0x3030_3030_3030_2e30)

// Writes finite `f` at `dst`, which has room for `F64_ROOM` bytes. Returns the count written. A caller refuses an
// infinity or a NaN before this.
f64_text :: proc "contextless" (dst: [^]u8, f: f64) -> int #no_bounds_check {
	bits := transmute(u64)f
	neg := int(bits >> 63)
	dst[0] = '-'
	p := dst[neg:]
	k, n := decimal_digits(p, bits)
	if k == 0 {
		p[0] = '0'
		return neg + 1
	}
	return neg + layout(p, k, n)
}

// Writes finite `f` at `dst`, which has room for `F64_ROOM` bytes, with the shortest digits that read back as the same
// binary32. Returns the count written.
f32_text :: proc "contextless" (dst: [^]u8, f: f32) -> int #no_bounds_check {
	bits := transmute(u32)f
	neg := int(bits >> 31)
	dst[0] = '-'
	p := dst[neg:]
	exp := int(bits >> 23) & 0xff
	mant := u64(bits & (1 << 23 - 1))
	if exp == 0 {
		exp = 1
	} else {
		mant |= 1 << 23
	}
	buf: [40]u8 = ---
	d := strconv._shortest_decimal(buf[:], mant, exp, 23)
	if d.count == 0 {
		p[0] = '0'
		return neg + 1
	}
	// The 16 bytes after the digits are '0', and at most 9 digits are set.
	intrinsics.unaligned_store((^u128)(&p[1]), intrinsics.unaligned_load((^u128)(raw_data(d.digits))))
	p[17] = '0'
	return neg + layout(p, d.count, d.decimal_point)
}

// The digits of finite `bits`' float, sign ignored: d1..dk at p[1..], '0' past dk through p[18), so `p` has room for 19
// bytes. The value is 0.d1..dk * 10^n: the decimal point sits after digit n. A zero is k = 0.
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
	// k significant digits, d1 at p[1]. Branch-free: `has_last` is unpredictable on random input. k is the count
	// written, which the caller's next store waits on, so it comes from a scalar bcd8 of the half that ends the
	// digits, not off the vector.
	tail := lo8 if lo8 != 0 else hi8
	k = extra - 1 + max(8 * int(lo8 != 0) + nonzero_bytes(bcd8(tail)), 17 * int(has_last))
	// The decimal point sits after digit n.
	return k, int(dec_exp) + 16 + extra
}

// The text of digits d1..dk, k > 0, at p[1..19) with the decimal point after digit n, written from p[0]. Returns the count.
@(private)
layout :: #force_inline proc "contextless" (p: [^]u8, k, n: int) -> int #no_bounds_check {
	// One unsigned compare for -3 <= n <= k + 15, the range jq prints without an exponent.
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
		// ddd.ddd: d1..dn moved left, d(n+1).. put back where they were.
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

// A subnormal's digits normalized to the form `to_decimal` gives a normal: 15 digits in `sig` and the 16th in `last`.
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

// `e±xx` at p[w:] with an exponent of two digits at least, for -324 <= e <= 308. Returns the offset past it. The 8-byte
// store carries bytes past the output, inside the caller's room.
@(private)
exponent_text :: #force_inline proc "contextless" (p: [^]u8, w: int, e: int) -> int #no_bounds_check {
	x := u32(e if e >= 0 else -e)
	h := x / 100
	r := x - h * 100
	t := r / 10
	word := 'e' | u64('+' + u32(e < 0) * 2) << 8 | u64(h + '0') << 16 | u64(t + '0') << 24 | u64(r - t * 10 + '0') << 32
	drop := u64(x < 100)
	word = (word & 0xffff) | (word >> 16 >> (drop * 8)) << 16
	(^u64)(&p[w])^ = word
	return w + 5 - int(drop)
}

// `x` < 10^8 as eight digit values 0..9, the most significant in the low byte.
@(private)
bcd8 :: #force_inline proc "contextless" (x: u64) -> u64 {
	// Split into 4-digit halves, then 2-digit quarters, then digits, each by a multiply-shift division done in all lanes
	// at once.
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
