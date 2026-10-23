package core

import "base:intrinsics"

// What a number's binary64 projection is relative to its authored value. One result per token,
// whoever reads it: a row, a span, or a decode.
Exactness :: enum u8 {
	// No binary64 value: not a number, out of range (`1e400`), a malformed span. The value is 0.
	None,
	// The authored value is nonzero and the result is +-0 (`1e-400`).
	Underflowed,
	// The correctly rounded value. The span is the number.
	Inexact,
	// The authored value bit for bit: `0`, `-0`, `2.5`, `1e2`.
	Exact,
}

// A binary64 projection and its exactness. Two words, so a reader returns it in registers.
Number :: struct {
	value:     f64,
	exactness: Exactness,
}

// The powers of ten a binary64 represents exactly. A Clinger fast path scales by them: `mant * 10^e`
// for `0 <= e <= 22` is correctly rounded when `mant` is an exact f64, and `mant / 10^-e` likewise.
@(rodata)
POW10_F64 := [23]f64{
	1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
}

// The decimal digits of `src[p:hi]` folded into a `T`, `over` once the value passed it. The run is read to
// `hi` past an overflow, so a fraction or exponent after one is still the wrong kind: `digits = false` at the
// first non-digit. Sign and range are the caller's.
fold_digits :: #force_inline proc(src: []byte, p, hi: u64, $T: typeid) -> (mag: T, over, digits: bool) {
	for i in p ..< hi {
		d := src[i] - '0'
		if d > 9 {
			return mag, over, false
		}
		m, o1 := intrinsics.overflow_mul(mag, 10)
		a, o2 := intrinsics.overflow_add(m, T(d))
		over ||= o1 || o2
		mag = a
	}
	return mag, over, true
}

#assert(size_of(Number) == 16)
