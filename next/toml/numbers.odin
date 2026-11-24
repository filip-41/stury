package toml

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The numbers of a TOML text. The number kinds in a number token's `tape.NUMBER_KIND` bits: a decimal that is also a
// JSON number, a decimal written with a plus sign or underscores, a hex, octal or binary integer, and the two words.
// The digit counts above them are set for the decimals only.
@(private)
Number_Spelling :: enum u16 {
	Plain   = 0,
	Decimal = 2,
	Hex     = 4,
	Octal   = 6,
	Binary  = 8,
	Inf     = 10,
	Nan     = 12,
}

#assert(u16(max(Number_Spelling)) <= tape.NUMBER_KIND)

// Whether `b` ends a value: white space, a line end, a comment, a separator or a close.
@(private)
terminator :: #force_inline proc "contextless" (b: u8) -> bool {
	switch b {
	case ' ', '\t', '\n', '\r', '#', ',', ']', '}':
		return true
	}
	return false
}

// The end of the run of bytes that is no terminator from `i`.
@(private)
run_end :: #force_inline proc "contextless" (src: []u8, i: int) -> int #no_bounds_check {
	k := i
	for k < len(src) && !terminator(src[k]) {
		k += 1
	}
	return k
}

@(private)
digit_in_base :: #force_inline proc "contextless" (b: u8, base: u64) -> (v: u64, ok: bool) {
	d := u64(spell.HEX_NIBBLE[b])
	return d, d < base
}

// A digit group at `i`: digits with a single underscore between two of them. Returns the byte past the group and the
// number of digits, `value` accumulating them in `base` and `over` set when it passes `u64`. A group that opens with a
// non-digit holds none, and an underscore that is not between digits ends the group before it.
@(private)
digit_group :: proc "contextless" (src: []u8, i, end: int, base: u64, value: ^u64, over: ^bool) -> (next, count: int, underscore: bool) #no_bounds_check {
	k := i
	for k < end {
		b := src[k]
		if b == '_' {
			before, after := false, false
			if k > i {
				_, before = digit_in_base(src[k - 1], base)
			}
			if k + 1 < end {
				_, after = digit_in_base(src[k + 1], base)
			}
			if !before || !after {
				break
			}
			underscore = true
			k += 1
			continue
		}
		d, ok := digit_in_base(b, base)
		if !ok {
			break
		}
		x := u128(value^) * u128(base) + u128(d)
		if x >> 64 != 0 {
			over^ = true
		}
		value^ = u64(x)
		count += 1
		k += 1
	}
	return k, count, underscore
}

// Judges the number at `i`, a sign or a digit or the start of `inf` or `nan`. Returns the byte past it and its
// spelling. An integer outside `i64` is a fault, as the specification asks.
@(private)
scan_number :: proc "contextless" (src: []u8, i: int) -> (end: int, spelling: u16, v: Verdict) #no_bounds_check {
	e := run_end(src, i)
	k := i
	plus, neg := false, false
	if src[k] == '+' || src[k] == '-' {
		plus, neg = src[k] == '+', src[k] == '-'
		k += 1
	}
	if k >= e {
		return k, 0, bad(k, .Bad_Number, .None)
	}
	if src[k] == 'i' || src[k] == 'n' {
		switch string(src[k:e]) {
		case "inf":
			return e, u16(Number_Spelling.Inf), 0
		case "nan":
			return e, u16(Number_Spelling.Nan), 0
		}
		return k, 0, bad(k, .Bad_Number, .None)
	}
	value: u64
	over: bool
	if src[k] == '0' && !plus && !neg && k + 1 < e && (src[k + 1] == 'x' || src[k + 1] == 'o' || src[k + 1] == 'b') {
		base := u64(16) if src[k + 1] == 'x' else 8 if src[k + 1] == 'o' else 2
		form := Number_Spelling.Hex if base == 16 else .Octal if base == 8 else .Binary
		next, count, _ := digit_group(src, k + 2, e, base, &value, &over)
		if count == 0 {
			return k + 2, 0, bad(k + 2, .Bad_Number, .None)
		}
		if next != e {
			return next, 0, bad(next, .Bad_Number, .Bad_Underscore if src[next] == '_' else .None)
		}
		if over || value > u64(max(i64)) {
			return e, 0, bad(i, .Bad_Number, .Out_Of_Range)
		}
		return e, u16(form), 0
	}
	if _, digit_next := digit(src[:e], k + 1); src[k] == '0' && (digit_next || k + 1 < e && src[k + 1] == '_') {
		return k + 1, 0, bad(k + 1, .Bad_Number, .Leading_Zero)
	}
	underscore: bool
	int_digits, frac_digits, count: int
	k, int_digits, underscore = digit_group(src, k, e, 10, &value, &over)
	if int_digits == 0 {
		return k, 0, bad(k, .Bad_Number, .None)
	}
	is_float, exp := false, false
	scratch: u64
	scratch_over: bool
	if k < e && src[k] == '.' {
		is_float = true
		us: bool
		k, frac_digits, us = digit_group(src, k + 1, e, 10, &scratch, &scratch_over)
		underscore ||= us
		if frac_digits == 0 {
			return k, 0, bad(k, .Bad_Number, .None)
		}
	}
	if k < e && (src[k] == 'e' || src[k] == 'E') {
		is_float, exp = true, true
		k += 1
		if k < e && (src[k] == '+' || src[k] == '-') {
			k += 1
		}
		us: bool
		k, count, us = digit_group(src, k, e, 10, &scratch, &scratch_over)
		underscore ||= us
		if count == 0 {
			return k, 0, bad(k, .Bad_Number, .None)
		}
	}
	if k != e {
		return k, 0, bad(k, .Bad_Number, .Bad_Underscore if src[k] == '_' else .None)
	}
	if !is_float && (over || value > (u64(1) << 63 if neg else u64(max(i64)))) {
		return e, 0, bad(i, .Bad_Number, .Out_Of_Range)
	}
	// An integer zero written with a sign is 0, which a plain JSON number is not when it is `-0`.
	form := Number_Spelling.Decimal if plus || underscore || neg && !is_float && value == 0 else .Plain
	spelling = tape.number_spelling(u16(form), u64(int_digits), u64(frac_digits))
	if exp {
		spelling |= tape.NUMBER_EXP
	}
	return e, spelling, 0
}

