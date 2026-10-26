package number

import "core:math"
import lex "../lex"

// The digit pack of a number row whose token is spelled outside JSON's grammar (JSON5's hex, `.5`, `5.`, `+1`,
// `Infinity`, `NaN`). A JSON token never packs zero integer digits, so the readers test for it only on the
// arm that already falls back to the text.
DIALECT_SPELLED :: u16(0xFF00)

// The hex digits `src[lo:hi]` of a JSON5 hex token: `mag` is their value when it fits 64 bits (`over` is set
// when it does not, and `mag` has wrapped), and `approx` always their value accumulated as a double.
json5_hex :: proc(src: []byte, lo, hi: u64) -> (mag: u64, approx: f64, over: bool) {
	for i in lo ..< hi {
		d := u64(lex.HEX_NIBBLE[src[i]])
		over ||= mag > max(u64) >> 4
		mag = mag << 4 | d
		approx = approx * 16 + f64(d)
	}
	return
}

// The value of a JSON5 number token a dialect walk accepted with `DIALECT_SPELLED`. `Infinity` and `NaN` are
// `.Exact`: the value is the one written. A decimal token is respelled as JSON (no `+`, a `0` before a leading
// point, no trailing point) and read as JSON reads it.
json5_number_value :: proc(src: []byte, lo, hi: u64) -> Number {
	p := lo
	neg := src[p] == '-'
	if neg || src[p] == '+' {
		p += 1
	}
	sign := -1.0 if neg else 1.0
	if p >= hi {
		return NO_NUMBER
	}
	switch {
	case src[p] == 'I':
		return {sign * math.inf_f64(1), .Exact}
	case src[p] == 'N':
		return {math.nan_f64(), .Exact}
	case hi - p > 2 && src[p] == '0' && src[p + 1] | 0x20 == 'x':
		mag, f, over := json5_hex(src, p + 2, hi)
		if !over {
			f = f64(mag)
			if f < 18446744073709551616.0 && u64(f) == mag {
				return {sign * f, .Exact}
			}
		}
		if math.is_inf(f) {
			return NO_NUMBER
		}
		return {sign * f, .Inexact}
	}
	// One byte more than the token at most: the `0` before a leading point.
	stack: [128]u8
	buf := stack[:]
	if hi - lo + 1 > len(stack) {
		buf = make([]u8, hi - lo + 1)
	}
	defer if len(buf) > len(stack) {
		delete(buf)
	}
	k := 0
	if neg {
		buf[k] = '-'
		k += 1
	}
	if src[p] == '.' {
		buf[k] = '0'
		k += 1
	}
	for i in p ..< hi {
		if src[i] == '.' && (i + 1 == hi || src[i + 1] - '0' >= 10) {
			continue
		}
		buf[k] = src[i]
		k += 1
	}
	return number_span(buf[:k], 0, u64(k))
}
