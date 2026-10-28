package kernel

// Format-neutral kernels on 64-byte blocks: loading a block, reading the last partial block of an input in place,
// comparing bytes, sorting bytes into sets, and packing per-byte masks into one bit per byte. A `Block` holds 64 input bytes, or the 64 lane
// masks (0x00 or 0xFF) made from them. Its layout belongs to the architecture (arm64.odin, lanes64.odin).

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
@(no_sanitize_address)
load_tail :: #force_inline proc "contextless" (src: []u8, lo: int) -> (t: Tail) {
	rem := len(src) - lo
	p := uintptr(raw_data(src)) + uintptr(lo)
	t.live = u64(1) << u64(rem) - 1
	if p & 4095 <= 4096 - 64 {
		t.block = load(([^]u8)(p))
	} else {
		t.shift = u64(64 - rem)
		t.block = load(([^]u8)(p - uintptr(t.shift)))
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
