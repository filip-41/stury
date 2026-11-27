package spell

import "base:intrinsics"
import "base:runtime"
import "core:strconv"

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

// The most digits, zeros included, that a decimal of more than `FOLDED_DIGITS` digits is read from, bounding the work
// of the slow fallback when the decimal's order does not already settle overflow or underflow.
@(private = "file")
MAX_NUMBER_DIGITS :: 4096
// The most digits `Number_Lex.mant` holds exactly.
@(private = "file")
FOLDED_DIGITS :: 19
// The decimal order, 10^`order`, at or above which a value is past binary64's largest and below which it rounds to zero.
@(private = "file")
OVERFLOW_ORDER :: 310
@(private = "file")
UNDERFLOW_ORDER :: -324
// The scale past which `strconv.fast_float_compute_float` answers the same, bounding the `int` it takes.
@(private = "file")
SCALE_CLAMP :: 1000
// The value an exponent stops growing at, past the `i32` range so it still reads as out of range.
@(private = "file")
EXP_SATURATED :: i64(max(i32)) + 1
// Binary64 infinity, which `strconv.fast_float_compute_float` returns on overflow.
@(private = "file")
F64_INF_BITS :: u64(0x7FF) << 52

// The powers of ten exact in binary64, for the Clinger fast path.
@(private, rodata)
POW10_F64 := [23]f64{
	1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,  1e8,  1e9,  1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
}

// A lexed decimal.
@(private = "file")
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

// The value of `src[lo:hi]` read with JSON5's decimal grammar, which also takes a `+` and a point with digits on one
// side only (while still rejecting multi-digit leading zeros), false for a span that is no number.
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
// Caller guarantees `src[lo:hi]` is a walk-validated decimal integer when `lo < hi <= u64(len(src))`.
@(require_results)
number_int :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, digits: int) -> (Number, bool) {
	if lo >= u64(len(src)) {
		return {}, false
	}
	p, neg := skip_sign(raw_data(src), lo)
	if uint(digits - 1) >= 19 || p + u64(digits) != hi || hi > u64(len(src)) {
		return {}, false
	}
	return integer_number(fold_digits_end(src, hi, u64(digits)), neg)
}

