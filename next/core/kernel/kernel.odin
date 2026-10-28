package kernel

import "base:intrinsics"

// Format-neutral kernels on 64-byte blocks: loading a block, reading the last partial block of an input in place,
// comparing bytes, sorting bytes into sets, packing per-byte masks into one bit per byte, and following quoted strings
// across blocks. A `Block` holds 64 input bytes, or the 64 lane masks (0x00 or 0xFF) made from them. Its layout
// belongs to the architecture (arm64.odin, lanes64.odin).

// The last partial block of an input. Lane j of `block` holds the input byte at `lo + j - shift`. Lanes outside the
// input hold whatever memory is there, so a mask packed from `block` goes through `align` before anything that
// carries state from block to block reads it.
Tail :: struct {
	block: Block,
	shift: u64,
	live:  u64,
}

// The bytes of `src` from `lo` to its end, fewer than 64, read in place: `lo < len(src) < lo + 64`. A 64-byte load
// from `lo` stays in one 4 KiB page unless `lo` lies in the page's last 63 bytes. Then the input itself reaches the
// next page, and the load that ends where the input ends, which starts in `lo`'s page, is taken instead. Either load
// may read bytes around `src`, never a page that `src` does not touch. 4 KiB is the smallest page of any target.
// Out of line: inlined where the compiler sees how large `src`'s allocation is, a load past its end is undefined, and
// LLVM drops the writes that filled it. The load is written here, not through `load`, so that ASan skips it at every
// optimization level.
@(no_sanitize_address)
load_tail :: #force_no_inline proc "contextless" (src: []u8, lo: int) -> (t: Tail) {
	rem := len(src) - lo
	when ODIN_DEBUG {
		assert_contextless(0 < rem && rem < 64)
	}
	p := raw_data(src)[lo:]
	t.live = u64(1) << u64(rem) - 1
	if uintptr(p) & 4095 > 4096 - 64 {
		t.shift = u64(64 - rem)
		p = intrinsics.ptr_offset(p, -int(t.shift))
	}
	// A vector load: Odin lowers an array load to a `memcpy` at -o:none, which ASan checks.
	when intrinsics.type_is_simd_vector(Block) {
		t.block = intrinsics.unaligned_load((^Block)(p))
	} else {
		t.block = transmute(Block)intrinsics.unaligned_load((^#simd[64]u8)(p))
	}
	return
}

// A mask packed from `t.block`, one bit per input byte from `lo`, the bits past the input cleared.
align :: #force_inline proc "contextless" (m: u64, t: Tail) -> u64 {
	return m >> t.shift & t.live
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

// Bit i set where an odd number of the bits of `x` at or below i are set. With the quotes of a block in `x`, these
// are the bytes from each opening quote up to its closing quote, the closing quote excluded.
prefix_xor :: #force_inline proc "contextless" (x: u64) -> u64 {
	x := x
	x ~= x << 1
	x ~= x << 2
	x ~= x << 4
	x ~= x << 8
	x ~= x << 16
	x ~= x << 32
	return x
}

// Where the previous block left its strings: `inside` is all ones when it ended inside a string, `odd_escape` is 1
// when it ended in an odd run of escape bytes, which escapes the first byte of the next block.
String_State :: struct {
	inside:     u64,
	odd_escape: u64,
}

// The quotes of a block that no escape byte escapes, and its bytes inside a string, from its quote and escape bytes,
// carrying `s` to the next block. An escape byte escapes the byte after it unless it is escaped itself. Blocks
// without escape bytes are the common case and skip the escape arithmetic.
string_region :: #force_inline proc "contextless" (quote, escape: u64, s: ^String_State) -> (quotes, inside: u64) {
	quotes = quote
	if escape != 0 || s.odd_escape != 0 {
		quotes &~= escaped(escape, &s.odd_escape)
	}
	inside = prefix_xor(quotes) ~ s.inside
	s.inside = u64(i64(inside) >> 63)
	return
}

// The bytes after an odd run of escape bytes. Adding a run's first bit to the escapes clears the run and sets the
// bit after it, which lies an odd distance from the first bit when the run has odd length: an odd bit after a run
// that starts on an even bit, an even bit after one that starts on an odd bit. A run that reaches the end of the
// block has odd length only when it starts on an odd bit, so the carry out of that add is the next block's `odd`.
// With `odd` set, bit 0 continues the previous run: it counts as an odd start, and is escaped when not an escape.
@(private = "file")
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
