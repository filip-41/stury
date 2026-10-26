package number

import "core:strconv"
import core_pkg "../../../core"

// `fast_float_compute_float`'s overflow: +Inf, which JSON has no value for.
F64_INF_BITS :: u64(0x7FF) << 52

// The `.Dom` number decode: the payload and the flags of the `Exactness` it is. The state is
// a fact of the token, not a second parse: a zero mantissa is `.Exact`, a nonzero one is `.Exact`
// when its binary64 is the authored value, proved by `dom_exact_scale` from the folded significand
// (`|e| <= 22`), a zero from a nonzero mantissa is `.Underflowed`, a decoder refusal `.None`,
// anything else `.Inexact`. `emit_number` writes the flags onto the row.
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
dom_number_value :: #force_inline proc(src: []byte, lo, hi: u64, n: Number_Lex) -> (f64, Row_Flags) {
	EXACT :: Row_Flags{.Decoded, .Exact}
	INEXACT :: Row_Flags{.Decoded, .Inexact}
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
			return (-v if neg else v), (EXACT if u64(v) == mant else INEXACT)
		}
		if digits <= 15 && e >= -22 && e <= 22 {
			// The Clinger window: an exact f64 times or over an exact power of
			// ten, one rounding. A nonzero mantissa here cannot underflow.
			f := f64(mant)
			v := f * core_pkg.POW10_F64[e] if e > 0 else f / core_pkg.POW10_F64[-e]
			return (-v if neg else v), (EXACT if dom_exact_scale(mant, e) else INEXACT)
		}
		b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
		if b == F64_INF_BITS {
			return 0, dom_state_flags(.None) // an overflow: JSON has no value for it
		}
		v := transmute(f64)(b | u64(neg) << 63)
		// Exactness for a significand past 15 digits that may still be an exact f64.
		// Combining the `mant` facts as bits keeps the folded value out of the walk's
		// control flow.
		exact := u8(mant == 0)
		if e >= -22 && e <= 22 {
			exact |= u8(dom_exact_scale(mant, e))
		}
		flags := EXACT if exact != 0 else INEXACT
		return v, (Row_Flags{.Decoded, .Underflowed, .Inexact} if v == 0 && mant != 0 else flags)
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
			v := f * core_pkg.POW10_F64[e] if e > 0 else f / core_pkg.POW10_F64[-e]
			return (-v if neg else v), true
		}
		b := #force_inline strconv.fast_float_compute_float(f64, int(e), n.mant)
		return transmute(f64)(b | u64(neg) << 63), b != F64_INF_BITS
	}
	v, flags := dom_number_value_cold(src, lo, hi, n.mant, n.int_at, n.int_digits, n.frac_at, n.frac_digits, n.exp, .Negative in n.spelling)
	return v, .Decoded in flags
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
) -> (f64, Row_Flags) {
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
		return 0, dom_state_flags(.None)
	case v != 0:
		return v, dom_state_flags(.Inexact)
	case nonzero:
		return v, dom_state_flags(.Underflowed)
	}
	return v, dom_state_flags(.Exact)
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

// The `i64` the integer token of a document row writes, from the digit counts the walk kept (`number_token`):
// `-0` is 0, an integer past `i64` and a token with a fraction or an exponent are not an `i64`. `known` is false
// for a row the counts do not settle (none counted, past the 19 digits a word fold holds, an exponent), which the
// caller reads from the text. Memory-safe on any row: it reads no byte outside `src[:hi]`.
int_token :: #force_inline proc(src: []byte, lo, hi: u64, digits: u16) -> (v: i64, ok, known: bool) #no_bounds_check {
	int_digits, frac_digits := u64(digits & 0xFF), u64(digits >> 8)
	sign := hi - lo - int_digits
	if int_digits - 1 >= EL_MAX_DIGITS || hi > u64(len(src)) {
		return 0, false, false
	}
	if sign > 1 {
		// A fraction is no integer, whatever follows it. Any other token is the caller's to lex.
		return 0, false, frac_digits != 0
	}
	mant := fold_known(src, hi, int_digits)
	// Two's complement: a magnitude of 2^63 wraps to `min(i64)`.
	v = i64(mant if sign == 0 else 0 - mant)
	ok = mant <= u64(max(i64)) + u64(sign)
	return v if ok else 0, ok, true
}

