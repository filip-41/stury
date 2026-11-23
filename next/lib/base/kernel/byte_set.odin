package kernel

import "base:intrinsics"
import "core:simd"

// A set of bytes, tested a register at a time. A byte is in the set when its low nibble's bit is set in the row of its
// high nibble: `low[h]` holds the bits of low nibbles 0 to 7 of the members whose high nibble is `h`, and `high[h]`
// those of 8 to 15. Any set of bytes has that form.
Byte_Set :: struct {
	low, high: V,
}

// The set of the bytes whose bit is set in `members`, bit `b` of the four words standing for byte `b`.
byte_set :: proc "contextless" (members: [4]u64) -> (t: Byte_Set) {
	low, high: [16]u8
	for h in 0 ..< 16 {
		row := members[h / 4] >> uint(h % 4 * 16)
		low[h], high[h] = u8(row), u8(row >> 8)
	}
	return {transmute(V)low, transmute(V)high}
}

// The index of the first byte of `src` that is in `t`, or -1.
index_set :: #force_inline proc "contextless" (src: []u8, t: Byte_Set) -> int {
	return find_set(src, t)
}

// Bit k of lane j is set for k = j mod 8: the bit a low nibble stands for within its half row.
@(private, rodata)
NIBBLE_BITS := [16]u8{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}

// 0xFF in each lane of `b` that is in `t`, looked up one register of the tier at a time.
@(private)
members :: #force_inline proc "contextless" ($T: Tier, b: Block, t: Byte_Set) -> Block {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	m: [64 / N]U
	bits := load16(raw_data(NIBBLE_BITS[:]))
	#unroll for i in 0 ..< 64 / N {
		low := simd.bit_and(w[i], U(0x0f))
		high := simd.shr(w[i], U(4))
		first_half := simd.lanes_lt(low, U(8))
		row := simd.bit_or(simd.bit_and(lookup(T, t.low, high), first_half), simd.bit_and_not(lookup(T, t.high, high), first_half))
		m[i] = simd.lanes_ne(simd.bit_and(row, lookup(T, bits, low)), U(0))
	}
	return transmute(Block)m
}

@(private)
set_loop :: #force_inline proc "contextless" ($T: Tier, src: []u8, t: Byte_Set) -> int {
	for lo := 0; lo < len(src); lo += 64 {
		bits := pack(members(T, load_block(T, src, lo), t))
		// A padded last block's zero bytes may be members.
		if left := len(src) - lo; left < 64 {
			bits &= u64(1) << uint(left) - 1
		}
		if bits != 0 {
			return lo + int(intrinsics.count_trailing_zeros(bits))
		}
	}
	return -1
}
