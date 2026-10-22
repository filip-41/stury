package index

// Skipping a container stage 2 does not read. Only its brackets outside strings are looked at, matched by
// kind, and its other tokens are never listed. Its quotes balance by construction, since the close bracket it
// stops at is outside every string.
//
// A bracket outside a string has nothing open across it (no string, escape or scalar run), so the walk
// restarts after the close bracket from the zero Carry, as at a document start.
//
// Reads are unchecked. A listed position is read only below `r.n`, the slots the index filled. `skip_chunk`
// hands `skip_block` a block in place only while `p + 64 <= hi`, and the last, shorter one as a copy in a
// 64-byte buffer of spaces. `take_bracket` writes `kinds[depth + 1]`: depth starts at 1 under
// `room <= MAX_DEPTH`, and `bad` is acted on after each block, so depth passes `room` by at most one
// block's 64 brackets, which `Bracket_Kinds` holds.

import "base:intrinsics"
import core_pkg "../../../core"
import lex "../lex"

// Open brackets matched so far, innermost at `kinds[depth]`. Faults collect in
// `bad` and are acted on per block, so past `room` the slots take one block's
// worth of brackets.
//
// Declared `---` and read only at slots a push wrote. Odin zeroes a struct with
// padding even then, so `kinds` takes the bytes padding would: two slots for
// the root and the push past the top, five to end the struct on its alignment.
@(private = "file")
Bracket_Stack :: struct {
	depth: int,
	room:  int, // the deepest level an open bracket may reach
	bad:   u8,
	kinds: Bracket_Kinds,
}
#assert(size_of(Bracket_Stack) == 2 * size_of(int) + 1 + size_of(Bracket_Kinds))

@(private = "file")
Bracket_Kinds :: [core_pkg.MAX_DEPTH + 64 + 7]u8

// Brackets per block taken whether or not they exist, the way `flatten`
// writes, so a varying bracket count costs no misprediction.
@(private = "file")
BRACKET_STEP :: 2

// The close bracket matching the open bracket at `open`, the position `next`
// just handed out through `r`, or -1 when the source ends first, a close
// bracket of the other kind comes first, or nesting passes `room` levels
// counting the open bracket's own. The reader it returns continues after the
// close bracket.
//
// While nesting stays within a word's bits, the open kinds fit in one
// register, one bit per level, set for an object, and the walk over the
// region's listed positions stays inline. A container that nests deeper,
// closes past the region, or breaks a rule is left to the bracket stack,
// which walks it again from `open`.
skip_container :: #force_inline proc(ix: ^Index($F), r: Reader, open: int, room: int) -> (int, Reader) {
	// `[` and `{` have bit 1 set, `]` and `}` clear. `{` and `}` have bit 5.
	region := raw_data(ix.src)[r.lo:]
	limit := min(room, 64)
	kinds := u64(ix.src[open] >> 5) & 1
	depth := 1
	#no_bounds_check for i := r.i; i < r.n && limit > 0; i += 1 {
		off := ix.buf[i]
		b := region[off]
		if lex.CHAR_FLAGS[b] & lex.F_BRACKET == 0 {
			continue
		}
		obj := u64(b >> 5) & 1
		if b & 2 != 0 {
			kinds = kinds << 1 | obj
			depth += 1
			if depth > limit {
				break
			}
			continue
		}
		if kinds & 1 != obj {
			break
		}
		kinds >>= 1
		depth -= 1
		if depth == 0 {
			return r.lo + int(off), Reader{i = i + 1, n = r.n, lo = r.lo}
		}
	}
	return skip_stacked(ix, r, open, room)
}

