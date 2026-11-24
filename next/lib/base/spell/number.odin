package spell

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"
import "stury:lib/base/kernel"

// A number's value, read from its decimal text.
Number :: struct {
	bits: u64, // the value's bits as `kind` reads them
	kind: Number_Kind,
}

#assert(size_of(Number) == 16)

Number_Kind :: enum u8 {
	Int, // fits `i64`, and `-0` is 0
	Uint, // fits only `u64`
	Float, // the correctly rounded binary64, keeping the sign of `-0.0` and of an underflow to zero
	Wide, // past binary64's range, or a span of more than `MAX_NUMBER_DIGITS` digits whose size does not settle it
}

// The most digits, zeros included, that a decimal of more than `FOLDED_DIGITS` digits is read from, as a bound on the
// work. It keeps every exponent such a decimal's value allows below the 10^4 `strconv.parse_f64` reads.
@(private)
MAX_NUMBER_DIGITS :: 4096
// The most digits `Number_Lex.mant` holds exactly.
@(private)
FOLDED_DIGITS :: 19
// The decimal order, 10^`order`, at or above which a value is past binary64's largest and below which it rounds to zero.
@(private)
OVERFLOW_ORDER :: 310
@(private)
UNDERFLOW_ORDER :: -324
// The scale past which `strconv.fast_float_compute_float` answers the same, bounding the `int` it takes.
@(private)
SCALE_CLAMP :: 1000
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
	mant:                 u64, // the first `FOLDED_DIGITS` digits of both runs, all of them when there are no more
	neg, has_frac:        bool,
	has_exp, ok:          bool, // `ok`: the span is exactly one number
}

// The value of `src[lo:hi]` read with RFC 8259's number grammar, false for a span that is no number.
@(require_results)
number_strict :: proc "contextless" (src: []u8, lo, hi: u64) -> (Number, bool) {
	if num, ok := number_short(src, lo, hi); ok {
		return num, true
	}
	n := lex_decimal(src, lo, hi, false)
	if !n.ok {
		return {}, false
	}
	return number_of_lex(src, lo, hi, n), true
}

// The value of `src[lo:hi]` when it is a short RFC 8259 number with no exponent: at most 16 bytes past its sign, digits
// with at most one point between two of them, and with 16 bytes of `src` from its first digit. False for any other
// span, which `number_strict` reads. The span is judged in two words, with no loop over its bytes.
@(require_results)
number_short :: #force_inline proc "contextless" (src: []u8, lo, hi: u64) -> (num: Number, ok: bool) #no_bounds_check {
	base := raw_data(src)
	if lo >= hi {
		return
	}
	neg := base[lo] == '-'
	p := lo + u64(neg)
	m := hi - p
	if m == 0 || m > 16 {
		return
	}
	if m <= 8 && p + 8 <= u64(len(src)) {
		return short_word(base[p:], m, neg)
	}
	if p + 16 > u64(len(src)) {
		return
	}
	// The bytes past the span read as `0` digits.
	w0, w1 := short_pad(kernel.load8(base[p:]), m), short_pad(kernel.load8(base[p + 8:]), m - min(m, 8))
	k := short_nondigit(w0, w1)
	if k >= m {
		if m > 1 && base[p] == '0' {
			return
		}
		return integer_number(short_digits(w0, w1, m), neg)
	}
	if base[p + k] != '.' || k == 0 || k == m - 1 || k > 1 && base[p] == '0' {
		return
	}
	// The point read as a `0` digit, which no other non-digit may follow.
	x := (u128(w0) | u128(w1) << 64) &~ (u128(0xFF) << (8 * k)) | u128(0x30) << (8 * k)
	if short_nondigit(u64(x), u64(x >> 64)) < m {
		return
	}
	low := u128(1) << (8 * k) - 1
	merged := x & low | x >> 8 &~ low
	v := f64(short_digits(u64(merged), u64(merged >> 64), m - 1)) / POW10_F64[m - k - 1]
	return {transmute(u64)(-v if neg else v), .Float}, true
}

// The value of `src[lo:hi]` when it is an RFC 8259 integer of at most 16 digits with 8 bytes of `src` from its first
// digit, read in one or two words. False for any other span, which `number_short` or `number_strict` reads.
@(require_results)
integer_short :: #force_inline proc "contextless" (src: []u8, lo, hi: u64) -> (v: i64, ok: bool) #no_bounds_check {
	base := raw_data(src)
	if lo >= hi {
		return
	}
	neg := base[lo] == '-'
	p := lo + u64(neg)
	m := hi - p
	if m - 1 >= 16 || p + 8 > u64(len(src)) || m > 1 && base[p] == '0' {
		return
	}
	// Each byte less `0` is a digit when it and it plus 6 keep their high nibble clear.
	ZEROS :: 0x3030_3030_3030_3030
	mag: u64
	if m <= 8 {
		x := (kernel.load8(base[p:]) ~ ZEROS) << (8 * (8 - m))
		if ((x + 0x0606_0606_0606_0606) | x) & 0xF0F0_F0F0_F0F0_F0F0 != 0 {
			return
		}
		mag = digits8_nibbles(x)
	} else {
		x := (kernel.load8(base[p:]) ~ ZEROS) << (8 * (16 - m))
		y := kernel.load8(base[p + m - 8:]) ~ ZEROS
		if ((x + 0x0606_0606_0606_0606) | x | (y + 0x0606_0606_0606_0606) | y) & 0xF0F0_F0F0_F0F0_F0F0 != 0 {
			return
		}
		mag = digits8_nibbles(x) * 100_000_000 + digits8_nibbles(y)
	}
	return -i64(mag) if neg else i64(mag), true
}

