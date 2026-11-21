package json

import "base:intrinsics"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// A member gap is the text between an object's open bracket or a member's value and the next member's value, such as
// `,"name":` or the same with a line break and an indent before the key. The walk learns the gaps of each object and
// matches them against the next object at the same place in the tree, which judges a member's comma, white space, key
// and colon in one compare.
//
// A match is as strict as the states. A gap is learned only from bytes they accepted, around a key with no escape, and
// every gap after a value stands in the same place of the grammar. The gap after an open bracket stands elsewhere and
// has a slot of its own.

// Whether the walk learns member gaps.
@(private)
GAPS :: #config(JSON_GAPS, true)

// Rows in a walk's gap table
@(private)
GAP_ROWS :: 64
// Slots per row. Slot 0 holds the gap after the open bracket and slot k the gap after member k's value; members past
// the last slot share it.
@(private)
GAP_MEMBERS :: 32
// The longest gap learned.
@(private)
GAP_MAX :: 64
// Relearns with no match between them that retire a slot.
@(private)
GAP_RELEARNS :: 8
@(private)
GAP_MISS_BYTES :: 64 // text read per miss a walk allows before it stops matching gaps
@(private)
GAP_MISS_FLOOR :: 512 // misses a walk allows on top of those

#assert(GAP_MEMBERS & (GAP_MEMBERS - 1) == 0)
#assert(GAP_MAX < GAP_DEAD)

// A learned gap.
@(private)
Gap :: struct {
	lo:    u32, // the gap's offset in the text
	n:     u8, // the gap's length, 0 for none learned, `GAP_DEAD` for a retired slot
	key:   Gap_Key,
	key_n: u8, // the key's length
	miss:  Gap_Miss,
}

@(private)
Gap_Key :: bit_field u8 {
	offset:  u8   | 6, // the key's offset in the gap
	_:       u8   | 1,
	newline: bool | 1, // the gap begins with a line break
}

@(private)
Gap_Miss :: bit_field u8 {
	relearns: u8   | 7, // since the last match
	suspect:  bool | 1, // after a miss, which keeps the gap until a second miss in a row
}

@(private)
GAP_DEAD :: u8(0xFF)

// A key's offset in its gap leaves room for its quotes and the colon, so its six bits in `Gap_Key` hold it.
#assert(GAP_MAX - 3 < 1 << 6)

// A walk's gap table.
@(private)
Gaps :: struct {
	slots:  [GAP_ROWS * GAP_MEMBERS]Gap,
	child:  [GAP_ROWS * GAP_MEMBERS]u8, // the row of the objects in slot `m`'s value, 0 before one opens
	rows:   u64, // rows in use, row 0 included
	misses: u64, // members read with no match
}

// The first slot of the row for objects in slot `m`'s value, or 0 before one opens; `m` without gaps.
@(private)
gap_child :: #force_inline proc "contextless" (w: ^Walk($S, $H), m: u64, $G: bool) -> u64 #no_bounds_check {
	when !G {
		return m
	}
	return u64(w.gaps.child[m]) * GAP_MEMBERS
}

@(private, cold)
gap_new_row :: #force_no_inline proc "contextless" (g: ^Gaps, m: u64) -> u64 #no_bounds_check {
	row := u64(GAP_ROWS - 1)
	if g.rows < GAP_ROWS {
		row = g.rows
		g.rows += 1
		intrinsics.mem_zero(&g.slots[row * GAP_MEMBERS], GAP_MEMBERS * size_of(Gap))
		intrinsics.mem_zero(&g.child[row * GAP_MEMBERS], GAP_MEMBERS)
	}
	g.child[m] = u8(row)
	return row
}

// The slot after `m`, `m` without gaps. A row's last slot is its own successor.
@(private)
gap_next :: #force_inline proc "contextless" (m: u64, $G: bool) -> u64 {
	when !G {
		return m
	}
	return m + u64((m + 1) & (GAP_MEMBERS - 1) != 0)
}

// The start of the value after `p` when the text at `p` repeats slot `m`'s gap, with the key token the gap holds; nil
// otherwise. Each gap length has a branch with constant offsets, so the value's start does not wait on the slot's load.
@(private)
gap_match :: #force_inline proc "contextless" (w: ^Walk($S, $H), p, end: [^]u8, m: u64) -> (r: [^]u8, key: tape.Token, nl: bool) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= GAP_MAX + 8 {
		return nil, {}, false
	}
	s := &w.gaps.slots[m]
	n := int(s.n)
	e := w.base[u64(s.lo):]
	r = gap_match_len(p, e, n)
	if r == nil {
		return nil, {}, false
	}
	if s.miss != {} {
		s.miss = {}
	}
	learned := s.key
	return r, tape.Token{at(w, p) + u64(learned.offset) + 1, u32(s.key_n), .String, .Key, tape.SPELLING_QUOTED}, learned.newline
}

