#+build amd64
package kernel

import "core:simd"
import "core:simd/x86"
import "core:sys/info"

// The x86-64 tiers, each a class of machine: v2 has SSE4.2 and 16-byte registers, v3 AVX2 and 32-byte registers, v4
// AVX-512BW, 64-byte registers and mask registers. Every tier also has POPCNT and PCLMULQDQ, so v2 with PCLMULQDQ
// is the floor. A caller builds each hot loop once per tier, as a `#force_no_inline` procedure with the tier's
// `FEATURES`, and picks one by `tier()`. The kernels below take the tier as `$T`, and keep each tier's instructions
// in a procedure with its features, which LLVM inlines into such a loop: Odin refuses `#force_inline` into a
// procedure without the features, and a tier's instructions written in a generic procedure fail to compile where it
// is not inlined.
Tier :: enum u8 {
	V2,
	V3,
	V4,
}

// The target features of each tier, for `@(enable_target_feature)` on a caller's hot loops. Features add to the
// build's CPU without changing how LLVM tunes for it, and Odin's default CPU, x86-64-v2, splits every unaligned
// 32-byte load in two: v3 and v4 turn that off.
FEATURES :: [Tier]string {
	.V2 = "ssse3,sse4.1,sse4.2,popcnt,pclmul",
	.V3 = "avx,avx2,bmi,bmi2,popcnt,pclmul,-slow-unaligned-mem-32",
	.V4 = "avx,avx2,bmi,bmi2,popcnt,pclmul,avx512f,avx512bw,avx512vl,evex512,-slow-unaligned-mem-32",
}

// The width of each tier's vector registers.
VECTOR_BYTES :: [Tier]int {
	.V2 = 16,
	.V3 = 32,
	.V4 = 64,
}

// The best tier this CPU runs. `core:sys/info` reports AVX and AVX-512 only where the OS saves their registers.
tier :: proc "contextless" () -> Tier {
	f := info.cpu_features()
	V3 :: info.CPU_Features{.avx, .avx2, .bmi1, .bmi2, .popcnt, .pclmulqdq}
	switch {
	case V3 + {.avx512f, .avx512bw, .avx512vl} <= f:
		return .V4
	case V3 <= f:
		return .V3
	}
	return .V2
}

@(private = "file")
V :: #simd[16]u8
@(private = "file")
H :: #simd[32]u8
@(private = "file")
W :: #simd[64]u8

// Lane j is `t[i[j]]`, for indices below 16: one shuffle per vector register.
@(private)
lookup :: #force_inline proc "contextless" ($T: Tier, t: V, i: #simd[VECTOR_BYTES[T]]u8) -> #simd[VECTOR_BYTES[T]]u8 {
	when T == .V4 {
		return transmute(W)lookup_v4(t, transmute(Block)i)
	} else when T == .V3 {
		return transmute(H)lookup_v3(t, transmute([2]V)i)
	} else {
		return lookup_v2(t, i)
	}
}

// The tier's instructions take and return arrays of 16-byte vectors, which cross a call in the same registers on both
// sides of a feature boundary.
@(private = "file", enable_target_feature = FEATURES[.V2])
lookup_v2 :: proc "contextless" (t, i: V) -> V {
	return transmute(V)x86._mm_shuffle_epi8(transmute(x86.__m128i)t, transmute(x86.__m128i)i)
}

@(private = "file", enable_target_feature = FEATURES[.V3])
lookup_v3 :: proc "contextless" (t: V, i: [2]V) -> [2]V {
	return transmute([2]V)pshufb256(transmute(H)[2]V{t, t}, transmute(H)i)
}

@(private = "file", enable_target_feature = FEATURES[.V4])
lookup_v4 :: proc "contextless" (t: V, i: Block) -> Block {
	return transmute(Block)pshufb512(transmute(W)[4]V{t, t, t, t}, transmute(W)i)
}

// Bit i set where an odd number of the bits of `x` at or below i are set. With the quotes of a block in `x`, these
// are the bytes from each opening quote up to its closing quote, the closing quote excluded. One carry-less
// multiplication on every tier.
prefix_xor :: #force_inline proc "contextless" ($T: Tier, x: u64) -> u64 {
	return clmul_prefix_xor(x)
}

// Bit i of the carry-less product of `x` and all ones is the XOR of bits 0 to i of `x`.
@(private = "file", enable_target_feature = "pclmul")
clmul_prefix_xor :: proc "contextless" (x: u64) -> u64 {
	p := x86._mm_clmulepi64_si128(x86.__m128i{i64(x), 0}, x86.__m128i{-1, -1}, 0)
	return u64(simd.extract(p, 0))
}

// The bytes of `src` from `lo` to its end, fewer than 64, read in place: `lo < len(src) < lo + 64`. On v4 a masked
// load reads only the input's bytes and zeros the other lanes.
load_tail :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Tail {
	when T == .V4 {
		return {block = masked_tail(src, lo), live = u64(1) << u64(len(src) - lo) - 1}
	} else when T == .V3 {
		return paged_tail_v3(src, lo)
	} else {
		return paged_tail(src, lo)
	}
}

@(private = "file", no_sanitize_address, enable_target_feature = FEATURES[.V3])
paged_tail_v3 :: #force_no_inline proc "contextless" (src: []u8, lo: int) -> Tail {
	return read_paged_tail(src, lo)
}

// The bytes of `src` from `lo` to its end, fewer than 64, followed by zeros: for a check that reads every lane, as
// UTF-8 validation does, where `align` cannot clear what the lanes outside the input did.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	when T == .V4 {
		return masked_tail(src, lo)
	} else {
		return copied_tail(src, lo)
	}
}

@(private = "file", enable_target_feature = FEATURES[.V4])
masked_tail :: proc "contextless" (src: []u8, lo: int) -> Block {
	rem := len(src) - lo
	when ODIN_DEBUG {
		assert_contextless(0 < rem && rem < 64)
	}
	live := simd.lanes_lt(simd.indices(W), W(u8(rem)))
	return transmute(Block)simd.masked_load((^W)(raw_data(src)[lo:]), W(0), live)
}

// Odin's `core:simd/x86` lacks the 64-byte shuffle, and has the 32-byte one only after dev-2026-10.
@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.x86.avx2.pshuf.b")
	pshufb256 :: proc(table, index: H) -> H ---
	@(link_name = "llvm.x86.avx512.pshuf.b.512")
	pshufb512 :: proc(table, index: W) -> W ---
}
