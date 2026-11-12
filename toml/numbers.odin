#+private
package toml

import core "../core"

// The number kinds in bits 0 to 3 of a number token's `spelling`: a decimal that is also a JSON number, a decimal
// written with a plus sign or underscores, a hex, octal or binary integer, and the two words. The digit counts above
// them are set for the decimals only.
NUMBER_PLAIN :: u16(Number_Spelling.Plain)
NUMBER_DECIMAL :: u16(Number_Spelling.Decimal)
NUMBER_HEX :: u16(Number_Spelling.Hex)
NUMBER_OCTAL :: u16(Number_Spelling.Octal)
NUMBER_BINARY :: u16(Number_Spelling.Binary)
NUMBER_INF :: u16(Number_Spelling.Inf)
NUMBER_NAN :: u16(Number_Spelling.Nan)

#assert(NUMBER_DECIMAL == core.NUMBER_DECIMAL)
#assert(NUMBER_NAN <= core.NUMBER_KIND_MASK)

// Whether `b` ends a value: white space, a line end, a comment, a separator or a close.
terminator :: #force_inline proc "contextless" (b: u8) -> bool {
	switch b {
	case ' ', '\t', '\n', '\r', '#', ',', ']', '}':
		return true
	}
	return false
}

// The end of the run of bytes that is no terminator from `i`.
run_end :: #force_inline proc "contextless" (src: []u8, i: int) -> int {
	k := i
	for k < len(src) && !terminator(src[k]) {
		k += 1
	}
	return k
}

digit_in_base :: #force_inline proc "contextless" (b: u8, base: u64) -> (v: u64, ok: bool) {
	d: u64
	switch {
	case b >= '0' && b <= '9':
		d = u64(b - '0')
	case b >= 'a' && b <= 'f':
		d = u64(b - 'a') + 10
	case b >= 'A' && b <= 'F':
		d = u64(b - 'A') + 10
	case:
		return 0, false
	}
	return d, d < base
}

// A digit group at `i`: digits with a single underscore between two of them. Returns the byte past the group and the
// number of digits, `value` accumulating them in `base` and `over` set when it passes `u64`. A group that opens with a
// non-digit holds none, and an underscore that is not between digits ends the group before it.
digit_group :: proc "contextless" (src: []u8, i, end: int, base: u64, value: ^u64, over: ^bool) -> (next, count: int, underscore: bool) {
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
		hi, lo := mul_add(value^, base, d)
		if hi != 0 {
			over^ = true
		}
		value^ = lo
		count += 1
		k += 1
	}
	return k, count, underscore
}

// `a * b + c` as a 128-bit value's high and low words.
mul_add :: #force_inline proc "contextless" (a, b, c: u64) -> (hi, lo: u64) {
	x := u128(a) * u128(b) + u128(c)
	return u64(x >> 64), u64(x)
}

// Judges the number at `i`, a sign or a digit or the start of `inf` or `nan`. Returns the byte past it and its
// `spelling`. An integer outside `i64` is a fault, as the specification asks.
scan_number :: proc "contextless" (src: []u8, i: int) -> (end: int, spelling: u16, v: Verdict) {
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
		word := string(src[k:e])
		switch word {
		case "inf":
			return e, NUMBER_INF, 0
		case "nan":
			return e, NUMBER_NAN, 0
		}
		return k, 0, bad(k, .Bad_Number, .None)
	}
	value: u64
	over: bool
	if src[k] == '0' && !plus && !neg && k + 1 < e && (src[k + 1] == 'x' || src[k + 1] == 'o' || src[k + 1] == 'b') {
		base := u64(16) if src[k + 1] == 'x' else 8 if src[k + 1] == 'o' else 2
		form := NUMBER_HEX if base == 16 else NUMBER_OCTAL if base == 8 else NUMBER_BINARY
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
		return e, form, 0
	}
	if src[k] == '0' && k + 1 < e && (src[k + 1] == '_' || src[k + 1] >= '0' && src[k + 1] <= '9') {
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
	form := NUMBER_DECIMAL if plus || underscore || neg && !is_float && value == 0 else NUMBER_PLAIN
	spelling = core.number_spelling(form, u64(int_digits), u64(frac_digits))
	if exp {
		spelling |= core.NUMBER_EXP
	}
	return e, spelling, 0
}
