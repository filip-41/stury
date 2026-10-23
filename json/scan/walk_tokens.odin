package scan

// The tokens between values that the walks step over: a key and its colon, the whitespace around them, the
// comma of a compact array of numbers.

import "walk"
import lex "lex"

// A key and its colon, skipping whitespace around each. A missing key faults at the byte that cannot
// start one, a missing colon at the byte that cannot be one. `next` is the byte the value starts with.
@(private)
object_key :: #force_inline proc(
	s: ^Scanner,
	cur: ^$C,
	q: ^Query_Ctx,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	sp: u64,
	// The enclosing object's frame: its `lo` names the object a demand row belongs to.
	owner: ^Open_Frame,
	pend: ^Demand_Pend,
) -> (next: int, err: Maybe(Error)) {
	if lex.peek(s) != '"' {
		// `pretty_skip_peek` skips all the whitespace, so the pretty cursor skips nothing after it.
		when C == Pretty_Cursor {
			pretty_skip_peek(s, cur, .Member)
		} else {
			when C == Byte_Cursor && .Nodes in Q {
				lex.skip_indent(s)
			}
			cursor_skip(s, cur)
		}
		if at := lex.peek(s); at != '"' {
			if at == -1 {
				return -1, Error{offset = s.pos, kind = .Truncated}
			}
			return -1, Error{offset = s.pos, kind = .Bad_Char}
		}
	}
	key_lo := s.pos
	// The key's parse records whether its text carried an escape, so no consumer rescans the key.
	when Q & lex.KEY_ESC_KINDS != {} {
		q.key_esc_live = true
		q.key_saw_escape = false
	}
	perr: Maybe(Error)
	known := false
	when Q <= EXTENT_ONLY {
		known = cursor_string_known(s, cur, check, Q, true)
	}
	if !known {
		when check == .Values {
			perr = lex.parse_string_q(s, q, key_lo, true, Q)
		} else {
			perr = lex.skip_string_q(s, q, key_lo, true, Q)
		}
		cursor_advance(cur)
	}
	when Q & lex.KEY_ESC_KINDS != {} {
		q.key_esc_live = false
	}
	if perr != nil {
		return -1, perr
	}
	when Q & lex.KEY_ESC_KINDS != {} {
		key_hi := s.pos
		// Latched before the colon is consumed. The next row written is the member value's, so the two
		// spans and the escape bit have one candidate row. `emit_node` consumes all three together.
		when .Nodes in Q {
			q.node_key_lo = key_lo
			q.node_key_hi = key_hi
			q.node_key_escaped = q.key_saw_escape
		}
		next, err = expect_colon(s, cur, Q)
		if err != nil {
			return
		}
		when .Shape in Q {
			if serr := shape_key(s, q, key_lo, key_hi, sp, .Unique in Q); serr != nil {
				return -1, serr
			}
		} else when .Unique in Q {
			if uerr := walk_key_unique(q, s.src, key_lo, key_hi, sp); uerr != nil {
				return -1, uerr
			}
		}
		when .Demand in Q {
			// Bound now, resolved when the value closes (half the answer is its extent). `owner.lo` names
			// the object an appended row belongs to.
			walk.demand_key(q, Q, key_lo, key_hi, s.pos, sp, owner.lo, pend)
		}
		when .Path in Q {
			// `sp` is the object's frame index, so the step that reads its members is `sp - 1`.
			if auto_key(s, q, Q, int(sp) - 1, key_lo, key_hi) {
				wild_key(q, s.src, key_lo, key_hi, sp)
			}
		}
	} else {
		next, err = expect_colon(s, cur, Q)
	}
	return
}

// The colon between a key and its value, and the whitespace around it. A missing colon is Truncated at end
// of input and Bad_Char otherwise. `next` is the byte after the whitespace.
@(private)
expect_colon :: #force_inline proc(s: ^Scanner, cur: ^$C, $Q: bit_set[Walk_Kind]) -> (next: int, err: Maybe(Error)) {
	// Fast path for a colon flush against its value, as in a compact document: `s.pos + 1 < n` keeps the
	// next byte in bounds and a byte above 0x20 is not whitespace. Every other shape falls through, which
	// keeps the error offsets unchanged. A JSONC `/` there may open a comment, so that walk skips it.
	when C != Jsonc_Cursor {
		#no_bounds_check {
			n := u64(len(s.src))
			when C == Pretty_Cursor {
				if s.pos < n && s.src[s.pos] == ' ' {
					s.pos += 1
				}
			}
			if s.pos + 1 < n && s.src[s.pos] == ':' {
				after := s.src[s.pos + 1]
				if after > ' ' {
					s.pos += 1
					cursor_advance(cur)
					return int(after), nil
				}
				// A pretty printer's `": "`.
				when (C == Byte_Cursor && .Nodes in Q) || C == Pretty_Cursor {
					if after == ' ' && s.pos + 2 < n {
						after = s.src[s.pos + 2]
						if after > ' ' {
							s.pos += 2
							cursor_advance(cur)
							return int(after), nil
						}
					}
				}
			}
		}
	}
	cursor_skip(s, cur)
	if lex.peek(s) != ':' {
		if lex.peek(s) == -1 {
			return -1, Error{offset = s.pos, kind = .Truncated}
		}
		return -1, Error{offset = s.pos, kind = .Bad_Char}
	}
	s.pos += 1
	cursor_advance(cur)
	return cursor_skip_peek(s, cur), nil
}

// A comma and then a number start: the next element of a compact array of numbers.
@(private)
number_follows :: #force_inline proc(s: ^Scanner) -> bool {
	#no_bounds_check {
		if s.pos + 1 >= u64(len(s.src)) || s.src[s.pos] != ',' {
			return false
		}
		b := s.src[s.pos + 1]
		return b - '0' <= 9 || b == '-'
	}
}

// Runs `cursor_skip_peek` where a pretty printer puts a newline and an indent. The byte cursor first skips the
// indent two spaces at a time (`lex.skip_indent`). Only the row-writing walks do this, as with `": "` in
// `expect_colon` and the indent before a key in `object_key`; in the other walks the extra code adds
// instructions on every compact input. A `Pretty_Cursor` walk, chosen for a document that starts like
// pretty-printed output, predicts the indent from `at` everywhere.
@(private)
indent_skip_peek :: #force_inline proc(s: ^Scanner, cur: ^$C, $Q: bit_set[Walk_Kind], $at: Indent_At) -> int {
	when C == Pretty_Cursor {
		return pretty_skip_peek(s, cur, at)
	} else when C == Byte_Cursor && .Nodes in Q {
		#no_bounds_check {
			if s.pos < u64(len(s.src)) {
				b := s.src[s.pos]
				if b > ' ' {
					return int(b)
				}
				if b == '\n' {
					lex.skip_indent(s)
				}
			}
		}
	}
	return cursor_skip_peek(s, cur)
}
