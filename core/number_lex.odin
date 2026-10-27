package core

import "base:intrinsics"

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

Number_Spelling_Flag :: enum u8 {
	Negative,     // token began '-'
	Has_Exponent, // authored 'e'/'E'
	Has_Fraction, // authored '.'
}

// These co-occur (`-1.5e2` has all three), so a token carries them as a flag set.
Number_Spelling :: bit_set[Number_Spelling_Flag; u8]

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
		for p < hi && src[p] - '0' < 10 {
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

// Force-route build knob, declared here once for every scanner. `-define:SCAN_FORCE_SLOW=true`
// compiles every optimized route out of the walk (vector span finders, batched digit runs, the pure-integer
// fast path, the literal word compare, the escape nibble table), leaving the scalar semantic floor, so the
// differential tests can build both and compare the answers.
SCAN_FORCE_SLOW :: #config(SCAN_FORCE_SLOW, false)

@(rodata)
DIGIT8_POW10: [9]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000,
}

// High bit set in the first lane that is not an ASCII digit. A borrow or a
// carry moves toward higher bytes, so later lanes may be spurious. The first
// set lane is the first non-digit. `m == 0` means eight digits.
//
// A lane below '0' borrows into bit 7, one in ':' ..= 0xB9 carries into it, and one from 0xBA up keeps it
// through the subtraction. A digit lane with no borrow or carry from below sets neither. Only a non-digit
// lane below sends one up, so the first set lane needs no third term for the high bytes.
digit8_gap :: #force_inline proc(w: u64) -> u64 {
	return ((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
}

// End of the digit run at `p`. The 8-byte load runs only while eight bytes remain. The tail, and
// the whole run under `SCAN_FORCE_SLOW`, is scalar.
//
// When `$fold`, the same words fold the run into `mant`, continuing what it holds. The fold has
// no cap: past 19 digits `mant` wraps and the caller's digit count says so. A k-digit head is
// `digits8_value` of the word shifted up by `64 - 8k` bits. The shift is taken in two steps so
// `k == 0` shifts the whole word out and folds nothing, with no branch on `k`.
digit_run :: #force_inline proc(src: []byte, p: u64, mant: ^u64, $fold: bool) -> u64 {
	n := u64(len(src))
	q := p
	when !SCAN_FORCE_SLOW {
		#no_bounds_check {
			for q + 8 <= n {
				w := load8_le(src, q)
				m := digit8_gap(w)
				if m != 0 {
					// The gap's lowest set bit is lane k's bit 7, so `~tz & 0x38` is `56 - 8k`.
					tz := intrinsics.count_trailing_zeros(m)
					k := tz >> 3
					when fold {
						mant^ = mant^ * DIGIT8_POW10[k] + digits8_value((w << (~tz & 0x38)) << 8)
					}
					return q + k
				}
				when fold {
					mant^ = mant^ * DIGIT8_POW10[8] + digits8_value(w)
				}
				q += 8
			}
		}
	}
	#no_bounds_check {
		for q < n {
			d := src[q]
			if d < '0' || d > '9' {
				break
			}
			when fold {
				mant^ = mant^ * 10 + u64(d - '0')
			}
			q += 1
		}
	}
	return q
}
