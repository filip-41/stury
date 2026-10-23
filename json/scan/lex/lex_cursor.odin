package lex

// JSON lexing: whitespace, wire UTF-8, and where an unchecked value ends.

import "base:intrinsics"
import "core:simd"
import core_pkg "../../../core"

peek :: #force_inline proc(s: ^Scanner) -> int {
	if s.pos >= u64(len(s.src)) {
		return -1
	}
	return int(s.src[s.pos])
}

// Skip JSON whitespace. One byte at a time, through `CHAR_FLAGS`: the set is
// exactly {9, 10, 13, 32}, so a control byte is a fault and is not skipped.
// Every whitespace byte is <= 0x20, so a byte above that ends the run without
// the table load.
skip_ws :: #force_inline proc(s: ^Scanner) {
	#no_bounds_check {
		n := u64(len(s.src))
		for s.pos < n {
			c := s.src[s.pos]
			if c > ' ' || CHAR_FLAGS[c] & F_WS == 0 {
				break
			}
			s.pos += 1
		}
	}
}

// A newline and the pairs of spaces after it, as a pretty printer indents a line. What is left is
// `skip_ws`'s. Two bytes a step, each step a predicted branch: the indent's width is a pattern the
// branch predictor learns, where a width counted from the loaded bytes would put a load on every
// step's address.
skip_indent :: #force_inline proc(s: ^Scanner) {
	#no_bounds_check {
		n := u64(len(s.src))
		if s.pos < n && s.src[s.pos] == '\n' {
			s.pos += 1
			for s.pos + 2 <= n && intrinsics.unaligned_load((^u16le)(&s.src[s.pos])) == 0x2020 {
				s.pos += 2
			}
		}
	}
}

// The widest indent `spaces_lead` judges, and the bytes it reads.
LEAD_MAX :: 32
@(rodata, private = "file")
LEAD_MASK := [2 * LEAD_MAX]u8{0 ..< LEAD_MAX = 0xFF}

// Whether the `k` bytes at `at` are all spaces, for `k < LEAD_MAX` and LEAD_MAX bytes readable there. A
// mask compare with no count, so the bytes feed only the caller's branch and no address waits on them.
spaces_lead :: #force_inline proc(src: []byte, at, k: u64) -> bool {
	V :: #simd[16]u8
	#no_bounds_check {
		p := ([^]u8)(&src[at])
		m := ([^]u8)(&LEAD_MASK[LEAD_MAX - k])
		a := simd.bit_and(simd.bit_xor(intrinsics.unaligned_load((^V)(p)), V(' ')), intrinsics.unaligned_load((^V)(m)))
		b := simd.bit_and(simd.bit_xor(intrinsics.unaligned_load((^V)(p[16:])), V(' ')), intrinsics.unaligned_load((^V)(m[16:])))
		// `reduce_max`, not `reduce_or`: NEON has a max across lanes, where an or folds through scalar shifts.
		return simd.reduce_max(simd.bit_or(a, b)) == 0
	}
}

// `skip_peek` for a pretty-printed document: the first non-whitespace byte, or -1 at end of input. A
// byte above a space returns at once. A newline is followed by its indent (`skip_indent`), a space by one
// more byte; what is left is `skip_ws`'s.
skip_peek_pretty :: #force_inline proc(s: ^Scanner) -> int {
	#no_bounds_check {
		n := u64(len(s.src))
		if s.pos < n {
			b := s.src[s.pos]
			if b > ' ' {
				return int(b)
			}
			if b == '\n' {
				skip_indent(s)
			} else if b == ' ' {
				s.pos += 1
			}
			if s.pos < n && s.src[s.pos] > ' ' {
				return int(s.src[s.pos])
			}
		}
	}
	return skip_peek(s)
}

// `skip_ws` then `peek`: the first non-whitespace byte, or -1 at end of input.
skip_peek :: #force_inline proc(s: ^Scanner) -> int {
	skip_ws(s)
	return peek(s)
}

