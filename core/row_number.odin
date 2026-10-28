package core

import "core:strconv"

// The number of a plain number row, decoded from its token and the digit pack the builder kept
// (`number_digits_pack`), and the cold arms that read a row the pack does not settle: from its text, or through
// the document's spelling (`SPELLED_NUMBER`).

// `number_token` of a row whose digit counts do not settle it: a format's own spelling (`SPELLED_NUMBER`), read
// through `spelling`, or a span read from its text. Out of line, so `number_token` inlines neither.
@(cold)
number_uncounted :: proc(src: []byte, lo, hi: u64, digits: u16, spelling: ^Row_Spelling) -> Number {
	if digits == SPELLED_NUMBER && lo < hi && hi <= u64(len(src)) {
		return spelling.number(src, lo, hi) if spelling != nil else NO_NUMBER
	}
	return number_span(src, lo, hi)
}

// `int_token`'s answer for a row the counts do not settle: a spelled one through `spelling`, any other from its
// text (`int_span`).
@(cold)
int_uncounted :: proc(src: []byte, lo, hi: u64, digits: u16, spelling: ^Row_Spelling) -> (v: i64, ok: bool) {
	if digits == SPELLED_NUMBER && lo < hi && hi <= u64(len(src)) {
		if spelling == nil {
			return 0, false
		}
		return spelling.int(src, lo, hi)
	}
	return int_span(src, lo, hi)
}

// The `i64` the integer token `src[lo:hi]` writes, `-0` as 0, as every integer target reads it; false for a
// fraction, an exponent, a value past `i64` or a span that is no number.
int_span :: proc(src: []byte, lo, hi: u64) -> (v: i64, ok: bool) {
	n := lex_number_value(src, lo, hi)
	if !n.ok || n.spelling & {.Has_Fraction, .Has_Exponent} != {} {
		return 0, false
	}
	mag, over, _ := fold_digits(src, n.int_at, n.int_at + n.int_digits, u64)
	if over {
		return 0, false
	}
	neg := .Negative in n.spelling
	if mag > u64(max(i64)) + u64(neg) {
		return 0, false
	}
	// Two's complement: `mag == 2^63` wraps to `min(i64)`.
	return i64(0 - mag) if neg else i64(mag), true
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
number_token :: #force_inline proc(src: []byte, lo, hi: u64, digits: u16, spelling: ^Row_Spelling) -> Number #no_bounds_check {
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
				bits = transmute(u64)(f64(mant) / POW10_F64[frac_digits])
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
		return number_uncounted(src, lo, hi, digits, spelling)
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
	return dom_number_value(src, lo, hi, n)
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
