package json

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import "core:unicode"
import core "../core"
import kernel "../core/kernel"

// JSON5 1.0.0's forms past JSON's, in a spec with `.Es5`: its numbers, its strings and their escapes, its unquoted
// keys and its whitespace. A token JSON spells alike is read by JSON's own leaf: a state comes here only where that
// leaf refuses a token or none of JSON's starts. JSON5's whitespace is read with the comments (comments.odin).

// What a number token's `spelling` says: JSON's own grammar, a decimal JSON does not write (`+1`, `.5`, `5.`), a
// hexadecimal integer, or `Infinity` or `NaN` with any sign.
Number_Spelling :: enum u16 {
	Json,
	Decimal,
	Hex,
	Infinity,
	Nan,
}

// `p` stands on a number JSON's leaf refused, or read only up to an `x`: the JSON5 number, then what follows it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_number5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, spelling, kind := number5(p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .Number, .Value, p, q, u16(spelling)) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` stands on a single-quoted value string.
@(private, enable_target_feature = STATE_FEATURES)
st_string5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, esc, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .String, .Value, p, q, u16(esc)) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_value` on a byte that starts no JSON value: a comment run, one of JSON5's own starts, a close bracket after a
// trailing comma, or the fault. Its own state, so `st_value` holds none of it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_value5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if gap(p, end, S) {
		return #must_tail st_comments_value(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	switch p[0] {
	case '\'':
		return #must_tail st_string5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case '+', '.', 'I', 'N':
		return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	// An array's close where a value must start follows a comma, or an open bracket and comments.
	if p[0] == ']' && d & 1 == 0 && d >= 2 {
		return #must_tail st_close(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return fault(w, hs, p, .Bad_Char)
}

// `p` stands where an object's key must start, on a byte that opens no JSON key: a comment run, the object's close
// after a trailing comma, a single-quoted key or an unquoted one, then its colon. A byte that starts none of those is
// `Bad_Char` with `.Identifier`.
@(private, enable_target_feature = STATE_FEATURES)
st_key5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if gap(p, end, S) {
		return #must_tail st_comments_key(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if p[0] == '}' {
		return #must_tail st_close(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	q: [^]u8
	esc: bool
	kind: core.Fault_Kind
	if p[0] == '\'' {
		q, esc, kind = string_long(w, p, end)
		if kind != .None {
			return fault(w, hs, q, kind)
		}
	} else {
		q, esc, kind = ident5(p, end)
		if kind != .None {
			return fault(w, hs, q, kind)
		}
		if q == p {
			return fault(w, hs, p, .Bad_Char, .Identifier)
		}
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	switch emit(w, on, &hs, .String, .Key, p, q, u16(esc)) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// The JSON5 number at `p`, which starts with a sign, a digit, `.`, `I` or `N`: one past it and its spelling, or the
// fault's kind and the byte it is at. A decimal integer part is `0` or starts with a nonzero digit, as in JSON, and
// either the integer or the fraction part may be empty, not both.
@(private)
number5 :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, spelling: Number_Spelling, kind: core.Fault_Kind) #no_bounds_check {
	q = p
	if q[0] == '+' {
		spelling = .Decimal
	}
	if q[0] == '+' || q[0] == '-' {
		q = q[1:]
		if q >= end {
			return end, spelling, .Truncated
		}
	}
	switch q[0] {
	case 'I':
		q, kind = word5(q, end, "Infinity")
		return q, .Infinity, kind
	case 'N':
		q, kind = word5(q, end, "NaN")
		return q, .Nan, kind
	}
	if q[0] == '0' && intrinsics.ptr_sub(end, q) > 1 && q[1] | 0x20 == 'x' {
		r := hex_run(q[2:], end)
		if r == q[2:] {
			q, kind = bad_or_truncated(r, end)
			return q, .Hex, kind
		}
		return r, .Hex, .None
	}
	whole := q
	if q[0] == '0' {
		q = q[1:]
		if q < end && q[0] - '0' < 10 {
			return q, spelling, .Bad_Number
		}
	} else {
		q = digit_run(q, end)
	}
	if q < end && q[0] == '.' {
		r := digit_run(q[1:], end)
		if r == q[1:] || q == whole {
			if r == q[1:] && q == whole {
				q, kind = bad_or_truncated(r, end)
				return q, spelling, kind
			}
			spelling = .Decimal
		}
		q = r
	} else if q == whole {
		q, kind = bad_or_truncated(q, end)
		return q, spelling, kind
	}
	if q < end && q[0] | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := digit_run(q, end)
		if r == q {
			q, kind = bad_or_truncated(r, end)
			return q, spelling, kind
		}
		q = r
	}
	return q, spelling, .None
}

// The lanes of `v` that are a hex digit: a decimal digit, or `a` to `f` in either case.
@(private)
hex_digits :: #force_inline proc "contextless" (v: #simd[16]u8) -> #simd[16]u8 {
	K :: #simd[16]u8
	lower := v | 0x20
	return simd.bit_or(
		simd.bit_and(simd.lanes_ge(v, K('0')), simd.lanes_le(v, K('9'))),
		simd.bit_and(simd.lanes_ge(lower, K('a')), simd.lanes_le(lower, K('f'))),
	)
}

// The end of the run of hex digits at `p`: 16 bytes a step while 16 remain.
@(private)
hex_run :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for intrinsics.ptr_sub(end, q) >= 16 {
		// The first lane no digit stands in.
		k := kernel.first_lane(~hex_digits(load16(q)))
		if k != 16 {
			return q[k:]
		}
		q = q[16:]
	}
	for q < end && HEX[q[0]] != 0xff {
		q = q[1:]
	}
	return q
}

// The word at `p`, which starts with its first letter: one past it, or `Bad_Number` at the first byte that breaks it.
@(private)
word5 :: proc "contextless" (p, end: [^]u8, word: string) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	for i in 0 ..< len(word) {
		q = p[i:]
		if q >= end {
			return end, .Truncated
		}
		if q[0] != word[i] {
			return q, .Bad_Number
		}
	}
	return p[len(word):], .None
}

// The JSON5 string whose opening quote, `"` or `'`, is at `p`, read byte by byte: one past its closing quote and
// whether it holds an escape, or the fault at the first byte that breaks it, unless `tol` takes it. Every character
// but its quote, a backslash, CR and LF stands for itself.
@(private, cold)
string5 :: #force_no_inline proc "contextless" (p, end: [^]u8, tol: bit_set[Tolerance; u8]) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
	quote := p[0]
	q = p[1:]
	for {
		if q >= end {
			return end, false, .Truncated
		}
		c := q[0]
		switch {
		case c == quote:
			return q[1:], esc, .None
		case c == '\\':
			esc = true
			if q, kind = escape5(q, end, tol); kind != .None {
				return q, false, kind
			}
		case c == '\n' || c == '\r':
			return q, false, .Bad_Char
		case c < 0x80:
			q = q[1:]
		case:
			if q, kind = utf8_lax(q, end, tol); kind != .None {
				return q, false, kind
			}
		}
	}
}

