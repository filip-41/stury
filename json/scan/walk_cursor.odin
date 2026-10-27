package scan

import index "index"
import lex "lex"

// How the walk gets from one token to the next. The cursor only decides how whitespace is passed.
//
// The byte cursor steps over whitespace one byte at a time. The index cursor jumps to stage 1's next
// token start, and only when the gap begins with whitespace: a gap that begins with anything else holds a
// byte the walk has to see and fault at, so `s.pos` stays where the byte cursor would have stopped.
// Faults therefore keep the same kind and offset under either cursor.
//
// The walk advances the cursor once per token it consumes. The jump is sound because the walk and stage 1
// agree on where tokens start and end (a backslash escapes one byte, in both). The one way they part is a
// leaf stopping inside a token, as a number leaf stops at the `x` of `1x`. The walk then stands on a byte
// that is neither whitespace nor an operator, so the cursor stays put and the walk faults there.
Byte_Cursor :: struct {}

// The byte cursor for a document that looks pretty-printed (`pretty_head`), chosen once per walk. After a
// structural token it skips a newline and the predicted indent (`pretty_skip_peek`). `object_key` and
// `expect_colon` try the pretty printer's layout first. Any document reads correctly; a compact one reads slower.
Pretty_Cursor :: struct {
	ind:  u64, // the indent of the last line passed
	step: u64, // the spaces added per nesting level
}

// The position of a newline in the walk, which determines the next line's indent under a pretty printer: one
// step deeper after an open bracket, the same after a comma, one step out before a close bracket.
Indent_At :: enum {
	Open,
	Member,
	Close,
}

// `lex.skip_peek_pretty` with a newline's indent predicted from `at` instead of counted. The jump target is
// known before the indent bytes load, so the next token's load does not depend on them; they feed only the branch
// that checks the prediction. On a misprediction the indent is counted, and after an open bracket the extra
// indent becomes `step`.
pretty_skip_peek :: #force_inline proc(s: ^Scanner, cur: ^Pretty_Cursor, $at: Indent_At) -> int {
	#no_bounds_check {
		n := u64(len(s.src))
		if s.pos < n && s.src[s.pos] == '\n' {
			line := s.pos + 1
			k := cur.ind
			when at == .Open {
				k += cur.step
			} else when at == .Close {
				k -= cur.step // wraps past LEAD_MAX when `ind` is under a step, so the line is counted
			}
			if k < lex.LEAD_MAX && line + lex.LEAD_MAX <= n && lex.spaces_lead(s.src, line, k) && s.src[line + k] > ' ' {
				s.pos = line + k
				cur.ind = k
				return int(s.src[s.pos])
			}
			c := lex.skip_peek_pretty(s)
			// On input a pretty printer did not lay out, `step` may be wrong; that costs only mispredictions.
			when at == .Open {
				cur.step = s.pos - line - cur.ind
			}
			cur.ind = s.pos - line
			return c
		}
	}
	return lex.skip_peek_pretty(s)
}

// The longest first indent `pretty_head` accepts. A longer run, or other whitespace, is not pretty-printed.
PRETTY_INDENT_MAX :: 16
// The shortest document `pretty_head` checks. Below it the check costs more than the pretty walk saves.
PRETTY_MIN_BYTES :: 1024

// Reports whether the root's opening bracket at `at` is followed by a newline, 1 to PRETTY_INDENT_MAX spaces
// and a token, as `json.dumps(indent=n)` and `jq` write.
pretty_head :: #force_inline proc(src: []byte, at: int) -> bool {
	#no_bounds_check {
		n := len(src)
		if n < PRETTY_MIN_BYTES || at + 2 >= n || src[at + 1] != '\n' || src[at + 2] != ' ' {
			return false
		}
		i := at + 3
		end := min(n, at + 2 + PRETTY_INDENT_MAX)
		for i < end && src[i] == ' ' {
			i += 1
		}
		return i < n && src[i] > ' '
	}
}

// The facts a Locate walk and a Values walk ask their index for.
LOCATE_FACTS :: index.Facts{.Scalar_Shape, .Wire_On_Skip}
VALUES_FACTS :: index.Facts{.Ctrl_In_String}

