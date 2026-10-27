package core

import "base:intrinsics"
import "core:strconv"

// What a number's binary64 projection is relative to its authored value. One result per token,
// whoever reads it: a row, a span, or a decode. The zero value is `Exact`, so a zero `Number` is 0.
Exactness :: enum u8 {
	// The authored value bit for bit: `0`, `-0`, `2.5`, `1e2`.
	Exact,
	// The correctly rounded value. The span is the number.
	Inexact,
	// The authored value is nonzero and the result is +-0 (`1e-400`).
	Underflowed,
	// No binary64 value: not a number, out of range (`1e400`), a malformed span. The value is 0.
	None,
}

// A binary64 projection and its exactness. Two words, so a reader returns it in registers. The zero `Number` is
// the exact value 0.
Number :: struct {
	value:     f64,
	exactness: Exactness,
}

// What a reader answers for a token with no binary64 value, since the zero `Number` is the exact 0.
NO_NUMBER :: Number{exactness = .None}

// The powers of ten that a binary64 represents exactly, for the Clinger fast path. `mant * 10^e` for
// `0 <= e <= 22` is correctly rounded when `mant` is an exact f64, and so is `mant / 10^-e`.
@(rodata)
POW10_F64 := [23]f64{
	1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
}

// Folds the decimal digits of `src[p:hi]` into a `T`; `over` is set once the value overflows `T`. Scanning
// continues to `hi` after an overflow, so a later fraction or exponent still returns `digits = false` at the
// first non-digit. The caller handles sign and range.
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

// The unsigned integer `src[p:hi]`: its magnitude, whether it overflows a u128, and whether the span is one
// or more digits and nothing else. Up to 19 digits fit a u64 and take the 8-byte digit run, which reads on
// past `hi` while digits last, so the byte at `hi`, if any, must not be a digit.
fold_int :: #force_inline proc(src: []byte, p, hi: u64) -> (mag: u128, over, ok: bool) {
	if hi - p > 19 {
		return fold_digits(src, p, hi, u128)
	}
	small: u64
	end := digit_run(src, p, &small, true)
	return u128(small), false, p < hi && end == hi
}

// `fast_float_compute_float`'s overflow: +Inf, which JSON has no value for.
F64_INF_BITS :: u64(0x7FF) << 52

// The number decode: the binary64 and the `Exactness` it is. The state is a fact of the token, not a
// second parse: a zero mantissa is `.Exact`, a nonzero one is `.Exact` when its binary64 is the authored
// value, proved by `dom_exact_scale` from the folded significand (`|e| <= 22`), a zero from a nonzero
// mantissa is `.Underflowed`, a decoder refusal `NO_NUMBER`, anything else `.Inexact`.
//
// `n` is the token lexed (`Number_Lex`): `n.mant` is the fold of both digit runs, the significand itself
// when they total at most 19 digits. `n.int_digits == 0` is `skip_number_q`'s token, whose digits were
// never read.
//
// The arm is chosen by facts the walk has before the fold finishes (digit count, decimal scale):
// a branch on the folded `mant` is unpredictable on 16-19 digit significands and resolves only
// after the whole digit chain. So the Clinger arm takes only significands of at most 15 digits
// (`10^15 < 2^53`, exact by count alone), Eisel-Lemire (strconv's fast_float) takes the rest and refuses
// an overflow, and every other token calls `dom_number_value_cold`. Both arms are correctly rounded, so
// the split decides no value.
dom_number_value :: #force_inline proc(src: []byte, lo, hi: u64, n: Number_Lex) -> Number {
	mant, neg := n.mant, .Negative in n.spelling
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	if n.int_digits != 0 && DOM_MAYBE_EXACT(digits) {
		if e == 0 {
			// An integer: the conversion rounds to nearest-even, which is the
			// correctly rounded value of any 19-digit integer. `0` and `-0` keep
			// their sign. It is exact when the conversion round-trips, so `0` too: `u64(v)` of a rounded-up
			// 19-digit value saturates or lands elsewhere, and either way differs from `mant`.
			v := f64(mant)
			return {-v if neg else v, .Exact if u64(v) == mant else .Inexact}
		}
		if digits <= 15 && e >= -22 && e <= 22 {
			// The Clinger window: an exact f64 times or over an exact power of
			// ten, one rounding. A nonzero mantissa here cannot underflow.
			f := f64(mant)
			v := f * POW10_F64[e] if e > 0 else f / POW10_F64[-e]
			return {-v if neg else v, .Exact if dom_exact_scale(mant, e) else .Inexact}
		}
		b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
		if b == F64_INF_BITS {
			return NO_NUMBER // an overflow: JSON has no value for it
		}
		v := transmute(f64)(b | u64(neg) << 63)
		// Exactness for a significand past 15 digits that may still be an exact f64.
		// Combining the `mant` facts as bits keeps the folded value out of the walk's
		// control flow.
		exact := u8(mant == 0)
		if e >= -22 && e <= 22 {
			exact |= u8(dom_exact_scale(mant, e))
		}
		st := Exactness.Exact if exact != 0 else .Inexact
		return {v, .Underflowed if v == 0 && mant != 0 else st}
	}
	// Loose arguments: a struct passed out of line would be spilled to memory in the walk that inlines this.
	return dom_number_value_cold(src, lo, hi, mant, n.int_at, n.int_digits, n.frac_at, n.frac_digits, n.exp, neg)
}

