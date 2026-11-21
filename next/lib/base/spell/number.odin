package spell

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"

// A number's value, read from its decimal text.
Number :: struct {
	bits: u64, // the value's bits as `kind` reads them
	kind: Number_Kind,
}

#assert(size_of(Number) == 16)

Number_Kind :: enum u8 {
	Int, // fits `i64`; `-0` is 0
	Uint, // fits only `u64`
	Float, // the correctly rounded binary64, keeping the sign of `-0.0` and of an underflow to zero
	Wide, // past binary64, `MAX_NUMBER_DIGITS` or `MAX_NUMBER_SCALE`; the caller reads its text
}

// The most digits a number reads as a binary64, zeros included.
@(private)
MAX_NUMBER_DIGITS :: 256
// The largest exponent and scale, either sign, a number reads as a binary64.
@(private)
MAX_NUMBER_SCALE :: 4096
// The value an exponent stops growing at, past the `i32` range so it still reads as out of range.
@(private)
EXP_SATURATED :: i64(max(i32)) + 1
// Binary64 infinity, which `strconv.fast_float_compute_float` returns on overflow.
@(private)
F64_INF_BITS :: u64(0x7FF) << 52

// The powers of ten exact in binary64, for the Clinger fast path.
@(private, rodata)
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

// A lexed decimal.
@(private)
Number_Lex :: struct {
	int_at, int_digits:   u64,
	frac_at, frac_digits: u64,
	exp:                  i64,
	mant:                 u64, // both digit runs folded, exact up to 19 digits in all
	neg, has_frac:        bool,
	has_exp, ok:          bool, // `ok`: the span is exactly one number
}

// The value of `src[lo:hi]` read with RFC 8259's number grammar, false for a span that is no number.
@(require_results)
number_strict :: proc "contextless" (src: []u8, lo, hi: u64) -> (Number, bool) {
	n := lex_decimal(src, lo, hi, false)
	if !n.ok {
		return {}, false
	}
	return number_of_lex(src, lo, hi, n), true
}

// The value of `src[lo:hi]` read with JSON5's decimal grammar, which also takes a `+` and a point with digits on one
// side only, false for a span that is no number.
@(require_results)
number_loose :: proc "contextless" (src: []u8, lo, hi: u64) -> (Number, bool) {
	n := lex_decimal(src, lo, hi, true)
	if !n.ok {
		return {}, false
	}
	return number_of_lex(src, lo, hi, n), true
}

// The value of the signed integer `src[lo:hi]` of `digits` digits, at most 19, which a walk counted. False for a span
// of another length or a value below `i64`'s minimum.
@(require_results)
number_int :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, digits: int) -> (Number, bool) {
	p, neg := skip_sign(raw_data(src), lo)
	if digits <= 0 || digits > 19 || p + u64(digits) != hi {
		return {}, false
	}
	return integer_number(fold_digits_end(src, hi, u64(digits)), neg)
}

// The value of the decimal `src[lo:hi]` with a point and no exponent, from the digit counts a walk found. Only the
// point's place is checked against them.
@(require_results)
number_fraction :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number #no_bounds_check {
	base := raw_data(src)
	total := int_digits + frac_digits
	// A point at most 19 bytes before `hi` leaves both digit runs ending past `FOLD_WORDS_FROM`.
	if int_digits > 0 && frac_digits >= 0 && total <= 19 && hi >= FOLD_WORDS_FROM + 19 {
		point := hi - u64(frac_digits) - 1
		if base[point] == '.' {
			if total <= 7 {
				start := point - u64(int_digits)
				if start + 8 <= u64(len(src)) {
					w := load8(base[start:])
					lo_mask := (u64(1) << (u64(int_digits) * 8)) - 1
					merged := ((w & lo_mask) | ((w >> 8) & ~lo_mask)) << ((8 - u64(total)) * 8)
					v := f64(digits8_value(merged)) / POW10_F64[frac_digits]
					return {transmute(u64)(-v if base[lo] == '-' else v), .Float}
				}
			}
			whole := fold_digits_end_words(base, point, u64(int_digits))
			frac := fold_digits_end_words(base, hi, u64(frac_digits))
			sig := whole * POW10_U64[frac_digits] + frac
			if total <= 15 {
				v := f64(sig) / POW10_F64[frac_digits]
				return {transmute(u64)(-v if base[lo] == '-' else v), .Float}
			}
			b := #force_inline strconv.fast_float_compute_float(f64, -frac_digits, sig)
			if b == F64_INF_BITS {
				return {0, .Wide}
			}
			return {b | u64(base[lo] == '-') << 63, .Float}
		}
	}
	return number_decimal(src, lo, hi)
}

// The value of the decimal `src[lo:hi]` with an exponent, from the digit counts a walk found. A span the counts do
// not match is read again whole.
@(require_results)
number_exponent :: #force_no_inline proc "contextless" (src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number #no_bounds_check {
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
	return number_significand(whole * POW10_U64[frac_digits] + frac, e, neg)
}

// The correctly rounded binary64 of `mant` × 10^`e` with sign `neg`, or `Wide` on overflow. Below 2^53 both `mant`
// and `10^|e|` (for `|e| <= 22`) are exact in binary64, so Clinger's single operation holds.
number_significand :: #force_inline proc "contextless" (mant: u64, e: i64, neg: bool) -> Number {
	if mant < 1 << 53 && e >= -22 && e <= 22 {
		f := f64(mant)
		v := f * POW10_F64[e] if e >= 0 else f / POW10_F64[-e]
		return {transmute(u64)(-v if neg else v), .Float}
	}
	if e == 0 {
		v := f64(mant)
		return {transmute(u64)(-v if neg else v), .Float}
	}
	b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
	if b == F64_INF_BITS {
		return {0, .Wide}
	}
	return {b | u64(neg) << 63, .Float}
}