// A document whose first STRING_HEAD_PROBE bytes are at least 7/8 string content is read by the byte
// cursor: its tokens are far apart, and the vector span skip passes them cheaper than stage 1 classifies
// the bytes between. A head with few strings (numbers, nesting) stays on the index cursor. The probe
// toggles on `"` and takes a backslash to cover the next byte, roughly, since it only picks a cursor and
// never a result (the cursors agree). A shorter head is a small document, where either costs little.
@(private = "file")
STRING_HEAD_PROBE :: 1024
@(private = "file")
STRING_HEAD_EIGHTHS :: 7

head_is_mostly_string :: proc(src: []u8, at: int) -> bool {
	if len(src) - at < STRING_HEAD_PROBE {
		return false
	}
	in_string, escaped := false, false
	inside := 0
	for b in src[at:at + STRING_HEAD_PROBE] {
		if escaped {
			escaped = false
		} else if b == '\\' {
			escaped = in_string
		} else if b == '"' {
			in_string = !in_string
		}
		inside += int(in_string)
	}
	return inside * 8 >= STRING_HEAD_EIGHTHS * STRING_HEAD_PROBE
}

// Query kinds whose hooks need only a token's extent (and from a key whether it held an escape), so
// only walks asking no other kind pass tokens without their leaves.
EXTENT_ONLY :: bit_set[Walk_Kind]{.Path, .Demand, .Gate}

// Only inlined procs take a cursor, so its fields stay in registers.
Index_Cursor :: struct($F: index.Facts) {
	ix: ^index.Index(F),
	r:  index.Reader,
	p:  int, // the first token start the walk has not consumed, or -1 past the last
}

cursor_advance :: proc {
	byte_cursor_advance,
	pretty_cursor_advance,
	index_cursor_advance,
	dialect_cursor_advance,
}

cursor_skip :: proc {
	byte_cursor_skip,
	pretty_cursor_skip,
	index_cursor_skip,
	dialect_skip,
}

cursor_skip_peek :: #force_inline proc(s: ^Scanner, cur: ^$C) -> int {
	cursor_skip(s, cur)
	return lex.peek(s)
}

// Passes the string opening at `s.pos` without its leaf, when the cursor already knows the leaf would
// accept it. Leaves `s.pos` past the string, or on the next token when no query reads the position in
// between. False means the leaf has to run.
cursor_string_known :: proc {
	byte_cursor_string_known,
	pretty_cursor_string_known,
	index_cursor_string_known,
	dialect_cursor_string_known,
}

// The same for the number or literal at `s.pos` and its Locate leaf.
cursor_scalar_known :: proc {
	byte_cursor_scalar_known,
	pretty_cursor_scalar_known,
	index_cursor_scalar_known,
	dialect_cursor_scalar_known,
}

// Skips the value at `s.pos` to where `lex.value_end` ends it, without checking its grammar. At `.Locate` its
// wire UTF-8 is checked on the way, as for a visited token; at `.Values` a skipped value is not read. Returns false,
// with the walk unmoved, when the value has no end under these rules or contains a byte that needs the read's
// fault; the caller then reads the value.
cursor_skip_value :: proc {
	byte_cursor_skip_value,
	pretty_cursor_skip_value,
	index_cursor_skip_value,
}

@(private = "file")
byte_cursor_advance :: #force_inline proc(_: ^Byte_Cursor) {}

@(private = "file")
byte_cursor_skip :: #force_inline proc(s: ^Scanner, _: ^Byte_Cursor) {
	lex.skip_ws(s)
}

@(private = "file")
byte_cursor_string_known :: #force_inline proc(_: ^Scanner, _: ^Byte_Cursor, $check: Check_Level, $Q: bit_set[Walk_Kind], key: bool) -> bool {
	return false
}

@(private = "file")
byte_cursor_scalar_known :: #force_inline proc(_: ^Scanner, _: ^Byte_Cursor, $Q: bit_set[Walk_Kind]) -> bool {
	return false
}

