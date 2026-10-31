package core

import "base:intrinsics"
import "core:strconv"

// A number token's value, decoded from its span when it is read. The walk stores no number, so a document holds the
// token's bytes and the spelling facts the walk recorded.
//
// `Int` is an integer that fits `i64`, stored in two's complement in `bits`. `Uint` is a positive integer that fits
// `u64` and not `i64`. `Float` is a binary64 in `bits`, correctly rounded to nearest even, for a fraction, an
// exponent, an integer past `u64`, or a negative integer past `i64`'s floor, when a binary64 represents the value.
// `Wide` is a number that no `i64`, `u64` or `f64` holds, for which the caller reads the span. `-0` is `Int` 0, as
// integer parsing reads it, and `-0.0` is `Float` -0.0.
Number_Kind :: enum u8 {
	Int,
	Uint,
	Float,
	Wide,
}

Number :: struct {
	bits: u64,
	kind: Number_Kind,
}

#assert(size_of(Number) == 16)

// The bits of binary64 infinity, which `strconv.fast_float_compute_float` returns on overflow.
@(private)
F64_INF_BITS :: u64(0x7FF) << 52

// The powers of ten from 1e0 to 1e22, each exact as a binary64, used by the Clinger window.
@(rodata)
POW10_F64 := [23]f64{
	1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
}

// A lexed decimal. `int_at` and `int_digits` locate the integer run, `frac_at` and `frac_digits` the fraction run,
// and `mant` folds both runs (the significand itself when they total at most 19 digits). `exp` is the exponent,
// `neg` is the sign, `has_frac` and `has_exp` say which parts the token has, and `ok` says the span is exactly one
// number.
@(private)
Number_Lex :: struct {
	int_at, int_digits:   u64,
	frac_at, frac_digits: u64,
	exp:                  i64,
	mant:                 u64,
	neg, has_frac:        bool,
	has_exp, ok:          bool,
}

// The value a lexed exponent saturates at, `max(i32) + 1`, past the `i32` range so it still reads as out of it.
@(private)
EXP_SATURATED :: i64(max(i32)) + 1

// Limits on a number handed to a decoder. A number with more authored mantissa digits than `MAX_NUMBER_DIGITS`, or
// with an exponent or scale beyond ±`MAX_NUMBER_SCALE`, is `Wide` and its span is not decoded.
MAX_NUMBER_DIGITS :: 256
MAX_NUMBER_SCALE :: 4096

// Returns the value of the decimal in `src[lo:hi]`, a span the walk accepted as a number. The caller must have
// checked the span, or call `number_json`, which checks it.
number_decimal :: proc(src: []u8, lo, hi: u64) -> Number {
	return number_of_lex(src, lo, hi, lex_decimal(src, lo, hi, false))
}

// Returns the integer in `src[lo:hi]` whose digit count the walk recorded, `digits` of them, at most 19. The span is
// a decimal integer with an optional sign, so the run's end is known and the fold does not search. Returns `ok` false
// for a span the counts do not describe, or a negative value past `i64`'s floor, which the caller reads with the full
// decimal decoder.
number_int :: #force_inline proc(src: []u8, lo, hi: u64, digits: int) -> (Number, bool) {
	base := raw_data(src)
	p := lo
	neg := false
	if base[p] == '-' {
		neg = true
		p += 1
	} else if base[p] == '+' {
		p += 1
	}
	if digits <= 0 || digits > 19 || p + u64(digits) != hi {
		return {}, false
	}
	// The digits end at `hi`. Each word load is anchored there and a mask drops the bytes before the run, so the
	// fold has no branch on the run's length and no tail loop.
	mag := fold_digits_end(src, hi, u64(digits))
	return integer_number(mag, neg)
}

// Returns `mag` with sign `neg` as a `Number`: `Int` when it fits `i64`, `Uint` when positive and past `i64`, and
// false when a negative magnitude is past `i64`'s floor (the caller reads the value as a float).
@(private)
integer_number :: #force_inline proc(mag: u64, neg: bool) -> (Number, bool) {
	if neg {
		if mag <= u64(1) << 63 {
			return {u64(0) - mag, .Int}, true
		}
	} else if mag <= u64(max(i64)) {
		return {mag, .Int}, true
	} else {
		return {mag, .Uint}, true
	}
	return {}, false
}

