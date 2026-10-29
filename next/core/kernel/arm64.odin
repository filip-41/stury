#+build arm64
package kernel

import "base:intrinsics"
import "core:simd"

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

// The lanes of `b` below `c`.
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	k := V(c)
	return {simd.lanes_lt(b[0], k), simd.lanes_lt(b[1], k), simd.lanes_lt(b[2], k), simd.lanes_lt(b[3], k)}
}

// The lanes of `a` or of `b`.
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return {simd.bit_or(a[0], b[0]), simd.bit_or(a[1], b[1]), simd.bit_or(a[2], b[2]), simd.bit_or(a[3], b[3])}
}

// The lanes of `c`, as `classes` returns it, in a set of `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> (m: Block) {
	k := V(bits)
	#unroll for i in 0 ..< 4 {
		m[i] = simd.lanes_ne(simd.bit_and(c[i], k), V(0))
	}
	return
}

// One bit per lane mask. NEON has no instruction that gathers lane bits, each lane keeps its bit of a byte (1, 2 ..
// 128), and three rounds of pairwise adds fold the 64 lanes into 8 bytes. The bits never overlap, so the adds are
// ORs. LLVM's portable lowering of the same packing sums each register across its lanes and moves it out on its
// own, which takes more cycles.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	s := fold(m)
	return (transmute([2]u64)addp(s, s))[0]
}

// `pack` of each mask. The last round of pairwise adds takes two masks at once, so masks packed together cost less
// than masks packed one by one.
pack_n :: #force_inline proc "contextless" (m: [$N]Block) -> (r: [N]u64) where 2 <= N && N <= 4 {
	ab := transmute([2]u64)addp(fold(m[0]), fold(m[1]))
	r[0], r[1] = ab[0], ab[1]
	when N == 3 {
		c := fold(m[2])
		r[2] = (transmute([2]u64)addp(c, c))[0]
	} else when N == 4 {
		cd := transmute([2]u64)addp(fold(m[2]), fold(m[3]))
		r[2], r[3] = cd[0], cd[1]
	}
	return
}

// The 64 lane masks of `m` weighted and folded into 16 bytes: the first two of the three rounds of pairwise adds.
// A lane mask is 0x00 or 0xFF, so `min` weights it as `and` would. With `and`, LLVM merges the weighting into the
// compare that made the mask, `has` costs and, cmeq and bic per register instead of cmtst, and the walk is slower.
@(private = "file")
fold :: #force_inline proc "contextless" (m: Block) -> V {
	w := V{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}
	return addp(addp(simd.min(m[0], w), simd.min(m[1], w)), addp(simd.min(m[2], w), simd.min(m[3], w)))
}

// Whether every byte of `b` is below 0x80.
is_ascii :: #force_inline proc "contextless" (b: Block) -> bool {
	return simd.reduce_max(simd.bit_or(simd.bit_or(b[0], b[1]), simd.bit_or(b[2], b[3]))) < 0x80
}

// Whether any lane mask is set. `umaxv` reduces a register in one instruction, an OR reduction goes through scalar
// registers.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return simd.reduce_max(simd.bit_or(simd.bit_or(m[0], m[1]), simd.bit_or(m[2], m[3]))) != 0
}

// The first lane set in the 16 lane masks of `m`, or 16. A narrowing shift (`shrn`) keeps four bits a lane in a scalar
// register, since NEON has no instruction that gathers one bit a lane.
first_lane :: #force_inline proc "contextless" (m: V) -> u64 {
	bits := transmute(u64)cast(#simd[8]u8)simd.shr(transmute(#simd[8]u16)m, 4)
	return u64(intrinsics.count_trailing_zeros(bits)) >> 2
}

@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.aarch64.neon.addp.v16i8")
	addp :: proc(a, b: V) -> V ---
}
