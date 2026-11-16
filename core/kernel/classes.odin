package kernel

import "core:simd"

// Two 16-byte tables that sort bytes into up to 8 sets. Byte `b` is in set k when `lo[b & 15] & hi[b >> 4]` shares a
// bit with `bits[k]`. Each pair of a set and a high nibble owns one bit, so membership is exact while the sets have at
// most 8 such pairs between them.
Nibble_Table :: struct {
	lo, hi: #simd[16]u8,
}

// Returns, for each byte of `b`, the class bits its two nibbles give from `t`. Looks up both nibbles one vector
// register at a time.
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

// Returns 0xFF in each lane whose class bits in `c`, as `classes` returned them, share a bit with `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> Block {
	return transmute(Block)simd.lanes_ne(simd.bit_and(transmute(W)c, W(bits)), W(0))
}
