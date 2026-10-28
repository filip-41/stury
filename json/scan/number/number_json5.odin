package number

import "core:math"
import core_pkg "../../../core"

// The digit pack of a number row whose token JSON5 spells outside JSON's grammar (hex, `.5`, `5.`, `+1`,
// `Infinity`, `NaN`).
DIALECT_SPELLED :: core_pkg.SPELLED_NUMBER

// The hex digits `src[lo:hi]` of a JSON5 hex token: `mag` is their value when it fits 64 bits (`over` is set
// when it does not, and `mag` has wrapped), and `approx` always their value accumulated as a double.
json5_hex :: proc(src: []byte, lo, hi: u64) -> (mag: u64, approx: f64, over: bool) {
	for i in lo ..< hi {
		d := u64(core_pkg.HEX_NIBBLE[src[i]])
		over ||= mag > max(u64) >> 4
		mag = mag << 4 | d
		approx = approx * 16 + f64(d)
	}
	return
}

// The value of a JSON5 number token a dialect walk accepted with `DIALECT_SPELLED`. `Infinity` and `NaN` are
// `.Exact`: the value is the one written. A decimal token is read by `core_pkg.number_of_loose_text`.
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
	n, _ := core_pkg.number_of_loose_text(src[lo:hi])
	return n
}
