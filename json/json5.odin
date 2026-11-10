package json

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import "core:unicode"
import "core:unicode/utf8"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"

// This file reads JSON5 1.0.0's forms beyond JSON's in a spec with `.Es5`. They are its numbers, strings and escapes,
// unquoted keys and whitespace. A token JSON spells alike is read by JSON's leaf, and a state here runs only where that
// leaf refuses a token or no JSON start matches. JSON5's whitespace is read with the comments (comments.odin).

// The number grammar a token's `spelling` records: JSON's, a decimal JSON does not allow (`+1`, `.5`, `5.`), hex,
// `Infinity` or `NaN`.
Number_Spelling :: enum u16 {
	Json     = 0,
	Decimal  = 2,
	Hex      = 4,
	Infinity = 6,
	Nan      = 8,
}

// Returns the `Number_Spelling` in a token's `spelling`.
number_spelling_of :: #force_inline proc "contextless" (spelling: u16) -> Number_Spelling {
	return Number_Spelling(spelling & core.NUMBER_KIND_MASK)
}

// `p` is at a number JSON's leaf refused or read only up to an `x`. Reads the JSON5 number, then what follows it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_number5 :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, spelling, kind, _ := number_run(p, end, S, true, false)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if w.finite && number_spelling_of(spelling) >= .Infinity {
		return fault(w, hs, p, .Bad_Char, .Non_Finite)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
		return stopped(w, hs, q, d, ind, .After)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
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
	for q < end && spell.HEX_NIBBLE[q[0]] != 0xff {
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
	return bad_or_truncated(q, end)
}

// Steps over the JSON5 escape at the backslash `e`: `\0` before no digit, `\x` and two hex digits, a backslash before
// a line end (CR LF counts as one), JSON's `\u` escape with its surrogate halves paired, and a backslash before any
// character but a digit, which spells that character. A digit after `\0`, and `\1` to `\9`, fault `Bad_Escape` at the
// digit. `tol` is the walk's tolerances, and `lax` says an escaped ill-formed sequence was accepted as U+FFFD.
@(private)
escape5 :: proc "contextless" (e, end: [^]u8, tol: bit_set[core.Tolerance; u8]) -> (q: [^]u8, kind: core.Fault_Kind, lax: bool) #no_bounds_check {
	q = e[1:]
	if q >= end {
		return end, .Truncated, false
	}
	c := q[0]
	switch {
	case c == 'u':
		return escape_exact(e, end, tol)
	case c == 'x':
		_, q, kind = escape_digits(q[1:], end, 2)
		return q, kind, false
	case c == '0':
		if intrinsics.ptr_sub(end, q) > 1 && q[1] - '0' < 10 {
			return q[1:], .Bad_Escape, false
		}
		return q[1:], .None, false
	case c - '1' < 9:
		return q, .Bad_Escape, false
	case c == '\r':
		if intrinsics.ptr_sub(end, q) > 1 && q[1] == '\n' {
			return q[2:], .None, false
		}
		return q[1:], .None, false
	case c < 0x80:
		return q[1:], .None, false
	}
	return utf8_lax(q, end, tol)
}

// Reads one character of an identifier at `q` that is no ASCII identifier byte: a `\u` escape or a UTF-8 character,
// which `r` steps past, or the fault. `r` is `q` when the character may not be there, which ends the identifier. `esc`
// reports whether the character was an escape. Out of line, so `ident5` stays small enough for the compiler to inline into `st_key5`.
@(private, cold)
ident5_char :: #force_no_inline proc "contextless" (q, end: [^]u8, start: bool) -> (r: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
	c := q[0]
	if c == '\\' {
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

// Reads the unquoted key at `p`, an ECMAScript 5.1 IdentifierName. Returns one past it and whether it holds a `\u`
// escape, or `p` when no identifier starts there. It ends before the first character that cannot continue it. A
// malformed `\u` escape, or one that writes a character not allowed there, faults `Bad_Escape`, and malformed UTF-8
// faults `Bad_Char` as in a string.
@(private)
ident5 :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
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

// 1 for an ASCII byte an identifier may hold: a letter, `$`, `_` or a digit.
@(private, rodata)
IDENT := [128]u8 {
	'a' ..= 'z' = 1,
	'A' ..= 'Z' = 1,
	'$' = 1,
	'_' = 1,
	'0' ..= '9' = 1,
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
