package spell

import "base:intrinsics"
import "core:math"
import "core:strconv"

// A number's value. `Int` fits `i64`, `Uint` fits only `u64`, and `-0` is `Int` 0. `Float` is a correctly rounded
// binary64 that keeps the sign of `-0.0` and of an underflow to zero. `Wide` is too large for binary64 or over the caps
// below, and the caller reads its span.
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

// Binary64 infinity. `strconv.fast_float_compute_float` returns it on overflow.
@(private)
F64_INF_BITS :: u64(0x7FF) << 52

// The powers of ten that are exact in binary64, for the Clinger fast path.
@(rodata)
POW10_F64 := [23]f64{
	1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
}

// A hex digit's value, or 0xFF for any other byte.
@(rodata)
HEX_NIBBLE: [256]u8 = {
	0 ..< '0' = 0xFF, ':' ..< 'A' = 0xFF, 'G' ..< 'a' = 0xFF, 'g' ..= 0xFF = 0xFF,
	'0' = 0, '1' = 1, '2' = 2, '3' = 3, '4' = 4, '5' = 5, '6' = 6, '7' = 7, '8' = 8, '9' = 9,
	'A' = 10, 'B' = 11, 'C' = 12, 'D' = 13, 'E' = 14, 'F' = 15,
	'a' = 10, 'b' = 11, 'c' = 12, 'd' = 13, 'e' = 14, 'f' = 15,
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

// A lexed exponent stops growing here. It is past the `i32` range, so it still reads as out of range.
@(private)
EXP_SATURATED :: i64(max(i32)) + 1

// A number is `Wide` when its mantissa has more than `MAX_NUMBER_DIGITS` digits, counting zeros, or when its
// exponent or scale is outside ±`MAX_NUMBER_SCALE`.
MAX_NUMBER_DIGITS :: 256
MAX_NUMBER_SCALE :: 4096

// Decodes `src[lo:hi]` with the loose grammar, without checking that the span is a number.
@(private)
number_decimal :: proc(src: []u8, lo, hi: u64) -> Number {
	return number_of_lex(src, lo, hi, lex_decimal(src, lo, hi, false))
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

// The position past an optional sign at `lo`, and whether the sign is `-`.
@(private)
skip_sign :: #force_inline proc "contextless" (base: [^]u8, lo: u64) -> (p: u64, neg: bool) {
	c := base[lo]
	return lo + u64(c == '-' || c == '+'), c == '-'
}

// Returns false for a negative magnitude past `i64`'s minimum.
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

// Returns the correctly rounded binary64 of `mant * 10^e` with sign `neg`, or `Wide` on overflow. `mant` holds every
// digit of the significand, and `exact` says it has at most 15, so it is below 2^53 and the Clinger fast path holds for
// `e` within ±22.
number_significand :: #force_inline proc(mant: u64, e: i64, neg: bool, exact: bool) -> Number {
	if e == 0 {
		v := f64(mant)
		return {transmute(u64)(-v if neg else v), .Float}
	}
	if exact && e >= -22 && e <= 22 {
		f := f64(mant)
		v := f * POW10_F64[e] if e > 0 else f / POW10_F64[-e]
		return {transmute(u64)(-v if neg else v), .Float}
	}
	b := #force_inline strconv.fast_float_compute_float(f64, int(e), mant)
	if b == F64_INF_BITS {
		return {0, .Wide}
	}
	return {b | u64(neg) << 63, .Float}
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

// Whether an exponent `exp`, or the scale `e` it gives the significand's digits, is outside ±`MAX_NUMBER_SCALE`.
@(private)
scale_wide :: #force_inline proc "contextless" (exp, e: i64) -> bool {
	return exp > MAX_NUMBER_SCALE || exp < -MAX_NUMBER_SCALE || e > MAX_NUMBER_SCALE || e < -MAX_NUMBER_SCALE
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
// valid number with the strict grammar, and whether it is a valid number. The loose grammar is the strict one plus a
// leading `+`, leading zeros, and a point with no digits on one side.
number_loose :: proc(src: []u8, lo, hi: u64) -> (num: Number, integer, strict, ok: bool) {
	n := lex_decimal(src, lo, hi, false)
	if !n.ok {
		return {0, .Wide}, false, false, false
	}
	strict = n.int_at == lo + u64(n.neg) && n.int_digits > 0 && (n.int_digits == 1 || src[n.int_at] != '0')
	strict &&= !n.has_frac || n.frac_digits > 0
	return number_of_lex(src, lo, hi, n), !n.has_frac && !n.has_exp, strict, true
}

// Parses the first `n` bytes at `p`, at most 8, and reports whether all are digits. Always loads 8 bytes.
@(private = "file")
short_digits :: #force_inline proc "contextless" (p: [^]u8, n: u64) -> (v: u64, ok: bool) {
	x := (intrinsics.unaligned_load((^u64)(p)) ~ 0x3030_3030_3030_3030) << ((8 - n) * 8)
	ok = ((x + 0x0606_0606_0606_0606) | x) & 0xf0f0_f0f0_f0f0_f0f0 == 0
	return digits8_value(x), ok
}

