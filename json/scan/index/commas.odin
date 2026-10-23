package index

// A container's top-level commas and a piece's bracket balance, 64 bytes at a time, for json's root entries
// (records.odin), which cut one large text into pieces read in parallel. Neither checks the text: on
// malformed input the answers are some count, never a fault.
//
// Both read `s` as though no backslash precedes it: a caller cuts where the byte before is no backslash.
// Loads are unchecked: a block is read in place only while 64 bytes remain, and the last, shorter one is
// copied into a zeroed 64-byte buffer first, so no load passes `s`'s end. A zero byte is no quote,
// backslash, bracket or comma, so the padding changes no answer.

import "base:intrinsics"
import "core:simd"

// How a piece of a text moves bracket depth (`[` and `{` up, `]` and `}` down), read both ways it may open.
Bracket_Balance :: struct {
	outside:        int, // opened outside a string: the depth change of the brackets outside strings
	inside:         int, // opened inside one: likewise. The quotes then pair the other way
	ends_in_string: bool, // opened outside a string, whether it ends in one. Opened inside, it ends in one exactly when this is false
}

// `s`'s bracket balance under both guesses of whether it opens inside a string, in one pass.
bracket_balance :: proc(s: []byte) -> (b: Bracket_Balance) #no_bounds_check {
	prev_odd, in_string: u64
	tail: [64]u8 = ---
	for lo := 0; lo < len(s); lo += 64 {
		p, _ := block_at(s, lo, &tail)
		_, instr, open, close := classify_brackets(p, &prev_odd, &in_string)
		b.outside += int(intrinsics.count_ones(open & ~instr)) - int(intrinsics.count_ones(close & ~instr))
		b.inside += int(intrinsics.count_ones(open & instr)) - int(intrinsics.count_ones(close & instr))
	}
	b.ends_in_string = in_string != 0
	return
}

// A pull over the commas of `s` outside strings and brackets: each block is classified once and its commas
// are taken one at a time, so walking every entry of a container reads its bytes once.
Comma_Cursor :: struct {
	at:        int, // the next block's first byte
	top:       u64, // the commas of the block before `at` not yet taken
	prev_odd:  u64,
	in_string: u64,
	depth:     int,
}

// A cursor from `from`, where `s` opens `depth` brackets into the container, inside a string or not.
comma_cursor :: proc(from: int, in_string := false, depth := 0) -> Comma_Cursor {
	return {at = from, in_string = ~u64(0) if in_string else 0, depth = depth}
}

// The next comma of `s` outside strings and brackets at or past the cursor, or -1 when there is none. `s` is
// the same slice on every call.
next_top_comma :: #force_inline proc(c: ^Comma_Cursor, s: []byte) -> int #no_bounds_check {
	for c.top == 0 {
		if c.at >= len(s) {
			return -1
		}
		tail: [64]u8 = ---
		p, _ := block_at(s, c.at, &tail)
		v, instr, open, close := classify_brackets(p, &c.prev_odd, &c.in_string)
		open &= ~instr
		close &= ~instr
		comma := pack4(simd.lanes_eq(v[0], V(',')), simd.lanes_eq(v[1], V(',')), simd.lanes_eq(v[2], V(',')), simd.lanes_eq(v[3], V(','))) & ~instr
		c.top = comma if c.depth == 0 else 0
		if open | close != 0 {
			// A comma is outside brackets when the brackets before it in the block bring the depth to 0.
			c.top = 0
			for m := comma; m != 0; m &= m - 1 {
				below := (m & -m) - 1
				if c.depth + int(intrinsics.count_ones(open & below)) == int(intrinsics.count_ones(close & below)) {
					c.top |= m & -m
				}
			}
			c.depth += int(intrinsics.count_ones(open)) - int(intrinsics.count_ones(close))
		}
		c.at += 64
	}
	bit := int(intrinsics.count_trailing_zeros(c.top))
	c.top &= c.top - 1
	return c.at - 64 + bit
}

// The block of 64 bytes at `b`: which of its bytes are inside strings, from the carries of the block
// before (`prev_odd`, `in_string`), which it moves on, and its opening and closing brackets, in strings or
// not.
classify_brackets :: #force_inline proc(b: [^]u8, prev_odd, in_string: ^u64) -> (v: [4]V, instr, open, close: u64) #no_bounds_check {
	v = {load(b), load(b[16:]), load(b[32:]), load(b[48:])}
	quote, bs := quotes_and_backslashes(v)
	_, instr = string_region(quote, bs, prev_odd, in_string)
	// `[` and `{` differ only in 0x20, as do `]` and `}`.
	f := [4]V{v[0] | V(0x20), v[1] | V(0x20), v[2] | V(0x20), v[3] | V(0x20)}
	open = pack4(simd.lanes_eq(f[0], V('{')), simd.lanes_eq(f[1], V('{')), simd.lanes_eq(f[2], V('{')), simd.lanes_eq(f[3], V('{')))
	close = pack4(simd.lanes_eq(f[0], V('}')), simd.lanes_eq(f[1], V('}')), simd.lanes_eq(f[2], V('}')), simd.lanes_eq(f[3], V('}')))
	return
}
