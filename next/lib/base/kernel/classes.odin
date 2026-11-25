package kernel

import "core:simd"

// Two 16-byte tables sorting bytes into up to 8 sets: byte `b` is in set k when `lo[b & 15] & hi[b >> 4]` shares a bit
// with set k's bits. Each distinct non-empty (set, low-nibble subset) bucket takes one bit — high nibbles with the same
// low-nibble subset share a bit — so membership is exact while the sets need at most 8 buckets.
Nibble_Table :: struct {
	lo, hi: #simd[16]u8,
}
#assert(size_of(Nibble_Table) == 32)

// The class bits each byte of `b` gets from `t`, looked up one register of the tier at a time.
// On amd64, callers must carry `@(enable_target_feature = FEATURES[T])` so `lookup` inlines as `pshufb`/`vpshufb`.
@(require_results)
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
// Operated per 16-byte register so WebAssembly folds `i8x16.ne` straight into `pack`'s `i8x16.bitmask` without
// `i8x16.lt_s`, and amd64 lowers `any_lane(has(...))` to `ptest`/`vptest`.
@(require_results)
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> Block {
	b, z := V(bits), V(0)
	return {
		simd.lanes_ne(simd.bit_and(c[0], b), z),
		simd.lanes_ne(simd.bit_and(c[1], b), z),
		simd.lanes_ne(simd.bit_and(c[2], b), z),
		simd.lanes_ne(simd.bit_and(c[3], b), z),
	}
}
