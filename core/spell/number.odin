package spell

// Decimal number text read as a `Number`. `number_strict` takes RFC 8259's grammar and `number_loose` also takes a
// leading `+`, leading zeros and a point with no digits on one side. `number_int`, `number_fraction` and
// `number_exponent` decode from digit counts a walk has already found.

import "base:intrinsics"
import "core:strconv"

// A number's value. `Int` fits `i64`, `Uint` fits only `u64`, and `-0` is `Int` 0. `Float` is a correctly rounded
// binary64 that keeps the sign of `-0.0` and of an underflow to zero. `Wide` is too large for binary64 or past
// `MAX_NUMBER_DIGITS` or `MAX_NUMBER_SCALE`, and the caller reads its span.
Number :: struct {
	bits: u64,
	kind: Number_Kind,
}

#assert(size_of(Number) == 16)

Number_Kind :: enum u8 {
	Int,
	Uint,
	Float,
	Wide,
}

// A number is `Wide` when its mantissa has more than `MAX_NUMBER_DIGITS` digits, counting zeros, or when its exponent
// or scale is outside ±`MAX_NUMBER_SCALE`.
@(private)
MAX_NUMBER_DIGITS :: 256
@(private)
MAX_NUMBER_SCALE :: 4096

// A lexed exponent stops growing here. It is past the `i32` range, so it still reads as out of range.
@(private)
EXP_SATURATED :: i64(max(i32)) + 1

// Binary64 infinity. `strconv.fast_float_compute_float` returns it on overflow.
@(private)
F64_INF_BITS :: u64(0x7FF) << 52

// The powers of ten that are exact in binary64, for the Clinger fast path.
@(rodata)
POW10_F64 := [23]f64{
	1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
}

@(private, rodata)
POW10_U64: [20]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
	10_000_000_000, 100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000,
	1_000_000_000_000_000, 10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000,
	10_000_000_000_000_000_000,
}

// A lexed decimal. `mant` folds both digit runs and is exact when they total at most 19 digits. `ok` is set when the
// span is exactly one number.
@(private)
Number_Lex :: struct {
	int_at, int_digits:   u64,
	frac_at, frac_digits: u64,
	exp:                  i64,
	mant:                 u64,
	neg, has_frac:        bool,
	has_exp, ok:          bool,
}

// Decodes `src[lo:hi]` with RFC 8259's number grammar. Returns false if the span is not a valid number.
number_strict :: proc(src: []u8, lo, hi: u64) -> (Number, bool) {
	n := lex_decimal(src, lo, hi, true)
	if !n.ok {
		return {0, .Wide}, false
	}
	return number_of_lex(src, lo, hi, n), true
}

// Returns the integer and fraction digit counts of `src[lo:hi]` and whether it has an exponent, or false if the span is
// not a number in RFC 8259's grammar. It decodes no value.
number_shape_strict :: proc "contextless" (src: []u8, lo, hi: u64) -> (int_digits, frac_digits: u64, has_exp, ok: bool) {
	n := lex_decimal(src, lo, hi, true)
	return n.int_digits, n.frac_digits, n.has_exp, n.ok
}

// Decodes `src[lo:hi]` with the loose grammar, and also returns whether the span is a plain integer, whether it is a
// valid number with the strict grammar, and whether it is a valid number.
number_loose :: proc(src: []u8, lo, hi: u64) -> (num: Number, integer, strict, ok: bool) {
	n := lex_decimal(src, lo, hi, false)
	if !n.ok {
		return {0, .Wide}, false, false, false
	}
	strict = n.int_at == lo + u64(n.neg) && n.int_digits > 0 && (n.int_digits == 1 || src[n.int_at] != '0')
	strict &&= !n.has_frac || n.frac_digits > 0
	return number_of_lex(src, lo, hi, n), !n.has_frac && !n.has_exp, strict, true
}

// Decodes a signed decimal integer of `digits` digits, at most 19. Returns false when the span has another length or
// the value is below `i64`'s minimum.
number_int :: #force_inline proc(src: []u8, lo, hi: u64, digits: int) -> (Number, bool) {
	p, neg := skip_sign(raw_data(src), lo)
	if digits <= 0 || digits > 19 || p + u64(digits) != hi {
		return {}, false
	}
	mag := fold_digits_end(src, hi, u64(digits))
	return integer_number(mag, neg)
}

// Decodes a signed decimal of `int_digits` digits, a point and `frac_digits` digits, with no exponent. The counts are
// trusted and only the point's position is checked. A leading point or more than 19 digits goes to `number_decimal`.
number_fraction :: #force_inline proc(src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number {
	base := raw_data(src)
	if int_digits > 0 && int_digits + frac_digits <= 19 {
		point := hi - u64(frac_digits) - 1
		if base[point] == '.' {
			neg := base[lo] == '-'
			whole := fold_digits_end(src, point, u64(int_digits))
			frac := fold_digits_end(src, hi, u64(frac_digits))
			sig := whole * POW10_U64[frac_digits] + frac
			return number_significand(sig, -i64(frac_digits), neg, int_digits + frac_digits <= 15)
		}
	}
	return number_decimal(src, lo, hi)
}

