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

// Returns a mask with 0xFF in each lane where `b`'s byte equals `c`.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	k := V(c)
	return {simd.lanes_eq(b[0], k), simd.lanes_eq(b[1], k), simd.lanes_eq(b[2], k), simd.lanes_eq(b[3], k)}
}

// Returns a mask with 0xFF in each lane where `b`'s byte is below `c`.
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	k := V(c)
	return {simd.lanes_lt(b[0], k), simd.lanes_lt(b[1], k), simd.lanes_lt(b[2], k), simd.lanes_lt(b[3], k)}
}

// Returns `a` OR `b` lane by lane, 0xFF where either mask is set.
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return {simd.bit_or(a[0], b[0]), simd.bit_or(a[1], b[1]), simd.bit_or(a[2], b[2]), simd.bit_or(a[3], b[3])}
}

// Returns 0xFF in each lane whose class bits in `c`, as `classes` returned them, share a bit with `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> (m: Block) {
	k := V(bits)
	#unroll for i in 0 ..< 4 {
		m[i] = simd.lanes_ne(simd.bit_and(c[i], k), V(0))
	}
	return
}

// Returns one bit per lane of `m`, 64 bits in all. NEON has no instruction that gathers lane bits, so each lane
// keeps its bit inside a byte (1 to 128), and three rounds of pairwise adds fold the 64 lanes into 8 bytes. The bits
// do not overlap, and the adds act as ORs. LLVM's portable lowering of `extract_msbs` sums each register across its
// lanes and moves each out separately.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	s := fold(m)
	return (transmute([2]u64)addp(s, s))[0]
}

// Returns `pack(m[i])` for each of the 2 to 4 masks. The last round of pairwise adds handles two masks at once, so
// packing masks together uses fewer instructions than packing each alone.
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

// Folds the 64 lane masks of `m` into 16 bytes with the first two rounds of pairwise adds, weighting each lane by
// 1 to 128. A lane mask is 0x00 or 0xFF, so `min` weights it as `and` would. With `and`, LLVM merges the weighting
// into the compare that made the mask, and `has` compiles to and, cmeq and bic per register instead of cmtst.
@(private = "file")
fold :: #force_inline proc "contextless" (m: Block) -> V {
	w := V{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}
	return addp(addp(simd.min(m[0], w), simd.min(m[1], w)), addp(simd.min(m[2], w), simd.min(m[3], w)))
}

// Whether every byte of `b` is below 0x80.
is_ascii :: #force_inline proc "contextless" (b: Block) -> bool {
	return simd.reduce_max(simd.bit_or(simd.bit_or(b[0], b[1]), simd.bit_or(b[2], b[3]))) < 0x80
}

// Reports whether any lane mask in `m` is set. `umaxv` reduces a register in one instruction, where an OR reduction
// would use scalar registers.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return simd.reduce_max(simd.bit_or(simd.bit_or(m[0], m[1]), simd.bit_or(m[2], m[3]))) != 0
}

// Returns the index of the first set lane in the 16 lane masks of `m`, or 16 when none is set. NEON has no
// instruction that gathers one bit a lane, so a narrowing shift (`shrn`) keeps four bits a lane in a scalar register.
first_lane :: #force_inline proc "contextless" (m: V) -> u64 {
	bits := transmute(u64)cast(#simd[8]u8)simd.shr(transmute(#simd[8]u16)m, 4)
	return u64(intrinsics.count_trailing_zeros(bits)) >> 2
}

@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.aarch64.neon.addp.v16i8")
	addp :: proc(a, b: V) -> V ---
}
