#+build !arm64
package kernel

import "base:intrinsics"
import "core:simd"

// One 64-lane vector. LLVM splits it to the target's width: four registers on SSE, two on AVX2, one on AVX-512,
// where a compare writes a mask register and `pack` is one move out of it. Written at 16 lanes, the AVX-512 build
// instead merges 16-lane mask registers one OR at a time.
Block :: #simd[64]u8

load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	return intrinsics.unaligned_load((^Block)(p))
}

// The lanes of `b` equal to `c`.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return simd.lanes_eq(b, Block(c))
}

// The lanes of `a` or of `b`.
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return simd.bit_or(a, b)
}

// The set bits of every byte of `b`, from the table, looked up 16 lanes at a time. Odin lowers a 64-lane
// `runtime_swizzle` to `pshufb` only when the whole build has AVX-512BW, and lane by lane otherwise.
classes :: #force_inline proc "contextless" (b: Block, t: Nibble_Table) -> Block {
	lo := transmute([4]#simd[16]u8)simd.bit_and(b, Block(0x0f))
	hi := transmute([4]#simd[16]u8)simd.shr(b, Block(4))
	c: [4]#simd[16]u8
	#unroll for i in 0 ..< 4 {
		c[i] = simd.bit_and(simd.runtime_swizzle(t.lo, lo[i]), simd.runtime_swizzle(t.hi, hi[i]))
	}
	return transmute(Block)c
}

// The lanes of `c`, as `classes` returns it, in a set of `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> Block {
	return simd.lanes_ne(simd.bit_and(c, Block(bits)), Block(0))
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
	return transmute(u64)simd.extract_msbs(m)
}

// Whether any lane mask is set. The packed mask is the test: packing costs one instruction per register, as a
// vector test does.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return pack(m) != 0
}
