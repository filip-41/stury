package encode

// Shortest round-trip digits for a finite binary64: a port of zmij's `to_decimal` (the `zmij` crate 1.0.23,
// `src/lib.rs`, MIT). A Schubfach variant: the significand is scaled by 10^(-e-1), so the shorter candidate
// (15 or 16 digits) is the integral part of the product and the 17th digit is read off its fraction. When
// a shorter candidate rounds back to the same bits, `has_last` is false and the trailing zeros of `sig`
// are the caller's to drop.

@(private)
DOUBLE_MANTISSA_BITS :: 52
@(private)
EXP_OFFSET :: 1023 + DOUBLE_MANTISSA_BITS
// Bits below the integral part in the top word of the scaled significand. EXP_SHIFT includes it.
@(private)
EXTRA_SHIFT :: 6

// The shift that puts the binary point of bin_sig * 2^bin_exp * 10^-dec_exp at a fixed place in the
// 192-bit product, for -350 <= dec_exp <= 350.
@(private)
compute_exp_shift :: #force_inline proc "contextless" (bin_exp, dec_exp: i32) -> i32 {
	return bin_exp + ((-dec_exp * 217707) >> 16) + 1
}

// The top 128 bits of the 192-bit product (x_hi * 2^64 + x_lo) * y.
@(private)
umul192_hi128 :: #force_inline proc "contextless" (x_hi, x_lo, y: u64) -> (hi, lo: u64) {
	p := u128(x_hi) * u128(y)
	lo = u64(p) + u64((u128(x_lo) * u128(y)) >> 64)
	hi = u64(p >> 64) + u64(lo < u64(p))
	return
}

// (x * y + c) >> 64
@(private)
umul128_add_hi64 :: #force_inline proc "contextless" (x, y, c: u64) -> u64 {
	return u64((u128(x) * u128(y) + u128(c)) >> 64)
}

// `bin_sig * 2^(raw_exp - EXP_OFFSET)` as `(sig * 10 + last) * 10^exp` when `has_last`, else `sig * 10^(exp + 1)`.
// `regular` is false only for a power of two above the subnormals, whose lower neighbour is half as far.
@(private)
to_decimal :: #force_inline proc "contextless" (
	bin_sig: u64,
	raw_exp: u64,
	regular: bool,
) -> (
	sig: u64,
	exp: i32,
	last: u64,
	has_last: bool,
) #no_bounds_check {
	// Odin defines a shift by 64 or more as 0, which costs a compare and select per variable shift. Every
	// shift here is below 64 (and EXTRA_SHIFT + 1 - shift is never negative), so the `& 63` masks only drop
	// those guards.
	if !regular {
		bin_exp := i32(raw_exp) - EXP_OFFSET
		// floor(log10(3/4 * 2^bin_exp)), for -1334 <= bin_exp <= 2620.
		dec_exp := (bin_exp * 315653 - 131072) >> 20
		shift := u64(compute_exp_shift(bin_exp, dec_exp + 1) + EXTRA_SHIFT) & 63
		pow10 := POW10_SIG[-dec_exp - 1 - POW10_MIN]
		hi, lo := umul192_hi128(pow10[0], pow10[1], bin_sig << shift)
		integral := hi >> EXTRA_SHIFT
		fractional := hi << (64 - EXTRA_SHIFT) | lo >> EXTRA_SHIFT
		half_ulp := pow10[0] >> ((EXTRA_SHIFT + 1 - shift) & 63)
		round_up := half_ulp > max(u64) - fractional
		round_down := half_ulp >> 1 > fractional
		digit := max(
			umul128_add_hi64(fractional, 10, 1 << 63 - 1),
			umul128_add_hi64(fractional - half_ulp >> 1, 10, max(u64)),
		)
		return integral + u64(round_up), dec_exp, digit, !(round_up || round_down)
	}
	// floor(log10(2^bin_exp)) as one multiply-high, the crate's choice on Apple targets. A negative
	// bin_exp wraps to 2^64 + bin_exp, which adds the multiplier itself to the product's high word. Its low
	// 32 bits are zero, so the truncation to i32 drops it.
	dec_exp := i32(u64((u128(raw_exp - EXP_OFFSET) * u128(78913 << 46)) >> 64))
	shift := u64(EXP_SHIFT[raw_exp]) & 63
	even := 1 - bin_sig & 1
	pow10 := POW10_SIG[-dec_exp - 1 - POW10_MIN]
	hi, lo := umul192_hi128(pow10[0], pow10[1], bin_sig << shift)
	integral := hi >> EXTRA_SHIFT
	fractional := hi << (64 - EXTRA_SHIFT) | lo >> EXTRA_SHIFT
	half_ulp := pow10[0] >> ((EXTRA_SHIFT + 1 - shift) & 63) + even
	round_up := fractional + half_ulp < fractional
	round_down := half_ulp > fractional
	digit := umul128_add_hi64(fractional, 10, 1 << 63 + 6)
	if fractional == 1 << 62 {
		// Exactly .25 scales to 2.5, which ties to the even 2.
		digit = 2
	}
	return integral + u64(round_up), dec_exp, digit, !(round_up || round_down)
}
