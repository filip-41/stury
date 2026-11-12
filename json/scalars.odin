package json

import "base:intrinsics"
import spell "../core/spell"
import core "../core"

// Reads the number at `p`, which starts with `-` or a digit. Returns its end and `spelling`, or a fault and the byte it
// is at, `Bad_Number` at the `x` of JSON5's hex. `$lax` reads a JSON5 number instead, which may also start with `+`,
// `.`, `I` or `N`, and whose decimal integer or fraction part may be empty, but not both. The states read JSON's and
// leave the rest to `st_number5`, so the common number pays no test for JSON5's. `$fold` true returns the integer and
// fraction digits in `mant`, which wraps past 19 digits. Inlined, so a caller that drops `spelling` does not count
// digits.
@(private)
number_run :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec, $lax, $fold: bool) -> (q: [^]u8, spelling: u16, kind: core.Fault_Kind, mant: u64) #no_bounds_check {
	q = p
	k := Number_Spelling.Json
	if q[0] == '-' || lax && q[0] == '+' {
		if q[0] == '+' {
			k = .Decimal
		}
		q = q[1:]
		if q >= end {
			return end, 0, .Truncated, 0
		}
	}
	when lax {
		switch q[0] {
		case 'I':
			q, kind = word5(q, end, "Infinity")
			return q, u16(Number_Spelling.Infinity), kind, 0
		case 'N':
			q, kind = word5(q, end, "NaN")
			return q, u16(Number_Spelling.Nan), kind, 0
		}
		if q[0] == '0' && intrinsics.ptr_sub(end, q) > 1 && q[1] | 0x20 == 'x' {
			r := hex_run(q[2:], end)
			if r == q[2:] {
				q, kind = bad_or_truncated(r, end)
				return q, 0, kind, 0
			}
			return r, u16(Number_Spelling.Hex), .None, 0
		}
	}
	int_at := q
	if q[0] == '0' {
		q = q[1:]
		if q < end && (q[0] - '0' < 10 || .Es5 in FEATURES[S] && q[0] | 0x20 == 'x') {
			return q, 0, .Bad_Number, 0
		}
	} else {
		r := spell.digit_end(q, end, &mant, fold)
		if r == q && !(lax && q[0] == '.') {
			return q, 0, .Bad_Number, 0
		}
		q = r
	}
	int_digits := u64(intrinsics.ptr_sub(q, int_at))
	frac_digits: u64
	if q >= end {
		return q, core.number_spelling(u16(k), int_digits, frac_digits), .None, mant
	}
	c := q[0]
	if c == '.' {
		r := spell.digit_end(q[1:], end, &mant, fold)
		when lax {
			if r == q[1:] || q == int_at {
				if r == q[1:] && q == int_at {
					q2, k2 := bad_or_truncated(r, end)
					return q2, 0, k2, 0
				}
				k = .Decimal
			}
		} else {
			if r == q[1:] {
				q2, k2 := bad_or_truncated(r, end)
				return q2, 0, k2, 0
			}
		}
		frac_digits = u64(intrinsics.ptr_sub(r, q[1:]))
		q = r
		if q >= end {
			return q, core.number_spelling(u16(k), int_digits, frac_digits), .None, mant
		}
		c = q[0]
	}
	if c | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := spell.digit_end(q, end, nil, false)
		if r == q {
			q2, k2 := bad_or_truncated(r, end)
			return q2, 0, k2, 0
		}
		return r, core.number_spelling(u16(k), int_digits, frac_digits) | core.NUMBER_EXP, .None, mant
	}
	return q, core.number_spelling(u16(k), int_digits, frac_digits), .None, mant
}

// Calls `number_run`, and hands `mant` to a hook with a field `mant`.
@(private)
number_h :: #force_inline proc "contextless" (p, end: [^]u8, w: ^Walk($S, $H)) -> (q: [^]u8, spelling: u16, kind: core.Fault_Kind) {
	when intrinsics.type_has_field(H, "mant") {
		q, spelling, kind, w.hooks.mant = number_run(p, end, S, false, true)
	} else {
		q, spelling, kind, _ = number_run(p, end, S, false, false)
	}
	return
}

@(private)
bad_or_truncated :: #force_inline proc "contextless" (q, end: [^]u8) -> ([^]u8, core.Fault_Kind) {
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Number
}

// The first four bytes of `true`, `null` and `false` as a little-endian `u32`.
@(private)
TRUE_WORD :: u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24
@(private)
NULL_WORD :: u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24
@(private)
FALS_WORD :: u32('f') | u32('a') << 8 | u32('l') << 16 | u32('s') << 24