// Parses an optional sign followed by 1 to 16 digits, and returns false for anything else. It may read up to 8 bytes
// past the span.
short_integer :: #force_inline proc "contextless" (p: [^]u8, n: u64) -> (v: i64, ok: bool) {
	skip := u64(1) if p[0] == '-' || p[0] == '+' else 0
	digits := n - skip
	if digits - 1 >= 16 {
		return
	}
	mag: u64
	if digits <= 8 {
		mag, ok = short_digits(p[skip:], digits)
	} else {
		high, high_ok := short_digits(p[skip:], digits - 8)
		low, low_ok := short_digits(p[skip + digits - 8:], 8)
		mag, ok = high * 100_000_000 + low, high_ok && low_ok
	}
	return -i64(mag) if p[0] == '-' else i64(mag), ok
}

// Parses an optional sign, up to 8 digits, an optional point and up to 8 more digits, with at most 15 digits in total.
// Returns false for anything else. The digits and the power of ten both fit an f64 exactly, so the one division is
// correctly rounded. It may read up to 9 bytes past the span.
short_decimal :: #force_inline proc "contextless" (p: [^]u8, n: u64) -> (v: f64, ok: bool) {
	skip := u64(1) if p[0] == '-' || p[0] == '+' else 0
	q := p[skip:]
	chars := n - skip
	if chars - 1 >= 16 {
		return
	}
	dots := intrinsics.unaligned_load((^u64)(q)) ~ 0x2e2e_2e2e_2e2e_2e2e
	point := intrinsics.count_trailing_zeros((dots - 0x0101_0101_0101_0101) & ~dots & 0x8080_8080_8080_8080) / 8
	frac: u64
	if point >= chars {
		point = chars
	} else {
		frac = chars - point - 1
	}
	if frac > 8 || point > 8 || point + frac > 15 || point + frac == 0 || (point < chars && q[point] != '.') {
		return
	}
	whole, whole_ok := short_digits(q, point)
	part, part_ok := short_digits(q[point + 1:], frac)
	v = f64(whole * POW10_U64[frac] + part) / POW10_F64[frac]
	return -v if p[0] == '-' else v, whole_ok && part_ok
}

// Decodes `0x` and hex digits with an optional sign. Past `u64` it returns the nearest `Float`, or `Wide` past
// binary64. A malformed span is `Wide`.
number_hex :: proc(src: []u8, lo, hi: u64) -> Number {
	top, shift, neg, ok := hex_significand(src, lo, hi)
	if !ok {
		return {0, .Wide}
	}
	if shift == 0 {
		if num, is_int := integer_number(top, neg); is_int {
			return num
		}
	}
	v := math.ldexp(f64(top), shift)
	if math.is_inf(v) {
		return {0, .Wide}
	}
	return {transmute(u64)(-v if neg else v), .Float}
}

// The f32 nearest hex `src[lo:hi]`, rounded once, and false if the span is not hex. Past `max(f32)` it is infinite.
number_hex_f32 :: proc(src: []u8, lo, hi: u64) -> (f32, bool) {
	top, shift, neg, ok := hex_significand(src, lo, hi)
	if !ok {
		return 0, false
	}
	// `f32(top)` scaled by a power of two is exact in binary64 until it is past `max(f32)`.
	v := f32(math.ldexp(f64(f32(top)), shift))
	return -v if neg else v, true
}