// The binary64 of `src[lo:hi]` when it is an RFC 8259 number with no exponent, at most 8 digits before its point and 8
// after it, 15 in all, and 17 bytes of `src` from its first digit. Its digits and the power of ten are exact, so the
// one division rounds once. The words are read whatever the point's place, with no branch on it. False for any other
// span, which `number_short` or `number_strict` reads.
@(require_results)
float_short :: #force_inline proc "contextless" (src: []u8, lo, hi: u64) -> (v: f64, ok: bool) #no_bounds_check {
	base := raw_data(src)
	if lo >= hi {
		return
	}
	neg := base[lo] == '-'
	p := lo + u64(neg)
	m := hi - p
	if m - 1 >= 16 || p + 17 > u64(len(src)) {
		return
	}
	ZEROS :: 0x3030_3030_3030_3030
	w := kernel.load8(base[p:])
	dots := w ~ 0x2E2E_2E2E_2E2E_2E2E
	// The place of the first point in the first word, 8 for none.
	point := u64(intrinsics.count_trailing_zeros((dots - 0x0101_0101_0101_0101) &~ dots & 0x8080_8080_8080_8080)) >> 3
	frac := m - point - 1 if point < m else 0
	point = min(point, m)
	if point == 0 || point == 8 && m > 8 || frac > 8 || point + frac > 15 || point < m && frac == 0 || point > 1 && base[p] == '0' {
		return
	}
	x := (w ~ ZEROS) << (8 * (8 - point))
	y := (kernel.load8(base[p + point + 1:]) ~ ZEROS) << (8 * (8 - frac)) if frac > 0 else 0
	if ((x + 0x0606_0606_0606_0606) | x | (y + 0x0606_0606_0606_0606) | y) & 0xF0F0_F0F0_F0F0_F0F0 != 0 {
		return
	}
	v = f64(digits8_nibbles(x) * POW10_U64[frac] + digits8_nibbles(y)) / POW10_F64[frac]
	return -v if neg else v, true
}

// `number_short` of the `m` bytes at `p`, at most 8, after the sign, in one word.
@(private)
short_word :: #force_inline proc "contextless" (p: [^]u8, m: u64, neg: bool) -> (num: Number, ok: bool) #no_bounds_check {
	w := short_pad(kernel.load8(p), m)
	nd := short_marks(w)
	if nd == 0 {
		if m > 1 && p[0] == '0' {
			return
		}
		return integer_number(digits8_value(w << (8 * (8 - m))), neg)
	}
	k := u64(intrinsics.count_trailing_zeros(nd)) >> 3
	if p[k] != '.' || k == 0 || k == m - 1 || k > 1 && p[0] == '0' {
		return
	}
	// The point read as a `0` digit, which no other non-digit may follow.
	w = w &~ (u64(0xFF) << (8 * k)) | u64(0x30) << (8 * k)
	if short_marks(w) != 0 {
		return
	}
	low := u64(1) << (8 * k) - 1
	merged := w & low | w >> 8 &~ low
	v := f64(digits8_value(merged << (8 * (9 - m)))) / POW10_F64[m - k - 1]
	return {transmute(u64)(-v if neg else v), .Float}, true
}

// The high bits of the bytes of `w` that are no digit, exact for the first such byte only, as a later one may be
// marked by its carry.
@(private)
short_marks :: #force_inline proc "contextless" (w: u64) -> u64 {
	return ((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
}

// Word `w` of a short number's span with its bytes from `k` on, `k` below 8, set to `0` digits.
@(private)
short_pad :: #force_inline proc "contextless" (w: u64, k: u64) -> u64 {
	if k >= 8 {
		return w
	}
	keep := u64(1) << (8 * k) - 1
	return w & keep | 0x3030_3030_3030_3030 &~ keep
}

// The place of the first byte of the 16 in `w0` and `w1` that is no digit, 16 for none. A byte past the first such one
// may be marked by its carry, and is not read.
@(private)
short_nondigit :: #force_inline proc "contextless" (w0, w1: u64) -> u64 {
	if m0 := short_marks(w0); m0 != 0 {
		return u64(intrinsics.count_trailing_zeros(m0)) >> 3
	}
	m1 := short_marks(w1)
	return 8 + u64(intrinsics.count_trailing_zeros(m1)) >> 3 if m1 != 0 else 16
}

