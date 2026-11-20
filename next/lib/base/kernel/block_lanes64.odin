#+build !arm64
package kernel

import "base:intrinsics"
import "core:simd"

// Block operations on one 64-lane vector, which LLVM splits to four SSE or two AVX2 registers.

// The load goes through `v` first: Odin folds a `transmute` of the load into a load at `Block`'s alignment.
load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	v := intrinsics.unaligned_load((^W)(p))
	return transmute(Block)v
}

// 0xFF in each lane where `b`'s byte equals `c`.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_eq(transmute(W)b, W(c))
}

pack_n :: #force_inline proc "contextless" (m: [$N]Block) -> (r: [N]u64) where 2 <= N && N <= 4 {
	#unroll for i in 0 ..< N {
		r[i] = pack(m[i])
	}
	return
}

// One bit per lane of `m`, by `pmovmskb` per register.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	return transmute(u64)simd.extract_msbs(transmute(W)m)
}

is_ascii :: #force_inline proc "contextless" (b: Block) -> bool {
	return simd.extract_msbs(transmute(W)b) == {}
}

// By `ptest`; a max reduction is a shuffle tree on x86.
all_zero :: #force_inline proc "contextless" (v: #simd[$N]u8) -> bool {
	return simd.reduce_or(v) == 0
}

is_ascii16 :: #force_inline proc "contextless" (v: V) -> bool {
	return transmute(u16)simd.extract_msbs(v) == 0
}

// The first set lane of `m`, or 16 for none: bit 16 stops the count when no lane is set.
first_lane16 :: #force_inline proc "contextless" (m: V) -> u64 {
	return u64(intrinsics.count_trailing_zeros(u32(transmute(u16)simd.extract_msbs(m)) | 0x1_0000))
}

// The last set lane of `m`, which has one.
last_lane16 :: #force_inline proc "contextless" (m: V) -> u64 {
	return 31 - u64(intrinsics.count_leading_zeros(u32(transmute(u16)simd.extract_msbs(m))))
}
