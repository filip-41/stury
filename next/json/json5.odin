package json

import "base:intrinsics"
import "base:runtime"
import "core:unicode"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// JSON5 1.0.0's forms past JSON's, in a spec with `.Es5`: its numbers, strings and escapes, unquoted keys and white
// space. A token JSON spells alike is read by JSON's states, and a state here runs only where they refuse a byte.

// The length of the JSON5 white space character at `p` that JSON lacks: VT, FF, U+00A0, U+FEFF, U+2028, U+2029 and the
// rest of Zs; 0 for any other.
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

// The number grammar a JSON5 number token's spelling records in its `tape.NUMBER_KIND` bits: JSON's, a decimal JSON
// does not allow (`+1`, `.5`, `5.`), hex, `Infinity` or `NaN`.
@(private)
Number_Spelling :: enum u16 {
	Json     = 0,
	Decimal  = 2,
	Hex      = 4,
	Infinity = 6,
	Nan      = 8,
}

#assert(u16(max(Number_Spelling)) <= tape.NUMBER_KIND)

// The spelling bit of a JSON5 string or key that holds an escape JSON lacks, which `node_text` decodes with `decode5`.
@(private)
SPELLING_JSON5 :: u16(8)

// The state at a JSON5 number that JSON's grammar refused, or that starts with `+`, `.`, `I` or `N`.
@(private, enable_target_feature = STATE_FEATURES)
st_number5 :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, spelling, kind := number5(p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The end and spelling of the JSON5 number at `p`, or the fault and the byte it is at. Past JSON's grammar it may start
// with `+`, be hex, `Infinity` or `NaN`, and have an empty integer or fraction part, but not both.
@(private)
number5 :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) #no_bounds_check {
	q = p
	k := Number_Spelling.Json
	if q[0] == '-' || q[0] == '+' {
		if q[0] == '+' {
			k = .Decimal
		}
		q = q[1:]
		if q >= end {
			return end, 0, .Truncated
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
		r := spell.hex_digit_end(q[2:], end)
		if r == q[2:] {
			q, kind = bad_or_truncated(r, end)
			return q, 0, kind
		}
		return r, u16(Number_Spelling.Hex), .None
	}
	int_at := q
	if q[0] == '0' {
		q = q[1:]
		if q < end && q[0] - '0' < 10 {
			return q, 0, .Bad_Number
		}
	} else {
		r := spell.digit_end(q, end)
		if r == q && q[0] != '.' {
			return q, 0, .Bad_Number
		}
		q = r
	}
	int_digits := u64(intrinsics.ptr_sub(q, int_at))
	frac_digits: u64
	if q >= end {
		return q, tape.number_spelling(u16(k), int_digits, 0), .None
	}
	c := q[0]
	if c == '.' {
		r := spell.digit_end(q[1:], end)
		if r == q[1:] || q == int_at {
			if r == q[1:] && q == int_at {
				q, kind = bad_or_truncated(r, end)
				return q, 0, kind
			}
			k = .Decimal
			if r == q[1:] && (r >= end || r[0] | 0x20 != 'e') {
				return r, tape.number_spelling(u16(k), int_digits, 0) | tape.NUMBER_POINT, .None
			}
		}
		frac_digits = u64(intrinsics.ptr_sub(r, q[1:]))
		q = r
		if q >= end {
			return q, tape.number_spelling(u16(k), int_digits, frac_digits), .None
		}
		c = q[0]
	}
	if c | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := spell.digit_end(q, end)
		if r == q {
			q, kind = bad_or_truncated(r, end)
			return q, 0, kind
		}
		return r, tape.number_spelling(u16(k), int_digits, frac_digits) | tape.NUMBER_EXP, .None
	}
	return q, tape.number_spelling(u16(k), int_digits, frac_digits), .None
}

// One past `word` at `p`, or the fault: `Bad_Number` at the first byte that differs, `Truncated` at the text's end.
@(private)
word5 :: proc "contextless" (p, end: [^]u8, word: string) -> (q: [^]u8, kind: tape.Fault_Kind) #no_bounds_check {
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

// One past the JSON5 escape at the backslash `e`, or the fault. Valid are `\0` before no digit, `\x` and two hex
// digits, a backslash before a line end (CR LF as one), a `\u` escape with its surrogate halves paired, and a backslash
// before any other character but a digit, which spells that character. A digit after `\0`, and `\1` to `\9`, fault
// `Bad_Escape` at the digit.
@(private)
escape5 :: proc "contextless" (e, end: [^]u8) -> (q: [^]u8, kind: tape.Fault_Kind) #no_bounds_check {
	q = e[1:]
	if q >= end {
		return end, .Truncated
	}
	c := q[0]
	switch {
	case c == 'u':
		return escape_exact(e, end)
	case c == 'x':
		_, q, kind = escape_digits(q[1:], end, 2)
		return
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
	return spell.utf8_char(q, end)
}

// One past the closing quote of the JSON5 string at `p` and its spelling, or the fault at the first byte that breaks
// it. The string closes at its own quote, `"` or `'`, uses the escapes of `escape5`, and holds any byte but CR and LF.
@(private, cold)
string5 :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) #no_bounds_check {
	quote := p[0]
	q = p[1:]
	for {
		if q >= end {
			return end, 0, .Truncated
		}
		c := q[0]
		switch {
		case c == quote:
			return q[1:], spelling, .None
		case c == '\\':
			r, k := escape5(q, end)
			if k != .None {
				return r, 0, k
			}
			spelling |= tape.SPELLING_DECODE | (0 if spell.ESCAPED[q[1]] != 0 || q[1] == 'u' else SPELLING_JSON5)
			q = r
		case c == '\n' || c == '\r':
			return q, 0, .Bad_Char
		case c < 0x80:
			q = q[1:]
		case:
			r, k := spell.utf8_char(q, end)
			if k != .None {
				return r, 0, k
			}
			q = r
		}
	}
}