// `dom_number_value`'s binary64 alone, for a reader that needs no exactness: false only for a token with no
// binary64 value. It keeps the arms by digit count: a `mant` test to route below 2^53 mispredicts on 16-digit
// values.
f64_number_value :: #force_inline proc(src: []byte, lo, hi: u64, n: Number_Lex) -> (f64, bool) {
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	if n.int_digits != 0 && DOM_MAYBE_EXACT(digits) {
		neg := .Negative in n.spelling
		if e == 0 {
			v := f64(n.mant)
			return (-v if neg else v), true
		}
		if digits <= 15 && e >= -22 && e <= 22 {
			f := f64(n.mant)
			v := f * POW10_F64[e] if e > 0 else f / POW10_F64[-e]
			return (-v if neg else v), true
		}
		b := #force_inline strconv.fast_float_compute_float(f64, int(e), n.mant)
		return transmute(f64)(b | u64(neg) << 63), b != F64_INF_BITS
	}
	cold := dom_number_value_cold(src, lo, hi, n.mant, n.int_at, n.int_digits, n.frac_at, n.frac_digits, n.exp, .Negative in n.spelling)
	return cold.value, cold.exactness != .None
}

// Every token the inline arms of `dom_number_value` do not answer, decoded by `dom_number_el` from the
// walk's lexing of it. One the walk skipped (`int_digits == 0`) is lexed there. A zero is `.Exact` when every
// significant digit is zero and `.Underflowed` otherwise. Any other value is a rounding, `.Inexact` rather than
// re-proved: only the inline arms prove a nonzero one `.Exact`.
dom_number_value_cold :: proc(
	src: []byte,
	lo, hi: u64,
	mant: u64,
	int_at, int_digits: u64,
	frac_at, frac_digits: u64,
	exp: i64,
	neg: bool,
) -> Number {
	lexed := Number_Lex{
		int_at      = int_at,
		int_digits  = int_digits,
		frac_at     = frac_at,
		frac_digits = frac_digits,
		exp         = exp,
		mant        = mant,
		spelling    = {.Negative} if neg else {},
		whole       = int_digits != 0,
	}
	v, ok, nonzero := dom_number_el(src, lo, hi, lexed)
	switch {
	case !ok:
		return NO_NUMBER
	case v != 0:
		return {v, .Inexact}
	case nonzero:
		return {v, .Underflowed}
	}
	return {v, .Exact}
}

// The binary64 projection of a number token and its exactness, from the token's own bytes: the result
// the walk gives a `.Dom` row (`dom_number_value`), so a span and a row answer alike. A zero mantissa is
// `.Exact`. A nonzero one is `.Exact` when its binary64 is the authored value (`dom_number_value` says how
// that is proved). A zero from a nonzero mantissa digit is `.Underflowed`. A token with no binary64 value,
// or a span that is not a finished number, is `NO_NUMBER` (`.None`). Everything else is `.Inexact`: a
// significand past 19 digits is under-claimed rather than proved exact.
//
// The span is the caller's to have checked. This checks only that it is a finished number extent.
number_span :: proc(src: []byte, lo, hi: u64) -> Number {
	return number_lexed(src, lo, hi, lex_number_value(src, lo, hi))
}


// `number_span` of a span its caller already lexed (`lex_number_value`).
number_lexed :: #force_inline proc(src: []byte, lo, hi: u64, n: Number_Lex) -> Number {
	if !n.ok {
		return NO_NUMBER
	}
	return dom_number_value(src, lo, hi, n)
}

// The decimal `text` spells, `[+-]?(d+(.d*)?|.d+)([eE][+-]?d+)?` and nothing else, read as JSON reads the token
// respelled in its grammar: no `+`, a `0` before a leading point, no trailing point. `ok` is false for any other
// text, whose number is `NO_NUMBER`.
number_of_loose_text :: proc(text: []byte) -> (n: Number, ok: bool) {
	hi := u64(len(text))
	sign := u64(hi > 0 && (text[0] == '-' || text[0] == '+'))
	lexed := lex_number_value(text, sign, hi)
	// Past the sign, a `-` is a second one.
	if !lexed.whole || .Negative in lexed.spelling {
		return NO_NUMBER, false
	}
	if sign != 0 && text[0] == '-' {
		lexed.spelling += {.Negative}
	}
	if lexed.int_digits != 0 {
		return dom_number_value(text, 0, hi, lexed), true
	}
	// A leading point: the `0` written before it is an integer digit, counted toward the 19 a significand is
	// proved exact within.
	stack: [128]u8
	buf := stack[:]
	if len(text) + 1 > len(stack) {
		buf = make([]u8, len(text) + 1)
	}
	defer if len(buf) > len(stack) {
		delete(buf)
	}
	k := 0
	if .Negative in lexed.spelling {
		buf[0] = '-'
		k = 1
	}
	buf[k] = '0'
	k += 1 + copy(buf[k + 1:], text[sign:])
	return number_span(buf[:k], 0, u64(k)), true
}

#assert(size_of(Number) == 16)
