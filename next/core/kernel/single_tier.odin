#+build !amd64
package kernel

import "core:simd"

// One tier: arm64 always has NEON, and other targets take LLVM's lowering of the portable code.
Tier :: enum u8 {
	Base,
}

// The target features of each tier, for `@(enable_target_feature)` on a caller's hot loops.
FEATURES :: [Tier]string {
	.Base = "",
}

// The best tier this CPU runs.
tier :: proc "contextless" () -> Tier {
	return .Base
}

@(private = "file")
V :: #simd[16]u8

// The set bits of every byte of `b`, from the table: `t` looks up both nibbles.
classes :: #force_inline proc "contextless" ($T: Tier, b: Block, t: Nibble_Table) -> (c: Block) {
	#unroll for i in 0 ..< 4 {
		lo := simd.runtime_swizzle(t.lo, simd.bit_and(b[i], V(0x0f)))
		c[i] = simd.bit_and(lo, simd.runtime_swizzle(t.hi, simd.shr(b[i], V(4))))
	}
	return
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

// The bytes of `src` from `lo` to its end, fewer than 64, read in place: `lo < len(src) < lo + 64`.
load_tail :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Tail {
	return paged_tail(src, lo)
}

// The bytes of `src` from `lo` to its end, fewer than 64, followed by zeros: for a check that reads every lane, as
// UTF-8 validation does, where `align` cannot clear what the lanes outside the input did.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	return copied_tail(src, lo)
}
