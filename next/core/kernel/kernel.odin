package kernel

import "base:intrinsics"
import "core:simd"

// Format-neutral kernels on 64-byte blocks: loading a block, and the last partial block of an input padded with zeros,
// comparing bytes, sorting bytes into sets, packing per-byte masks into one bit per byte, finding the bytes an escape
// escapes, finding the first lane of a 16-byte mask, and validating UTF-8 (utf8.odin). The operations are per architecture (arm64.odin, lanes64.odin). Kernels whose
// instructions differ by CPU take a `Tier` as `$T` (amd64.odin, single_tier.odin).

// 64 input bytes, or the 64 lane masks (0x00 or 0xFF) made from them, as four 16-byte vectors. Kernels that work
// on all 64 lanes at once reinterpret it as one 64-lane vector (lanes64.odin). An array, so that a block crosses a
// call between procedures compiled for different x86 tiers in the same registers on both sides: a 64-lane vector
// is returned in one register by an AVX-512 procedure and in four by an SSE one.
Block :: [4]#simd[16]u8

// A block's vector registers on NEON and SSE, and the whole block as one vector.
@(private)
V :: #simd[16]u8
@(private)
W :: #simd[64]u8

// `load_padded` without a masked load: a copy.
@(private)
copied_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, raw_data(src[lo:]), len(src) - lo)
	return load(raw_data(buf[:]))
}

// A table that sorts bytes into up to eight sets: byte `b` is in set k when `lo[b & 15] & hi[b >> 4]` shares a bit
// with `bits[k]`, as `nibble_table` returns it. Each pair of a set and a high nibble owns one bit, so membership is
// exact while the sets have at most eight such pairs between them.
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

// The set bits of every byte of `b`, from the table: `t` looks up both nibbles, one vector register at a time.
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

// The bytes after an odd run of escape bytes. Adding a run's first bit to the escapes clears the run and sets the
// bit after it, which lies an odd distance from the first bit when the run has odd length: an odd bit after a run
// that starts on an even bit, an even bit after one that starts on an odd bit. A run that reaches the end of the
// block has odd length only when it starts on an odd bit, so the carry out of that add is the next block's `odd`.
// With `odd` set, bit 0 continues the previous run: it counts as an odd start, and is escaped when not an escape.
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
