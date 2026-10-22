package encode

// Byte-level minification of a validated JSON span (`minify_span`, `minify_dense`, `copy_unblank`).

import "base:intrinsics"
import "core:simd"
import idx "../scan/index"

// Bytes `minify_dense` may store past its end: a block's worth.
MINIFY_SLACK :: 64

// For each 8-bit keep mask, the lanes it keeps in order, one index per byte, low byte first.
@(private, rodata)
KEEP_LANES: [256]u64 = {
	0x0000000000000000, 0x0000000000000000, 0x0000000000000001, 0x0000000000000100,
	0x0000000000000002, 0x0000000000000200, 0x0000000000000201, 0x0000000000020100,
	0x0000000000000003, 0x0000000000000300, 0x0000000000000301, 0x0000000000030100,
	0x0000000000000302, 0x0000000000030200, 0x0000000000030201, 0x0000000003020100,
	0x0000000000000004, 0x0000000000000400, 0x0000000000000401, 0x0000000000040100,
	0x0000000000000402, 0x0000000000040200, 0x0000000000040201, 0x0000000004020100,
	0x0000000000000403, 0x0000000000040300, 0x0000000000040301, 0x0000000004030100,
	0x0000000000040302, 0x0000000004030200, 0x0000000004030201, 0x0000000403020100,
	0x0000000000000005, 0x0000000000000500, 0x0000000000000501, 0x0000000000050100,
	0x0000000000000502, 0x0000000000050200, 0x0000000000050201, 0x0000000005020100,
	0x0000000000000503, 0x0000000000050300, 0x0000000000050301, 0x0000000005030100,
	0x0000000000050302, 0x0000000005030200, 0x0000000005030201, 0x0000000503020100,
	0x0000000000000504, 0x0000000000050400, 0x0000000000050401, 0x0000000005040100,
	0x0000000000050402, 0x0000000005040200, 0x0000000005040201, 0x0000000504020100,
	0x0000000000050403, 0x0000000005040300, 0x0000000005040301, 0x0000000504030100,
	0x0000000005040302, 0x0000000504030200, 0x0000000504030201, 0x0000050403020100,
	0x0000000000000006, 0x0000000000000600, 0x0000000000000601, 0x0000000000060100,
	0x0000000000000602, 0x0000000000060200, 0x0000000000060201, 0x0000000006020100,
	0x0000000000000603, 0x0000000000060300, 0x0000000000060301, 0x0000000006030100,
	0x0000000000060302, 0x0000000006030200, 0x0000000006030201, 0x0000000603020100,
	0x0000000000000604, 0x0000000000060400, 0x0000000000060401, 0x0000000006040100,
	0x0000000000060402, 0x0000000006040200, 0x0000000006040201, 0x0000000604020100,
	0x0000000000060403, 0x0000000006040300, 0x0000000006040301, 0x0000000604030100,
	0x0000000006040302, 0x0000000604030200, 0x0000000604030201, 0x0000060403020100,
	0x0000000000000605, 0x0000000000060500, 0x0000000000060501, 0x0000000006050100,
	0x0000000000060502, 0x0000000006050200, 0x0000000006050201, 0x0000000605020100,
	0x0000000000060503, 0x0000000006050300, 0x0000000006050301, 0x0000000605030100,
	0x0000000006050302, 0x0000000605030200, 0x0000000605030201, 0x0000060503020100,
	0x0000000000060504, 0x0000000006050400, 0x0000000006050401, 0x0000000605040100,
	0x0000000006050402, 0x0000000605040200, 0x0000000605040201, 0x0000060504020100,
	0x0000000006050403, 0x0000000605040300, 0x0000000605040301, 0x0000060504030100,
	0x0000000605040302, 0x0000060504030200, 0x0000060504030201, 0x0006050403020100,
	0x0000000000000007, 0x0000000000000700, 0x0000000000000701, 0x0000000000070100,
	0x0000000000000702, 0x0000000000070200, 0x0000000000070201, 0x0000000007020100,
	0x0000000000000703, 0x0000000000070300, 0x0000000000070301, 0x0000000007030100,
	0x0000000000070302, 0x0000000007030200, 0x0000000007030201, 0x0000000703020100,
	0x0000000000000704, 0x0000000000070400, 0x0000000000070401, 0x0000000007040100,
	0x0000000000070402, 0x0000000007040200, 0x0000000007040201, 0x0000000704020100,
	0x0000000000070403, 0x0000000007040300, 0x0000000007040301, 0x0000000704030100,
	0x0000000007040302, 0x0000000704030200, 0x0000000704030201, 0x0000070403020100,
	0x0000000000000705, 0x0000000000070500, 0x0000000000070501, 0x0000000007050100,
	0x0000000000070502, 0x0000000007050200, 0x0000000007050201, 0x0000000705020100,
	0x0000000000070503, 0x0000000007050300, 0x0000000007050301, 0x0000000705030100,
	0x0000000007050302, 0x0000000705030200, 0x0000000705030201, 0x0000070503020100,
	0x0000000000070504, 0x0000000007050400, 0x0000000007050401, 0x0000000705040100,
	0x0000000007050402, 0x0000000705040200, 0x0000000705040201, 0x0000070504020100,
	0x0000000007050403, 0x0000000705040300, 0x0000000705040301, 0x0000070504030100,
	0x0000000705040302, 0x0000070504030200, 0x0000070504030201, 0x0007050403020100,
	0x0000000000000706, 0x0000000000070600, 0x0000000000070601, 0x0000000007060100,
	0x0000000000070602, 0x0000000007060200, 0x0000000007060201, 0x0000000706020100,
	0x0000000000070603, 0x0000000007060300, 0x0000000007060301, 0x0000000706030100,
	0x0000000007060302, 0x0000000706030200, 0x0000000706030201, 0x0000070603020100,
	0x0000000000070604, 0x0000000007060400, 0x0000000007060401, 0x0000000706040100,
	0x0000000007060402, 0x0000000706040200, 0x0000000706040201, 0x0000070604020100,
	0x0000000007060403, 0x0000000706040300, 0x0000000706040301, 0x0000070604030100,
	0x0000000706040302, 0x0000070604030200, 0x0000070604030201, 0x0007060403020100,
	0x0000000000070605, 0x0000000007060500, 0x0000000007060501, 0x0000000706050100,
	0x0000000007060502, 0x0000000706050200, 0x0000000706050201, 0x0000070605020100,
	0x0000000007060503, 0x0000000706050300, 0x0000000706050301, 0x0000070605030100,
	0x0000000706050302, 0x0000070605030200, 0x0000070605030201, 0x0007060503020100,
	0x0000000007060504, 0x0000000706050400, 0x0000000706050401, 0x0000070605040100,
	0x0000000706050402, 0x0000070605040200, 0x0000070605040201, 0x0007060504020100,
	0x0000000706050403, 0x0000070605040300, 0x0000070605040301, 0x0007060504030100,
	0x0000070605040302, 0x0007060504030200, 0x0007060504030201, 0x0706050403020100,
}

