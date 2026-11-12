package cbor

import "base:intrinsics"
import "core:math"
import spell "../core/spell"
import core "../core"

// The bignum and exponent sizes `number_text` spells, which bound the work a hostile item can ask for.
@(private)
BIGNUM_BYTES_MAX :: 8192
@(private)
EXPONENT_MAX :: 5000

// CBOR's `Readers.number`, exported so a caller that knows the format calls it without the table: the value of number
// token `t`, which is an integer, a float widened to binary64, a bignum, a decimal fraction or a bigfloat. A tag fact is
// its tag number. A bignum, decimal fraction or bigfloat that binary64 or `Int` cannot hold exactly reads as `Wide`,
// with its digits in `number_text`.
number :: proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	if t.kind != .Number {
		return {}, false
	}
	span := v.src[t.lo:t.lo + u64(t.n)]
	if t.role == .Tag {
		return integer(span)
	}
	switch t.spelling & core.NUMBER_KIND_MASK {
	case CN_INT:
		return integer(span)
	case CN_FLOAT:
		return {float(span), .Float}, true
	case CN_BIG:
		return bignum(span, t.spelling & NEGATIVE != 0)
	case CN_DEC:
		stack: [192]u8
		text, ok := number_text(v, t, stack[:])
		if !ok {
			return {0, .Wide}, true
		}
		n, valid := spell.number_strict(stack[:len(text)], 0, u64(len(text)))
		return n if valid else {0, .Wide}, true
	case CN_BIGFLOAT:
		return bigfloat(span)
	}
	return {}, false
}

// The head of the item at the start of `span`.
@(private)
head_of :: #force_inline proc "contextless" (span: []u8) -> (major: u8, arg: u64, hl: int) {
	major = span[0] >> 5
	arg, hl, _ = head(span, 0, span[0] & 31)
	return
}

@(private)
integer :: proc "contextless" (span: []u8) -> (core.Number, bool) {
	major, arg, _ := head_of(span)
	if major == 1 {
		if arg > u64(max(i64)) {
			return {0, .Wide}, true
		}
		return {u64(-1 - i64(arg)), .Int}, true
	}
	return {arg, .Int if arg <= u64(max(i64)) else .Uint}, true
}

@(private)
float :: proc "contextless" (span: []u8) -> u64 {
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

// The payload chunks of a byte string item, or of the run of chunks that follows an indefinite string's first byte.
@(private)
Chunks :: struct {
	src:      []u8,
	pos:      int,
	indef:    bool,
	consumed: bool,
}

// The chunks of the string item `item`, which starts at its head.
@(private)
chunks_of :: #force_inline proc "contextless" (item: []u8) -> Chunks {
	if item[0] & 31 == 31 {
		return {src = item, pos = 1, indef = true}
	}
	_, arg, hl := head_of(item)
	return {src = item[hl:hl + int(arg)]}
}

// The chunks of the span of an indefinite string token.
@(private)
chunks_run :: #force_inline proc "contextless" (span: []u8) -> Chunks {
	return {src = span, indef = true}
}

@(private)
chunk_next :: proc "contextless" (c: ^Chunks) -> (chunk: []u8, ok: bool) {
	if !c.indef {
		if c.consumed {
			return nil, false
		}
		c.consumed = true
		return c.src, true
	}
	if c.pos >= len(c.src) || c.src[c.pos] == 0xff {
		return nil, false
	}
	arg, hl, _ := read_head(c.src, c.pos, c.src[c.pos] & 31)
	chunk = c.src[c.pos + hl:c.pos + hl + int(arg)]
	c.pos += hl + int(arg)
	return chunk, true
}

@(private)
bignum :: proc "contextless" (span: []u8, negative: bool) -> (core.Number, bool) {
	m: u64
	significant := 0
	it := chunks_of(span)
	for chunk in chunk_next(&it) {
		for b in chunk {
			if significant == 0 && b == 0 {
				continue
			}
			significant += 1
			if significant > 8 {
				return {0, .Wide}, true
			}
			m = m << 8 | u64(b)
		}
	}
	if m > u64(max(i64)) {
		return {m, .Uint} if !negative else {0, .Wide}, true
	}
	return {u64(-1 - i64(m)) if negative else m, .Int}, true
}

// The decimal digits of a number, little-endian, in `buf`, with room for the sign before them.
@(private)
Digits :: struct {
	buf: []u8,
	n:   int,
}

// Sets `d` to `d * mul + add`. Returns false when the digits fill `buf`.
@(private)
mul_add :: proc "contextless" (d: ^Digits, mul: u32, add: u32) -> bool {
	carry := u64(add)
	for k in 0 ..< d.n {
		v := u64(d.buf[k]) * u64(mul) + carry
		d.buf[k], carry = u8(v % 10), v / 10
	}
	for carry > 0 {
		if d.n == len(d.buf) {
			return false
		}
		d.buf[d.n] = u8(carry % 10)
		d.n += 1
		carry /= 10
	}
	return true
}

// Sets `d`, which is zero, to `v`.
@(private)
set_u64 :: proc "contextless" (d: ^Digits, v: u64) -> bool {
	v := v
	for v > 0 {
		if d.n == len(d.buf) {
			return false
		}
		d.buf[d.n] = u8(v % 10)
		d.n += 1
		v /= 10
	}
	return true
}


// The value of a bigfloat, when its mantissa is an integer binary64 holds and its exponent is in range.
@(private)
bigfloat :: proc "contextless" (span: []u8) -> (core.Number, bool) {
	pos := 1
	if span[0] & 31 != 31 {
		_, _, pos = head_of(span)
	}
	emajor, earg, ehl := head_of(span[pos:])
	mmajor, marg, _ := head_of(span[pos + ehl:])
	if earg > EXPONENT_MAX || mmajor > 1 || marg >= 1 << 53 {
		return {0, .Wide}, true
	}
	exp := int(earg) if emajor == 0 else -1 - int(earg)
	m := f64(marg) if mmajor == 0 else -1 - f64(marg)
	return {transmute(u64)math.ldexp(m, exp), .Float}, true
}
