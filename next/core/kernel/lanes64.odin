#+build !arm64
package kernel

import "base:intrinsics"
import "core:simd"

// Operations on all 64 lanes of a block at once, as one vector that LLVM splits to the target's width: four registers
// on SSE, two on AVX2, one on AVX-512, where a compare writes a mask register and `pack` is one move out of it.
// Written at 16 lanes, the AVX-512 code instead merges 16-lane mask registers one OR at a time.

// Loaded into a variable first: Odin folds a `transmute` of the load into a load of `Block` at its own alignment.
load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	v := intrinsics.unaligned_load((^W)(p))
	return transmute(Block)v
}

// The lanes of `b` equal to `c`.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_eq(transmute(W)b, W(c))
}

// The lanes of `b` below `c`.
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_lt(transmute(W)b, W(c))
}

// The lanes of `a` or of `b`.
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return transmute(Block)simd.bit_or(transmute(W)a, transmute(W)b)
}

// The lanes of `c`, as `classes` returns it, in a set of `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> Block {
	return transmute(Block)simd.lanes_ne(simd.bit_and(transmute(W)c, W(bits)), W(0))
}

// `pack` of each mask.
pack_n :: #force_inline proc "contextless" (m: [$N]Block) -> (r: [N]u64) where 2 <= N && N <= 4 {
	#unroll for i in 0 ..< N {
		r[i] = pack(m[i])
	}
	return
}

// One bit per lane mask: `pmovmskb` per register, or `kmovq` from a mask register.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	return transmute(u64)simd.extract_msbs(transmute(W)m)
}

// Whether every byte of `b` is below 0x80.
is_ascii :: #force_inline proc "contextless" (b: Block) -> bool {
	return simd.extract_msbs(transmute(W)b) == {}
}

// Whether any lane mask is set. The packed mask is the test: packing costs one instruction per register, as a
// vector test does.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return pack(m) != 0
}

// Whether any byte of `b` is below `c`: the packed mask is the test, as in `any_lane`. x86 has no byte minimum across
// a register.
any_below :: #force_inline proc "contextless" (b: Block, c: u8) -> bool {
	return pack(below(b, c)) != 0
}

// The first lane set in the 16 lane masks of `m`, or 16: one bit a lane by `pmovmskb`, and a bit past the lanes that
// stands for the empty mask.
first_lane :: #force_inline proc "contextless" (m: V) -> u64 {
	return u64(intrinsics.count_trailing_zeros(u32(transmute(u16)simd.extract_msbs(m)) | 0x1_0000))
}
