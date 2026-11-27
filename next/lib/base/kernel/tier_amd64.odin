#+build amd64
package kernel

import "base:intrinsics"
import "core:simd"
import "core:simd/x86"

// The x86-64 tiers: `.V2` is x86-64-v2 (SSE4.2, 16-byte registers), the floor and every walk's tier. `.V3` adds AVX2,
// 32-byte registers and PCLMULQDQ for bulk loops. A caller builds each bulk loop once per tier as a `#force_no_inline`
// procedure with the tier's `FEATURES` and picks one with `tier()`. The kernels take the tier as `$T` and inline into
// that loop, since Odin refuses `#force_inline` into a procedure without the features.
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

// Individual x86-64 ISA capabilities, queried non-monotonically via `caps()` alongside the linear `Tier`.
Cap :: enum u8 {
	Ssse3,
	Sse41,
	Sse42,
	Popcnt,
	Pclmul,
	Avx,
	Avx2,
	Bmi1,
	Bmi2,
	Avx512f,
	Avx512bw,
	Avx512vl,
	Avx512_Vbmi2,
	Vpclmul,
}

Caps :: bit_set[Cap; u32]
#assert(size_of(Caps) == 4)
#assert(len(Cap) < 32)

@(private = "file")
TIER_CAPS :: [Tier]Caps {
	.V2 = {.Ssse3, .Sse41, .Sse42, .Popcnt},
	.V3 = {.Ssse3, .Sse41, .Sse42, .Popcnt, .Pclmul, .Avx, .Avx2, .Bmi1, .Bmi2},
}

// Sentinel bit in `cached_caps` marking that CPUID/XGETBV has run (0 = unset).
@(private = "file")
CAPS_CACHED :: u32(1 << 31)

@(private = "file")
FORCED :: #config(TIER, -1)
#assert(FORCED >= -1 && FORCED < len(Tier), "-define:TIER names no tier")

// 0 = unset, 1 = .V2, 2 = .V3.
@(private = "file")
cached_tier: u8

// 0 = unset, else `CAPS_CACHED | transmute(u32)detected_caps`.
@(private = "file")
cached_caps: u32

// The highest tier this CPU supports, or `Tier(TIER)` when `-define:TIER=<n>` is set (default -1, runtime detection).
// Runtime detection probes CPUID and `xgetbv(0)` for OS-saved YMM state once via `detect_tier` and caches the result.
@(require_results)
tier :: #force_inline proc "contextless" () -> Tier {
	when FORCED >= 0 {
		return Tier(FORCED)
	}
	c := intrinsics.atomic_load_explicit(&cached_tier, .Relaxed)
	if intrinsics.unlikely(c == 0) {
		c = detect_tier()
	}
	return Tier(c - 1)
}

// Non-monotonic ISA capabilities supported by this CPU and OS, or the tier's fixed capability set when `-define:TIER=<n>`
// is set. Runtime detection probes CPUID and `xgetbv(0)` once and caches the result atomically.
@(require_results)
caps :: #force_inline proc "contextless" () -> Caps {
	when FORCED >= 0 {
		return TIER_CAPS[Tier(FORCED)]
	}
	raw := intrinsics.atomic_load_explicit(&cached_caps, .Relaxed)
	if intrinsics.unlikely(raw == 0) {
		raw = detect_caps()
	}
	return transmute(Caps)(raw &~ CAPS_CACHED)
}

// Probes CPUID and `xgetbv(0)` once, populates both `cached_caps` and `cached_tier`, and returns `cached_caps`.
@(private = "file", require_results)
detect_caps :: #force_no_inline proc "contextless" () -> u32 {
	detected: Caps
	max_id, _, _, _ := intrinsics.x86_cpuid(0, 0)
	if max_id >= 1 {
		_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
		if ecx1 & (1 << 1) != 0 {
			detected += {.Pclmul}
		}
		if ecx1 & (1 << 9) != 0 {
			detected += {.Ssse3}
		}
		if ecx1 & (1 << 19) != 0 {
			detected += {.Sse41}
		}
		if ecx1 & (1 << 20) != 0 {
			detected += {.Sse42}
		}
		if ecx1 & (1 << 23) != 0 {
			detected += {.Popcnt}
		}
		// Both XSAVE (26) and OSXSAVE (27) must be set before `xgetbv(0)` to avoid trapping on hypervisors exposing one.
		XSAVE_OSXSAVE :: u32(1 << 26 | 1 << 27)
		ymm_os, zmm_os := false, false
		if ecx1 & XSAVE_OSXSAVE == XSAVE_OSXSAVE {
			xcr0, _ := intrinsics.x86_xgetbv(0)
			ymm_os = (xcr0 & 0x6) == 0x6
			zmm_os = (xcr0 & 0xE6) == 0xE6
		}
		if ymm_os && ecx1 & (1 << 28) != 0 {
			detected += {.Avx}
		}
		if max_id >= 7 {
			_, ebx7, ecx7, _ := intrinsics.x86_cpuid(7, 0)
			if ebx7 & (1 << 3) != 0 {
				detected += {.Bmi1}
			}
			if ebx7 & (1 << 8) != 0 {
				detected += {.Bmi2}
			}
			if .Avx in detected {
				if ebx7 & (1 << 5) != 0 {
					detected += {.Avx2}
				}
				if ecx7 & (1 << 10) != 0 {
					detected += {.Vpclmul}
				}
			}
			if zmm_os && .Avx in detected {
				if ebx7 & (1 << 16) != 0 {
					detected += {.Avx512f}
				}
				if ebx7 & (1 << 30) != 0 {
					detected += {.Avx512bw}
				}
				if ebx7 & (1 << 31) != 0 {
					detected += {.Avx512vl}
				}
				if ecx7 & (1 << 6) != 0 {
					detected += {.Avx512_Vbmi2}
				}
			}
		}
	}
	raw := transmute(u32)detected | CAPS_CACHED
	t: Tier = .V3 if TIER_CAPS[.V3] <= detected else .V2
	intrinsics.atomic_store_explicit(&cached_caps, raw, .Relaxed)
	intrinsics.atomic_store_explicit(&cached_tier, u8(t) + 1, .Relaxed)
	return raw
}