// Reads the literal at `p`, which starts with `t`, `f` or `n`. Returns one past it and its kind, or nil and `.Null`
// when the bytes are no literal. Tests the three words with no branch on which one it is, since `true` and `false`
// alternate in a column of flags.
@(private)
literal :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) < 5 {
		return literal_short(p, end)
	}
	w := u32(intrinsics.unaligned_load((^u32le)(p)))
	n := (u64(w == TRUE_WORD) | u64(w == NULL_WORD)) << 2 | (u64(w == FALS_WORD) & u64(p[4] == 'e')) * 5
	if n == 0 {
		return nil, .Null
	}
	c := p[0]
	return p[n:], .True if c == 't' else (.False if c == 'f' else .Null)
}

// `literal_short` is `literal` when exactly 4 bytes remain in the text.
@(private)
literal_short :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) == 4 {
		switch u32(intrinsics.unaligned_load((^u32le)(p))) {
		case TRUE_WORD:
			return p[4:], .True
		case NULL_WORD:
			return p[4:], .Null
		}
	}
	return nil, .Null
}

// Reads `word` at `p`, which starts with the word's first letter. Returns one past it with `ok` true, or the first
// byte that differs with `ok` false, `end` when the text ends first.
@(private)
word_end :: #force_inline proc "contextless" (p, end: [^]u8, word: string) -> (q: [^]u8, ok: bool) #no_bounds_check {
	for i in 0 ..< len(word) {
		q = p[i:]
		if q >= end {
			return end, false
		}
		if q[0] != word[i] {
			return q, false
		}
	}
	return p[len(word):], true
}

// The fault for a literal `literal` refused. It is the first byte that breaks the word its first letter names, or
// `end` and `Truncated`.
@(private, cold)
literal_fault :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) {
	q, _ = word_end(p, end, "true" if p[0] == 't' else ("false" if p[0] == 'f' else "null"))
	return q, .Truncated if q >= end else .Bad_Char
}

// JSON's `Readers.resolve` returns the node's kind, which is its value's kind.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	return doc.nodes[i].kind
}

// JSON's `Readers.number`, false for a token that is not a number. A decimal of at most 19 digits is decoded from the
// walk's digit counts, and the rest go to `number_slow`.
number :: #force_inline proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	if t.kind == .Number {
		sp := t.spelling
		if sp & core.NUMBER_KIND_MASK <= u16(Number_Spelling.Decimal) {
			lo, hi := t.lo, t.lo + u64(t.n)
			int_digits, frac_digits := core.number_digit_counts(sp)
			if core.number_shape(sp) < 32 {
				if num, ok := spell.number_int(v.src, lo, hi, int_digits); ok {
					return num, true
				}
			} else if sp & core.NUMBER_EXP != 0 {
				return spell.number_exponent(v.src, lo, hi, int_digits, frac_digits), true
			} else {
				return spell.number_fraction(v.src, lo, hi, int_digits, frac_digits), true
			}
		}
		return number_slow(v, t), true
	}
	return {}, false
}

// JSON's `Readers.number_f32`. Hex past `u64` has rounded once into binary64, so it is read again from its digits.
@(private)
number_f32 :: proc(doc: ^core.Token_View, n: core.Node) -> (f32, bool) {
	if number_spelling_of(n.spelling) != .Hex {
		return 0, false
	}
	return spell.number_hex_f32(doc.src, n.lo, n.lo + u64(n.n))
}

// Decodes what `number` does not: long decimals, hex, `Infinity` and `NaN`.
@(private, cold)
number_slow :: #force_no_inline proc(doc: ^core.Token_View, n: core.Node) -> core.Number {
	lo, hi := n.lo, n.lo + u64(n.n)
	switch number_spelling_of(n.spelling) {
	case .Json, .Decimal:
		// JSON5's `5.` has no fraction digit, so it is the integer `5`.
		num, _, _, _ := spell.number_loose(doc.src, lo, hi - u64(doc.src[hi - 1] == '.'))
		return num
	case .Hex:
		return spell.number_hex(doc.src, lo, hi)
	case .Infinity:
		// JSON5's `Infinity`, signed by a `-` before it, and its `NaN`, a quiet one with a zero sign.
		return {0x7ff0_0000_0000_0000 | u64(lo < hi && doc.src[lo] == '-') << 63, .Float}
	case .Nan:
		return {0x7ff8_0000_0000_0000, .Float}
	}
	return {0, .Wide}
}
