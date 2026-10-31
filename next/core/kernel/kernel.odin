package kernel

import "base:intrinsics"
import "core:simd"

// Format-neutral kernels that work on 64-byte blocks: load a block, load the last partial block padded with zeros,
// compare bytes, sort bytes into sets, pack per-byte masks to one bit per byte, find the bytes an escape escapes,
// find the first set lane of a 16-byte mask, and validate UTF-8 (utf8.odin). arm64.odin and lanes64.odin hold the
// per-architecture operations. Kernels whose instructions differ by CPU take a `Tier` as `$T` (amd64.odin,
// single_tier.odin).

// 64 input bytes, or the 64 lane masks (0x00 or 0xFF) made from them, as four 16-byte vectors. lanes64.odin
// reinterprets it as one 64-lane vector. It is an array so that a block crosses a call between procedures built for
// different x86 tiers in the same registers on both sides, since a 64-lane vector returns in one register from an
// AVX-512 procedure and in four from an SSE one.
Block :: [4]#simd[16]u8

// A block's vector registers on NEON and SSE, and the whole block as one vector.
@(private)
V :: #simd[16]u8
@(private)
W :: #simd[64]u8

// Returns the bytes of `src` from `lo` to `len(src)` copied into a zeroed 64-byte buffer and loaded as a `Block`.
// `load_padded` uses it where no masked load exists.
@(private)
copied_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, raw_data(src[lo:]), len(src) - lo)
	return load(raw_data(buf[:]))
}

// Two 16-byte tables that sort bytes into up to 8 sets. Byte `b` is in set k when `lo[b & 15] & hi[b >> 4]` shares a
// bit with `bits[k]`, as `nibble_table` returns them. Each pair of a set and a high nibble owns one bit, so
// membership is exact while the sets have at most 8 such pairs between them.
Nibble_Table :: struct {
	lo, hi: #simd[16]u8,
}

nibble_table :: proc(sets: []string) -> (t: Nibble_Table, bits: [8]u8) {
	assert(len(sets) <= 8, "more than eight sets")
	lo, hi: [16]u8
	next: uint
	for set, k in sets {
		pair: [16]u8
		for c in transmute([]u8)set {
			h := c >> 4
			if pair[h] == 0 {
				assert(next < 8, "more than eight pairs of a set and a high nibble")
				pair[h] = 1 << next
				next += 1
			}
			hi[h] |= pair[h]
			lo[c & 15] |= pair[h]
			bits[k] |= pair[h]
		}
	}
	return {transmute(#simd[16]u8)lo, transmute(#simd[16]u8)hi}, bits
}

// Returns, for each byte of `b`, the class bits its two nibbles give from `t`. Looks up both nibbles one vector
// register at a time.
classes :: #force_inline proc "contextless" ($T: Tier, b: Block, t: Nibble_Table) -> Block #no_bounds_check {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	c: [64 / N]U
	#unroll for i in 0 ..< 64 / N {
		c[i] = simd.bit_and(lookup(T, t.lo, simd.bit_and(w[i], U(0x0f))), lookup(T, t.hi, simd.shr(w[i], U(4))))
	}
	return transmute(Block)c
}

// Returns a mask of the bytes after an odd run of escape bytes. Adding a run's first bit to the escapes clears the
// run and sets the bit after it, an odd distance from the first bit when the run is odd: an odd bit after a run
// starting on an even bit, an even bit after a run starting on an odd bit. A run reaching the end of the block is odd
// only when it starts on an odd bit, so the carry out of that add becomes the next block's `odd`. When `*odd` is
// set, bit 0 continues the previous run, counts as an odd start and is treated as escaped if it is not an escape. On
// return `*odd` says whether this block ends in a run of odd length.
escaped :: #force_inline proc "contextless" (escape: u64, odd: ^u64) -> u64 {
	EVEN :: u64(0x5555_5555_5555_5555)
	starts := escape &~ (escape << 1)
	even_starts_mask := EVEN ~ odd^
	even_carries := escape + (starts & even_starts_mask)
	odd_carries, overflow := intrinsics.overflow_add(escape, starts &~ even_starts_mask)
	odd_carries |= odd^
	odd^ = u64(overflow)
	return (even_carries &~ escape & ~EVEN) | (odd_carries &~ escape & EVEN)
}