// Where a minify walk stands between two pieces of one value. A piece other than the last is whole 64-byte
// blocks.
@(private)
Minify_State :: struct {
	in_string, prev_odd: u64,
}

// `span`, one strict JSON value or a piece of one that `state` carries on from, minus its whitespace outside
// strings, at `out`, which has room for `len(span) + MINIFY_SLACK` bytes. Returns the count written. A piece other
// than the last (`more`) is whole 64-byte blocks and goes to `minify_dense`, which leaves `state` for the next.
// The rest is copied where it holds no byte below 0x21, its string mask owed: `minify_dense` first makes up
// what is owed, and a last block with nothing to drop needs no mask at all.
minify_span :: proc(out: [^]u8, span: []byte, state: ^Minify_State, more: bool) -> int #no_bounds_check {
	if more {
		return minify_dense(out, span, state)
	}
	w, i, owed, dense := 0, 0, 0, DENSE_SPAN
	for i < len(span) {
		at := copy_unblank(out[w:], span[i:])
		i += at
		w += at
		if i >= len(span) {
			break
		}
		if tail := span[i:]; len(tail) < 64 && !has_blank(tail) {
			intrinsics.mem_copy_non_overlapping(&out[w], raw_data(tail), len(tail))
			return w + len(tail)
		}
		settle_strings(span[owed:i], &state.in_string, &state.prev_odd)
		// Dense stretches that find little clean after them grow, so that a document of blanks is walked in
		// few pieces.
		dense = DENSE_SPAN if at >= CLEAN_CHUNK else min(2 * dense, DENSE_MAX)
		step := min(dense, len(span) - i)
		w += minify_dense(&out[w], span[i:i + step], state)
		i += step
		owed = i
	}
	return w
}

// Bytes of `span` that `minify_span` hands `minify_dense` at a time before it looks for a clean stretch again,
// and the most a run of such pieces that find none grows to.
@(private = "file")
DENSE_SPAN :: 16384
@(private = "file")
DENSE_MAX :: 1 << 20

// Whether `bytes` holds a byte below 0x21.
@(private = "file")
has_blank :: proc(bytes: []byte) -> bool {
	for b in bytes {
		if b <= ' ' {
			return true
		}
	}
	return false
}