// The value of `src[lo:hi]`, which a walk accepted as a number, read with no digit counts.
@(private, require_results)
number_decimal :: proc "contextless" (src: []u8, lo, hi: u64) -> Number {
	return number_of_lex(src, lo, hi, lex_decimal(src, lo, hi, false))
}

@(private)
lex_decimal :: proc "contextless" (src: []u8, lo, hi: u64, $LOOSE: bool) -> (n: Number_Lex) {
	if lo >= hi || hi > u64(len(src)) {
		return
	}
	base := raw_data(src)
	p := lo
	if src[p] == '-' || LOOSE && src[p] == '+' {
		n.neg = src[p] == '-'
		p += 1
	}
	if p >= hi {
		return
	}
	n.int_at = p
	when LOOSE {
		p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant), base))
	} else {
		if src[p] == '0' {
			p += 1
			if p < hi && src[p] - '0' < 10 {
				return
			}
		} else if src[p] - '1' < 9 {
			p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant), base))
		} else {
			return
		}
	}
	n.int_digits = p - n.int_at
	if p < hi && src[p] == '.' {
		n.has_frac = true
		p += 1
		n.frac_at = p
		p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant), base))
		n.frac_digits = p - n.frac_at
		if n.frac_digits == 0 && !LOOSE {
			return
		}
	}
	if LOOSE && n.int_digits + n.frac_digits == 0 {
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

// The signed value of the exponent at `p`, saturated at `EXP_SATURATED`, the end of its digits, and whether it has any.
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

// The value of a lexed number. An integer that fits `i64` or `u64` stays exact.
@(private)
number_of_lex :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, n: Number_Lex) -> Number {
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	if digits > MAX_NUMBER_DIGITS || scale_wide(n.exp, e) {
		return {0, .Wide}
	}
	if !n.has_frac && !n.has_exp {
		// `mant` is exact up to 19 digits. Only a non-negative 20-digit integer can fit `u64`.
		mag, fits := n.mant, true
		if !n.neg && n.int_digits == 20 {
			tens, over := intrinsics.overflow_mul(fold_digits_end(src, n.int_at + 19, 19), 10)
			carry: bool
			mag, carry = intrinsics.overflow_add(tens, u64(src[n.int_at + 19] - '0'))
			fits = !over && !carry
		} else if n.int_digits > 19 {
			fits = false
		}
		if fits {
			if num, ok := integer_number(mag, n.neg); ok {
				return num
			}
		}
	}
	if digits <= 19 {
		return number_significand(n.mant, e, n.neg)
	}
	return wide_number(string(src[lo:hi]))
}

// The place past an optional `-` at `lo`, and whether there is one.
@(private)
skip_sign :: #force_inline proc "contextless" (base: [^]u8, lo: u64) -> (p: u64, neg: bool) {
	neg = base[lo] == '-'
	return lo + u64(neg), neg
}

// `mag` with sign `neg` as an `Int` or a `Uint`, false for a negative magnitude past `i64`'s minimum.
@(private)
integer_number :: #force_inline proc "contextless" (mag: u64, neg: bool) -> (Number, bool) {
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

// Whether an exponent `exp`, or the scale `e` it gives the significand's digits, is past ±`MAX_NUMBER_SCALE`.
@(private)
scale_wide :: #force_inline proc "contextless" (exp, e: i64) -> bool {
	return exp > MAX_NUMBER_SCALE || exp < -MAX_NUMBER_SCALE || e > MAX_NUMBER_SCALE || e < -MAX_NUMBER_SCALE
}

// The value of a decimal of more than 19 digits, `Wide` on overflow.
@(private, cold)
wide_number :: #force_no_inline proc "contextless" (span: string) -> Number {
	// `parse_f64` allocates nothing, so the default context serves it.
	context = runtime.default_context()
	v, ok := strconv.parse_f64(span)
	if !ok || transmute(u64)v & F64_INF_BITS == F64_INF_BITS {
		return {0, .Wide}
	}
	return {transmute(u64)v, .Float}
}

// The value of the hex digits `digits`, negated when `neg`: an integer while one holds it, else the correctly rounded
// binary64, `Wide` past its range.
@(require_results)
number_hex :: proc "contextless" (digits: []u8, neg: bool) -> Number #no_bounds_check {
	i := 0
	for i < len(digits) && digits[i] == '0' {
		i += 1
	}
	mant: u64
	n := 0
	for ; i < len(digits) && n < 16; i += 1 {
		mant = mant << 4 | u64(HEX_NIBBLE[digits[i]])
		n += 1
	}
	if i == len(digits) {
		if !neg {
			return {mant, .Int if mant <= u64(max(i64)) else .Uint}
		}
		if mant <= u64(1) << 63 {
			return {u64(0) - mant, .Int}
		}
	}
	// The digits past the first sixteen scale the value and only break a tie in its rounding. Past 240 of them the
	// value is at least `2^1024`.
	rest := len(digits) - i
	if rest > 240 {
		return {0, .Wide}
	}
	sticky := false
	for ; i < len(digits); i += 1 {
		sticky ||= digits[i] != '0'
	}
	lz := intrinsics.count_leading_zeros(mant)
	mant <<= lz
	top, low := mant >> 11, mant & 0x7FF
	if low > 0x400 || low == 0x400 && (sticky || top & 1 != 0) {
		top += 1
	}
	f := math.ldexp(f64(top), 11 + 4 * rest - int(lz))
	if math.is_inf(f) {
		return {0, .Wide}
	}
	return {transmute(u64)f | u64(neg) << 63, .Float}
}