// The value of the decimal `src[lo:hi]` with a point and no exponent, from the digit counts a walk found. Only the
// point's place is checked against them.
// Caller guarantees `src[lo:hi]` is a walk-validated decimal with a point when `lo < hi <= u64(len(src))`.
@(require_results)
number_fraction :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number #no_bounds_check {
	base := raw_data(src)
	total := int_digits + frac_digits
	// A point at most 19 bytes before `hi` leaves both digit runs ending past `FOLD_WORDS_FROM`.
	if hi <= u64(len(src)) && uint(int_digits - 1) < 19 && uint(frac_digits - 1) < 19 && total <= 19 && hi >= FOLD_WORDS_FROM + 19 {
		point := hi - u64(frac_digits) - 1
		if lo < point && base[point] == '.' {
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
// Caller guarantees `src[lo:hi]` is a walk-validated decimal with an exponent when `lo < hi <= u64(len(src))`.
@(require_results)
number_exponent :: #force_no_inline proc "contextless" (src: []u8, lo, hi: u64, int_digits, frac_digits: int) -> Number #no_bounds_check {
	if lo >= u64(len(src)) || hi > u64(len(src)) || uint(int_digits) > 19 || uint(frac_digits) > 19 || int_digits + frac_digits > 19 {
		return number_decimal(src, lo, hi)
	}
	base := raw_data(src)
	p, neg := skip_sign(base, lo)
	int_at := p
	if p + u64(int_digits) > hi {
		return number_decimal(src, lo, hi)
	}
	p += u64(int_digits)
	frac_at := p
	if p < hi && base[p] == '.' {
		p += 1
		frac_at = p
		if p + u64(frac_digits) > hi {
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
@(private = "file", require_results)
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
@(private = "file", require_results)
number_decimal :: proc "contextless" (src: []u8, lo, hi: u64) -> Number {
	n := lex_decimal(src, lo, hi, false)
	if !n.ok {
		return {}
	}
	return number_of_lex(src, lo, hi, n)
}

@(private = "file", require_results)
lex_decimal :: proc "contextless" (src: []u8, lo, hi: u64, $LOOSE: bool) -> (n: Number_Lex) #no_bounds_check {
	if lo >= hi || hi > u64(len(src)) {
		return
	}
	base := raw_data(src)
	p := lo
	if base[p] == '-' || LOOSE && base[p] == '+' {
		n.neg = base[p] == '-'
		p += 1
	}
	if p >= hi {
		return
	}
	n.int_at = p
	if base[p] == '0' {
		p += 1
		if p < hi && base[p] - '0' < 10 {
			return
		}
	} else if base[p] - '1' < 9 {
		p = u64(intrinsics.ptr_sub(digit_fold(base[p:], base[hi:], &n.mant, FOLDED_DIGITS), base))
	} else {
		when !LOOSE {
			return
		}
	}
	n.int_digits = p - n.int_at
	if p < hi && base[p] == '.' {
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
	if p < hi && base[p] | 0x20 == 'e' {
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
@(private = "file", require_results)
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
// Caller guarantees `n` came from `lex_decimal(src, lo, hi, ...)`, so `n.int_at + n.int_digits <= hi <= u64(len(src))`.
@(private = "file", require_results)
number_of_lex :: #force_inline proc "contextless" (src: []u8, lo, hi: u64, n: Number_Lex) -> Number #no_bounds_check {
	digits := n.int_digits + n.frac_digits
	e := n.exp - i64(n.frac_digits)
	if !n.has_frac && !n.has_exp {
		// `mant` holds the first 19 digits, which is all of them up to 19. Only a non-negative 20-digit integer can
		// fit `u64`.
		mag, fits := n.mant, true
		if !n.neg && n.int_digits == 20 {
			tens, over := intrinsics.overflow_mul(n.mant, 10)
			carry: bool
			mag, carry = intrinsics.overflow_add(tens, u64(raw_data(src)[n.int_at + 19] - '0'))
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
@(private = "file", require_results)
skip_sign :: #force_inline proc "contextless" (base: [^]u8, lo: u64) -> (p: u64, neg: bool) {
	neg = base[lo] == '-'
	return lo + u64(neg), neg
}

// `mag` with sign `neg` as an `Int` or a `Uint`, false for a negative magnitude past `i64`'s minimum.
@(private, require_results)
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
@(private = "file", cold, require_results)
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
// Caller guarantees `n` came from `lex_decimal(src, lo, hi, ...)`.
@(private = "file", require_results)
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

// Canonical signed decimal parts of an integer text: `neg` and `digits` without leading zeros.
@(require_results)
decimal_parts :: proc "contextless" (s: string) -> (neg: bool, digits: string) {
	t := s
	if len(t) > 0 && t[0] == '-' {
		neg = true
		t = t[1:]
	}
	for len(t) > 1 && t[0] == '0' {
		t = t[1:]
	}
	if t == "0" {
		neg = false
	}
	return neg, t
}

// Whether `s` is a plain decimal integer (optional leading `-`, digits only).
@(require_results)
is_plain_int_dec :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	i := 1 if s[0] == '-' else 0
	if i >= len(s) {
		return false
	}
	for c in transmute([]u8)s[i:] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// The binary64 a `.Wide` decimal text rounds to, including decimals past `MAX_NUMBER_DIGITS` digits whose order still
// falls within binary64's finite range.
@(cold, require_results)
wide_double :: #force_no_inline proc "contextless" (text: []u8) -> f64 {
	if len(text) == 0 {
		return 0
	}
	n := lex_decimal(text, 0, u64(len(text)), true)
	if n.ok {
		sign := u64(n.neg) << 63
		order, any_nonzero := decimal_order(text, n)
		switch {
		case !any_nonzero, order <= UNDERFLOW_ORDER:
			return transmute(f64)sign
		case order >= OVERFLOW_ORDER:
			return transmute(f64)(F64_INF_BITS | sign)
		}
		// Finite order past `MAX_NUMBER_DIGITS` or near the f64 boundary: collect up to 768 significant digits plus a
		// sticky digit so `strconv.parse_f64` rounds every binary64 midpoint exactly.
		SIG_MAX :: 768
		buf: [SIG_MAX + 32]u8 = ---
		w := 0
		if n.neg {
			buf[w] = '-'
			w += 1
		}
		started := false
		sig := 0
		sticky := false
		runs := [2][]u8 {
			text[n.int_at : n.int_at + n.int_digits],
			text[n.frac_at : n.frac_at + n.frac_digits],
		}
		for run in runs {
			for c in run {
				if !started {
					if c == '0' {
						continue
					}
					started = true
				}
				if sig < SIG_MAX {
					buf[w] = c
					w += 1
					sig += 1
				} else if c != '0' {
					sticky = true
				}
			}
		}
		if sticky {
			buf[w] = '1'
			w += 1
			sig += 1
		} else {
			for sig > 1 && buf[w - 1] == '0' {
				w -= 1
				sig -= 1
			}
		}
		buf[w] = 'e'
		w += 1
		ebuf: [24]u8 = ---
		context = runtime.default_context()
		exp_s := strconv.write_int(ebuf[:], order - i64(sig), 10)
		copy(buf[w:], exp_s)
		w += len(exp_s)
		v, ok := strconv.parse_f64(string(buf[:w]))
		if ok || transmute(u64)v & F64_INF_BITS == F64_INF_BITS {
			return v
		}
		return transmute(f64)sign
	}
	context = runtime.default_context()
	if v, ok := strconv.parse_f64(string(text)); ok || transmute(u64)v & F64_INF_BITS == F64_INF_BITS {
		return v
	}
	neg := text[0] == '-'
	big_order := true
	for c, i in text {
		if c | 0x20 == 'e' {
			big_order = i + 1 >= len(text) || text[i + 1] != '-'
			break
		}
	}
	sign := u64(neg) << 63
	return transmute(f64)(F64_INF_BITS | sign) if big_order else transmute(f64)sign
}

// The shortest decimal text of finite `f` that reads back as `f` as binary64, in jq's layout: plain for a decimal
// point of 0.0001 to 10^15 past the digits and an exponent of two digits at least otherwise, with `.0` on whole
// numbers. NaN and infinities have empty text. Caller guarantees `buf` holds at least 32 bytes.
@(cold)
float64_text :: proc "contextless" (f: f64, buf: []u8) -> (string, bool) #no_bounds_check {
	if f - f != 0 {
		return "", true
	}
	// A contextless proc needs a context for `strconv`, whose allocator it does not use.
	context = runtime.default_context()
	scratch: [32]u8
	shortest := strconv.write_float(scratch[:], f, 'e', -1, 64, {})
	at := 0
	negative := shortest[0] == '-'
	if negative {
		at = 1
	}
	digits: [20]u8
	k := 0
	for ; at < len(shortest) && shortest[at] != 'e'; at += 1 {
		if shortest[at] != '.' {
			digits[k] = shortest[at]
			k += 1
		}
	}
	e := 0
	for c in shortest[at + 2:] {
		e = e * 10 + int(c - '0')
	}
	if shortest[at + 1] == '-' {
		e = -e
	}
	for k > 0 && digits[k - 1] == '0' {
		k -= 1
	}
	n := e + 1
	w := 0
	put :: proc "contextless" (buf: []u8, w: ^int, c: u8) {
		buf[w^] = c
		w^ += 1
	}
	if negative {
		put(buf, &w, '-')
	}
	switch {
	case k == 0:
		put(buf, &w, '0')
	case n + 3 >= 0 && n <= k + 15:
		if n <= 0 {
			put(buf, &w, '0')
			put(buf, &w, '.')
			for _ in 0 ..< -n {
				put(buf, &w, '0')
			}
		}
		for c, j in digits[:k] {
			if j == n && n > 0 {
				put(buf, &w, '.')
			}
			put(buf, &w, c)
		}
		for _ in k ..< n {
			put(buf, &w, '0')
		}
	case:
		put(buf, &w, digits[0])
		if k > 1 {
			put(buf, &w, '.')
			for c in digits[1:k] {
				put(buf, &w, c)
			}
		}
		put(buf, &w, 'e')
		put(buf, &w, '+' if n - 1 >= 0 else '-')
		x := abs(n - 1)
		if x >= 100 {
			put(buf, &w, u8('0' + x / 100))
		}
		put(buf, &w, u8('0' + x / 10 % 10))
		put(buf, &w, u8('0' + x % 10))
		return string(buf[:w]), true
	}
	if k <= n || k == 0 {
		put(buf, &w, '.')
		put(buf, &w, '0')
	}
	return string(buf[:w]), true
}