// The value of the first `t` digits, 1 to 16, of the 16 bytes in `w0` and `w1`.
@(private)
short_digits :: #force_inline proc "contextless" (w0, w1: u64, t: u64) -> u64 {
	if t <= 8 {
		return digits8_value(w0 << (8 * (8 - t)))
	}
	return digits8_value(w0) * POW10_U64[t - 8] + digits8_value(w1 << (8 * (16 - t)))
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
					w := kernel.load8(base[start:])
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
	whole := fold_digits_end(src, int_at + u64(int_digits), u64(int_digits)) if int_digits > 0 else 0
	frac := fold_digits_end(src, frac_at + u64(frac_digits), u64(frac_digits)) if frac_digits > 0 else 0
	return number_significand(whole * POW10_U64[frac_digits] + frac, e, neg)
}

// The correctly rounded binary64 of `mant` × 10^`e` with sign `neg`, or `Wide` on overflow. Up to 2^53 both `mant` and
// `10^|e|` (for `|e| <= 22`) are exact in binary64, so Clinger's single operation holds. A positive `e` to 37 moves the
// excess powers into `mant`, which stays an exact integer while it is at most 10^15.
number_significand :: #force_inline proc "contextless" (mant: u64, e: i64, neg: bool) -> Number {
	if mant <= 1 << 53 {
		if e >= -22 && e <= 22 {
			f := f64(mant)
			v := f * POW10_F64[e] if e >= 0 else f / POW10_F64[-e]
			return {transmute(u64)(-v if neg else v), .Float}
		}
		if e > 22 && e <= 37 {
			f := f64(mant) * POW10_F64[e - 22]
			if f <= 1e15 {
				v := f * POW10_F64[22]
				return {transmute(u64)(-v if neg else v), .Float}
			}
		}
	}
	if e == 0 {
		v := f64(mant)
		return {transmute(u64)(-v if neg else v), .Float}
	}
	b := #force_inline strconv.fast_float_compute_float(f64, int(clamp(e, -SCALE_CLAMP, SCALE_CLAMP)), mant)
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
		p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant, FOLDED_DIGITS), base))
	} else {
		if src[p] == '0' {
			p += 1
			if p < hi && src[p] - '0' < 10 {
				return
			}
		} else if src[p] - '1' < 9 {
			p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant, FOLDED_DIGITS), base))
		} else {
			return
		}
	}
	n.int_digits = p - n.int_at
	if p < hi && src[p] == '.' {
		n.has_frac = true
		p += 1
		n.frac_at = p
		room := FOLDED_DIGITS - int(min(n.int_digits, FOLDED_DIGITS))
		p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant, room), base))
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
	if !n.has_frac && !n.has_exp {
		// `mant` holds the first 19 digits, which is all of them up to 19. Only a non-negative 20-digit integer can
		// fit `u64`.
		mag, fits := n.mant, true
		if !n.neg && n.int_digits == 20 {
			tens, over := intrinsics.overflow_mul(n.mant, 10)
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
	if digits <= FOLDED_DIGITS {
		return number_significand(n.mant, e, n.neg)
	}
	return long_number(src, lo, hi, n)
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

// The value of a decimal of more than 19 digits. Its size settles an overflow or an underflow to zero whatever its
// length, as an exponent of any size scales the digits it follows.
@(private, cold)
long_number :: #force_no_inline proc "contextless" (src: []u8, lo, hi: u64, n: Number_Lex) -> Number {
	order, any_nonzero := decimal_order(src, n)
	switch {
	case !any_nonzero, order <= UNDERFLOW_ORDER:
		return {u64(n.neg) << 63, .Float}
	case order >= OVERFLOW_ORDER, n.int_digits + n.frac_digits > MAX_NUMBER_DIGITS:
		return {0, .Wide}
	}
	// `parse_f64` allocates nothing, so the default context serves it.
	context = runtime.default_context()
	v, ok := strconv.parse_f64(string(src[lo:hi]))
	if !ok || transmute(u64)v & F64_INF_BITS == F64_INF_BITS {
		return {0, .Wide}
	}
	return {transmute(u64)v, .Float}
}

// The order of a lexed decimal, the `k` with its value in [10^(k-1), 10^k), and whether any digit is nonzero.
@(private)
decimal_order :: proc "contextless" (src: []u8, n: Number_Lex) -> (order: i64, any_nonzero: bool) #no_bounds_check {
	for i in 0 ..< n.int_digits {
		if src[n.int_at + i] != '0' {
			return i64(n.int_digits - i) + n.exp, true
		}
	}
	for i in 0 ..< n.frac_digits {
		if src[n.frac_at + i] != '0' {
			return n.exp - i64(i), true
		}
	}
	return 0, false
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
