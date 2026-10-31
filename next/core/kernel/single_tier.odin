#+build !amd64
package kernel

import "base:intrinsics"
import "core:simd"

// The only tier on targets without x86-64 tiers. arm64 has NEON, and other targets use LLVM's lowering of the
// portable code.
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

// Returns `.Base`, the only tier.
tier :: proc "contextless" () -> Tier {
	return .Base
}

// Returns lane j as `t[i[j]]` for each index below 16, through `simd.runtime_swizzle`.
@(private)
lookup :: #force_inline proc "contextless" ($T: Tier, t, i: V) -> V {
	return simd.runtime_swizzle(t, i)
}

// Returns a mask with bit i set when an odd number of bits of `x` at or below i are set. With a block's quote bits
// as `x`, the set bits mark the bytes from each opening quote to its closing quote, excluding the close. Computed
// with six shifts and XORs.
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

// Returns the bytes of `src` from `lo` to `len(src)`, followed by zeros to fill a `Block`. For a check that reads
// every lane, such as UTF-8 validation. The caller must pass `0 < len(src) - lo < 64`.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	return copied_tail(src, lo)
}