// Returns the correctly rounded binary64 of `mant * 10^e`, or false on overflow. With `e` 0 it converts `mant`
// directly. With `mant_exact` set and `e` within ±22 it uses the exact Clinger window, else Eisel-Lemire.
// `mant_exact` says `mant` is exact as a binary64, which a digit count below 10^15 proves because a binary64 holds
// every integer below 2^53, so the choice of arm uses a fact the walk recorded rather than a test on the folded
// significand.
@(private)
f64_of_significand :: #force_inline proc(mant: u64, e: i64, neg: bool, mant_exact: bool) -> (f64, bool) {
	if e == 0 {
		v := f64(mant)
		return (-v if neg else v), true
	}
	if mant_exact && e >= -22 && e <= 22 {
		f := f64(mant)
		v := f * POW10_F64[e] if e > 0 else f / POW10_F64[-e]
		return (-v if neg else v), true
	}
	b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
	if b == F64_INF_BITS {
		return 0, false
	}
	return transmute(f64)(b | u64(neg) << 63), true
}

// Returns the decimal in `src[lo:hi]` whose shape the walk recorded: `int_digits` digits after an optional sign, a
// point, then `frac_digits` digits, and no exponent. The runs are folded from their ends into one significand, so the
// span is read without the grammar search `number_decimal` does. A span the counts do not describe falls back to the
// full decimal read.
number_fraction :: #force_inline proc(src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number {
	base := raw_data(src)
	p := lo
	neg := false
	if p < hi && base[p] == '-' {
		neg = true
		p += 1
	} else if p < hi && base[p] == '+' {
		p += 1
	}
	int_at := p
	mant: u64
	// Folds the significand as two runs from their ends: the integer run ends at the point and the fraction run at
	// `hi`, each word masked to its run, so neither fold branches on the run's length.
	if int_digits > 0 && int_digits + frac_digits <= 19 {
		point := hi - u64(frac_digits) - 1
		if base[point] == '.' {
			whole := fold_digits_end(src, point, u64(int_digits))
			frac := fold_digits_end(src, hi, u64(frac_digits))
			sig := whole * POW10_U64[frac_digits] + frac
			e := -i64(frac_digits)
			v, ok := f64_of_significand(sig, e, neg, int_digits + frac_digits <= 15)
			if !ok {
				return {0, .Wide}
			}
			return {transmute(u64)v, .Float}
		}
	}
	// The word trick removes the point from the first 8 bytes, so the fraction's count must cover the whole run.
	if int_digits > 0 && int_digits <= 7 && frac_digits > 0 && int_digits + frac_digits >= 8 && int_at + 8 < hi {
		w := u64(intrinsics.unaligned_load((^u64le)(base[int_at:])))
		if (w >> (8 * u64(int_digits))) & 0xff == '.' {
			mask := (u64(1) << (8 * u64(int_digits))) - 1
			w = (w & mask) | ((w >> 8) & ~mask) | (u64(base[int_at + 8]) << 56)
			mant = digits8_value(w)
			p = int_at + 9
			p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &mant, true), base))
			if p != hi || p - (int_at + u64(int_digits) + 1) != u64(frac_digits) {
				return number_decimal(src, lo, hi)
			}
			digits := int_digits + frac_digits
			if digits > 19 {
				return number_of_lex(src, lo, hi, Number_Lex {
					int_at = int_at,
					int_digits = u64(int_digits),
					frac_at = int_at + u64(int_digits) + 1,
					frac_digits = u64(frac_digits),
					mant = mant,
					neg = neg,
					has_frac = true,
					ok = true,
				})
			}
			// A recorded shape has no exponent and at most 19 digits, so `mant` is the significand. The value is
			// the exact Clinger divide when `digits <= 15` and `e >= -22`, else Eisel-Lemire.
			e := -i64(frac_digits)
			v: f64
			if digits <= 15 && e >= -22 {
				f := f64(mant)
				v = f / POW10_F64[-e]
			} else {
				b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
				if b == F64_INF_BITS {
					return {0, .Wide}
				}
				v = transmute(f64)(b | u64(neg) << 63)
				return {transmute(u64)v, .Float}
			}
			return {transmute(u64)(-v if neg else v), .Float}
		}
	}
	p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &mant, true), base))
	if p != int_at + u64(int_digits) || p >= hi || base[p] != '.' {
		return number_decimal(src, lo, hi)
	}
	p += 1
	frac_at := p
	p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &mant, true), base))
	if p != frac_at + u64(frac_digits) || p != hi {
		return number_decimal(src, lo, hi)
	}
	n := Number_Lex {
		int_at     = int_at,
		int_digits = u64(int_digits),
		frac_at    = frac_at,
		frac_digits = u64(frac_digits),
		mant       = mant,
		neg        = neg,
		has_frac   = true,
		ok         = true,
	}
	return number_of_lex(src, lo, hi, n)
}

