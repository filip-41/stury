package kernel

import "base:intrinsics"
import "core:simd"

// Format-neutral kernels on 64-byte blocks. This file holds the block and the operations every target shares.

// 64 input bytes, or the 64 lane masks (0x00 or 0xFF) made from them, as four 16-byte vectors. The block operations
// reinterpret it as one 64-lane vector. It is an array so that a block crosses a call between procedures built for
// different x86 tiers in the same registers on both sides, since a 64-lane vector returns in one register from an
// AVX-512 procedure and in four from an SSE one.
Block :: [4]#simd[16]u8

// A block's vector registers on NEON and SSE, and the whole block as one vector.
@(private)
V :: #simd[16]u8
@(private)
W :: #simd[64]u8

// The operations below compile on NEON one register at a time, since LLVM splits a 64-lane vector to the target's
// width.

// Returns a mask with 0xFF in each lane where `b`'s byte is below `c`.
below :: #force_inline proc "contextless" (b: Block, c: u8) -> Block {
	return transmute(Block)simd.lanes_lt(transmute(W)b, W(c))
}

// Returns `a` OR `b` lane by lane, 0xFF where either mask is set.
either :: #force_inline proc "contextless" (a, b: Block) -> Block {
	return transmute(Block)simd.bit_or(transmute(W)a, transmute(W)b)
}

// Reports whether any lane mask in `m` is set. A lane mask is set exactly when its top bit is.
any_lane :: #force_inline proc "contextless" (m: Block) -> bool {
	return !is_ascii(m)
}

// Reports whether any lane of the 16-lane mask `m` is set.
any_lane16 :: #force_inline proc "contextless" (m: V) -> bool {
	return !is_ascii16(m)
}

// The mask a load at `16 - n` gives: `n` lanes of 0xFF, then zeros.
@(private, rodata)
LIVE_LANES := [32]u8{0 ..< 16 = 0xFF, 16 ..< 32 = 0}

// Returns the mask of the first `n` lanes, for `n` up to 16: 0xFF in those and zeros in the rest.
live16 :: #force_inline proc "contextless" (n: int) -> V #no_bounds_check {
	return load16(raw_data(LIVE_LANES[16 - n:]))
}

// Loads the 16 bytes at `src` in one instruction, with the mask of its first `n` lanes, for `n` below 16. The lanes
// past `n` hold whatever follows `src` in its page. `ok` is false for a nil `src`, under the address sanitizer, and
// when the 16 bytes could cross a 4096-byte page.
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

// Returns the bytes of `src` from `lo` to `len(src)` copied into a zeroed 64-byte buffer and loaded as a `Block`.
// `load_padded` uses it where no masked load exists.
@(private)
copied_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, raw_data(src[lo:]), len(src) - lo)
	return load(raw_data(buf[:]))
}

// Loads the 16 bytes at `p`, which need no alignment.
load16 :: #force_inline proc "contextless" (p: [^]u8) -> V {
	return intrinsics.unaligned_load((^V)(p))
}

// Stores `v` as the 16 bytes at `p`, which need no alignment.
store16 :: #force_inline proc "contextless" (p: [^]u8, v: V) {
	intrinsics.unaligned_store((^V)(p), v)
}

// Returns the lanes of `v` that hold a control byte or a byte past 0x7F, and a DEL too when `del`.
control_or_high16 :: #force_inline proc "contextless" (v: V, $del: bool) -> V {
	return simd.lanes_gt(v - 0x20, V(0x5e if del else 0x5f))
}

// Returns the 64 bytes of `src` from `lo`, padded with zeros past its end, for `lo` below `len(src)`. The two loads
// merge as one 64-lane vector, since x86 merges two `Block`s through general-purpose registers.
load_block :: #force_inline proc "contextless" ($T: Tier, src: []u8, lo: int) -> Block {
	w := transmute(W)load(raw_data(src)[lo:]) if len(src) - lo >= 64 else transmute(W)load_padded(T, src, lo)
	return transmute(Block)w
}
