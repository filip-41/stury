#+build !amd64
// `simd` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package kernel

import "base:intrinsics"
import "core:simd"

// The one tier of a target with no x86 tiers: NEON on arm64, LLVM's lowering elsewhere.
Tier :: enum u8 {
	Base,
}

FEATURES :: [Tier]string {
	.Base = "",
}

@(private)
VECTOR_BYTES :: [Tier]int {
	.Base = 16,
}

tier :: proc "contextless" () -> Tier {
	return .Base
}

// Lane j is `t[i[j]]`, for indices below 16.
@(private)
lookup :: #force_inline proc "contextless" ($T: Tier, t, i: V) -> V {
	return simd.runtime_swizzle(t, i)
}

// `src[lo:]` zero-padded to a block, for `0 < len(src) - lo < 64`.
load_padded :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	return copied_tail(src, lo)
}

@(private)
scan :: #force_inline proc "contextless" (src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int {
	return scan_op(.Base, src, c, s, OP)
}