// Returns the decimal in `src[lo:hi]` whose shape the walk recorded with an exponent: `int_digits` digits after an
// optional sign, an optional point and `frac_digits` digits, then `e` or `E` and the exponent. Folds the significand
// from the two runs and reads the exponent digits, without lexing the span again. A span the counts do not describe
// falls back to the full decimal read.
number_exponent :: #force_inline proc(src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number {
	if int_digits > 19 || frac_digits > 19 || int_digits + frac_digits > 19 {
		return number_decimal(src, lo, hi)
	}
	base := raw_data(src)
	p := lo
	neg := false
	if p < hi && base[p] == '-' {
		neg = true
		p += 1
	} else if p < hi && base[p] == '+' {
		p += 1
	}
	int_at := p
	if int_digits < 0 || p + u64(int_digits) > hi {
		return number_decimal(src, lo, hi)
	}
	p += u64(int_digits)
	frac_at := p
	has_frac := false
	if p < hi && base[p] == '.' {
		has_frac = true
		p += 1
		frac_at = p
		if frac_digits < 0 || p + u64(frac_digits) > hi {
			return number_decimal(src, lo, hi)
		}
		p += u64(frac_digits)
	} else if frac_digits != 0 {
		return number_decimal(src, lo, hi)
	}
	if p >= hi || base[p] | 0x20 != 'e' {
		return number_decimal(src, lo, hi)
	}
	p += 1
	exp_neg := false
	if p < hi && (base[p] == '+' || base[p] == '-') {
		exp_neg = base[p] == '-'
		p += 1
	}
	exp_at := p
	exp: i64
	for p < hi && base[p] - '0' < 10 {
		exp = min(exp * 10 + i64(base[p] - '0'), EXP_SATURATED)
		p += 1
	}
	if p == exp_at || p != hi {
		return number_decimal(src, lo, hi)
	}
	if exp_neg {
		exp = -exp
	}
	whole := fold_digits_end(src, int_at + u64(int_digits), u64(int_digits)) if int_digits > 0 else 0
	frac := fold_digits_end(src, frac_at + u64(frac_digits), u64(frac_digits)) if frac_digits > 0 else 0
	mant := whole * POW10_U64[frac_digits] + frac
	n := Number_Lex {
		int_at     = int_at,
		int_digits = u64(int_digits),
		frac_at    = frac_at,
		frac_digits = u64(frac_digits),
		exp        = exp,
		mant       = mant,
		neg        = neg,
		has_frac   = has_frac,
		has_exp    = true,
		ok         = true,
	}
	return number_of_lex(src, lo, hi, n)
}

// Returns the value of `src[lo:hi]` as a decimal in RFC 8259's grammar, and false when the span is not one. A dsv
// cell uses the false result to ask whether the cell is a number at all.
number_json :: proc(src: []u8, lo, hi: u64) -> (Number, bool) {
	n := lex_decimal(src, lo, hi, true)
	if !n.ok {
		return {0, .Wide}, false
	}
	return number_of_lex(src, lo, hi, n), true
}

