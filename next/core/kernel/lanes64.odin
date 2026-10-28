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

// One bit per lane mask: `pmovmskb` per register, or `kmovq` from a mask register.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	return transmute(u64)simd.extract_msbs(m)
}

// Whether any lane mask is set. The packed mask is the test: packing costs one instruction per register, as a
// vector test does.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return pack(m) != 0
}
