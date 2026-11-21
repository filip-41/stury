package kernel

import "base:intrinsics"
import "core:simd"

// Kernels are the format-neutral SIMD pieces every format's walk and bulk loops build on: 64-byte blocks, their lane
// masks packed to `u64`, and scans over whole texts. Walks use the 16-byte operations on every target; on x86 only the bulk
// loops, string spans and whole-text scans, pick a wider tier.

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

// A load at `64 - n` gives the mask of the first `n` lanes.
@(private, rodata)
LIVE_LANES := [128]u8{0 ..< 64 = 0xFF, 64 ..< 128 = 0}

// The mask of the first `n` lanes, for `n` up to 16.
live16 :: #force_inline proc "contextless" (n: int) -> V #no_bounds_check {
	return load16(raw_data(LIVE_LANES[64 - n:]))
}

// Whether `size` bytes at `p` may be read past the end of the slice they start: they stay in `p`'s 4096-byte page,
// `p` is not nil, and no sanitizer watches the bytes past the end. The `- 1` makes a nil `p` wrap, so one test refuses
// both, and a page-aligned `p` too.
@(private)
over_read :: #force_inline proc "contextless" (p: [^]u8, $size: uintptr) -> bool {
	when ODIN_SANITIZER_FLAGS & {.Address, .Thread} != {} {
		return false
	} else {
		return (uintptr(p) - 1) & 4095 < 4096 - size
	}
}

// The 16 bytes at `src` in one load, with the mask of its first `n` lanes, for `n` below 16. Lanes past `n` hold
// whatever follows in the page. `ok` is false where `over_read` refuses.
head16 :: #force_inline proc "contextless" (src: [^]u8, n: int) -> (v, live: V, ok: bool) {
	if !over_read(src, 16) {
		return
	}
	return load16(src), live16(n), true
}

// `src[lo:]` zero-padded to a block, for `0 < len(src) - lo < 64`: one load masked to its live lanes where `over_read`
// allows, else a copy into a zeroed buffer.
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
	w := transmute(W)load(raw_data(src)[lo:]) if len(src) - lo >= 64 else transmute(W)load_padded(src, lo)
	return transmute(Block)w
}