// Returns a JSON5 hexadecimal integer: `0x` and one or more hex digits, with either sign. An integer that fits `i64`
// returns `Int`, one that fits only `u64` returns `Uint`, and a longer one returns `Float` when a binary64 represents
// it, else `Wide`. A malformed span returns `Wide`.
number_hex :: proc(src: []u8, lo, hi: u64) -> Number {
	p := lo
	neg := false
	if p < hi && (src[p] == '+' || src[p] == '-') {
		neg = src[p] == '-'
		p += 1
	}
	if hi - p < 3 || src[p] != '0' || src[p + 1] | 0x20 != 'x' {
		return {0, .Wide}
	}
	at := p + 2
	if hi - at > MAX_NUMBER_DIGITS {
		return {0, .Wide}
	}
	p = at
	mag: u64
	over := false
	for p < hi {
		d := HEX_NIBBLE[src[p]]
		if d > 15 {
			return {0, .Wide}
		}
		over ||= mag > max(u64) >> 4
		mag = mag << 4 | u64(d)
		p += 1
	}
	if p == at {
		return {0, .Wide}
	}
	if !over {
		if num, ok := integer_number(mag, neg); ok {
			return num
		}
	}
	v, ok := hex_to_f64(src, at, hi, neg)
	if !ok {
		return {0, .Wide}
	}
	return {transmute(u64)v, .Float}
}

// Returns JSON5's `Infinity` as a binary64, with a negative sign when `src[lo]` is `-` and `lo < hi`.
number_infinity :: proc(src: []u8, lo, hi: u64) -> Number {
	neg := lo < hi && src[lo] == '-'
	return {F64_INF_BITS | u64(neg) << 63, .Float}
}

// Returns JSON5's `NaN` as a quiet binary64 NaN with a zero sign, since the sign of NaN is not a value.
number_nan :: proc(src: []u8, lo, hi: u64) -> Number {
	return {0x7ff8_0000_0000_0000, .Float}
}

// Lexes the decimal in `src[lo:hi]`. `strict` selects RFC 8259's grammar, and false the looser grammar a JSON5 token
// or a dsv cell may use, which allows a `+` and a leading or trailing point. `n.ok` is false when the span is not one
// number.
@(private)
lex_decimal :: proc(src: []u8, lo, hi: u64, strict: bool) -> (n: Number_Lex) {
	if lo >= hi || hi > u64(len(src)) {
		return
	}
	p := lo
	if src[p] == '-' {
		n.neg = true
		p += 1
	} else if !strict && src[p] == '+' {
		p += 1
	}
	if p >= hi {
		return
	}
	n.int_at = p
	if strict {
		if src[p] == '0' {
			p += 1
			if p < hi && src[p] - '0' < 10 {
				return
			}
		} else if src[p] - '1' < 9 {
			base := raw_data(src)
			p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &n.mant, true), base))
		} else {
			return
		}
		n.int_digits = p - n.int_at
	} else {
		base := raw_data(src)
		p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &n.mant, true), base))
		n.int_digits = p - n.int_at
	}
	if p < hi && src[p] == '.' {
		n.has_frac = true
		p += 1
		n.frac_at = p
		base := raw_data(src)
		p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &n.mant, true), base))
		n.frac_digits = p - n.frac_at
		if strict && n.frac_digits == 0 {
			return
		}
	}
	if n.int_digits + n.frac_digits == 0 {
		return
	}
	if p < hi && src[p] | 0x20 == 'e' {
		n.has_exp = true
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
	n.ok = p == hi
	return
}

@(rodata, private = "file")
POW10_U64: [20]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
	10_000_000_000, 100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000,
	1_000_000_000_000_000, 10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000,
	10_000_000_000_000_000_000,
}