// The JSON5 escape at the backslash `e`, stepped over: `\0` before no digit, `\x` and two hex digits, a backslash
// before a line end (CR LF is one), JSON's `\u` escape with its surrogate halves paired, and a backslash before any
// other character but a digit, which stands for that character. A digit after `\0`, and `\1` to `\9`, are
// `Bad_Escape` at the digit. `tol` is the walk's tolerances.
@(private)
escape5 :: proc "contextless" (e, end: [^]u8, tol: bit_set[Tolerance; u8]) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	q = e[1:]
	if q >= end {
		return end, .Truncated
	}
	c := q[0]
	switch {
	case c == 'u':
		return escape_exact(e, end, tol)
	case c == 'x':
		for i in 1 ..= 2 {
			if q[i:] >= end {
				return end, .Truncated
			}
			if HEX[q[i]] == 0xff {
				return q[i:], .Bad_Escape
			}
		}
		return q[3:], .None
	case c == '0':
		if intrinsics.ptr_sub(end, q) > 1 && q[1] - '0' < 10 {
			return q[1:], .Bad_Escape
		}
		return q[1:], .None
	case c - '1' < 9:
		return q, .Bad_Escape
	case c == '\r':
		if intrinsics.ptr_sub(end, q) > 1 && q[1] == '\n' {
			return q[2:], .None
		}
		return q[1:], .None
	case c < 0x80:
		return q[1:], .None
	}
	return utf8_lax(q, end, tol)
}

// One character of an identifier at `q` that is no ASCII identifier byte: a `\u` escape or a UTF-8 character, which
// `r` steps past, or the fault. `r` is `q` when the character may not stand there, which ends the identifier, and
// `esc` says whether the character was an escape.
@(private)
ident5_char :: #force_inline proc "contextless" (q, end: [^]u8, start: bool) -> (r: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
	c := q[0]
	if c == '\\' {
		if intrinsics.ptr_sub(end, q) < 2 {
			return end, false, .Truncated
		}
		if q[1] != 'u' {
			return q[1:], false, .Bad_Escape
		}
		for i in 2 ..< 6 {
			if q[i:] >= end {
				return end, false, .Truncated
			}
			if HEX[q[i]] == 0xff {
				return q[i:], false, .Bad_Escape
			}
		}
		unit, _ := hex4(q[2:])
		r = q[6:]
		if !ident_char(rune(unit), start) {
			return q, false, .Bad_Escape
		}
		return r, true, .None
	}
	r, kind = utf8_char(q, end)
	if kind != .None {
		return r, false, kind
	}
	ch := rune(c & (0x7f >> u8(intrinsics.ptr_sub(r, q))))
	for b in q[1:intrinsics.ptr_sub(r, q)] {
		ch = ch << 6 | rune(b & 0x3f)
	}
	if !ident_char(ch, start) {
		return q, false, .None
	}
	return r, false, .None
}

