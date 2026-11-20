package kernel

import "base:intrinsics"
import "core:simd"

// Kernels are the format-neutral SIMD pieces every format's walk and bulk loops build on: 64-byte blocks, their lane
// masks packed to `u64`, and scans over whole texts. Walks use the 16-byte operations on every target; only bulk loops
// pick a wider x86 tier.

// 64 bytes, or the 64 lane masks (0x00 or 0xFF) made from them. An array of 16-byte vectors, so a block crosses a call
// between procedures of different tiers in the same registers.
Block :: [4]#simd[16]u8

@(private)
V :: #simd[16]u8
@(private)
W :: #simd[64]u8

// 0xFF in each lane where `b`'s byte is below `c`.
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_lt(transmute(W)b, W(c))
}

either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return transmute(Block)simd.bit_or(transmute(W)a, transmute(W)b)
}

// Whether any lane mask of `m` is set. A lane mask is set exactly when its top bit is.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return !is_ascii(m)
}

any_lane16 :: #force_inline proc "contextless" (m: V) -> bool {
	return !is_ascii16(m)
}

// A load at `16 - n` gives the mask of the first `n` lanes.
@(private, rodata)
LIVE_LANES := [32]u8{0 ..< 16 = 0xFF, 16 ..< 32 = 0}

// The mask of the first `n` lanes, for `n` up to 16.
live16 :: #force_inline proc "contextless" (n: int) -> V #no_bounds_check {
	return load16(raw_data(LIVE_LANES[16 - n:]))
}

// The 16 bytes at `src` in one load, with the mask of its first `n` lanes, for `n` below 16. Lanes past `n` hold
// whatever follows in the page. `ok` is false for a nil `src`, under the address sanitizer, and where the load could
// cross a 4096-byte page; the `- 1` makes a nil `src` wrap, so one test refuses both, and a page-aligned `src` too.
head16 :: #force_inline proc "contextless" (src: [^]u8, n: int) -> (v, live: V, ok: bool) {
	when .Address in ODIN_SANITIZER_FLAGS {
		return
	} else {
		if (uintptr(src) - 1) & 4095 >= 4080 {
			return
		}
		return load16(src), live16(n), true
	}
}

// `src[lo:]` copied into a zeroed 64-byte buffer and loaded as a block.
@(private)
copied_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, raw_data(src[lo:]), len(src) - lo)
	return load(raw_data(buf[:]))
}

load16 :: #force_inline proc "contextless" (p: [^]u8) -> V {
	return intrinsics.unaligned_load((^V)(p))
}

store16 :: #force_inline proc "contextless" (p: [^]u8, v: V) {
	intrinsics.unaligned_store((^V)(p), v)
}

// The lanes of `v` holding a control byte or a byte past 0x7F, and DEL too when `del`.
control_or_high16 :: #force_inline proc "contextless" (v: V, $del: bool) -> V {
	return simd.lanes_gt(v - 0x20, V(0x5e if del else 0x5f))
}

// The 64 bytes of `src` from `lo`, zero-padded past its end, for `lo` below `len(src)`. Both loads go through one
// 64-lane vector, since x86 merges two blocks through general registers.
load_block :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	w := transmute(W)load(raw_data(src)[lo:]) if len(src) - lo >= 64 else transmute(W)load_padded(T, src, lo)
	return transmute(Block)w
}