// Returns the `k` digits ending at `end` as the integer they write. Each word load is anchored at `end`, and a mask
// drops the bytes before the run. Folds byte by byte when `end < 24`.
@(private)
fold_digits_end :: #force_inline proc(src: []u8, end, k: u64) -> u64 {
	base := raw_data(src)
	if end < 24 {
		// A word load would start before the source, so the run is folded byte by byte.
		m := u64(0)
		for i in end - k ..< end {
			m = m * 10 + u64(base[i] - '0')
		}
		return m
	}
	low := digits8_value(load8_le(src, end - 8))
	if k <= 8 {
		return digits8_value(load8_le(src, end - 8) & KEEP_DIGITS_MASK[k])
	}
	if k <= 16 {
		return digits8_value(load8_le(src, end - 16) & KEEP_DIGITS_MASK[k - 8]) * 10000_0000 + low
	}
	mid := digits8_value(load8_le(src, end - 16))
	return (digits8_value(load8_le(src, end - 24) & KEEP_DIGITS_MASK[k - 16]) * 10000_0000 + mid) * 10000_0000 + low
}

// Returns the end of the digit run at `p` and, when `$fold` is set, accumulates the digits into `mant`, 8 bytes at a
// time while at least 8 remain. Both the walk and this decoder use this digit reader.
digit_end :: #force_inline proc "contextless" (p, end: [^]u8, mant: ^u64, $fold: bool) -> [^]u8 {
	q := p
	#no_bounds_check {
		for intrinsics.ptr_sub(end, q) >= 8 {
			w := u64(intrinsics.unaligned_load((^u64le)(q)))
			gap := (w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)
			m := gap & 0x8080_8080_8080_8080
			if m != 0 {
				tz := intrinsics.count_trailing_zeros(m)
				k := tz >> 3
				when fold {
					mant^ = mant^ * DIGIT8_POW10[k] + digits8_value((w << (~tz & 0x38)) << 8)
				}
				return q[k:]
			}
			when fold {
				mant^ = mant^ * DIGIT8_POW10[8] + digits8_value(w)
			}
			q = q[8:]
		}
		for q < end {
			d := q[0]
			if d < '0' || d > '9' {
				break
			}
			when fold {
				mant^ = mant^ * 10 + u64(d - '0')
			}
			q = q[1:]
		}
	}
	return q
}

// Returns the value of a lexed decimal. An integer within `i64` or `u64` returns its exact magnitude, and every other
// token returns the correctly rounded binary64, or `Wide` when it overflows or passes the caps.
@(private)
number_of_lex :: #force_inline proc(src: []u8, lo, hi: u64, n: Number_Lex) -> Number {
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	if digits > MAX_NUMBER_DIGITS || n.exp > MAX_NUMBER_SCALE || n.exp < -MAX_NUMBER_SCALE || e > MAX_NUMBER_SCALE || e < -MAX_NUMBER_SCALE {
		return {0, .Wide}
	}
	if !n.has_frac && !n.has_exp {
		// `digit_end` already folded the integer's digits when they fit a word, and 19 digits are exact in `u64`,
		// so this arm folds nothing when `int_digits <= 19`.
		if n.int_digits <= 19 {
			if num, ok := integer_number(n.mant, n.neg); ok {
				return num
			}
		}
		mag, over := fold_u64(src, n.int_at, n.int_digits)
		if !over {
			if num, ok := integer_number(mag, n.neg); ok {
				return num
			}
		}
	}
	v, ok := f64_of_lex(src, lo, hi, n)
	if !ok {
		return {0, .Wide}
	}
	return {transmute(u64)v, .Float}
}

// Returns the unsigned integer in `src[at:at+n]` and whether it overflowed `u64`.
@(private)
fold_u64 :: #force_inline proc(src: []u8, at, n: u64) -> (mag: u64, over: bool) {
	for i in at ..< at + n {
		d := src[i] - '0'
		m, o1 := intrinsics.overflow_mul(mag, 10)
		a, o2 := intrinsics.overflow_add(m, u64(d))
		over ||= o1 || o2
		mag = a
	}
	return
}