// Probes CPUID and `xgetbv(0)`, caches `u8(tier) + 1`, and returns that cached encoding (1 = .V2, 2 = .V3).
@(private = "file", require_results)
detect_tier :: #force_no_inline proc "contextless" () -> u8 {
	raw := detect_caps()
	detected := transmute(Caps)(raw &~ CAPS_CACHED)
	t: Tier = .V3 if TIER_CAPS[.V3] <= detected else .V2
	return u8(t) + 1
}

@(private = "file")
H :: #simd[32]u8

// Lane j is `t[i[j] & 15]` for `i[j] < 0x80`, or 0 when bit 7 is set (`pshufb`/`vpshufb` ignores bits 4..6 and zeroes
// bytes >= 0x80, relied on by `ws_other`). Callers must carry `FEATURES[T]` (or the x86-64-v2 floor for `.V2`) so the
// tier helper inlines.
@(private, require_results)
lookup :: #force_inline proc "contextless" ($T: Tier, t: V, i: #simd[VECTOR_BYTES[T]]u8) -> #simd[VECTOR_BYTES[T]]u8 {
	when T == .V3 {
		return transmute(H)lookup_v3(t, transmute([2]V)i)
	} else {
		return lookup_v2(t, i)
	}
}

// Tier procedures take and return 16-byte vectors, which cross a feature boundary in the same registers. They are not
// generic, since a tier's instructions in a generic procedure fail to compile where it is not inlined.
@(private = "file", require_results, enable_target_feature = FEATURES[.V2])
lookup_v2 :: proc "contextless" (t, i: V) -> V {
	return transmute(V)x86._mm_shuffle_epi8(transmute(x86.__m128i)t, transmute(x86.__m128i)i)
}

@(private = "file", require_results, enable_target_feature = FEATURES[.V3])
lookup_v3 :: proc "contextless" (t: V, i: [2]V) -> [2]V {
	return transmute([2]V)x86._mm256_shuffle_epi8(transmute(x86.__m256i)[2]V{t, t}, transmute(x86.__m256i)i)
}

// Bit i is the XOR of bits 0 to i of `x`: bit i of the carry-less product of `x` and all ones. Reachable only from
// `.V3` callers (`prefix_xor` when `T != Tier(0)`), so `"avx,pclmul"` keeps out-of-line builds VEX-encoded.
@(private, require_results, enable_target_feature = "avx,pclmul")
clmul_prefix_xor :: proc "contextless" (x: u64) -> u64 {
	p := x86._mm_clmulepi64_si128(x86.__m128i{i64(x), 0}, x86.__m128i{-1, -1}, 0)
	return u64(simd.extract(p, 0))
}

// `scan_op` built for the CPU's tier, each copy out of line with its tier's features. A text shorter than a block, where
// no tier's loop runs, inlines the floor tier into the caller, relying on the x86-64-v2 target floor so `lookup_v2`
// inlines without a call.
@(private, require_results)
scan :: #force_inline proc "contextless" (src: []u8, c: u8, $OP: Scan_Op) -> int {
	if len(src) < 64 {
		return scan_op(.V2, src, c, OP)
	}
	if tier() == .V3 {
		return scan_v3(src, c, OP)
	}
	return scan_v2(src, c, OP)
}

@(private = "file", enable_target_feature = FEATURES[.V2])
scan_v2 :: #force_no_inline proc "contextless" (src: []u8, c: u8, $OP: Scan_Op) -> int {
	return scan_op(.V2, src, c, OP)
}

@(private = "file", enable_target_feature = FEATURES[.V3])
scan_v3 :: #force_no_inline proc "contextless" (src: []u8, c: u8, $OP: Scan_Op) -> int {
	return scan_op(.V3, src, c, OP)
}

// `set_loop` built for the CPU's tier, as `scan` is (including the x86-64-v2 floor assumption on the `< 64`-byte path).
@(private, require_results)
find_set :: #force_inline proc "contextless" (src: []u8, t: Byte_Set) -> int {
	if len(src) < 64 {
		return set_loop(.V2, src, t)
	}
	if tier() == .V3 {
		return set_v3(src, t)
	}
	return set_v2(src, t)
}

@(private = "file", enable_target_feature = FEATURES[.V2])
set_v2 :: #force_no_inline proc "contextless" (src: []u8, t: Byte_Set) -> int {
	return set_loop(.V2, src, t)
}

@(private = "file", enable_target_feature = FEATURES[.V3])
set_v3 :: #force_no_inline proc "contextless" (src: []u8, t: Byte_Set) -> int {
	return set_loop(.V3, src, t)
}
