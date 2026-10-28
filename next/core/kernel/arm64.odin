#+build arm64
package kernel

import "base:intrinsics"
import "core:simd"

// Four NEON registers, kept apart because `pack` reduces them pairwise.
Block :: [4]#simd[16]u8

@(private = "file")
V :: #simd[16]u8

load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	return {
		intrinsics.unaligned_load((^V)(p)),
		intrinsics.unaligned_load((^V)(p[16:])),
		intrinsics.unaligned_load((^V)(p[32:])),
		intrinsics.unaligned_load((^V)(p[48:])),
	}
}

// The lanes of `b` equal to `c`.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	k := V(c)
	return {simd.lanes_eq(b[0], k), simd.lanes_eq(b[1], k), simd.lanes_eq(b[2], k), simd.lanes_eq(b[3], k)}
}

// One bit per lane mask. NEON has no instruction that gathers lane bits, each lane keeps its bit of a byte (1, 2 ..
// 128), and three rounds of pairwise adds fold the 64 lanes into 8 bytes. The bits never overlap, so the adds are
// ORs. LLVM's portable lowering of the same packing sums each register across its lanes and moves it out on its
// own, which takes more cycles.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	w := V{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}
	s := addp(addp(simd.bit_and(m[0], w), simd.bit_and(m[1], w)), addp(simd.bit_and(m[2], w), simd.bit_and(m[3], w)))
	return (transmute([2]u64)addp(s, s))[0]
}

// Whether any lane mask is set. `umaxv` reduces a register in one instruction, an OR reduction goes through scalar
// registers.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return simd.reduce_max(simd.bit_or(simd.bit_or(m[0], m[1]), simd.bit_or(m[2], m[3]))) != 0
}

@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.aarch64.neon.addp.v16i8")
	addp :: proc(a, b: V) -> V ---
}