// The spelling of the number whose bytes run from `lo` to `hi`, which a walk judged.
@(private)
respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	_, spelling, _ := scan_number(src[:hi], int(lo))
	return spelling
}

// The value of number node `t` of `src`: a JSON number for a decimal, the digits' value for a hex, octal or binary
// integer, and a `Float` of infinity or NaN for the two words. A float past binary64's range reads as `Wide`, as in
// every format, and not as the infinity it rounds to, which the text does not write: a reader that wants the exact
// value reads it from the text.
@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	lo, hi := t.lo, t.lo + u64(t.n)
	switch Number_Spelling(t.spelling & tape.NUMBER_KIND) {
	case .Plain:
		num, _ := spell.number_strict(src, lo, hi)
		return num
	case .Decimal:
		return decimal_value(src[lo:hi])
	case .Hex, .Octal, .Binary:
		return prefixed_value(src[lo + 2:hi], t.spelling & tape.NUMBER_KIND)
	case .Inf:
		return {0x7ff0_0000_0000_0000 | u64(src[lo] == '-') << 63, .Float}
	case .Nan:
		return {0x7ff8_0000_0000_0001, .Float}
	}
	return {}
}

// The number a decimal spells with a plus sign or underscores: the JSON number of its digits. A text too long for the
// frame's buffer reads as `Wide`, as a decimal of more than `spell`'s digit bound does.
@(private)
decimal_value :: proc "contextless" (text: []u8) -> spell.Number {
	stack: [DECIMAL_ROOM]u8 = ---
	k := 0
	for b, i in text {
		if b == '_' || b == '+' && i == 0 {
			continue
		}
		if k == len(stack) {
			return {kind = .Wide}
		}
		stack[k] = b
		k += 1
	}
	num, _ := spell.number_strict(stack[:k], 0, u64(k))
	return num
}

// The bytes of a decimal's digits and signs that `decimal_value` reads in its frame: the 4096 digits past which
// `spell` reads a number as `Wide`, and room for the signs, the point and the exponent's digits.
@(private)
DECIMAL_ROOM :: 4096 + 128

// The integer a hex, octal or binary run of digits spells, which the walk judged to fit 63 bits.
@(private)
prefixed_value :: proc "contextless" (digits: []u8, form: u16) -> spell.Number {
	base := u64(16) if form == u16(Number_Spelling.Hex) else 8 if form == u16(Number_Spelling.Octal) else 2
	value: u64
	for b in digits {
		if b != '_' {
			d, _ := digit_in_base(b, base)
			value = value * base + d
		}
	}
	return {value, .Int}
}