// The unquoted key at `p`, an ECMAScript 5.1 IdentifierName: one past it and whether it holds a `\u` escape, or `p`
// when no identifier starts there. It ends before the first character that cannot go on with it. A `\u` escape that
// is malformed, or writes no character the identifier may have there, is `Bad_Escape`, and malformed UTF-8 is
// `Bad_Char` as in a string.
@(private)
ident5 :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
	q = p
	// The first character, where a digit may not stand, is read apart from the run: the loop after it holds no test
	// for the start.
	if q < end {
		c := q[0]
		if c < 0x80 && c != '\\' {
			if IDENT[c] == 0 || IDENT[c] == IDENT_DIGIT {
				return
			}
			q = q[1:]
		} else {
			r, e, k := ident5_char(q, end, true)
			if k != .None {
				return r, e, k
			}
			if r == q {
				return
			}
			q, esc = r, e
		}
	}
	for q < end {
		c := q[0]
		if c < 0x80 && c != '\\' {
			if IDENT[c] == 0 {
				return q, esc, .None
			}
			q = q[1:]
			continue
		}
		r, e, k := ident5_char(q, end, false)
		if k != .None {
			return r, esc, k
		}
		if r == q {
			return q, esc, .None
		}
		q, esc = r, esc || e
	}
	return
}

// Whether `r` may stand in an identifier: first a letter (Lu, Ll, Lt, Lm, Lo, Nl), `$` or `_`, after that also a mark
// (Mn, Mc), a decimal digit (Nd), a connector (Pc), ZWNJ or ZWJ.
@(private, cold)
ident_char :: #force_no_inline proc "contextless" (r: rune, start: bool) -> bool {
	context = runtime.default_context()
	if r == '$' || r == '_' || unicode.is_letter(r) || unicode.in_range(r, unicode.nl_ranges) {
		return true
	}
	if start {
		return false
	}
	if r == 0x200c || r == 0x200d {
		return true
	}
	return unicode.in_range(r, unicode.mn_ranges) || unicode.in_range(r, unicode.mc_ranges) || unicode.in_range(r, unicode.nd_ranges) || unicode.in_range(r, unicode.pc_ranges)
}

// The ASCII bytes of an identifier: a letter, `$` and `_` anywhere, a digit after its first character.
@(private)
IDENT_DIGIT :: 2

@(private, rodata)
IDENT := [128]u8 {
	'a' ..= 'z' = 1,
	'A' ..= 'Z' = 1,
	'$' = 1,
	'_' = 1,
	'0' ..= '9' = IDENT_DIGIT,
}

// The length of the JSON5 whitespace character at `p` that JSON lacks: VT, FF, U+00A0, U+FEFF, U+2028, U+2029 and the
// other characters of Zs. 0 for any other.
@(private)
ws5_len :: proc "contextless" (p, end: [^]u8) -> int #no_bounds_check {
	room := intrinsics.ptr_sub(end, p)
	if room < 1 {
		return 0
	}
	switch p[0] {
	case 0x0b, 0x0c:
		return 1
	case 0xc2:
		if room >= 2 && p[1] == 0xa0 {
			return 2
		}
	case 0xe1:
		if room >= 3 && p[1] == 0x9a && p[2] == 0x80 {
			return 3
		}
	case 0xe2:
		if room >= 3 && (p[1] == 0x80 && (p[2] - 0x80 <= 0x0a || p[2] == 0xa8 || p[2] == 0xa9 || p[2] == 0xaf) || p[1] == 0x81 && p[2] == 0x9f) {
			return 3
		}
	case 0xe3:
		if room >= 3 && p[1] == 0x80 && p[2] == 0x80 {
			return 3
		}
	case 0xef:
		if room >= 3 && p[1] == 0xbb && p[2] == 0xbf {
			return 3
		}
	}
	return 0
}

// Whether `p` stands on U+2028 or U+2029, which end a line in JSON5.
@(private)
line_sep5 :: #force_inline proc "contextless" (p, end: [^]u8) -> bool #no_bounds_check {
	return intrinsics.ptr_sub(end, p) >= 3 && p[0] == 0xe2 && p[1] == 0x80 && p[2] | 1 == 0xa9
}
