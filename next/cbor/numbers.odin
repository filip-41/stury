package cbor

import "base:intrinsics"
import "core:math"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The values of CBOR's number tokens: integers, floats widened to binary64, bignums, decimal fractions and bigfloats,
// and a tag's number, each read as `spell.Number` reads a decimal of its value: an integer when `i64` or `u64` holds
// it, else a binary64 when it holds the value exactly, else `Wide`, whose digits `node_text` gives. So a bignum or an
// integer past `u64`, a decimal fraction and a bigfloat read as a float only when it is one exactly.

// The most payload bytes of a bignum, or of the mantissa of a decimal fraction or a bigfloat, whose text a number node
// gives, and the largest exponent of a bigfloat whose text it gives. A number past either has no text, and `text_room`
// says so by giving 0. They bound the work a hostile item asks for, as the digits of a bignum take time quadratic in
// its size.
BIGNUM_BYTES_MAX :: 8192
@(private)
EXPONENT_MAX :: 5000

// The value of number node `t` of `src`. A tag fact's is its tag number.
@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	span := src[t.lo:t.lo + u64(t.n)]
	if t.role == .Tag {
		_, arg, _ := head_of(span)
		return {arg, .Int if arg <= u64(max(i64)) else .Uint}
	}
	switch t.spelling & tape.NUMBER_KIND {
	case NUMBER_FLOAT:
		return {float_bits(span), .Float}
	case NUMBER_BIG, NUMBER_BIG_NEGATIVE:
		return bignum(span, t.spelling & tape.NUMBER_KIND == NUMBER_BIG_NEGATIVE)
	case NUMBER_DECIMAL:
		if !decimal_exact(span) {
			return {0, .Wide}
		}
		// A decimal fraction whose text is longer than this reads as `Wide`.
		stack: [192]u8
		limbs: [24]u32 = ---
		text, ok := fraction_text(span, stack[:], limbs[:], false)
		if !ok {
			return {0, .Wide}
		}
		n, valid := spell.number_strict(transmute([]u8)text, 0, u64(len(text)))
		return n if valid else {0, .Wide}
	case NUMBER_BIGFLOAT:
		return bigfloat(span)
	}
	return integer(span)
}

// `number_value` for a typed read's hook, which reads an unsigned integer and a binary64 in place and gives any other
// number to `number_value`.
@(private)
number_in_place :: #force_inline proc "contextless" (src: []u8, t: tape.Node) -> spell.Number #no_bounds_check {
	if t.role != .Tag {
		b := src[t.lo]
		switch t.spelling & tape.NUMBER_KIND {
		case NUMBER_INT:
			if b < 0x20 {
				arg, _, _ := read_head(src, t.lo, b)
				return {arg, .Int if arg <= u64(max(i64)) else .Uint}
			}
		case NUMBER_FLOAT:
			if b == 0xfb {
				return {u64(intrinsics.unaligned_load((^u64be)(raw_data(src)[t.lo + 1:]))), .Float}
			}
		}
	}
	return number_value(src, t)
}

// The number kind of the number token at `lo`: a float for an initial byte of `f9` or above, else an integer. `hi` is
// unused, as the slot of `Format` takes it.
@(private)
respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	return NUMBER_FLOAT if src[lo] >= 0xf9 else NUMBER_INT
}

// The head of the item at the start of `span`.
@(private)
head_of :: #force_inline proc "contextless" (span: []u8) -> (major: u8, arg: u64, hl: u64) {
	major = span[0] >> 5
	arg, hl, _ = read_head(span, 0, span[0] & 31)
	return
}

@(private)
integer :: proc "contextless" (span: []u8) -> spell.Number {
	major, arg, _ := head_of(span)
	if major == 1 {
		if arg > u64(max(i64)) {
			// `arg + 1` overflows for the largest argument, whose value is -2^64.
			if arg == max(u64) {
				return {transmute(u64)f64(-18446744073709551616.0), .Float}
			}
			return {transmute(u64)(-f64(arg + 1)), .Float} if holds_exactly(u128(arg) + 1) else {0, .Wide}
		}
		return {u64(-1 - i64(arg)), .Int}
	}
	return {arg, .Int if arg <= u64(max(i64)) else .Uint}
}

// Whether binary64 holds the integer `m` exactly: its bits from the highest set to the lowest set fit its 53.
@(private)
holds_exactly :: #force_inline proc "contextless" (m: u128) -> bool {
	return m == 0 || 128 - intrinsics.count_leading_zeros(m) - intrinsics.count_trailing_zeros(m) <= 53
}