// `skip_container`'s answer for any container, by the bracket stack.
@(private = "file")
skip_stacked :: proc(ix: ^Index($F), r: Reader, open: int, room: int) -> (int, Reader) {
	r := r
	if room < 1 {
		return -1, r
	}
	st: Bracket_Stack = ---
	st.depth, st.room, st.bad = 1, min(room, core_pkg.MAX_DEPTH), 0
	st.kinds[1] = ix.src[open]
	// The rest of the current region is listed already: walking its positions
	// costs less than classifying it again.
	for r.i < r.n {
		#no_bounds_check p := r.lo + int(ix.buf[r.i])
		r.i += 1
		b := ix.src[p]
		if b | 0x20 != '{' && b | 0x20 != '}' {
			continue
		}
		take_bracket(&st.kinds, &st.depth, &st.bad, st.room, b, 1)
		if st.bad != 0 {
			return -1, r
		}
		if st.depth == 0 {
			return p, r
		}
	}
	for lo := ix.next_lo; lo < len(ix.src); lo += CHUNK {
		hi := min(lo + CHUNK, len(ix.src))
		at, ok := skip_chunk(ix, lo, hi, &st)
		if !ok {
			return -1, Reader{}
		}
		if at >= 0 {
			ix.next_lo = at + 1
			ix.carry = Carry{prev = before16(ix.src, at + 1)}
			return at, Reader{}
		}
	}
	ix.next_lo = len(ix.src)
	return -1, Reader{}
}

// The outermost close bracket in `[lo, hi)`, or -1 when it is not there.
@(private = "file")
skip_chunk :: proc(ix: ^Index($F), lo, hi: int, st: ^Bracket_Stack) -> (at: int, ok: bool) {
	src := raw_data(ix.src)
	p := lo
	for p + 64 <= hi {
		k := skip_block(src[p:], &ix.carry, st) or_return
		if k >= 0 {
			return p + k, true
		}
		p += 64
	}
	if p < hi {
		pad: [64]u8 = ' '
		copy(pad[:], ix.src[p:hi])
		k := skip_block(raw_data(pad[:]), &ix.carry, st) or_return
		if k >= 0 {
			return p + k, true
		}
	}
	return -1, true
}

// The offset of the outermost close bracket in the block at `p`, or -1. Only the string carries move: the
// block's other carries and its wire faults are a read's, and a skip reads nothing.
@(private = "file")
skip_block :: #force_inline proc(p: [^]u8, cy: ^Carry, st: ^Bracket_Stack) -> (k: int, ok: bool) {
	_, instr, open, close := classify_brackets(p, &cy.prev_odd, &cy.in_string)
	// Locals, so the stack's slots are the only memory the loop touches.
	depth, bad, room := st.depth, st.bad, st.room
	m := (open | close) & ~instr
	#unroll for _ in 0 ..< BRACKET_STEP {
		i := int(intrinsics.count_trailing_zeros(m) & 63)
		live := int(m != 0)
		m &= m - 1
		take_bracket(&st.kinds, &depth, &bad, room, p[i], live)
		if depth == 0 {
			return i, bad == 0
		}
	}
	for ; m != 0; m &= m - 1 {
		i := int(intrinsics.count_trailing_zeros(m))
		take_bracket(&st.kinds, &depth, &bad, room, p[i], 1)
		if depth == 0 {
			return i, bad == 0
		}
	}
	st.depth, st.bad = depth, bad
	return -1, bad == 0
}

// Pushes an open bracket or pops a close one, or does nothing unless `live`.
// Branch-free, since open and close alternate unpredictably: a close of the
// wrong kind and an open past `room` set `bad` rather than stopping.
@(private = "file")
take_bracket :: #force_inline proc(kinds: ^Bracket_Kinds, depth: ^int, bad: ^u8, room: int, b: u8, live: int) {
	// `[` and `{` have bit 1 set, `]` and `}` clear. A matching pair differs
	// in bits 1 and 2 alone.
	open := int(b >> 1) & 1
	#no_bounds_check {
		top := kinds[depth^]
		kinds[depth^ + 1] = b
		bad^ |= (0 - u8(live & (1 - open))) & (top ~ b ~ 6)
	}
	depth^ += live * (2 * open - 1)
	bad^ |= u8(depth^ > room)
}
