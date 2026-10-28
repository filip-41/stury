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

// The set bits of every byte of `b`, from the table: `t` looks up both nibbles, 16, 32 or 64 bytes at a time.
classes :: #force_inline proc "contextless" ($T: Tier, b: Block, t: Nibble_Table) -> Block {
	when T == .V4 {
		return classes_v4(b, t)
	} else when T == .V3 {
		return classes_v3(b, t)
	} else {
		return classes_v2(b, t)
	}
}

@(private = "file", enable_target_feature = FEATURES[.V2])
classes_v2 :: proc "contextless" (b: Block, t: Nibble_Table) -> (c: Block) {
	lo, hi := transmute(x86.__m128i)t.lo, transmute(x86.__m128i)t.hi
	#unroll for i in 0 ..< 4 {
		l := x86._mm_shuffle_epi8(lo, transmute(x86.__m128i)simd.bit_and(b[i], V(0x0f)))
		h := x86._mm_shuffle_epi8(hi, transmute(x86.__m128i)simd.shr(b[i], V(4)))
		c[i] = transmute(V)simd.bit_and(l, h)
	}
	return
}

@(private = "file", enable_target_feature = FEATURES[.V3])
classes_v3 :: proc "contextless" (b: Block, t: Nibble_Table) -> Block {
	lo := transmute(H)[2]V{t.lo, t.lo}
	hi := transmute(H)[2]V{t.hi, t.hi}
	w := transmute([2]H)b
	c: [2]H
	#unroll for i in 0 ..< 2 {
		c[i] = simd.bit_and(pshufb256(lo, simd.bit_and(w[i], H(0x0f))), pshufb256(hi, simd.shr(w[i], H(4))))
	}
	return transmute(Block)c
}

@(private = "file", enable_target_feature = FEATURES[.V4])
classes_v4 :: proc "contextless" (b: Block, t: Nibble_Table) -> Block {
	lo := transmute(W)[4]V{t.lo, t.lo, t.lo, t.lo}
	hi := transmute(W)[4]V{t.hi, t.hi, t.hi, t.hi}
	w := transmute(W)b
	return transmute(Block)simd.bit_and(pshufb512(lo, simd.bit_and(w, W(0x0f))), pshufb512(hi, simd.shr(w, W(4))))
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