// `minify_span`'s walk over blocks that may hold whitespace: `span`, whole blocks but for the last, minus its
// whitespace outside strings, at `out`, which has room for `len(span) + MINIFY_SLACK` bytes. Returns the count written. Rows are not
// read: the string mask comes from the quotes no backslash escapes, as the scan's index finds it. Inside a
// string a byte below 0x21 can only be a space, which stays. It stays out of line: inlined, its size would
// move the loops of the row walks it sits beside.
minify_dense :: #force_no_inline proc(out: [^]u8, span: []byte, state: ^Minify_State) -> int #no_bounds_check {
	V :: #simd[16]u8
	SPACE :: V(0x20)
	in_string, prev_odd := state.in_string, state.prev_odd
	w := 0
	for i := 0; i < len(span); i += 64 {
		live := min(64, len(span) - i)
		p := raw_data(span[i:])
		// The last block is padded with spaces, which sit outside every string and so are dropped.
		pad: [4]V = ---
		if live < 64 {
			pad = {SPACE, SPACE, SPACE, SPACE}
			intrinsics.mem_copy_non_overlapping(&pad, p, live)
			p = ([^]u8)(&pad)
		}
		v := [4]V{idx.load(p), idx.load(p[16:]), idx.load(p[32:]), idx.load(p[48:])}
		quote, bs := idx.quotes_and_backslashes(v)
		_, instr := idx.string_region(quote, bs, &prev_odd, &in_string)
		blank := idx.pack4(simd.lanes_le(v[0], SPACE), simd.lanes_le(v[1], SPACE), simd.lanes_le(v[2], SPACE), simd.lanes_le(v[3], SPACE))
		drop := blank & ~instr
		if drop == 0 {
			intrinsics.unaligned_store((^[4]V)(&out[w]), v)
			w += live
			continue
		}
		w = keep_block(out, w, v, ~drop)
	}
	state^ = {in_string, prev_odd}
	return w
}

// The whole 64-byte blocks at the start of `span` up to the first that holds a byte below 0x21, copied to
// `out`. Returns their length. A run of CLEAN_CHUNK bytes with none is copied by `memcpy`, which stores faster than
// a loop of vector moves does.
@(private = "file")
copy_unblank :: proc(out: [^]u8, span: []byte) -> int #no_bounds_check {
	V :: #simd[16]u8
	i := 0
	for {
		if i + CLEAN_CHUNK <= len(span) && clean_block(span[i:]) {
			// A byte below 0x21 is looked for 512 bytes at a time, so a chunk that holds one is given up early.
			clean := true
			for j := i; clean && j < i + CLEAN_CHUNK; j += 512 {
				m := V(0xff)
				#unroll for k in 0 ..< 8 {
					v := intrinsics.unaligned_load((^[4]V)(&span[j + 64 * k]))
					m = simd.min(m, simd.min(simd.min(v[0], v[1]), simd.min(v[2], v[3])))
				}
				clean = simd.reduce_min(m) > ' '
			}
			if clean {
				intrinsics.mem_copy_non_overlapping(&out[i], &span[i], CLEAN_CHUNK)
				i += CLEAN_CHUNK
				continue
			}
		}
		for i + 64 <= len(span) && clean_block(span[i:]) {
			intrinsics.unaligned_store((^[4]V)(&out[i]), intrinsics.unaligned_load((^[4]V)(&span[i])))
			i += 64
		}
		return i
	}
}

// Whether the 64 bytes at the start of `span` hold no byte below 0x21.
@(private = "file")
clean_block :: #force_inline proc(span: []byte) -> bool #no_bounds_check {
	V :: #simd[16]u8
	v := intrinsics.unaligned_load((^[4]V)(&span[0]))
	return simd.reduce_min(simd.min(simd.min(v[0], v[1]), simd.min(v[2], v[3]))) > ' '
}

// Bytes `copy_unblank` hands to `memcpy` at a time.
@(private = "file")
CLEAN_CHUNK :: 4096

// The string mask's carries moved on over `blocks`, whole 64-byte blocks whose bytes were copied unread.
@(private = "file")
settle_strings :: #force_inline proc(blocks: []byte, in_string, prev_odd: ^u64) #no_bounds_check {
	for i := 0; i < len(blocks); i += 64 {
		p := raw_data(blocks[i:])
		quote, bs := idx.quotes_and_backslashes({idx.load(p), idx.load(p[16:]), idx.load(p[32:]), idx.load(p[48:])})
		idx.string_region(quote, bs, prev_odd, in_string)
	}
}

// The lanes of the four vectors that `keep` marks, in order, at `out[w:]`. Returns the new offset. Each group of
// eight lanes is one table shuffle half and one 8-byte store, so up to 64 bytes from `w` are written. One
// vector popcount counts all eight groups, and a multiply turns the counts into the running offsets.
@(private)
keep_block :: #force_inline proc "contextless" (out: [^]u8, w: int, v: [4]#simd[16]u8, keep: u64) -> int #no_bounds_check {
	counts := transmute(u64)simd.count_ones(transmute(#simd[8]u8)keep)
	// Byte k of `running` is the lanes kept by the groups below k. Byte 7 of `counts * ONES` is all of them.
	ONES :: 0x0101_0101_0101_0101
	running := (counts * ONES) << 8
	for k in 0 ..< 4 {
		shift := 16 * uint(k)
		lo := keep >> shift & 0xff
		hi := keep >> (shift + 8) & 0xff
		lanes := transmute(#simd[16]u8)[2]u64{KEEP_LANES[lo], KEEP_LANES[hi] + 0x0808_0808_0808_0808}
		packed := transmute([2]u64)simd.runtime_swizzle(v[k], lanes)
		intrinsics.unaligned_store((^u64)(&out[w + int(running >> shift & 0xff)]), packed[0])
		intrinsics.unaligned_store((^u64)(&out[w + int(running >> (shift + 8) & 0xff)]), packed[1])
	}
	return w + int((counts * ONES) >> 56)
}
