#+build !arm64
package kernel

import "base:intrinsics"
import "core:simd"

when ODIN_ENDIAN != .Little {
	#panic("kernel block ops require little-endian")
}

// Only arm64 has a carry-less multiply on the floor tier.
@(private)
PMULL :: false

// Block operations on one 64-lane vector, which LLVM splits to four SSE or two AVX2 registers on x86.

// Loads 64 unaligned bytes from `p`. The caller guarantees 64 readable bytes at `p`.
// The load goes through `v` first: Odin folds a `transmute` of the load into a load at `Block`'s alignment.
load :: #force_inline proc "contextless" (p: [^]u8) -> Block {
	v := intrinsics.unaligned_load((^W)(p))
	return transmute(Block)v
}

// One bit per lane of `m` (each lane 0x00 or 0xFF), by `pmovmskb` per register on x86.
pack :: #force_inline proc "contextless" (m: Block) -> u64 {
	// LLVM's WebAssembly backend cannot widen a 64-lane compare joined to an `i64` mask, so each register packs alone.
	when IS_WASM {
		return u64(transmute(u16)simd.extract_msbs(m[0])) | u64(transmute(u16)simd.extract_msbs(m[1])) << 16 |
			u64(transmute(u16)simd.extract_msbs(m[2])) << 32 | u64(transmute(u16)simd.extract_msbs(m[3])) << 48
	} else {
		return transmute(u64)simd.extract_msbs(transmute(W)m)
	}
}

// `pack` of 2 to 4 lane masks (each lane 0x00 or 0xFF).
pack_n :: #force_inline proc "contextless" (m: [$N]Block) -> (r: [N]u64) where 2 <= N, N <= 4 {
	#unroll for i in 0 ..< N {
		r[i] = pack(m[i])
	}
	return
}

// Compiles to `ptest` on x86 (a max reduction is a shuffle tree there). On WebAssembly, `reduce_or` is a shuffle tree,
// while reducing 16-byte registers and checking `extract_msbs(lanes_ne(r, 0))` lowers to `v128.any_true`.
all_zero :: #force_inline proc "contextless" (v: #simd[$N]u8) -> bool {
	when IS_WASM && N >= 16 && N % 16 == 0 {
		when N == 16 {
			r := v
		} else {
			parts := transmute([N / 16]V)v
			r := parts[0]
			#unroll for i in 1 ..< N / 16 {
				r = simd.bit_or(r, parts[i])
			}
		}
		return transmute(u16)simd.extract_msbs(simd.lanes_ne(r, V(0))) == 0
	} else {
		return simd.reduce_or(v) == 0
	}
}

// Whether every byte of `v` is below 0x80.
is_ascii16 :: #force_inline proc "contextless" (v: V) -> bool {
	return transmute(u16)simd.extract_msbs(v) == 0
}

// The first set lane of `m` (each lane 0x00 or 0xFF), or 16 for none: bit 16 stops the count when no lane is set.
first_lane16 :: #force_inline proc "contextless" (m: V) -> u64 {
	return u64(intrinsics.count_trailing_zeros(u32(transmute(u16)simd.extract_msbs(m)) | 0x1_0000))
}

// The last set lane of `m` (each lane 0x00 or 0xFF), which has one.
@(private)
last_lane16 :: #force_inline proc "contextless" (m: V) -> u64 {
	return 31 - u64(intrinsics.count_leading_zeros(u32(transmute(u16)simd.extract_msbs(m))))
}
