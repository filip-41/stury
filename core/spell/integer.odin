package spell

// Decimal integers, written left to right straight into the destination in groups of eight digits. The
// leading group of a short value is written branch-free from its BCD form. The full groups below it are
// four digit pairs from DIGITS2.
//
// Stores are unchecked and may run past the count returned: `spell_lead8` always stores 8 bytes, the low
// sixteen digits of a 17- to 20-digit value go in one 16-byte store, and `spell_i64` writes its `-` either
// way. No store reaches past 20 bytes, which every caller reserves. `spell_u64`'s split keeps each group below
// 10^8, so `spell_pair` indexes DIGITS2 with a pair below 100.

import "base:intrinsics"
import "core:simd"
import "core:strconv"

// The digit pairs of 00..99, so one division by 100 yields two digits.
@(rodata)
DIGITS2 := "0001020304050607080910111213141516171819" +
	"2021222324252627282930313233343536373839" +
	"4041424344454647484950515253545556575859" +
	"6061626364656667686970717273747576777879" +
	"8081828384858687888990919293949596979899"

// The room `spell_u64` and `spell_i64` need at `dst`: `-9223372036854775808` and `18446744073709551615` are 20 bytes.
INT_ROOM :: 20

// Writes `u` in decimal at `dst`, which has room for `INT_ROOM` bytes. Returns the count written.
spell_u64 :: #force_inline proc "contextless" (dst: [^]u8, u: u64) -> int {
	if u < 100_000_000 {
		return spell_lead8(dst, u)
	}
	if u < 10_000_000_000_000_000 {
		hi := u / 100_000_000
		n := spell_lead8(dst, hi)
		spell_eight(dst[n:], u32(u - hi * 100_000_000))
		return n + 8
	}
	// At most four digits above the low sixteen.
	top := u / 10_000_000_000_000_000
	rest := u - top * 10_000_000_000_000_000
	mid := rest / 100_000_000
	n := spell_lead4(dst, u32(top))
	spell_sixteen(dst[n:], mid, rest - mid * 100_000_000)
	return n + 16
}

// Writes `v` in decimal at `dst`, which has room for `INT_ROOM` bytes. Returns the count written.
spell_i64 :: #force_inline proc "contextless" (dst: [^]u8, v: i64) -> int {
	// The sign is stored either way and kept only when negative. Negation in u64 is exact for every i64,
	// min(i64) included.
	neg := int(v < 0)
	dst[0] = '-'
	u := u64(v)
	return neg + spell_u64(dst[neg:], 0 - u if neg != 0 else u)
}

// Writes the 128-bit integer with bits `x` (an `i128` when `signed`) in decimal at the start of `buf`, which has
// room for 40 bytes. Returns the text.
spell_u128 :: proc(buf: []u8, x: u128, signed: bool) -> string {
	return strconv.write_bits_128(buf, x, 10, signed, 128, strconv.digits, {})
}

@(private)
spell_pair :: #force_inline proc "contextless" (dst: [^]u8, x: u32) #no_bounds_check {
	intrinsics.unaligned_store((^u16)(dst), intrinsics.unaligned_load((^u16)(&raw_data(DIGITS2)[2 * x])))
}

// Exactly eight digits of `x` < 10^8, leading zeros included.
@(private)
spell_eight :: #force_inline proc "contextless" (dst: [^]u8, x: u32) {
	hi := x / 10000
	lo := x - hi * 10000
	spell_pair(dst, hi / 100)
	spell_pair(dst[2:], hi % 100)
	spell_pair(dst[4:], lo / 100)
	spell_pair(dst[6:], lo % 100)
}

// Exactly sixteen digits, `hi` then `lo` (each < 10^8, leading zeros included), in one 16-byte store.
@(private)
spell_sixteen :: #force_inline proc "contextless" (dst: [^]u8, hi, lo: u64) {
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
spell_lead8 :: #force_inline proc "contextless" (dst: [^]u8, x: u64) -> int {
	b := bcd8(x)
	// Leading zero digits are the low zero bytes, and the sentinel keeps the last digit of zero.
	skip := int(intrinsics.count_trailing_zeros(b | 1 << 56)) / 8
	intrinsics.unaligned_store((^u64)(dst), (b + ZEROS8) >> (8 * uint(skip)))
	return 8 - skip
}

// `x` < 10^4 with no leading zeros. Returns the count written.
@(private)
spell_lead4 :: #force_inline proc "contextless" (dst: [^]u8, x: u32) -> int {
	if x < 100 {
		if x < 10 {
			dst[0] = '0' + u8(x)
			return 1
		}
		spell_pair(dst, x)
		return 2
	}
	if x < 1000 {
		dst[0] = '0' + u8(x / 100)
		spell_pair(dst[1:], x % 100)
		return 3
	}
	spell_pair(dst, x / 100)
	spell_pair(dst[2:], x % 100)
	return 4
}
