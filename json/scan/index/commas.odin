package index

// A container's top-level commas, its close, a run's line feeds outside every text, and a piece's bracket balance,
// 64 bytes at a time, for json's root entries and concatenated texts (records.odin), which cut an input into
// pieces read in parallel. None checks the text: on malformed input the answers are some count, never a fault.
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
bracket_balance :: proc(s: []byte) -> Bracket_Balance {
	b, _ := balance_blocks(s, false)
	return b
}

// Where a run of concatenated texts may part from the depth `Bracket_Balance` counts, under both guesses of
// whether `s` opens inside a string: the lowest depth its brackets outside strings reach from its start (a closer
// below 0 is a stray, a text of its own), and whether a backslash stands outside a string (escaping a quote that
// opens a text).
Bracket_Strays :: struct {
	low_outside, low_inside:       int,
	escape_outside, escape_inside: bool,
}

// `bracket_balance`, and where `s` may part from it (`Bracket_Strays`), in one pass.
bracket_balance_strays :: proc(s: []byte) -> (Bracket_Balance, Bracket_Strays) {
	return balance_blocks(s, true)
}

@(private = "file")
balance_blocks :: #force_inline proc(s: []byte, $STRAYS: bool) -> (b: Bracket_Balance, st: Bracket_Strays) #no_bounds_check {
	prev_odd, in_string: u64
	tail: [64]u8 = ---
	for lo := 0; lo < len(s); lo += 64 {
		p, _ := block_at(s, lo, &tail)
		v, instr, open, close := classify_brackets(p, &prev_odd, &in_string)
		when STRAYS {
			_, bs := quote_and_escape_bits(v, '"', '\\')
			st.low_outside = block_low(st.low_outside, b.outside, open & ~instr, close & ~instr)
			st.low_inside = block_low(st.low_inside, b.inside, open & instr, close & instr)
			st.escape_outside ||= bs & ~instr != 0
			st.escape_inside ||= bs & instr != 0
		} else {
			_ = v
		}
		b.outside += int(intrinsics.count_ones(open & ~instr)) - int(intrinsics.count_ones(close & ~instr))
		b.inside += int(intrinsics.count_ones(open & instr)) - int(intrinsics.count_ones(close & instr))
	}
	b.ends_in_string = in_string != 0
	return
}

// The lower of `low` and the lowest depth a block's closers bring `depth` to.
@(private = "file")
block_low :: #force_inline proc(low, depth: int, open, close: u64) -> int {
	if depth - int(intrinsics.count_ones(close)) >= low {
		return low
	}
	low := low
	for m := close; m != 0; m &= m - 1 {
		through := (m & -m) << 1 - 1
		low = min(low, depth + int(intrinsics.count_ones(open & through)) - int(intrinsics.count_ones(close & through)))
	}
	return low
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
	return next_top(c, s, ',', false)
}

// The next line feed of `s` outside strings and brackets at or past the cursor, or -1 when there is none.
next_top_newline :: #force_inline proc(c: ^Comma_Cursor, s: []byte) -> int #no_bounds_check {
	return next_top(c, s, '\n', false)
}

// The next comma of `s` outside strings and brackets at or past the cursor, or the bracket that closes the
// container the cursor is in, whichever comes first, or -1 when there is neither. The byte tells which.
next_top_comma_or_close :: #force_inline proc(c: ^Comma_Cursor, s: []byte) -> int #no_bounds_check {
	return next_top(c, s, ',', true)
}

// Under `CLOSE` a closer is taken where a comma would be: at the cursor's depth, which only the container's own
// closer is at.
@(private = "file")
next_top :: #force_inline proc(c: ^Comma_Cursor, s: []byte, $B: u8, $CLOSE: bool) -> int #no_bounds_check {
	for c.top == 0 {
		if c.at >= len(s) {
			return -1
		}
		tail: [64]u8 = ---
		p, _ := block_at(s, c.at, &tail)
		v, instr, open, close := classify_brackets(p, &c.prev_odd, &c.in_string)
		open &= ~instr
		close &= ~instr
		comma := pack4(simd.lanes_eq(v[0], V(B)), simd.lanes_eq(v[1], V(B)), simd.lanes_eq(v[2], V(B)), simd.lanes_eq(v[3], V(B))) & ~instr
		when CLOSE {
			comma |= close
		}
		c.top = comma if c.depth == 0 else 0
		if open | close != 0 {
			// A byte is outside brackets when the brackets before it in the block bring the depth to 0.
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

// The bracket that closes the one the cursor started on, outside strings, or -1 when `s` ends first. A block that
// `s` ends partway through is read only when `last` (nothing follows `s`): otherwise the cursor stops before it, so
// that over a longer `s` it resumes where it stopped.
next_top_close :: proc(c: ^Comma_Cursor, s: []byte, last: bool) -> int #no_bounds_check {
	for c.at < len(s) && (last || len(s) - c.at >= 64) {
		tail: [64]u8 = ---
		p, _ := block_at(s, c.at, &tail)
		_, instr, open, close := classify_brackets(p, &c.prev_odd, &c.in_string)
		open &= ~instr
		close &= ~instr
		for m := close; m != 0; m &= m - 1 {
			through := (m & -m) << 1 - 1 // wraps to every bit for the block's last byte
			if c.depth + int(intrinsics.count_ones(open & through)) == int(intrinsics.count_ones(close & through)) {
				return c.at + int(intrinsics.count_trailing_zeros(m))
			}
		}
		c.depth += int(intrinsics.count_ones(open)) - int(intrinsics.count_ones(close))
		c.at += 64
	}
	return -1
}

// The block of 64 bytes at `b`: which of its bytes are inside strings, from the carries of the block
// before (`prev_odd`, `in_string`), which it moves on, and its opening and closing brackets, in strings or
// not.
classify_brackets :: #force_inline proc(b: [^]u8, prev_odd, in_string: ^u64) -> (v: [4]V, instr, open, close: u64) #no_bounds_check {
	v = {load(b), load(b[16:]), load(b[32:]), load(b[48:])}
	quote, bs := quote_and_escape_bits(v, '"', '\\')
	_, instr = string_region(quote, bs, prev_odd, in_string)
	// `[` and `{` differ only in 0x20, as do `]` and `}`.
	f := [4]V{v[0] | V(0x20), v[1] | V(0x20), v[2] | V(0x20), v[3] | V(0x20)}
	open = pack4(simd.lanes_eq(f[0], V('{')), simd.lanes_eq(f[1], V('{')), simd.lanes_eq(f[2], V('{')), simd.lanes_eq(f[3], V('{')))
	close = pack4(simd.lanes_eq(f[0], V('}')), simd.lanes_eq(f[1], V('}')), simd.lanes_eq(f[2], V('}')), simd.lanes_eq(f[3], V('}')))
	return
}
