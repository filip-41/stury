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

// The bytes of `src` from `lo` to its end, fewer than 64, followed by zeros: for a check that reads every lane, as
// UTF-8 validation does.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	return copied_tail(src, lo)
}
