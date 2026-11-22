package kernel

import "core:simd"

// Two 16-byte tables sorting bytes into up to 8 sets: byte `b` is in set k when `lo[b & 15] & hi[b >> 4]` shares a bit
// with set k's bits. Each pair of a set and a high nibble has one bit, so membership is exact while the sets have at
// most 8 such pairs.
Nibble_Table :: struct {
	lo, hi: #simd[16]u8,
}

// The class bits each byte of `b` gets from `t`, looked up one register of the tier at a time.
classes :: #force_inline proc "contextless" ($T: Tier, b: Block, t: Nibble_Table) -> Block {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	c: [64 / N]U
	#unroll for i in 0 ..< 64 / N {
		c[i] = simd.bit_and(lookup(T, t.lo, simd.bit_and(w[i], U(0x0f))), lookup(T, t.hi, simd.shr(w[i], U(4))))
	}
	return transmute(Block)c
}

// 0xFF in each lane whose class bits share a bit with `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> Block {
	return transmute(Block)simd.lanes_ne(simd.bit_and(transmute(W)c, W(bits)), W(0))
}
