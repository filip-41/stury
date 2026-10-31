package json

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import "core:unicode"
import core "../core"
import kernel "../core/kernel"

// This file reads JSON5 1.0.0's forms beyond JSON's in a spec with `.Es5`. They are its numbers, strings and escapes,
// unquoted keys and whitespace. A token JSON spells alike is read by JSON's leaf, and a state here runs only where that
// leaf refuses a token or no JSON start matches. JSON5's whitespace is read with the comments (comments.odin).

// `Number_Spelling` names the number grammar a token's `spelling` records. It is JSON's own, a decimal JSON does not
// write (`+1`, `.5`, `5.`), a hexadecimal integer, or `Infinity` or `NaN` with either sign.
Number_Spelling :: enum u16 {
	Json     = 0,
	Decimal  = 2,
	Hex      = 4,
	Infinity = 6,
	Nan      = 8,
}

// A number token's `spelling` holds these fields. Every kind value is even, so bit 0 (`SPELLING_DECODE`) is always
// clear.
//
//	bits 0 to 3   the `Number_Spelling`, whose values are 0, 2, 4, 6 and 8
//	bits 4 to 8   the integer digit count (saturated at 31)
//	bits 9 to 13  the fraction digit count (saturated at 31, 0 for no fraction)
//	bit 14        `NUMBER_EXP`
//
// A pure integer is a decimal with no fraction and no exponent. The reader folds the significand without lexing the
// span.
@(private)
NUMBER_KIND_MASK :: u16(0xF)
@(private)
NUMBER_INT_SHIFT :: 4
@(private)
NUMBER_FRAC_SHIFT :: 9
@(private)
NUMBER_FRAC_MAX :: 31
@(private)
NUMBER_FRAC_MASK :: u16(NUMBER_FRAC_MAX) << NUMBER_FRAC_SHIFT
@(private)
NUMBER_EXP :: u16(1 << 14)
@(private)
NUMBER_DIGITS_MAX :: 31

// Returns the `Number_Spelling` in a token's `spelling`, for a test or a consumer that reads the detail.
number_spelling_of :: #force_inline proc "contextless" (spelling: u16) -> Number_Spelling {
	return Number_Spelling(spelling & NUMBER_KIND_MASK)
}

// Builds the `spelling` of a decimal token from its kind and its integer and fraction digit counts. A pure integer
// has a zero fraction count and no `NUMBER_EXP`.
@(private)
number_spelling :: #force_inline proc "contextless" (kind: Number_Spelling, int_digits, frac_digits: u64) -> u16 {
	n := u16(min(int_digits, u64(NUMBER_DIGITS_MAX)))
	f := u16(min(frac_digits, u64(NUMBER_FRAC_MAX))) << NUMBER_FRAC_SHIFT
	return u16(kind) | n << NUMBER_INT_SHIFT | f
}

// Returns `number_spelling` plus `NUMBER_EXP`, from the walk's counts, without scanning the span again. Cold, since
// only a token with an `e` reaches it.
@(private, cold)
number_spelling_exp :: #force_no_inline proc "contextless" (kind: Number_Spelling, int_digits, frac_digits: u64) -> u16 {
	return number_spelling(kind, int_digits, frac_digits) | NUMBER_EXP
}

// Calls `number5` with `$shape` true for a hook and false for `core.No_Hooks`.
@(private)
number5_h :: #force_inline proc "contextless" (p, end: [^]u8, $H: typeid) -> (q: [^]u8, spelling: u16, kind: core.Fault_Kind) {
	when H == core.No_Hooks {
		return number5(p, end, false)
	} else {
		return number5(p, end, true)
	}
}

// `p` is at a number JSON's leaf refused or read only up to an `x`. Reads the JSON5 number, then what follows it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_number5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, spelling, kind := number5_h(p, end, H)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_value5` is `st_value` for a byte that starts no JSON value. It reads a comment run, one of JSON5's own starts, a
// close bracket after a trailing comma, or faults. A separate state, so `st_value` compiles none of it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_value5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if gap(p, end, S) {
		return #must_tail st_comments_value(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	switch p[0] {
	case '\'':
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case '+', '.', 'I', 'N':
		return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	// An array's close where a value must start follows a comma, or an open bracket and comments.
	if p[0] == ']' && d & 1 == 0 && d >= 2 {
		return #must_tail st_close(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return fault(w, hs, p, .Bad_Char)
}