@(private = "file")
byte_cursor_skip_value :: #force_inline proc(s: ^Scanner, _: ^Byte_Cursor, vc: u8, room: int, $check: Check_Level) -> bool {
	end := lex.value_end_at(s.src, int(s.pos), vc, room, check)
	if end < 0 {
		return false
	}
	s.pos = u64(end)
	return true
}

@(private = "file")
pretty_cursor_advance :: #force_inline proc(_: ^Pretty_Cursor) {}

@(private = "file")
pretty_cursor_skip :: #force_inline proc(s: ^Scanner, _: ^Pretty_Cursor) {
	lex.skip_indent(s)
	lex.skip_ws(s)
}

@(private = "file")
pretty_cursor_string_known :: #force_inline proc(_: ^Scanner, _: ^Pretty_Cursor, $check: Check_Level, $Q: bit_set[Walk_Kind], key: bool) -> bool {
	return false
}

@(private = "file")
pretty_cursor_scalar_known :: #force_inline proc(_: ^Scanner, _: ^Pretty_Cursor, $Q: bit_set[Walk_Kind]) -> bool {
	return false
}

@(private = "file")
pretty_cursor_skip_value :: #force_inline proc(s: ^Scanner, _: ^Pretty_Cursor, vc: u8, room: int, $check: Check_Level) -> bool {
	return byte_cursor_skip_value(s, &Byte_Cursor{}, vc, room, check)
}

// The index starts after the document's leading whitespace, so its string state starts outside a string.
// `reads_all` is a walk that cannot stop before the end.
index_cursor :: #force_inline proc(ix: ^index.Index($F), s: ^Scanner, reads_all: bool) -> (cur: Index_Cursor(F)) {
	index.init(ix, s.src, int(s.pos), reads_all)
	cur.ix = ix
	cur.p = index.next(ix, &cur.r)
	return
}

@(private = "file")
index_cursor_advance :: #force_inline proc(cur: ^Index_Cursor($F)) {
	cur.p = index.next(cur.ix, &cur.r)
}

@(private = "file")
index_cursor_skip :: #force_inline proc(s: ^Scanner, cur: ^Index_Cursor($F)) {
	at := int(s.pos)
	target := cur.p if cur.p >= 0 else len(s.src)
	#no_bounds_check if at < target && lex.CHAR_FLAGS[s.src[at]] & lex.F_WS != 0 {
		s.pos = u64(target)
	}
}

// When the token after the string is in the current region, the string closed there and the region's
// facts cover every byte of it: UTF-8 and control bytes are checked, and with no backslash in the region no
// escape is left for the Values leaf to check or a key's escape latch to record. Strings carry no Values
// limit, so nothing else could refuse one.
@(private = "file")
index_cursor_string_known :: #force_inline proc(s: ^Scanner, cur: ^Index_Cursor($F), $check: Check_Level, $Q: bit_set[Walk_Kind], key: bool) -> bool {
	when check == .Values {
		#assert(.Ctrl_In_String in F)
	}
	if cur.p != int(s.pos) || !cur.ix.chunk_wire_ok || !index.next_is_buffered(&cur.r) {
		return false
	}
	when check == .Values {
		if cur.ix.chunk_bs {
			return false
		}
	} else when .Path in Q || .Demand in Q {
		if key && cur.ix.chunk_bs {
			return false
		}
	}
	index_cursor_pass(s, cur, Q)
	return true
}

// Takes the token at `s.pos` as consumed, with the walk standing past it.
@(private = "file")
index_cursor_pass :: #force_inline proc(s: ^Scanner, cur: ^Index_Cursor($F), $Q: bit_set[Walk_Kind]) {
	cur.p = index.next(cur.ix, &cur.r)
	when Q != {} {
		s.pos = u64(token_end(s.src, cur.p))
	} else {
		s.pos = u64(cur.p)
	}
}

