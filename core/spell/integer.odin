package spell

// Decimal integers, written left to right into the destination with unchecked stores. A value below 10^8 is one
// 8-byte store, and each further group of eight digits one more 8-byte store, or for a 17- to 20-digit value one
// 16-byte store after a leading group of at most four digits. The stores reach past the count returned, but never
// past `INT_ROOM` bytes. `i64_text` stores its `-` either way.

import "base:intrinsics"
import "core:simd"

// The room `u64_text` and `i64_text` need at `dst`: `-9223372036854775808` and `18446744073709551615` are 20 bytes.
INT_ROOM :: 20

// Eight ASCII `0`s. Added to eight digit values 0..9, it gives their text.
@(private)
ZEROS8 :: u64(0x3030_3030_3030_3030)

// Writes `u` in decimal at `dst`, which has room for `INT_ROOM` bytes. Returns the count written.
u64_text :: #force_inline proc "contextless" (dst: [^]u8, u: u64) -> int {
	if u < 100_000_000 {
		return lead8_text(dst, u)
	}
	if u < 10_000_000_000_000_000 {
		high := u / 100_000_000
		n := lead8_text(dst, high)
		intrinsics.unaligned_store((^u64)(dst[n:]), bcd8(u - high * 100_000_000) | ZEROS8)
		return n + 8
	}
	top := u / 10_000_000_000_000_000
	low16 := u - top * 10_000_000_000_000_000
	mid := low16 / 100_000_000
	n := lead8_text(dst, top)
	sixteen_text(dst[n:], mid, low16 - mid * 100_000_000)
	return n + 16
}

// Writes `v` in decimal at `dst`, which has room for `INT_ROOM` bytes. Returns the count written.
i64_text :: #force_inline proc "contextless" (dst: [^]u8, v: i64) -> int {
	// The negation in u64 is exact for every i64, min(i64) included.
	neg := int(v < 0)
	dst[0] = '-'
	u := u64(v)
	return neg + u64_text(dst[neg:], 0 - u if neg != 0 else u)
}

// Writes `x` < 10^8 without leading zeros in one 8-byte store. Returns how many of the eight bytes are its digits.
// Short integers vary in length, so this takes no branch on it.
@(private)
lead8_text :: #force_inline proc "contextless" (dst: [^]u8, x: u64) -> int {
	digits := bcd8(x)
	// The leading zeros are the low zero bytes. The bit at 56 keeps the one digit of zero.
	skip := int(intrinsics.count_trailing_zeros(digits | 1 << 56)) / 8
	intrinsics.unaligned_store((^u64)(dst), (digits + ZEROS8) >> (8 * uint(skip)))
	return 8 - skip
}

// Writes `high` then `low`, each below 10^8 and with its leading zeros, as sixteen digits in one 16-byte store.
@(private)
sixteen_text :: #force_inline proc "contextless" (dst: [^]u8, high, low: u64) {
	// One multiply-shift per half splits it into a quotient and a remainder of four digits each. The vector steps then
	// split every four digits into two pairs and every pair into two digits, all lanes at once.
	QUOTIENT :: (1 << 40) / 10000 + 1
	high_fours := high + (1 << 32 - 10000) * ((high * QUOTIENT) >> 40)
	low_fours := low + (1 << 32 - 10000) * ((low * QUOTIENT) >> 40)
	fours := transmute(#simd[4]u32)(#simd[2]u64{high_fours, low_fours})
	fours = simd.shuffle(fours, fours, 1, 0, 3, 2) // the quotient first
	both := hundreds(fours)
	tens := simd.shr(both * ((1 << 10) / 10 + 1), 10)
	ones := both - tens * 10
	digits := transmute(#simd[16]u8)(tens | simd.shl(ones, 8))
	intrinsics.unaligned_store((^#simd[16]u8)(dst), digits | 0x30)
}

// Splits each lane of `fours`, each below 10^4, into its hundreds, in the lane's low 16 bits, and the rest, in its high
// 16. x86 multiplies 32-bit lanes in about 10 cycles and 16-bit lanes in 5, and every lane fits 16 bits, so there the
// hundreds are a 16-bit multiply-high by 2^22 / 100 rounded up, then a shift by 6, exact below 10^4.
@(private = "file")
hundreds :: #force_inline proc "contextless" (fours: #simd[4]u32) -> #simd[8]u16 {
	when ODIN_ARCH == .amd64 {
		H :: #simd[8]u16
		v := transmute(H)fours
		h := simd.shr(pmulhuw(v, H((1 << 22) / 100 + 1)), 6)
		return transmute(H)(transmute(#simd[4]u32)h | simd.shl(transmute(#simd[4]u32)(v - h * 100), 16))
	} else {
		pairs := simd.shr(fours * ((1 << 19) / 100 + 1), 19)
		return transmute(#simd[8]u16)(pairs | simd.shl(fours - pairs * 100, 16))
	}
}

when ODIN_ARCH == .amd64 {
	// SSE2's 16-bit multiply-high, which every x86-64 CPU has. LLVM does not select it from a widened multiply here.
	@(private = "file", default_calling_convention = "none")
	foreign _ {
		@(link_name = "llvm.x86.sse2.pmulhu.w")
		pmulhuw :: proc(a, b: #simd[8]u16) -> #simd[8]u16 ---
	}
}

// `x` < 10^8 as eight digit values 0..9, the most significant in the low byte.
@(private)
bcd8 :: #force_inline proc "contextless" (x: u64) -> u64 {
	// Splits into 4-digit halves, then 2-digit quarters, then digits, each by one multiply-shift in all lanes at once.
	abcd_efgh := x + (1 << 32 - 10000) * ((x * ((1 << 40) / 10000 + 1)) >> 40)
	ab_cd_ef_gh := abcd_efgh + (1 << 16 - 100) * ((abcd_efgh * ((1 << 19) / 100 + 1)) >> 19 & 0x7f_0000_007f)
	a_b_c_d_e_f_g_h := ab_cd_ef_gh + (1 << 8 - 10) * ((ab_cd_ef_gh * ((1 << 10) / 10 + 1)) >> 10 & 0xf_000f_000f_000f)
	return intrinsics.byte_swap(a_b_c_d_e_f_g_h)
}