// `st_key5` is `st_key` for a byte that opens no JSON key. It reads a comment run, the object's close after a trailing
// comma, a single-quoted or unquoted key, then its colon. A byte that starts none of those faults `Bad_Char` with
// detail `.Identifier`.
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
	esc, lax: bool
	kind: core.Fault_Kind
	if p[0] == '\'' {
		q, esc, lax, kind = string_long(w, p, end)
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
	a: core.Action
	if p[0] == '\'' {
		a = emit_string(w, on, &hs, .String, .Key, p, q, string_spelling(esc, lax))
	} else {
		// An unquoted key's token is its bare span, with `SPELLING_QUOTED` clear.
		a = emit(w, on, &hs, .String, .Key, p, q, string_spelling(esc, lax))
	}
	switch a {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// Reads the JSON5 number at `p`, which starts with a sign, a digit, `.`, `I` or `N`. Returns one past it and its
// spelling, or the fault's kind and the byte it is at. A decimal integer part is `0` or starts with a nonzero digit,
// as in JSON, and the integer or the fraction part may be empty, but not both.
@(private)
number5 :: proc "contextless" (p, end: [^]u8, $shape: bool) -> (q: [^]u8, spelling: u16, kind: core.Fault_Kind) #no_bounds_check {
	q = p
	kind5 := Number_Spelling.Json
	if q[0] == '+' {
		kind5 = .Decimal
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
		return q, u16(Number_Spelling.Infinity), kind
	case 'N':
		q, kind = word5(q, end, "NaN")
		return q, u16(Number_Spelling.Nan), kind
	}
	if q[0] == '0' && intrinsics.ptr_sub(end, q) > 1 && q[1] | 0x20 == 'x' {
		r := hex_run(q[2:], end)
		if r == q[2:] {
			q, kind = bad_or_truncated(r, end)
			return q, u16(Number_Spelling.Hex), kind
		}
		return r, u16(Number_Spelling.Hex), .None
	}
	whole := q
	if q[0] == '0' {
		q = q[1:]
		if q < end && q[0] - '0' < 10 {
			return q, u16(kind5), .Bad_Number
		}
	} else {
		q = core.digit_end(q, end, nil, false)
	}
	when shape {
		int_digits := u64(intrinsics.ptr_sub(q, whole))
		frac_digits: u64
	}
	if q < end && q[0] == '.' {
		r := core.digit_end(q[1:], end, nil, false)
		if r == q[1:] || q == whole {
			if r == q[1:] && q == whole {
				q, kind = bad_or_truncated(r, end)
				return q, u16(kind5), kind
			}
			kind5 = .Decimal
		}
		when shape {
			frac_digits = u64(intrinsics.ptr_sub(r, q[1:]))
		}
		q = r
	} else if q == whole {
		q, kind = bad_or_truncated(q, end)
		return q, u16(kind5), kind
	}
	if q < end && q[0] | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := core.digit_end(q, end, nil, false)
		if r == q {
			q, kind = bad_or_truncated(r, end)
			return q, u16(kind5), kind
		}
		when shape {
			return r, number_spelling_exp(kind5, int_digits, frac_digits), .None
		}
		q = r
	}
	when shape {
		return q, number_spelling(kind5, int_digits, frac_digits), .None
	}
	return q, u16(kind5), .None
}

// Returns the lanes of `v` that are a hex digit: `0` to `9`, or `a` to `f` in either case.
@(private)
hex_digits :: #force_inline proc "contextless" (v: #simd[16]u8) -> #simd[16]u8 {
	K :: #simd[16]u8
	lower := v | 0x20
	return simd.bit_or(
		simd.bit_and(simd.lanes_ge(v, K('0')), simd.lanes_le(v, K('9'))),
		simd.bit_and(simd.lanes_ge(lower, K('a')), simd.lanes_le(lower, K('f'))),
	)
}

// Returns the end of the run of hex digits at `p`, 16 bytes a step while 16 remain.
@(private)
hex_run :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for intrinsics.ptr_sub(end, q) >= 16 {
		// The first lane that holds no hex digit.
		k := kernel.first_lane(~hex_digits(load16(q)))
		if k != 16 {
			return q[k:]
		}
		q = q[16:]
	}
	for q < end && core.HEX_NIBBLE[q[0]] != 0xff {
		q = q[1:]
	}
	return q
}

