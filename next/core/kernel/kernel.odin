package kernel

import "base:intrinsics"
import "core:simd"

// Format-neutral kernels on 64-byte blocks: loading a block, reading the last partial block of an input in place,
// comparing bytes, sorting bytes into sets, packing per-byte masks into one bit per byte, following quoted strings
// and runs of bytes across blocks, listing the positions in a mask, and validating UTF-8 (utf8.odin). The operations
// are per architecture (arm64.odin, lanes64.odin). Kernels whose instructions differ by CPU take a `Tier` as `$T`
// (amd64.odin, single_tier.odin).

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

// The last partial block of an input. Lane j of `block` holds the input byte at `lo + j - shift`. Lanes outside the
// input hold whatever memory is there, so a mask packed from `block` goes through `align` before anything that
// carries state from block to block reads it.
Tail :: struct {
	block: Block,
	shift: u64,
	live:  u64,
}

// `load_tail` without a masked load: `lo < len(src) < lo + 64`. A 64-byte load
// from `lo` stays in one 4 KiB page unless `lo` lies in the page's last 63 bytes. Then the input itself reaches the
// next page, and the load that ends where the input ends, which starts in `lo`'s page, is taken instead. Either load
// may read bytes around `src`, never a page that `src` does not touch. 4 KiB is the smallest page of any target.
// Out of line: inlined where the compiler sees how large `src`'s allocation is, a load past its end is undefined, and
// LLVM drops the writes that filled it. A tier with wider registers than the build's CPU reads its own copy
// (`paged_tail_v3`), whose result the caller reloads as it was stored: a 32-byte load of a block stored 16 bytes at a
// time waits for both stores to reach the cache.
@(private, no_sanitize_address)
paged_tail :: #force_no_inline proc "contextless" (src: []u8, lo: int) -> Tail {
	return read_paged_tail(src, lo)
}

// The load is written here, not through `load`, so that ASan skips it at every optimization level.
@(private, no_sanitize_address)
read_paged_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> (t: Tail) {
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
	// A vector load: Odin lowers an array load to a `memcpy` at -o:none, which ASan checks. Loaded into a variable
	// first: Odin folds a `transmute` of the load into a load of `Block` at its own 16-byte alignment.
	v := intrinsics.unaligned_load((^#simd[64]u8)(p))
	t.block = transmute(Block)v
	return
}

// `load_padded` without a masked load: a copy.
@(private)
copied_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> Block {
	buf: [64]u8
	intrinsics.mem_copy_non_overlapping(&buf, raw_data(src[lo:]), len(src) - lo)
	return load(raw_data(buf[:]))
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

// Where the previous block left its strings: `inside` is all ones when it ended inside a string, `odd_escape` is 1
// when it ended in an odd run of escape bytes, which escapes the first byte of the next block.
String_State :: struct {
	inside:     u64,
	odd_escape: u64,
}

// The quotes of a block that no escape byte escapes, and its bytes inside a string, from its quote and escape bytes,
// carrying `s` to the next block. An escape byte escapes the byte after it unless it is escaped itself. Blocks
// without escape bytes are the common case and skip the escape arithmetic.
string_region :: #force_inline proc "contextless" ($T: Tier, quote, escape: u64, s: ^String_State) -> (quotes, inside: u64) {
	quotes = quote
	if escape != 0 || s.odd_escape != 0 {
		quotes &~= escaped(escape, &s.odd_escape)
	}
	inside = prefix_xor(T, quotes) ~ s.inside
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

// The bytes of the runs in `runs` that start at a bit of `starts`, and of the run that `carry` (0 or 1) says goes on
// from the block before, carrying to the next block whether such a run reaches the end of this one. `starts` holds
// only first bits of runs. Adding a run's first bit carries through the run, so the bits the sum clears are the run.
run_bytes :: #force_inline proc "contextless" (runs, starts: u64, carry: ^u64) -> u64 {
	sum, out := intrinsics.overflow_add(runs, starts | carry^)
	carry^ = u64(out)
	return (sum ~ runs) & runs
}

// `flatten` writes positions in steps of this many slots, the first step whatever the count, so that its branch is
// taken alike at sparse and dense rates: a mask with few bits pays for a step's slots, one with many saves the
// mispredicted exit of a loop per bit. The slots after the last position take junk: `out` holds this many past it.
FLATTEN_STEP :: 12
