package kernel

import "base:intrinsics"
import "core:simd"

// Format-neutral SIMD operations for every format's walk and bulk loops: 64-byte blocks, their lane masks packed to
// `u64`, and scans over whole texts. Walks use the 16-byte operations on every target. On x86 only the bulk loops
// (string spans and whole-text scans) pick a wider tier.

// 64 bytes, or the 64 lane masks (0x00 or 0xFF) made from them. An array of 16-byte vectors, so a block crosses a call
// between procedures of different tiers in the same registers.
Block :: [4]#simd[16]u8

@(private)
V :: #simd[16]u8
@(private)
W :: #simd[64]u8
@(private)
IS_WASM :: ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32

// 0xFF in each lane where `b`'s byte is below `c`.
@(require_results)
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	// Per register on WebAssembly so LLVM folds `i8x16.lt_u` straight into `pack`'s `i8x16.bitmask` without `i8x16.lt_s`.
	when IS_WASM {
		k := V(c)
		return {simd.lanes_lt(b[0], k), simd.lanes_lt(b[1], k), simd.lanes_lt(b[2], k), simd.lanes_lt(b[3], k)}
	} else {
		return transmute(Block)simd.lanes_lt(transmute(W)b, W(c))
	}
}

@(require_results)
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return transmute(Block)simd.bit_or(transmute(W)a, transmute(W)b)
}

// Whether any lane mask of `m` (each lane 0x00 or 0xFF, tested by its top bit) is set.
@(require_results)
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return !is_ascii(m)
}

@(require_results)
any_lane16 :: #force_inline proc "contextless" (m: V) -> bool {
	return !is_ascii16(m)
}

// A load at `64 - n` gives the mask of the first `n` lanes.
@(private, rodata)
LIVE_LANES := [128]u8{0 ..< 64 = 0xFF, 64 ..< 128 = 0}

// The mask of the first `n` lanes, for `0 <= n <= 16`. `#no_bounds_check` relies on `64 - n` staying within
// `LIVE_LANES`.
@(require_results)
live16 :: #force_inline proc "contextless" (n: int) -> V #no_bounds_check {
	return load16(raw_data(LIVE_LANES[64 - n:]))
}

// Whether `size` bytes at `p` may be read past the end of the slice they start: `p[0]` is readable, the read stays in
// `p`'s 4096-byte page, `p` is not nil, and no sanitizer is enabled.
@(private, require_results)
over_read :: #force_inline proc "contextless" (p: [^]u8, $size: uintptr) -> bool where size > 0, size <= 4096 {
	when ODIN_SANITIZER_FLAGS != {} {
		return false
	} else {
		return p != nil && uintptr(p) & 4095 <= 4096 - size
	}
}

// The 16 bytes at `src` in one load, with the mask of its first `n` lanes, for `0 < n < 16` and at least `n` readable
// bytes at `src`. Lanes past `n` hold whatever follows in the page. `ok` is false where `over_read` refuses.
@(require_results)
head16 :: #force_inline proc "contextless" (src: [^]u8, n: int) -> (v, live: V, ok: bool) {
	if !over_read(src, 16) {
		return
	}
	return load16(src), live16(n), true
}

// `src[lo:]` zero-padded to a block, for `0 <= lo < len(src)` and `len(src) - lo < 64`: one load masked to its live
// lanes where `over_read` allows, else a copy into a zeroed buffer. `#no_bounds_check` relies on those bounds so
// `raw_data(src)[lo:]` is in bounds and `64 - n` stays within `LIVE_LANES`.
@(require_results)
load_padded :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block #no_bounds_check {
	n := len(src) - lo
	p := raw_data(src)[lo:]
	if over_read(p, 64) {
		return transmute(Block)simd.bit_and(transmute(W)load(p), transmute(W)load(raw_data(LIVE_LANES[64 - n:])))
	}
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, p, n)
	return load(raw_data(buf[:]))
}

// Loads 16 unaligned bytes from `p`. The caller guarantees 16 readable bytes at `p`.
@(require_results)
load16 :: #force_inline proc "contextless" (p: [^]u8) -> V {
	return intrinsics.unaligned_load((^V)(p))
}

// Loads 8 unaligned bytes from `p` as a little-endian word. The caller guarantees 8 readable bytes at `p`.
@(require_results)
load8 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return u64(intrinsics.unaligned_load((^u64le)(p)))
}

// Stores 16 unaligned bytes to `p`. The caller guarantees 16 writable bytes at `p`.
store16 :: #force_inline proc "contextless" (p: [^]u8, v: V) {
	intrinsics.unaligned_store((^V)(p), v)
}

// The lanes of `v` holding a control byte or a byte past 0x7F, and DEL too when `del`.
@(require_results)
control_or_high16 :: #force_inline proc "contextless" (v: V, $del: bool) -> V {
	I :: #simd[16]i8
	when del {
		return simd.lanes_lt(transmute(I)(v + 1), I(0x21))
	} else {
		return simd.lanes_lt(transmute(I)v, I(0x20))
	}
}

// The 64 bytes of `src` from `lo`, zero-padded past its end, for `0 <= lo < len(src)`. Both loads go through one
// 64-lane vector, since x86 and WebAssembly otherwise merge two blocks through extra registers or spills.
@(require_results)
load_block :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	w := transmute(W)load(raw_data(src)[lo:]) if len(src) - lo >= 64 else transmute(W)load_padded(src, lo)
	return transmute(Block)w
}
