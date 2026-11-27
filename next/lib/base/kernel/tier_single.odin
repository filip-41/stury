#+build !amd64
// `simd` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package kernel

import "core:simd"

// The only tier of a target with no x86 tiers: NEON on arm64, LLVM's lowering elsewhere.
Tier :: enum u8 {
	Base,
}

@(private)
PMULL_FEATURES :: "neon,aes"

FEATURES :: [Tier]string {
	.Base = PMULL_FEATURES when PMULL else "",
}

@(private)
VECTOR_BYTES :: [Tier]int {
	.Base = 16,
}

// Individual target SIMD capabilities on non-x86 targets, matching the `caps()` surface of `tier_amd64.odin`.
Cap :: enum u8 {
	Neon,
	Pmull,
	Simd128,
}

Caps :: bit_set[Cap; u32]
#assert(size_of(Caps) == 4)

@(require_results)
tier :: #force_inline proc "contextless" () -> Tier {
	return .Base
}

@(require_results)
caps :: #force_inline proc "contextless" () -> Caps {
	when ODIN_ARCH == .arm64 {
		return {.Neon, .Pmull} when PMULL else {.Neon}
	} else when IS_WASM && !SCALAR_WASM {
		return {.Simd128}
	} else {
		return {}
	}
}

// Lane j is `t[i[j]]`, for indices below 16. WebAssembly without `simd128` has no variable shuffle to lower
// `runtime_swizzle` to, so its lanes are read one at a time.
@(private, require_results)
lookup :: #force_inline proc "contextless" ($T: Tier, t, i: V) -> V {
	when SCALAR_WASM {
		table := transmute([16]u8)t
		index := transmute([16]u8)i
		r: [16]u8
		#unroll for j in 0 ..< 16 {
			r[j] = table[index[j] & 15]
		}
		return transmute(V)r
	} else {
		return simd.runtime_swizzle(t, i)
	}
}

@(private, require_results)
scan :: #force_inline proc "contextless" (src: []u8, c: u8, $OP: Scan_Op) -> int {
	return scan_op(.Base, src, c, OP)
}

@(private, require_results)
find_set :: #force_inline proc "contextless" (src: []u8, t: Byte_Set) -> int {
	return set_loop(.Base, src, t)
}
