package spell

// Decimal integers, written left to right straight into the destination. The leading group of at most eight digits
// is written branch-free from its BCD form, and a full group of eight below it is one store.
//
// Stores are unchecked and may run past the count returned: `lead8_text` always stores 8 bytes, the last group of
// eight is stored whole at the position after the leading one (at most 8 + 8 bytes), the low sixteen digits of a
// 17- to 20-digit value go in one 16-byte store after a leading group of at most four digits (at most 4 + 16 bytes),
// and `i64_text` writes its `-` either way. No store reaches past 20 bytes, which every caller reserves.

import "base:intrinsics"
import "core:simd"

// The room `u64_text` and `i64_text` need at `dst`: `-9223372036854775808` and `18446744073709551615` are 20 bytes.
INT_ROOM :: 20

// Writes `u` in decimal at `dst`, which has room for `INT_ROOM` bytes. Returns the count written.
u64_text :: #force_inline proc "contextless" (dst: [^]u8, u: u64) -> int {
	if u < 100_000_000 {
		return lead8_text(dst, u)
	}
	if u < 10_000_000_000_000_000 {
		hi := u / 100_000_000
		n := lead8_text(dst, hi)
		intrinsics.unaligned_store((^u64)(dst[n:]), bcd8(u - hi * 100_000_000) | ZEROS8)
		return n + 8
	}
	// At most four digits above the low sixteen.
	top := u / 10_000_000_000_000_000
	rest := u - top * 10_000_000_000_000_000
	mid := rest / 100_000_000
	n := lead8_text(dst, top)
	sixteen_text(dst[n:], mid, rest - mid * 100_000_000)
	return n + 16
}

// Writes `v` in decimal at `dst`, which has room for `INT_ROOM` bytes. Returns the count written.
i64_text :: #force_inline proc "contextless" (dst: [^]u8, v: i64) -> int {
	// The sign is stored either way and kept only when negative. Negation in u64 is exact for every i64,
	// min(i64) included.
	neg := int(v < 0)
	dst[0] = '-'
	u := u64(v)
	return neg + u64_text(dst[neg:], 0 - u if neg != 0 else u)
}

// Exactly sixteen digits, `hi` then `lo` (each < 10^8, leading zeros included), in one 16-byte store.
@(private)
sixteen_text :: #force_inline proc "contextless" (dst: [^]u8, hi, lo: u64) {
	intrinsics.unaligned_store((^#simd[16]u8)(dst), bcd16(hi, lo) | 0x30)
}

// `hi` then `lo` (each < 10^8) as sixteen digit values 0..9, the most significant in lane 0.
@(private)
bcd16 :: #force_inline proc "contextless" (hi, lo: u64) -> #simd[16]u8 {
	// Per group, one multiply-shift splits it into two 4-digit halves, remainder in the low lane. The
	// vector steps then split every half into 2-digit pairs and every pair into digits, all lanes at once.
	HALF :: (1 << 40) / 10000 + 1
	hi_halves := hi + (1 << 32 - 10000) * ((hi * HALF) >> 40)
	lo_halves := lo + (1 << 32 - 10000) * ((lo * HALF) >> 40)
	halves := transmute(#simd[4]u32)(#simd[2]u64{hi_halves, lo_halves})
	halves = simd.shuffle(halves, halves, 1, 0, 3, 2) // the quotient half comes first
	pairs := simd.shr(halves * ((1 << 19) / 100 + 1), 19)
	pair_rems := halves - pairs * 100
	both := transmute(#simd[8]u16)(pairs | simd.shl(pair_rems, 16))
	tens := simd.shr(both * ((1 << 10) / 10 + 1), 10)
	ones := both - tens * 10
	return transmute(#simd[16]u8)(tens | simd.shl(ones, 8))
}

// `x` < 10^8 with no leading zeros, in one 8-byte store. Returns the count that belongs to it. Short integers are
// common and their lengths vary, so this path has no length branches.
@(private)
lead8_text :: #force_inline proc "contextless" (dst: [^]u8, x: u64) -> int {
	b := bcd8(x)
	// Leading zero digits are the low zero bytes, and the sentinel keeps the last digit of zero.
	skip := int(intrinsics.count_trailing_zeros(b | 1 << 56)) / 8
	intrinsics.unaligned_store((^u64)(dst), (b + ZEROS8) >> (8 * uint(skip)))
	return 8 - skip
}