// One past the `n`-byte gap at `p` matching `e` followed by a value-start byte, or nil on mismatch.
@(private)
gap_match_len :: #force_inline proc "contextless" (p, e: [^]u8, n: int) -> [^]u8 #no_bounds_check {
	#unroll for k in 3 ..= GAP_MAX {
		if n == k {
			if !gap_equal(p, e, k) || p[k] <= ' ' {
				return nil
			}
			return p[k:]
		}
	}
	return nil
}

// Whether the `k` bytes at `p` and `e` are equal, compared with overlapping loads. Both `p` and `e` have over `GAP_MAX + 8`
// readable bytes ahead, and `k` is a constant where `gap_match_len` inlines it.
@(private)
gap_equal :: #force_inline proc "contextless" (p, e: [^]u8, k: int) -> bool #no_bounds_check {
	if k < 8 {
		return ((word(p) ~ word(e)) & (u64(1) << (8 * u64(k)) - 1)) == 0
	}
	if k == 8 {
		return word(p) == word(e)
	}
	if k < 16 {
		return ((word(p) ~ word(e)) | (word(p[k - 8:]) ~ word(e[k - 8:]))) == 0
	}
	if k == 16 {
		return kernel.all_zero(simd.bit_xor(kernel.load16(p), kernel.load16(e)))
	}
	if k <= 32 {
		a := simd.bit_xor(kernel.load16(p), kernel.load16(e))
		b := simd.bit_xor(kernel.load16(p[k - 16:]), kernel.load16(e[k - 16:]))
		return kernel.all_zero(simd.bit_or(a, b))
	}
	if k <= 48 {
		a := simd.bit_xor(kernel.load16(p), kernel.load16(e))
		b := simd.bit_xor(kernel.load16(p[16:]), kernel.load16(e[16:]))
		c := simd.bit_xor(kernel.load16(p[k - 16:]), kernel.load16(e[k - 16:]))
		return kernel.all_zero(simd.bit_or(simd.bit_or(a, b), c))
	}
	a := simd.bit_xor(kernel.load16(p), kernel.load16(e))
	b := simd.bit_xor(kernel.load16(p[16:]), kernel.load16(e[16:]))
	c := simd.bit_xor(kernel.load16(p[32:]), kernel.load16(e[32:]))
	d := simd.bit_xor(kernel.load16(p[k - 16:]), kernel.load16(e[k - 16:]))
	return kernel.all_zero(simd.bit_or(simd.bit_or(a, b), simd.bit_or(c, d)))
}

@(private)
word :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return u64(intrinsics.unaligned_load((^u64le)(p)))
}

// Learns slot `m`'s gap, which did not match, from `w.gap_lo` to the value at `r`, around the key quoted from `p` to
// `q`. A first miss only marks the slot and a second in a row replaces its gap. `stop` when the walk's misses pass
// their limit, after which it reads on without gaps.
@(private)
gap_learn :: #force_inline proc "contextless" (w: ^Walk($S, $H), m: u64, p, q, r: [^]u8) -> (stop: bool) #no_bounds_check {
	if gap_miss(w, p) {
		return true
	}
	s := &w.gaps.slots[m]
	if s.n == GAP_DEAD {
		return
	}
	if s.n != 0 {
		if !s.miss.suspect {
			s.miss.suspect = true
			return
		}
		if s.miss.relearns >= GAP_RELEARNS {
			s.n = GAP_DEAD
			return
		}
	}
	lo := w.gap_lo
	n := at(w, r) - lo
	if n <= GAP_MAX && lo <= u64(max(u32)) {
		key_off := at(w, p) - lo
		nl := key_off > 0 && (w.base[lo] == '\n' || (key_off >= 2 && w.base[lo] == '\r' && w.base[lo + 1] == '\n'))
		s^ = {u32(lo), u8(n), {offset = u8(key_off), newline = nl}, u8(intrinsics.ptr_sub(q, p) - 2), {relearns = s.miss.relearns + 1}}
	}
	return
}

// Counts a member at `p` read with no match. True when the walk's misses pass their limit, after which it reads on
// without gaps.
@(private)
gap_miss :: #force_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8) -> bool {
	w.gaps.misses += 1
	return w.gaps.misses > GAP_MISS_FLOOR + at(w, p) / GAP_MISS_BYTES
}
