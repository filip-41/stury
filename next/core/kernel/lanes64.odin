#+build !arm64
package kernel

import "base:intrinsics"
import "core:simd"

// Block operations written on all 64 lanes at once, as one vector that LLVM splits to the target's width: four
// registers on SSE, two on AVX2, one on AVX-512, where a compare writes a mask register and `pack` moves it out with
// one instruction. Written at 16 lanes, the AVX-512 code would instead merge 16-lane mask registers with ORs.

// Loads 64 bytes from `p` as a `Block`, with no alignment requirement. The load is stored in `v` first, because Odin
// folds a `transmute` of the load into a load of `Block` at `Block`'s alignment.
load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	v := intrinsics.unaligned_load((^W)(p))
	return transmute(Block)v
}

// Returns a mask with 0xFF in each lane where `b`'s byte equals `c`.
eq :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_eq(transmute(W)b, W(c))
}

// Returns a mask with 0xFF in each lane where `b`'s byte is below `c`.
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_lt(transmute(W)b, W(c))
}

// Returns `a` OR `b` lane by lane, 0xFF where either mask is set.
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return transmute(Block)simd.bit_or(transmute(W)a, transmute(W)b)
}

// Returns 0xFF in each lane whose class bits in `c`, as `classes` returned them, share a bit with `bits`.
has :: #force_inline proc "contextless" (c: Block, bits: u8) -> Block {
	return transmute(Block)simd.lanes_ne(simd.bit_and(transmute(W)c, W(bits)), W(0))
}

// Returns `pack(m[i])` for each of the 2 to 4 masks.
pack_n :: #force_inline proc "contextless" (m: [$N]Block) -> (r: [N]u64) where 2 <= N && N <= 4 {
	#unroll for i in 0 ..< N {
		r[i] = pack(m[i])
	}
	return
}

// Returns one bit per lane of `m`, 64 bits in all, as `pmovmskb` per register or `kmovq` from a mask register.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	return transmute(u64)simd.extract_msbs(transmute(W)m)
}

// Whether every byte of `b` is below 0x80.
is_ascii :: #force_inline proc "contextless" (b: Block) -> bool {
	return simd.extract_msbs(transmute(W)b) == {}
}

// Reports whether any lane mask in `m` is set, by testing the packed mask. Packing uses one instruction per
// register, the same as a vector test.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return pack(m) != 0
}

// Returns the index of the first set lane in the 16 lane masks of `m`, or 16 when none is set. `pmovmskb` gives one
// bit per lane, and `0x1_0000` adds a bit past lane 15 that the trailing-zero count finds when no lane is set.
first_lane :: #force_inline proc "contextless" (m: V) -> u64 {
	return u64(intrinsics.count_trailing_zeros(u32(transmute(u16)simd.extract_msbs(m)) | 0x1_0000))
}