// Hex `src[lo:hi]` as `top << shift`. Past `u64`, `top` keeps its leading 64 bits and sets its least bit when a dropped
// bit is set, so one conversion to binary64 or f32 rounds it correctly.
@(private)
hex_significand :: proc(src: []u8, lo, hi: u64) -> (top: u64, shift: int, neg: bool, ok: bool) {
	p := lo
	if p < hi && (src[p] == '+' || src[p] == '-') {
		neg = src[p] == '-'
		p += 1
	}
	if hi - p < 3 || src[p] != '0' || src[p + 1] | 0x20 != 'x' {
		return
	}
	p += 2
	if hi - p > MAX_NUMBER_DIGITS {
		return
	}
	sticky := false
	for ; p < hi; p += 1 {
		d := u64(HEX_NIBBLE[src[p]])
		if d > 15 {
			return
		}
		if top <= max(u64) >> 4 {
			top = top << 4 | d
			continue
		}
		// `top` is at least 2^60, so it takes `room` more bits, at most 3.
		room := uint(intrinsics.count_leading_zeros(top))
		sticky ||= d & (1 << (4 - room) - 1) != 0
		top = top << room | d >> (4 - room)
		shift += 4 - int(room)
	}
	return top | u64(sticky), shift, neg, true
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

@(private, rodata)
POW10_U64: [20]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
	10_000_000_000, 100_000_000_000, 1_000_000_000_000, 10_000_000_000_000, 100_000_000_000_000,
	1_000_000_000_000_000, 10_000_000_000_000_000, 100_000_000_000_000_000, 1_000_000_000_000_000_000,
	10_000_000_000_000_000_000,
}

// Returns the value of the `k` digits that end at `end`. The word loads end at `end` and are masked to the run. Below
// 24 a load could start before `src`, so the digits are read one at a time.
@(private)
fold_digits_end :: #force_inline proc(src: []u8, end, k: u64) -> u64 {
	base := raw_data(src)
	if end < 24 {
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

// Returns the end of the digit run at `p`. With `$fold` it also adds the digits to `mant`.
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
					mant^ = mant^ * POW10_U64[k] + digits8_value((w << (~tz & 0x38)) << 8)
				}
				return q[k:]
			}
			when fold {
				mant^ = mant^ * POW10_U64[8] + digits8_value(w)
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
		// `mant` is exact up to 19 digits.
		mag, over := n.mant, false
		if n.int_digits > 19 {
			mag, over = fold_u64(src, n.int_at, n.int_digits)
		}
		if !over {
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

// A decimal of more than 19 digits, read by `strconv.parse_f64`. `Wide` on overflow.
@(private, cold)
wide_number :: #force_no_inline proc(span: string) -> Number {
	v, ok := strconv.parse_f64(span)
	if !ok || transmute(u64)v & F64_INF_BITS == F64_INF_BITS {
		return {0, .Wide}
	}
	return {transmute(u64)v, .Float}
}

// The word-at-a-time digit code needs a little-endian target, where the first byte is the low byte of a word.
when ODIN_ENDIAN != .Little {
	#panic("spell: digits8_value requires a little-endian target")
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

// Requires `p + 8 <= len(src)`.
@(private = "file")
load8_le :: #force_inline proc "contextless" (src: []u8, p: u64) -> u64 {
	#no_bounds_check {
		return intrinsics.unaligned_load((^u64)(&src[p]))
	}
}

// Returns the value of the 8 ASCII digits in `w`, first byte most significant.
@(private = "file")
digits8_value :: #force_inline proc "contextless" (w: u64) -> u64 {
	v := w & 0x0F0F_0F0F_0F0F_0F0F
	v = (v * 2561) >> 8
	v &= 0x00FF_00FF_00FF_00FF
	v = (v * (1 + (100 << 16))) >> 16
	return (v & 0xFFFF) * 10000 + (v >> 32 & 0xFFFF)
}