// Reads `word` at `p`, which starts with its first letter. Returns one past it, or `Bad_Number` at the first byte
// that differs, `Truncated` at the text's end.
@(private)
word5 :: proc "contextless" (p, end: [^]u8, word: string) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	ok: bool
	q, ok = word_end(p, end, word)
	if ok {
		return q, .None
	}
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Number
}

// Reads the JSON5 string whose opening quote, `"` or `'`, is at `p`, one byte at a time. Returns one past its closing
// quote, whether it holds an escape and whether `tol` accepted an ill-formed sequence, or the fault at the first byte
// that breaks it. Every byte but the quote, a backslash, CR and LF is a character of the string.
@(private, cold)
string5 :: #force_no_inline proc "contextless" (p, end: [^]u8, tol: bit_set[Tolerance; u8]) -> (q: [^]u8, esc, lax: bool, kind: core.Fault_Kind) #no_bounds_check {
	quote := p[0]
	q = p[1:]
	for {
		if q >= end {
			return end, false, false, .Truncated
		}
		c := q[0]
		switch {
		case c == quote:
			return q[1:], esc, lax, .None
		case c == '\\':
			esc = true
			if q[1:] < end && utf8_taken(q[1:], end, tol) {
				lax = true
			}
			if q, kind = escape5(q, end, tol); kind != .None {
				return q, false, false, kind
			}
		case c == '\n' || c == '\r':
			return q, false, false, .Bad_Char
		case c < 0x80:
			q = q[1:]
		case:
			if utf8_taken(q, end, tol) {
				lax = true
			}
			if q, kind = utf8_lax(q, end, tol); kind != .None {
				return q, false, false, kind
			}
		}
	}
}

// Steps over the JSON5 escape at the backslash `e`: `\0` before no digit, `\x` and two hex digits, a backslash before
// a line end (CR LF counts as one), JSON's `\u` escape with its surrogate halves paired, and a backslash before any
// character but a digit, which spells that character. A digit after `\0`, and `\1` to `\9`, fault `Bad_Escape` at the
// digit. `tol` is the walk's tolerances.
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
			if core.HEX_NIBBLE[q[i]] == 0xff {
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

// Reads one character of an identifier at `q` that is no ASCII identifier byte: a `\u` escape or a UTF-8 character,
// which `r` steps past, or the fault. `r` is `q` when the character may not be there, which ends the identifier. `esc`
// reports whether the character was an escape.
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
			if core.HEX_NIBBLE[q[i]] == 0xff {
				return q[i:], false, .Bad_Escape
			}
		}
		unit, _ := core.hex4(q[2:])
		r = q[6:]
		if !ident_char(rune(unit), start) {
			return q, false, .Bad_Escape
		}
		return r, true, .None
	}
	r, kind = kernel.utf8_char(q, end)
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

// Reads the unquoted key at `p`, an ECMAScript 5.1 IdentifierName. Returns one past it and whether it holds a `\u`
// escape, or `p` when no identifier starts there. It ends before the first character that cannot continue it. A
// malformed `\u` escape, or one that writes a character not allowed there, faults `Bad_Escape`, and malformed UTF-8
// faults `Bad_Char` as in a string.
@(private)
ident5 :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
	q = p
	// The first character, where a digit may not be, is read apart from the rest, so the loop after it has no test for
	// the start.
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

// Whether `r` may be in an identifier. As the first character it is a letter (Lu, Ll, Lt, Lm, Lo, Nl), `$` or `_`.
// Later it may also be a mark (Mn, Mc), a decimal digit (Nd), a connector (Pc), ZWNJ or ZWJ.
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

// The `IDENT` value for a decimal digit, 2. `IDENT` holds 1 for a letter, `$` or `_` and 2 for a digit.
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

// Returns the length in bytes of the JSON5 whitespace character at `p` that JSON lacks: VT, FF, U+00A0, U+FEFF,
// U+2028, U+2029 and the other characters of Zs. Returns 0 for any other byte.
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

// Whether `p` is at U+2028 or U+2029, which end a line in JSON5.
@(private)
line_sep5 :: #force_inline proc "contextless" (p, end: [^]u8) -> bool #no_bounds_check {
	return intrinsics.ptr_sub(end, p) >= 3 && p[0] == 0xe2 && p[1] == 0x80 && p[2] | 1 == 0xa9
}