// `number_span` of a token a strict walk accepted, as a document row holds one: `digits` is the row's
// `number_digits_pack`. A significand of at most 19 digits is folded from words ending where its runs end,
// with no search for the `.` or the `e` and no branch on a run's length. Any other token, and a row no walk
// counted, is lexed again (`number_span`). Memory-safe on any row: one that is not such a token reads no
// byte outside `src[:hi]` and answers a number of no meaning.
number_token :: #force_inline proc(src: []byte, lo, hi: u64, digits: u16) -> Number #no_bounds_check {
	int_digits, frac_digits := u64(digits & 0xFF), u64(digits >> 8)
	// An integer token is its digits and at most a sign: the run ends at `hi`, so the sign is the width
	// left over (a wrapped difference is more than one) and no byte before the run is read.
	sign := hi - lo - int_digits
	if int_digits - 1 < EL_MAX_DIGITS && hi <= u64(len(src)) {
		if sign <= 1 {
			mant := fold_known(src, hi, int_digits)
			// The conversion rounds to nearest even, as in `dom_number_value`.
			v := f64(mant)
			return {-v if sign != 0 else v, .Exact if u64(v) == mant else .Inexact}
		}
		// A fraction and no exponent: the point and the fraction's digits are the width left after the integer
		// run, and a sign is what is left of that.
		fsign := sign - frac_digits - 1
		if frac_digits != 0 && fsign <= 1 && int_digits + frac_digits <= EL_MAX_DIGITS {
			point := hi - frac_digits - 1
			whole := u64(src[point - 1] - '0') if int_digits == 1 else fold_known(src, point, int_digits)
			mant := whole * POW10_U64[frac_digits] + fold_known(src, hi, frac_digits)
			// Clinger's window or Eisel-Lemire, as in `dom_number_value`. The scale is below 20 digits, so an
			// overflow or an underflow cannot happen.
			bits: u64
			if int_digits + frac_digits <= 15 {
				bits = transmute(u64)(f64(mant) / core_pkg.POW10_F64[frac_digits])
			} else {
				bits = strconv.fast_float_compute_float(f64, -int(frac_digits), mant)
			}
			v := transmute(f64)(bits | fsign << 63)
			return {v, .Exact if dom_exact_scale(mant, -i64(frac_digits)) else .Inexact}
		}
	}
	neg := lo < hi && src[lo] == '-'
	int_at := lo + u64(neg)
	frac_at := int_at + int_digits + 1
	// Past the fraction, or past the integer run when there is none: where an exponent starts.
	tail := frac_at + frac_digits if frac_digits != 0 else frac_at - 1
	if int_digits == 0 || int_digits + frac_digits > EL_MAX_DIGITS || tail > hi || hi > u64(len(src)) {
		if digits == DIALECT_SPELLED && lo < hi && hi <= u64(len(src)) {
			return json5_number_value(src, lo, hi)
		}
		return number_span(src, lo, hi)
	}
	n := Number_Lex{int_at = int_at, int_digits = int_digits, frac_at = frac_at, frac_digits = frac_digits, ok = true, whole = true}
	n.mant = fold_known(src, int_at + int_digits, int_digits)
	if frac_digits != 0 {
		n.mant = n.mant * POW10_U64[frac_digits] + fold_known(src, tail, frac_digits)
	}
	if neg {
		n.spelling = {.Negative}
	}
	if tail < hi {
		// `e`, a sign or none, and the exponent's digits.
		p := tail + 1
		exp_neg := src[p] == '-'
		p += u64(src[p] == '-' || src[p] == '+')
		for ; p < hi; p += 1 {
			n.exp = min(n.exp * 10 + i64(src[p] - '0'), EXP_SATURATED)
		}
		n.exp = -n.exp if exp_neg else n.exp
	}
	v, flags := dom_number_value(src, lo, hi, n)
	if .Decoded not_in flags {
		return NO_NUMBER
	}
	return {v, dom_flag_state(flags)}
}

// The `1 <= k <= 19` digits ending at `src[end - 1]` as the integer they write: one word per eight digits,
// the first kept to its lanes in the run. A run ending before byte 24 is read by byte, as a word would load
// from before `src`.
@(private = "file")
fold_known :: #force_inline proc(src: []byte, end, k: u64) -> u64 #no_bounds_check {
	if end < 24 {
		m := u64(0)
		for i in end - k ..< end {
			m = m * 10 + u64(src[i] - '0')
		}
		return m
	}
	if k <= 8 {
		return digits8_nibbles(load8_le(src, end - 8) & KEEP_DIGITS[k])
	}
	low := digits8_value(load8_le(src, end - 8))
	if k <= 16 {
		return digits8_nibbles(load8_le(src, end - 16) & KEEP_DIGITS[k - 8]) * DIGIT8_POW10[8] + low
	}
	mid := digits8_value(load8_le(src, end - 16))
	return (digits8_nibbles(load8_le(src, end - 24) & KEEP_DIGITS[k - 16]) * DIGIT8_POW10[8] + mid) * DIGIT8_POW10[8] + low
}

// `KEEP_DIGITS[c]` keeps the digit nibbles of a little-endian word's last `c` bytes, the digits of a run that
// ends with the word. The bytes before become `digits8_nibbles`'s leading zeros.
@(rodata, private = "file")
KEEP_DIGITS := [9]u64{
	0,
	0x0F << 56,
	0x0F0F << 48,
	0x0F_0F0F << 40,
	0x0F0F_0F0F << 32,
	0x0F_0F0F_0F0F << 24,
	0x0F0F_0F0F_0F0F << 16,
	0x0F_0F0F_0F0F_0F0F << 8,
	0x0F0F_0F0F_0F0F_0F0F,
}

// `digits8_value` of a word whose non-digit bits are already cleared.
@(private = "file")
digits8_nibbles :: #force_inline proc(w: u64) -> u64 {
	hi, lo := digits8_quads(w)
	return hi * 10000 + lo
}

// Ten to the powers a significand of at most 19 digits shifts its integer run by.
@(rodata, private = "file")
POW10_U64 := [20]u64{
	1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19,
}

// `number_span` of a span its caller already lexed (`lex_number_value`).
number_lexed :: #force_inline proc(src: []byte, lo, hi: u64, n: Number_Lex) -> Number {
	if !n.ok {
		return NO_NUMBER
	}
	v, flags := dom_number_value(src, lo, hi, n)
	if .Decoded not_in flags {
		return NO_NUMBER
	}
	return {v, dom_flag_state(flags)}
}