// Where the token before the one at `next` ends: the whitespace between them
// is not part of it.
token_end :: #force_inline proc(src: []u8, next: int) -> int {
	end := next
	// `next` follows a token start (a non-whitespace byte at a lower offset) in the index, so the run stops before `end` reaches 0.
	#no_bounds_check for lex.CHAR_FLAGS[src[end - 1]] & lex.F_WS != 0 {
		end -= 1
	}
	return end
}

// The Locate leaf takes a scalar's whole run when it holds only the bytes its first byte allows, and
// Locate limits no scalar. With the next token in the region the run lies inside it, where the shape fact
// covers it.
@(private = "file")
index_cursor_scalar_known :: #force_inline proc(s: ^Scanner, cur: ^Index_Cursor($F), $Q: bit_set[Walk_Kind]) -> bool {
	when .Scalar_Shape not_in F {
		return false
	} else {
		if cur.p != int(s.pos) || !cur.ix.chunk_scalar_ok || !index.next_is_buffered(&cur.r) {
			return false
		}
		index_cursor_pass(s, cur, Q)
		return true
	}
}

// Skips a container by its brackets alone (`index.skip_container`), and a string or scalar to the next token
// start. Otherwise, and away from the cursor's token, the byte path decides. The index takes the reader by
// address, so it gets a copy; passing the cursor's own would keep it out of registers in every walk that can skip.
// At `.Locate` the index checks the wire UTF-8 of every region it classifies and of every block a container skip
// crosses (`wire_bad`). A skip is clean when its start region was clean and no fault was found in what it crossed.
// A faulty region beside the value also refuses the skip, and the value is read instead.
@(private = "file")
index_cursor_skip_value :: #force_inline proc(s: ^Scanner, cur: ^Index_Cursor($F), vc: u8, room: int, $check: Check_Level) -> bool {
	when check == .Locate {
		#assert(.Wire_On_Skip in F)
		ix := cur.ix
		if !ix.chunk_wire_ok {
			return false
		}
		lo, bad := s.pos, ix.wire_bad
		if !index_cursor_pass_value(s, cur, vc, room) {
			return false
		}
		if ix.wire_bad != bad {
			s.pos = lo
			cur.r, cur.p = index_restart(ix, s.src, int(lo))
			return false
		}
		return true
	} else {
		return index_cursor_pass_value(s, cur, vc, room)
	}
}

@(private = "file")
index_cursor_pass_value :: #force_inline proc(s: ^Scanner, cur: ^Index_Cursor($F), vc: u8, room: int) -> bool {
	if cur.p == int(s.pos) {
		if vc <= VC_ARRAY {
			at := cur.r
			close, r := index.skip_container(cur.ix, at, cur.p, room)
			if close >= 0 {
				cur.r = r
				cur.p = index.next(cur.ix, &cur.r)
				s.pos = u64(close + 1)
				return true
			}
			cur.r, cur.p = index_restart(cur.ix, s.src, int(s.pos))
			return false
		}
		cur.p = index.next(cur.ix, &cur.r)
		if cur.p >= 0 {
			s.pos = u64(token_end(s.src, cur.p))
			return true
		}
	}
	end: int
	at := cur.r
	end, cur.r, cur.p = index_skip_bytes(cur.ix, at, cur.p, s.src, int(s.pos), vc, room)
	if end < 0 {
		return false
	}
	s.pos = u64(end)
	return true
}

// The walk reads the container whose skip failed instead. Its open bracket at
// `lo` is outside every string, so the index restarts there.
@(cold)
@(private = "file")
index_restart :: proc(ix: ^index.Index($F), src: []u8, lo: int) -> (r: index.Reader, p: int) {
	index.init(ix, src, lo)
	p = index.next(ix, &r)
	return
}

// The bytes' skip, with the cursor brought to the first token after it.
@(cold)
@(private = "file")
index_skip_bytes :: proc(ix: ^index.Index($F), r: index.Reader, p: int, src: []u8, lo: int, vc: u8, room: int) -> (int, index.Reader, int) {
	r, p := r, p
	end := lex.value_end(src, lo, vc, room)
	if end >= 0 {
		for p >= 0 && p < end {
			p = index.next(ix, &r)
		}
	}
	return end, r, p
}