// Returns the correctly rounded binary64 of `n` in `src`, or false when the magnitude overflows. Uses `mant` and
// Eisel-Lemire for a significand of at most 19 digits, and `dom_acc_wide` and `parse_f64` for a longer one.
@(private)
f64_of_lex :: #force_inline proc(src: []u8, lo, hi: u64, n: Number_Lex) -> (f64, bool) {
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	neg := n.neg
	if digits <= 19 {
		return f64_of_significand(n.mant, e, neg, digits <= 15)
	}
	// A significand past the 19 digits a word holds, so the wide accumulator collects it, Eisel-Lemire brackets
	// it, and `strconv.parse_f64` handles only the tokens the bracket leaves `.Undecided`.
	el: EL_Facts
	dom_acc_wide(src, n, &el)
	if el.m == 0 {
		return (-0.0 if neg else 0.0), true
	}
	value, res := el_settle(el.m, el.e, el.nz, neg)
	switch res {
	case .Decided:
		return value, true
	case .Refused:
		return 0, false
	case .Undecided:
	}
	parsed, ok := strconv.parse_f64(string(src[lo:hi]))
	return parsed, ok
}

// The outcome of `el_settle` for one token.
@(private)
El_Decode :: enum u8 {
	Decided,
	Refused,
	Undecided,
}

// The significand and exponent Eisel-Lemire decides from: at most 19 digits in `m`, the decimal exponent `e`, and
// `nz`, which says a nonzero digit was dropped past `m`.
@(private)
EL_Facts :: struct {
	m:  u64,
	e:  i64,
	nz: bool,
}

// The significant digits kept in `m`: 19 fit a `u64` and decide every input of 19 or fewer digits.
@(private)
EL_MAX_DIGITS :: 19

// Returns the correctly rounded binary64 of `m * 10^q` for a nonzero significand of at most 19 digits. `neg` sets the
// sign bit, and `.Refused` reports overflow. `nz` says a nonzero digit was dropped past `m`. Equal endpoints settle
// the result because rounding is monotone, and endpoints that round apart return `.Undecided`.
@(private)
el_settle :: proc(m: u64, q: i64, nz, neg: bool) -> (f64, El_Decode) {
	b := strconv.fast_float_compute_float(f64, int(q), m)
	if nz && b != strconv.fast_float_compute_float(f64, int(q), m + 1) {
		return 0, .Undecided
	}
	if b == F64_INF_BITS {
		return 0, .Refused
	}
	return transmute(f64)(b | u64(neg) << 63), .Decided
}

// Computes `el_settle`'s facts for a token whose significand does not fit the 19 digits in `mant`. The fraction's
// leading zeros are skipped only when the integer part is the single digit `0`, so a multi-digit run keeps every
// digit, leading zero included.
@(private)
dom_acc_wide :: proc(src: []u8, n: Number_Lex, out: ^EL_Facts) {
	#no_bounds_check {
		sig_int := n.int_digits
		if sig_int == 1 && src[n.int_at] == '0' {
			sig_int = 0
		}
		fold_int := min(sig_int, u64(EL_MAX_DIGITS))
		m := fold_run(0, src, n.int_at, fold_int)
		room := u64(EL_MAX_DIGITS) - fold_int
		dropped_int := i64(sig_int - fold_int)
		nz := digits_nonzero(src, n.int_at + fold_int, sig_int - fold_int)
		lz := u64(0)
		if sig_int == 0 {
			for lz < n.frac_digits && src[n.frac_at + lz] == '0' {
				lz += 1
			}
		}
		frac_kept := i64(lz)
		fold_frac := min(n.frac_digits - lz, room)
		m = fold_run(m, src, n.frac_at + lz, fold_frac)
		frac_kept += i64(fold_frac)
		nz = nz || digits_nonzero(src, n.frac_at + lz + fold_frac, n.frac_digits - lz - fold_frac)
		out^ = {m = m, e = dropped_int - frac_kept + n.exp, nz = nz}
	}
}

// Returns `m` followed by the `n` digits at `src[at:]`, folded 8 at a time.
@(private = "file")
fold_run :: #force_inline proc "contextless" (m: u64, src: []u8, at, n: u64) -> u64 #no_bounds_check {
	m, j := m, u64(0)
	for n - j >= 8 {
		m = m * 10000_0000 + digits8_value(load8_le(src, at + j))
		j += 8
	}
	for j < n {
		m = m * 10 + u64(src[at + j] - '0')
		j += 1
	}
	return m
}

