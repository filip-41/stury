#+build amd64
package kernel

import "core:simd"
import "core:simd/x86"
import "core:sys/info"

// The x86-64 tiers: `.V2` is x86-64-v2 (SSE4.2, 16-byte registers), the floor and every walk's tier; `.V3` adds AVX2,
// 32-byte registers and PCLMULQDQ for bulk loops. A caller builds each bulk loop once per tier as a `#force_no_inline`
// procedure with the tier's `FEATURES` and picks one with `tier()`. The kernels take the tier as `$T` and inline into
// that loop; Odin refuses `#force_inline` into a procedure without the features.
Tier :: enum u8 {
	V2,
	V3,
}

// Features for `@(enable_target_feature)`. `-slow-unaligned-mem-32` stops LLVM splitting 32-byte unaligned loads, as
// it does for Odin's default CPU.
FEATURES :: [Tier]string {
	.V2 = "ssse3,sse4.1,sse4.2,popcnt",
	.V3 = "avx,avx2,bmi,bmi2,popcnt,pclmul,-slow-unaligned-mem-32",
}

@(private)
VECTOR_BYTES :: [Tier]int {
	.V2 = 16,
	.V3 = 32,
}

@(private = "file")
FORCED :: #config(TIER, -1)
#assert(FORCED < len(Tier), "-define:TIER names no tier")

// The highest tier this CPU supports, or `Tier(TIER)` under `-define:TIER=<n>`. `core:sys/info` reports AVX only where
// the OS saves its registers.
tier :: proc "contextless" () -> Tier {
	when FORCED >= 0 {
		return Tier(FORCED)
	}
	V3 :: info.CPU_Features{.avx, .avx2, .bmi1, .bmi2, .popcnt, .pclmulqdq}
	if V3 <= info.cpu_features() {
		return .V3
	}
	return .V2
}

@(private = "file")
H :: #simd[32]u8

// Lane j is `t[i[j]]`, for indices below 16, one shuffle per register.
@(private)
lookup :: #force_inline proc "contextless" ($T: Tier, t: V, i: #simd[VECTOR_BYTES[T]]u8) -> #simd[VECTOR_BYTES[T]]u8 {
	when T == .V3 {
		return transmute(H)lookup_v3(t, transmute([2]V)i)
	} else {
		return lookup_v2(t, i)
	}
}

// Tier procedures take and return 16-byte vectors, which cross a feature boundary in the same registers. They are not
// generic, since a tier's instructions in a generic procedure fail to compile where it is not inlined.
@(private = "file", enable_target_feature = FEATURES[.V2])
lookup_v2 :: proc "contextless" (t, i: V) -> V {
	return transmute(V)x86._mm_shuffle_epi8(transmute(x86.__m128i)t, transmute(x86.__m128i)i)
}

@(private = "file", enable_target_feature = FEATURES[.V3])
lookup_v3 :: proc "contextless" (t: V, i: [2]V) -> [2]V {
	return transmute([2]V)x86._mm256_shuffle_epi8(transmute(x86.__m256i)[2]V{t, t}, transmute(x86.__m256i)i)
}

// Bit i is the XOR of bits 0 to i of `x`: bit i of the carry-less product of `x` and all ones.
@(private, enable_target_feature = "pclmul")
clmul_prefix_xor :: proc "contextless" (x: u64) -> u64 {
	p := x86._mm_clmulepi64_si128(x86.__m128i{i64(x), 0}, x86.__m128i{-1, -1}, 0)
	return u64(simd.extract(p, 0))
}

// `src[lo:]` zero-padded to a block, for `0 < len(src) - lo < 64`.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	return copied_tail(src, lo)
}

// `scan_op` built for the CPU's tier, each copy out of line with its tier's features.
@(private)
scan :: #force_inline proc "contextless" (src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int {
	if tier() == .V3 {
		return scan_v3(src, c, s, OP)
	}
	return scan_v2(src, c, s, OP)
}

@(private, enable_target_feature = FEATURES[.V2])
scan_v2 :: #force_no_inline proc "contextless" (src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int {
	return scan_op(.V2, src, c, s, OP)
}

@(private, enable_target_feature = FEATURES[.V3])
scan_v3 :: #force_no_inline proc "contextless" (src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int {
	return scan_op(.V3, src, c, s, OP)
}