// Strict UTF-8 scalar step (RFC 3629): validates the one character starting
// at pos. Caller guarantees pos < n and src[pos] >= 0x80. Wire-level validity
// holds at every strictness level — only grammar is strictness-gated,
// so Structural and skip paths validate bytes exactly like Strict does.
//
// The first read, `c := src[pos]`, stays checked: its bound is the caller's
// promise, so a caller that got `pos < n` wrong traps here instead of reading
// outside the document. Every later read sits inside a band that opens with
// `if pos + W > n { return 0, .Truncated }`, and Odin does not elide a check
// from a dominating guard, so `#no_bounds_check` states what that guard proved.
@(private = "file")
Utf8_Step :: enum { Ok, Malformed, Truncated }
@(private = "file")
utf8_step :: #force_inline proc(src: []byte, pos, n: u64) -> (length: u64, outcome: Utf8_Step) {
	c := src[pos]
	if c < 0xC2 {
		return 0, .Malformed // stray continuation, C0, C1
	}
	#no_bounds_check {
		// PRE, restated per band and proved by the guard at the top of it:
		//   band 1 (below): `pos + 2 <= n`   so `src[pos+1]` is inside `src`
		//   band 2:          `pos + 3 <= n`   so `src[pos+1]`, `src[pos+2]` are
		//   band 3:          `pos + 4 <= n`   so `src[pos+1]` and `load32_le(src,pos)` are
		// `n` is `len(src)` at the one call site (`utf8_step_checked`), so `n <= len(src)`
		// holds by construction rather than by promise.
		if c < 0xE0 {
			if pos + 2 > n {
				return 0, .Truncated
			}
			if src[pos + 1] & 0xC0 != 0x80 { // one mask, not two range compares
				return 0, .Malformed
			}
			return 2, .Ok
		}
		if c < 0xF0 {
			if pos + 3 > n {
				return 0, .Truncated
			}
			c1 := src[pos + 1]
			if c == 0xE0 && c1 < 0xA0 {
				return 0, .Malformed // overlong
			}
			if c == 0xED && c1 > 0x9F {
				return 0, .Malformed // surrogate half
			}
			// Both continuations under one mask: RFC 3629 constrains only the two
			// leading bits. The loads stay inside the `pos + 3 > n` bound above.
			w2 := u32(c1) | u32(src[pos + 2]) << 8
			if w2 & 0xC0C0 != 0x8080 {
				return 0, .Malformed
			}
			return 3, .Ok
		}
		if c <= 0xF4 {
			if pos + 4 > n {
				return 0, .Truncated
			}
			c1 := src[pos + 1]
			if c == 0xF0 && c1 < 0x90 {
				return 0, .Malformed // overlong
			}
			if c == 0xF4 && c1 > 0x8F {
				return 0, .Malformed // past U+10FFFF
			}
			w := load32_le(src, pos) // the lead `c` is masked out of the low byte
			if w & 0xC0C0C000 != 0x80808000 {
				return 0, .Malformed
			}
			return 4, .Ok
		}
	}
	return 0, .Malformed // F5..FF can never lead
}

// The input ends inside the sequence `src[pos]` leads. That is `Truncated`
// only while every byte present could still continue it. A byte that cannot is
// `Bad_Char` at the lead, because no appended input repairs it. Same per-byte
// rules as `utf8_step`, including the second byte's range for E0, ED, F0 and
// F4. Kept out of line: `utf8_step_checked` is inlined on the string hot path.
@(cold)
@(private = "file")
utf8_short_error :: proc(src: []byte, pos: u64) -> Error {
	c := src[pos]
	for i in pos + 1 ..< u64(len(src)) {
		b := src[i]
		bad := b & 0xC0 != 0x80
		if i == pos + 1 {
			bad ||= c == 0xE0 && b < 0xA0 || c == 0xED && b > 0x9F || c == 0xF0 && b < 0x90 || c == 0xF4 && b > 0x8F
		}
		if bad {
			return Error{offset = pos, kind = .Bad_Char}
		}
	}
	return Error{offset = u64(len(src)), kind = .Truncated}
}

// One UTF-8 scalar, validated and consumed, with the wire-validity result the
// scanner reports: a malformed sequence is Bad_Char at its lead byte, running
// out of input is Truncated at end of source, unless a byte already present
// rules the sequence out. Caller guarantees pos < n and
// src[pos] >= 0x80.
utf8_step_checked :: #force_inline proc(s: ^Scanner) -> Maybe(Error) {
	length, outcome := utf8_step(s.src, s.pos, u64(len(s.src)))
	if outcome == .Malformed {
		return Error{offset = s.pos, kind = .Bad_Char}
	}
	if outcome == .Truncated {
		return utf8_short_error(s.src, s.pos)
	}
	s.pos += length
	return nil
}