// Reports whether any of the `n` digits at `src[at:]` is nonzero. Digits past the cap only move the bracket.
@(private = "file")
digits_nonzero :: #force_inline proc "contextless" (src: []u8, at, n: u64) -> bool {
	for k in 0 ..< n {
		if src[at + k] != '0' {
			return true
		}
	}
	return false
}

// Returns a hexadecimal integer past `u64` as a binary64, correctly rounded to nearest even, or false on overflow.
// Keeps the integer's top 54 bits and a sticky bit for the rest, in a single pass with no allocation.
@(private)
hex_to_f64 :: proc(src: []u8, at, hi: u64, neg: bool) -> (f64, bool) {
	i := at
	for i < hi && src[i] == '0' {
		i += 1
	}
	if i == hi {
		return (-0.0 if neg else 0.0), true
	}
	nd := hi - i
	first := HEX_NIBBLE[src[i]]
	nbits := 4 * nd - u64(clz4(first))
	if nbits <= 53 {
		mag: u64
		for k in i ..< hi {
			mag = mag << 4 | u64(HEX_NIBBLE[src[k]])
		}
		v := f64(mag)
		return (-v if neg else v), true
	}
	kept: u64
	count := u64(0)
	sticky := false
	for k in i ..< hi {
		d := HEX_NIBBLE[src[k]]
		start := int(3)
		if k == i {
			start = 3 - int(clz4(d))
		}
		for bit := start; bit >= 0; bit -= 1 {
			b := (d >> u8(bit)) & 1
			if count < 54 {
				kept = kept << 1 | u64(b)
				count += 1
			} else if b != 0 {
				sticky = true
			}
		}
	}
	m := kept >> 1
	round_bit := kept & 1
	if round_bit != 0 && (sticky || m & 1 != 0) {
		m += 1
	}
	e := i64(nbits) - 53
	if m == u64(1) << 53 {
		m >>= 1
		e += 1
	}
	exp := e + 1075
	if exp >= 2047 {
		return 0, false
	}
	bits := u64(neg) << 63 | u64(exp) << 52 | (m & ((u64(1) << 52) - 1))
	return transmute(f64)bits, true
}

// Returns the number of leading zero bits in the 4-bit value of hex digit `d`.
@(private)
clz4 :: #force_inline proc(d: u8) -> u32 {
	return intrinsics.count_leading_zeros(u32(d)) - 28
}

// The SWAR decimal-digit primitives used by `digit_end`, `fold_run` and `fold_digits_end`. The code requires a
// little-endian target: `src[p]` is the low byte of a loaded word, and byte 0 holds the most significant digit.
when ODIN_ENDIAN != .Little {
	#panic("core: digits8_value requires a little-endian target")
}

// `KEEP_DIGITS_MASK[c]` keeps the digit nibbles of the last `c` bytes of a little-endian word.
@(rodata, private = "file")
KEEP_DIGITS_MASK: [9]u64 = {
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

@(rodata, private = "file")
DIGIT8_POW10: [9]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000,
}

// Returns the 8 bytes at `src[p:]` as one little-endian word. The caller must guarantee `p + 8 <= len(src)`.
@(private = "file")
load8_le :: #force_inline proc "contextless" (src: []u8, p: u64) -> u64 {
	#no_bounds_check {
		return intrinsics.unaligned_load((^u64)(&src[p]))
	}
}

// Returns the 8 ASCII digits in `w`, with byte 0 the most significant, as the integer they write.
@(private = "file")
digits8_value :: #force_inline proc "contextless" (w: u64) -> u64 {
	v := w & 0x0F0F_0F0F_0F0F_0F0F
	v = (v * 2561) >> 8
	v &= 0x00FF_00FF_00FF_00FF
	v = (v * (1 + (100 << 16))) >> 16
	return (v & 0xFFFF) * 10000 + (v >> 32 & 0xFFFF)
}
