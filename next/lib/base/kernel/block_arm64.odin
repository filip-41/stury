#+build arm64
package kernel

import "base:intrinsics"
import "core:simd"

load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	return {
		load16(p),
		load16(p[16:]),
		load16(p[32:]),
		load16(p[48:]),
	}
}

// 0xFF in each lane where `b`'s byte equals `c`. Written per register: the 64-lane form changes how LLVM inlines the
// walks that call it.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	k := V(c)
	return {simd.lanes_eq(b[0], k), simd.lanes_eq(b[1], k), simd.lanes_eq(b[2], k), simd.lanes_eq(b[3], k)}
}

// One bit per lane of `m`. NEON has no lane-bit gather, so each lane is weighted 1 to 128 within its byte and three
// rounds of pairwise adds fold 64 lanes into 8 bytes; the bits do not overlap, so the adds act as ORs.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	s := fold(m)
	return (transmute([2]u64)addp(s, s))[0]
}

// `pack` of 2 to 4 masks, sharing the last round of adds between pairs.
pack_n :: #force_inline proc "contextless" (m: [$N]Block) -> (r: [N]u64) where 2 <= N, N <= 4 {
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

// The first two rounds of `pack`. `min` weights a 0x00/0xFF lane as `and` would, but keeps LLVM from merging the
// weighting into the compare, which turns `has` into and, cmeq and bic instead of cmtst.
@(private = "file")
fold :: #force_inline proc "contextless" (m: Block) -> V {
	w := V{1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128}
	return addp(
		addp(simd.min(m[0], w), simd.min(m[1], w)),
		addp(simd.min(m[2], w), simd.min(m[3], w)),
	)
}

is_ascii :: #force_inline proc "contextless" (b: Block) -> bool {
	return simd.reduce_max(simd.bit_or(simd.bit_or(b[0], b[1]), simd.bit_or(b[2], b[3]))) < 0x80
}

all_zero :: #force_inline proc "contextless" (v: #simd[$N]u8) -> bool {
	return simd.reduce_max(v) == 0
}

is_ascii16 :: #force_inline proc "contextless" (v: V) -> bool {
	return simd.reduce_max(v) < 0x80
}

// The first set lane of `m`, or 16 for none. A narrowing shift keeps four bits a lane in a scalar register.
first_lane16 :: #force_inline proc "contextless" (m: V) -> u64 {
	bits := transmute(u64)cast(#simd[8]u8)simd.shr(transmute(#simd[8]u16)m, 4)
	return u64(intrinsics.count_trailing_zeros(bits)) >> 2
}

// The last set lane of `m`, which has one.
last_lane16 :: #force_inline proc "contextless" (m: V) -> u64 {
	bits := transmute(u64)cast(#simd[8]u8)simd.shr(transmute(#simd[8]u16)m, 4)
	return (63 - u64(intrinsics.count_leading_zeros(bits))) >> 2
}

// NEON's pairwise add, opaque to LLVM. Through `simd.pairwise_add`, LLVM sees that `pack` uses only the low half of the
// last round and rewrites that `addp` as xtn, uzp2 and add, which costs `index_byte` about 15%.
@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.aarch64.neon.addp.v16i8")
	addp :: proc(a, b: V) -> V ---
}
