package number

import lex "../lex"

// A number span lexed once, for every reader of a span: where the integer and fraction digits sit, the
// exponent, the `spelling` flags, and `mant`, the fold of both digit runs (the significand itself when they total
// at most 19 digits, as the walk's fold is). `ok` is false when the span is not a finished number extent
// (`-`, `1.`, `1e`, trailing bytes, no integer digit). `whole` is the looser reading a decoder takes: the
// span is consumed with a digit somewhere, so `.5` and `1.` count (`ok` implies `whole`).
//
// The span is the caller's to have checked (a leading zero is not checked). The exponent saturates at
// `EXP_SATURATED`, so it cannot wrap however many digits it has.
Number_Lex :: struct {
	int_at, int_digits:   u64,
	frac_at, frac_digits: u64,
	exp:                  i64,
	mant:                 u64,
	spelling:             Number_Spelling,
	ok, whole:            bool,
}

// The magnitude a lexed exponent saturates at: one past the `i32` range, so it still reads as out of it.
EXP_SATURATED :: i64(max(i32)) + 1

lex_number_span :: proc(src: []byte, lo, hi: u64) -> (n: Number_Lex) {
	if lo >= hi || hi > u64(len(src)) {
		return
	}
	p := lo
	if src[p] == '-' {
		n.spelling += {.Negative}
		p += 1
	}
	// Folded within the span: bytes past `hi` are not the token's.
	digits := src[:hi]
	n.int_at = p
	p = digit_run(digits, p, &n.mant, true)
	n.int_digits = p - n.int_at
	bare_dot := false
	if p < hi && src[p] == '.' {
		n.spelling += {.Has_Fraction}
		p += 1
		n.frac_at = p
		p = digit_run(digits, p, &n.mant, true)
		n.frac_digits = p - n.frac_at
		bare_dot = n.frac_digits == 0
	}
	if p < hi && src[p] | 0x20 == 'e' {
		n.spelling += {.Has_Exponent}
		p += 1
		exp_neg := false
		if p < hi && (src[p] == '+' || src[p] == '-') {
			exp_neg = src[p] == '-'
			p += 1
		}
		exp_at := p
		for p < hi && lex.is_digit(src[p]) {
			n.exp = min(n.exp * 10 + i64(src[p] - '0'), EXP_SATURATED)
			p += 1
		}
		if p == exp_at {
			return
		}
		n.exp = -n.exp if exp_neg else n.exp
	}
	n.whole = p == hi && n.int_digits + n.frac_digits != 0
	n.ok = n.whole && n.int_digits != 0 && !bare_dot
	return
}

// `lex_number_span` for a decoder: an unchecked span's leading zeros (`007`) leave the integer run, all
// but its last digit. The decoders take a lone leading zero as the only insignificant integer digit,
// which is all a checked token can have.
lex_number_value :: proc(src: []byte, lo, hi: u64) -> (n: Number_Lex) {
	n = lex_number_span(src, lo, hi)
	for n.int_digits > 1 && src[n.int_at] == '0' {
		n.int_at += 1
		n.int_digits -= 1
	}
	return
}