// Where a value the walk leaves unvisited ends, without checking any of it, or
// -1 when it has no end. The ends are stage 1's token ends, so the index and
// the bytes leave a skip at the same byte: a backslash escapes the next byte
// everywhere, which only decides whether a quote opens or closes a string,
// and a bracket counts only outside strings.
//
// A container ends at its matching bracket. It has none when the source ends
// first, a bracket of the other kind closes first, or nesting passes `room`
// levels counting its own.
value_end :: #force_inline proc(src: []u8, lo: int, vc: u8, room: int) -> int {
	return value_end_at(src, lo, vc, room, .Values)
}

// `value_end` at the check level `check`. At `.Locate` a string or scalar byte >= 0x80 is judged where it is
// passed, and a malformed sequence leaves the value with no end, for the read to fault on. That is the byte
// loops alone, so only the byte cursor asks for it (`SCAN_FORCE_SLOW`); the index judges the bytes it
// classifies.
value_end_at :: proc(src: []u8, lo: int, vc: u8, room: int, $check: Check_Level) -> int {
	switch vc {
	case VC_OBJECT, VC_ARRAY:
		return container_end(src, lo, min(room, core_pkg.MAX_DEPTH), check)
	case VC_STRING:
		return string_end_at(src, lo, check)
	}
	return scalar_end(src, lo, check)
}

// Past the string opened at `open`, its bytes unchecked, or -1 when no quote closes it. Sixteen bytes at a
// time while they remain: a window with no quote or backslash is string, and at the first one a backslash
// takes the byte after it. `string_end_at` at `.Locate` also judges UTF-8, a byte at a time.
string_end :: #force_inline proc(src: []u8, open: int) -> int {
	return string_end_at(src, open, .Values)
}

@(private = "file")
string_end_at :: proc(src: []u8, open: int, $check: Check_Level) -> int {
	when check == .Locate {
		#assert(SCAN_FORCE_SLOW, "the vector loop does not judge UTF-8")
	}
	i := open + 1
	when !SCAN_FORCE_SLOW {
		qv: #simd[16]u8 = '"'
		bv: #simd[16]u8 = '\\'
		#no_bounds_check for i + 16 <= len(src) {
			v := load16(src, u64(i))
			stop := simd.lanes_eq(v, qv) | simd.lanes_eq(v, bv)
			if !any_lane(stop) {
				i += 16
				continue
			}
			i += int(first_stop_lane(stop))
			if src[i] == '"' {
				return i + 1
			}
			i += 2
		}
	}
	#no_bounds_check for i < len(src) {
		switch src[i] {
		case '\\':
			i += 2
		case '"':
			return i + 1
		case:
			when check == .Locate {
				if src[i] >= 0x80 {
					length, outcome := utf8_step(src, u64(i), u64(len(src)))
					if outcome != .Ok {
						return -1
					}
					i += int(length)
					continue
				}
			}
			i += 1
		}
	}
	return -1
}

@(private = "file")
scalar_end :: proc(src: []u8, lo: int, $check: Check_Level) -> int {
	esc := false
	i := lo
	#no_bounds_check for ; i < len(src); i += 1 {
		b := src[i]
		if CHAR_FLAGS[b] & (F_WS | F_BRACKET) != 0 || b == ',' || b == ':' || (b == '"' && !esc) {
			break
		}
		when check == .Locate {
			if b >= 0x80 {
				length, outcome := utf8_step(src, u64(i), u64(len(src)))
				if outcome != .Ok {
					return -1
				}
				i += int(length) - 1
			}
		}
		esc = b == '\\' && !esc
	}
	return i
}

@(private = "file")
container_end :: proc(src: []u8, open: int, room: int, $check: Check_Level) -> int {
	is_obj: [core_pkg.MAX_DEPTH]bool = ---
	depth := 0
	esc := false
	i := open
	// `src[open]` is `{` or `[` (`value_end` takes `vc` from that byte), so `depth >= 1` at every close.
	// Pushes stop at `room`, `0 <= room <= MAX_DEPTH` (the walk refuses `sp >= max_depth`).
	#no_bounds_check for i < len(src) {
		b := src[i]
		if b == '"' && !esc {
			i = string_end_at(src, i, check)
			if i < 0 {
				return -1
			}
			continue
		}
		if b | 0x20 == '{' {
			if depth == room {
				return -1
			}
			is_obj[depth] = b == '{'
			depth += 1
		} else if b | 0x20 == '}' {
			depth -= 1
			if is_obj[depth] != (b == '}') {
				return -1
			}
			if depth == 0 {
				return i + 1
			}
		}
		esc = b == '\\' && !esc
		i += 1
	}
	return -1
}
