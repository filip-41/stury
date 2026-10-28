#+build !amd64
package kernel

import "base:intrinsics"
import "core:simd"

// One tier: arm64 always has NEON, and other targets take LLVM's lowering of the portable code.
Tier :: enum u8 {
	Base,
}

// The target features of each tier, for `@(enable_target_feature)` on a caller's hot loops.
FEATURES :: [Tier]string {
	.Base = "",
}

// The width of each tier's vector registers.
VECTOR_BYTES :: [Tier]int {
	.Base = 16,
}

// The best tier this CPU runs.
tier :: proc "contextless" () -> Tier {
	return .Base
}

// Lane j is `t[i[j]]`, for indices below 16.
@(private)
lookup :: #force_inline proc "contextless" ($T: Tier, t, i: V) -> V {
	return simd.runtime_swizzle(t, i)
}

// Bit i set where an odd number of the bits of `x` at or below i are set. With the quotes of a block in `x`, these
// are the bytes from each opening quote up to its closing quote, the closing quote excluded.
prefix_xor :: #force_inline proc "contextless" ($T: Tier, x: u64) -> u64 {
	x := x
	x ~= x << 1
	x ~= x << 2
	x ~= x << 4
	x ~= x << 8
	x ~= x << 16
	x ~= x << 32
	return x
}

// The positions of the set bits of `m`, plus `base`, written from `out[n]` on, and the count after them. Reversed
// once, so that each position is a leading zero count: arm64 has no trailing zero count, and counting trailing zeros
// reverses the bits again for every slot. Once the bits run out the count is 64 and the slot takes junk. `& 63`
// keeps the shift defined without a select, and the last loop counts slots instead of testing `r`.
flatten :: #force_inline proc "contextless" (out: [^]u16, n: int, m: u64, base: u16) -> int #no_bounds_check {
	cnt := int(intrinsics.count_ones(m))
	w := out[n:]
	r := intrinsics.reverse_bits(m)
	#unroll for k in 0 ..< 2 {
		if k == 0 || cnt > FLATTEN_STEP * k {
			#unroll for i in 0 ..< FLATTEN_STEP {
				lz := intrinsics.count_leading_zeros(r)
				w[FLATTEN_STEP * k + i] = base + u16(lz)
				r ~= (u64(1) << 63) >> (lz & 63)
			}
		}
	}
	for i := 2 * FLATTEN_STEP; i < cnt; i += 1 {
		lz := intrinsics.count_leading_zeros(r)
		w[i] = base + u16(lz)
		r ~= (u64(1) << 63) >> (lz & 63)
	}
	return n + cnt
}

// The bytes of `src` from `lo` to its end, fewer than 64, read in place: `lo < len(src) < lo + 64`.
load_tail :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Tail {
	return paged_tail(src, lo)
}

// The bytes of `src` from `lo` to its end, fewer than 64, followed by zeros: for a check that reads every lane, as
// UTF-8 validation does, where `align` cannot clear what the lanes outside the input did.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	return copied_tail(src, lo)
}