// Decodes a decimal with an exponent from its digit counts. A span the counts do not match goes to `number_decimal`.
number_exponent :: #force_inline proc(src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number {
	if int_digits + frac_digits > 19 {
		return number_decimal(src, lo, hi)
	}
	base := raw_data(src)
	p, neg := skip_sign(base, lo)
	int_at := p
	if int_digits < 0 || p + u64(int_digits) > hi {
		return number_decimal(src, lo, hi)
	}
	p += u64(int_digits)
	frac_at := p
	if p < hi && base[p] == '.' {
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
	exp, end, has_digits := exponent_value(base, p + 1, hi)
	if !has_digits || end != hi {
		return number_decimal(src, lo, hi)
	}
	e := exp - i64(frac_digits)
	if scale_wide(exp, e) {
		return {0, .Wide}
	}
	whole := fold_digits_end(src, int_at + u64(int_digits), u64(int_digits)) if int_digits > 0 else 0
	frac := fold_digits_end(src, frac_at + u64(frac_digits), u64(frac_digits)) if frac_digits > 0 else 0
	return number_significand(whole * POW10_U64[frac_digits] + frac, e, neg, int_digits + frac_digits <= 15)
}

// Returns the correctly rounded binary64 of `mant * 10^e` with sign `neg`, or `Wide` on overflow. `mant` holds every
// digit of the significand, and `exact` says it has at most 15, so it is below 2^53 and the Clinger fast path holds for
// `e` within ±22.
number_significand :: #force_inline proc(mant: u64, e: i64, neg: bool, exact: bool) -> Number {
	if e == 0 || exact && e >= -22 && e <= 22 {
		// With no scale `mant` is exact up to 19 digits, and converting it rounds once.
		f := f64(mant)
		v := f * POW10_F64[e] if e >= 0 else f / POW10_F64[-e]
		return {transmute(u64)(-v if neg else v), .Float}
	}
	b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
	if b == F64_INF_BITS {
		return {0, .Wide}
	}
	return {b | u64(neg) << 63, .Float}
}

// Decodes `src[lo:hi]` with the loose grammar, without checking that the span is a number.
@(private)
number_decimal :: proc(src: []u8, lo, hi: u64) -> Number {
	return number_of_lex(src, lo, hi, lex_decimal(src, lo, hi, false))
}

// Lexes `src[lo:hi]` with the strict or loose grammar. `n.ok` is false if the span is not a number.
@(private)
lex_decimal :: proc "contextless" (src: []u8, lo, hi: u64, strict: bool) -> (n: Number_Lex) {
	if lo >= hi || hi > u64(len(src)) {
		return
	}
	base := raw_data(src)
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
	if strict && src[p] == '0' {
		p += 1
		if p < hi && src[p] - '0' < 10 {
			return
		}
	} else if !strict || src[p] - '1' < 9 {
		p = u64(intrinsics.ptr_sub(digit_end(base[p:], base[hi:], &n.mant, true), base))
	} else {
		return
	}
	n.int_digits = p - n.int_at
	if p < hi && src[p] == '.' {
		n.has_frac = true
		p += 1
		n.frac_at = p
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
		has_digits: bool
		n.exp, p, has_digits = exponent_value(base, p + 1, hi)
		if !has_digits {
			return
		}
	}
	n.ok = p == hi
	return
}

// Reads an exponent's optional sign and its digits at `p`, the value saturated at `EXP_SATURATED`. Returns the signed
// value, the end of the digits, and false when there is no digit.
@(private)
exponent_value :: #force_inline proc "contextless" (base: [^]u8, p, hi: u64) -> (exp: i64, end: u64, has_digits: bool) {
	end = p
	neg := false
	if end < hi && (base[end] == '+' || base[end] == '-') {
		neg = base[end] == '-'
		end += 1
	}
	digits_at := end
	for end < hi && base[end] - '0' < 10 {
		exp = min(exp * 10 + i64(base[end] - '0'), EXP_SATURATED)
		end += 1
	}
	return -exp if neg else exp, end, end != digits_at
}

// An integer that fits `i64` or `u64` stays exact. Anything else is the correctly rounded binary64, or `Wide` on
// overflow or past the caps.
@(private)
number_of_lex :: #force_inline proc(src: []u8, lo, hi: u64, n: Number_Lex) -> Number {
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	if digits > MAX_NUMBER_DIGITS || scale_wide(n.exp, e) {
		return {0, .Wide}
	}
	if !n.has_frac && !n.has_exp {
		// `mant` is exact up to 19 digits. Past that the digits are read again, and fail past `u64`.
		mag, fits := n.mant, true
		if n.int_digits > 19 {
			mag, fits = strconv.parse_u64_of_base(string(src[n.int_at:][:n.int_digits]), 10)
		}
		if fits {
			if num, ok := integer_number(mag, n.neg); ok {
				return num
			}
		}
	}
	if digits <= 19 {
		return number_significand(n.mant, e, n.neg, digits <= 15)
	}
	return wide_number(string(src[lo:hi]))
}

// The position past an optional sign at `lo`, and whether the sign is `-`.
@(private)
skip_sign :: #force_inline proc "contextless" (base: [^]u8, lo: u64) -> (p: u64, neg: bool) {
	c := base[lo]
	return lo + u64(c == '-' || c == '+'), c == '-'
}

// `mag` with sign `neg` as an `Int` or a `Uint`. Returns false for a negative magnitude past `i64`'s minimum.
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

// Whether an exponent `exp`, or the scale `e` it gives the significand's digits, is outside ±`MAX_NUMBER_SCALE`.
@(private)
scale_wide :: #force_inline proc "contextless" (exp, e: i64) -> bool {
	return exp > MAX_NUMBER_SCALE || exp < -MAX_NUMBER_SCALE || e > MAX_NUMBER_SCALE || e < -MAX_NUMBER_SCALE
}

// A decimal of more than 19 digits, read by `strconv.parse_f64`. `Wide` on overflow.
@(private, cold)
wide_number :: #force_no_inline proc(span: string) -> Number {
	v, ok := strconv.parse_f64(span)
	if !ok || transmute(u64)v & F64_INF_BITS == F64_INF_BITS {
		return {0, .Wide}
	}
	return {transmute(u64)v, .Float}
}