@(private)
float_bits :: proc "contextless" (span: []u8) -> u64 {
	f: f64
	switch len(span) {
	case 3:
		f = f64(transmute(f16)(u16(span[1]) << 8 | u16(span[2])))
	case 5:
		f = f64(transmute(f32)(u32(span[1]) << 24 | u32(span[2]) << 16 | u32(span[3]) << 8 | u32(span[4])))
	case:
		return u64(intrinsics.unaligned_load((^u64be)(raw_data(span[1:9]))))
	}
	return transmute(u64)f
}

// The value of the bignum whose byte string `span` is, `-1 - n` for a negative one of payload `n`.
@(private)
bignum :: proc "contextless" (span: []u8, negative: bool) -> spell.Number {
	// A magnitude of more significant bytes than this is past binary64's range.
	MOST :: 129
	// `digits[1:n]` is the magnitude, with a byte before it for the carry of the one a negative bignum adds.
	digits: [MOST + 2]u8
	n := 1
	r := string_run(span)
	for chunk in text_next(&r) {
		for b in chunk {
			if n == 1 && b == 0 {
				continue
			}
			if n > MOST {
				return {0, .Wide}
			}
			digits[n] = b
			n += 1
		}
	}
	from := 1
	if negative {
		k := n - 1
		for ; k >= 1 && digits[k] == 0xff; k -= 1 {
			digits[k] = 0
		}
		digits[k] += 1
		from = min(k, 1)
	}
	mag := digits[from:n]
	if len(mag) <= 8 {
		m: u64
		for b in mag {
			m = m << 8 | u64(b)
		}
		if !negative {
			return {m, .Int if m <= u64(max(i64)) else .Uint}
		}
		if m - 1 <= u64(max(i64)) {
			return {u64(-i64(m - 1) - 1), .Int}
		}
	}
	// The top 64 bits, with their lowest set for any bit past them, round to binary64 as the whole magnitude does.
	top: u64
	for b in mag[:min(8, len(mag))] {
		top = top << 8 | u64(b)
	}
	sticky := false
	for b in mag[min(8, len(mag)):] {
		sticky ||= b != 0
	}
	if sticky || !holds_exactly(u128(top)) {
		return {0, .Wide}
	}
	f := math.ldexp(f64(top), 8 * max(len(mag) - 8, 0))
	if math.is_inf(f) {
		return {0, .Wide}
	}
	return {transmute(u64)(-f if negative else f), .Float}
}

// The value of a bigfloat, when its mantissa is an integer binary64 holds and its exponent is in range.
@(private)
bigfloat :: proc "contextless" (span: []u8) -> spell.Number {
	pos := array_body(span)
	emajor, earg, ehl := head_of(span[pos:])
	mmajor, marg, _ := head_of(span[pos + ehl:])
	if earg > EXPONENT_MAX || mmajor > 1 || marg >= 1 << 53 {
		return {0, .Wide}
	}
	exp := int(earg) if emajor == 0 else -1 - int(earg)
	m := f64(marg) if mmajor == 0 else -1 - f64(marg)
	f := math.ldexp(m, exp)
	// A value past binary64's range, or that rounds to zero or into the subnormals, binary64 holds inexactly.
	if m != 0 && (math.is_inf(f) || abs(f) < 0h0010_0000_0000_0000) {
		return {0, .Wide}
	}
	return {transmute(u64)f, .Float}
}

// Whether binary64 holds the decimal fraction whose array is `span` exactly: a mantissa and an exponent that a few
// digits spell, `m * 10^e` for an `e` of at most 27 either way, whose integer or whose quotient by `5^-e` has 53 bits.
// A longer one, and a bignum mantissa, read as `Wide` though binary64 may hold them.
@(private)
decimal_exact :: proc "contextless" (span: []u8) -> bool {
	pos := array_body(span)
	emajor, earg, ehl := head_of(span[pos:])
	mantissa := span[pos + ehl:]
	if mantissa[0] >> 5 > 1 {
		return false
	}
	mmajor, marg, _ := head_of(mantissa)
	m := u128(marg) + u128(mmajor)
	if m == 0 {
		return true
	}
	if earg > 27 {
		return false
	}
	if emajor == 0 {
		for _ in 0 ..< earg {
			m *= 10
		}
		return holds_exactly(m)
	}
	// The exponent is -1 - earg.
	five := u128(1)
	for _ in 0 ..= earg {
		five *= 5
	}
	return m % five == 0 && holds_exactly(m / five)
}

// The offset of the first item of the array `span` starts with.
@(private)
array_body :: #force_inline proc "contextless" (span: []u8) -> u64 {
	if span[0] & 31 == 31 {
		return 1
	}
	_, _, hl := head_of(span)
	return hl
}