// The state at a single-quoted JSON5 string value.
@(private, enable_target_feature = STATE_FEATURES)
st_string5 :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, _, _ := string_short(p, end, '\'')
	if q == nil {
		q, _ = string_lean(p, end, '\'')
	}
	spelling: u16
	if q == nil {
		esc: bool
		q, esc = string_block(w, p, end, '\'')
		spelling = tape.SPELLING_DECODE if esc else 0
	}
	if q == nil {
		kind: tape.Fault_Kind
		if q, spelling, kind = string5(p, end); kind != .None {
			return fault(w, hs, q, kind)
		}
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Value, p, q, spelling) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a JSON5 key that opens with no `"`. Reads a plain ASCII identifier through the colon to the value, and
// passes any other key to `st_spec_key`. No gap is learned around an unquoted key, so a walk with gaps counts the
// member as a miss when its colon follows flush.
@(private, enable_target_feature = STATE_FEATURES)
st_key_ident :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q := ident_ascii(p, end)
	if q == nil {
		return #must_tail st_spec_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit(w, on, &hs, .String, .Key, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	r := colon_fast(q, end)
	if r == nil {
		return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	}
	when G {
		if gap_miss(w, p) {
			return #must_tail st_stop_gaps(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// One past the unquoted key at `p` when it is plain ASCII, a letter, `$` or `_` and then those or digits, and an ASCII
// byte other than `\` follows it; nil when `ident5` must read it.
@(private)
ident_ascii :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	if IDENT[p[0]] != IDENT_START {
		return nil
	}
	q := p[1:]
	for q < end && IDENT[q[0]] != 0 {
		q = q[1:]
	}
	if q >= end || q[0] >= 0x80 || q[0] == '\\' {
		return nil
	}
	return q
}

// The state at a JSON5 key that JSON refused, a single-quoted string or an ECMAScript 5.1 IdentifierName, which reads on
// through the colon to the value. A byte that starts no key faults `Bad_Char`.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_key5 :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	quoted := p[0] == '\''
	q: [^]u8
	spelling: u16
	kind: tape.Fault_Kind
	if quoted {
		q, spelling, kind = string5(p, end)
	} else {
		esc: bool
		q, esc, kind = ident5(p, end)
		spelling = tape.SPELLING_DECODE if esc else 0
	}
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if q == p {
		return fault(w, hs, p, .Bad_Char)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	a: tape.Action
	if quoted {
		a = emit_string(w, on, &hs, .Key, p, q, spelling)
	} else {
		// An unquoted key's token is its bare span, with `SPELLING_QUOTED` clear.
		a = emit(w, on, &hs, .String, .Key, p, q, spelling)
	}
	if a == .Stop {
		return stopped(w, hs, q)
	}
	if r := colon_fast(q, end); r != nil {
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The character of an identifier at `q` that is no ASCII identifier byte, a `\u` escape or a UTF-8 character, which
// `r` steps past, and whether it is an escape; `r` is `q` for a character that ends the identifier, or the fault.
@(private, cold)
ident5_char :: #force_no_inline proc "contextless" (q, end: [^]u8, start: bool) -> (r: [^]u8, esc: bool, kind: tape.Fault_Kind) #no_bounds_check {
	if q[0] == '\\' {
		if intrinsics.ptr_sub(end, q) < 2 {
			return end, false, .Truncated
		}
		if q[1] != 'u' {
			return q[1:], false, .Bad_Escape
		}
		unit: u32
		if unit, r, kind = escape_digits(q[2:], end, 4); kind != .None {
			return r, false, kind
		}
		if !ident_char(rune(unit), start) {
			return q, false, .Bad_Escape
		}
		return r, true, .None
	}
	r, kind = spell.utf8_char(q, end)
	if kind != .None {
		return r, false, kind
	}
	ch, _ := utf8.decode_rune_in_bytes(q[:intrinsics.ptr_sub(r, q)])
	if !ident_char(ch, start) {
		return q, false, .None
	}
	return r, false, .None
}

// One past the unquoted key at `p`, an ECMAScript 5.1 IdentifierName, and whether it holds a `\u` escape; `p` when no
// identifier starts there. It ends before the first character that cannot continue it. A malformed `\u` escape, or one
// that writes a character not allowed there, faults `Bad_Escape`, and malformed UTF-8 faults as in a string.
@(private)
ident5 :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: tape.Fault_Kind) #no_bounds_check {
	q = p
	// A digit may not be the first character.
	if q < end && q[0] - '0' < 10 {
		return
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
		r, e, k := ident5_char(q, end, q == p)
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

// The ASCII bytes an identifier may hold: `IDENT_START` for one it may start with, a letter, `$` or `_`, and 2 for a
// digit; 0 for any other byte.
@(private, rodata)
IDENT := [256]u8 {
	'a' ..= 'z' = IDENT_START,
	'A' ..= 'Z' = IDENT_START,
	'$' = IDENT_START,
	'_' = IDENT_START,
	'0' ..= '9' = 2,
}

@(private)
IDENT_START :: 1
