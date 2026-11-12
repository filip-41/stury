package cbor

import spell "../core/spell"
import core "../core"

// Reads the integer head at the start of `item`, major 0 or 1, into `d` as its magnitude. Returns whether it is
// negative, its length and whether the digits fit.
@(private)
int_digits :: proc "contextless" (item: []u8, d: ^Digits) -> (negative: bool, length: int, ok: bool) {
	major, arg, hl := head_of(item)
	ok = set_u64(d, arg)
	if major == 1 {
		ok = ok && mul_add(d, 1, 1)
	}
	return major == 1, hl, ok
}

// Reads the byte string at the start of `item` into `d` as a big-endian magnitude, plus one when the bignum is negative.
// Returns the string's length and whether the digits fit.
@(private)
bytes_digits :: proc "contextless" (item: []u8, d: ^Digits, negative: bool) -> (length: int, ok: bool) {
	it := chunks_of(item)
	for chunk in chunk_next(&it) {
		if len(chunk) > BIGNUM_BYTES_MAX {
			return 0, false
		}
		for b in chunk {
			if !mul_add(d, 256, u32(b)) {
				return 0, false
			}
		}
	}
	if negative && !mul_add(d, 1, 1) {
		return 0, false
	}
	return string_length(item), true
}

// The length of the byte string at the start of `item`, its break included when it is in chunks.
@(private)
string_length :: proc "contextless" (item: []u8) -> int {
	if item[0] & 31 != 31 {
		_, arg, hl := head_of(item)
		return hl + int(arg)
	}
	it := chunks_run(item[1:])
	for _ in chunk_next(&it) {}
	return 1 + it.pos + 1
}

// Reads a mantissa, an integer or a bignum with its tag, at the start of `item`.
@(private)
mantissa_digits :: proc "contextless" (item: []u8, d: ^Digits) -> (negative: bool, ok: bool) {
	if item[0] >> 5 != 6 {
		negative, _, ok = int_digits(item, d)
		return
	}
	_, tag, hl := head_of(item)
	negative = tag == 3
	_, ok = bytes_digits(item[hl:], d, negative)
	return
}

// Writes `d` into `buf` as decimal text with its sign. `d.buf` is `buf[1:]`, so the sign has the byte before the digits.
@(private)
digits_text :: proc "contextless" (d: ^Digits, buf: []u8, negative: bool) -> string {
	if d.n == 0 {
		buf[1] = '0'
		return string(buf[1:2])
	}
	digits := buf[1:1 + d.n]
	for &c in digits {
		c += '0'
	}
	for k in 0 ..< d.n / 2 {
		digits[k], digits[d.n - 1 - k] = digits[d.n - 1 - k], digits[k]
	}
	if negative {
		buf[0] = '-'
		return string(buf[:1 + d.n])
	}
	return string(digits)
}

// CBOR's `Readers.number_text`: the decimal digits of number token `t`. An integer, a tag and a bignum give their
// digits, a float its shortest digits, and none for an infinity or a NaN, a decimal fraction `<mantissa>e<exponent>`,
// and a bigfloat its exact value, a negative exponent as `e-<places>`. Returns false when `buf` is too short, or when a
// bigfloat's exponent or a bignum is larger than the digits are bounded to.
number_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	if t.kind != .Number {
		return "", false
	}
	span := v.src[t.lo:t.lo + u64(t.n)]
	if t.role == .Tag {
		return integer_text(span, buf)
	}
	switch t.spelling & core.NUMBER_KIND_MASK {
	case CN_INT:
		return integer_text(span, buf)
	case CN_FLOAT:
		return float_text(span, buf)
	case CN_BIG:
		if len(buf) < 2 {
			return "", false
		}
		d := Digits{buf = buf[1:]}
		negative := t.spelling & NEGATIVE != 0
		_, fit := bytes_digits(span, &d, negative)
		if !fit {
			return "", false
		}
		return digits_text(&d, buf, negative), true
	case CN_DEC, CN_BIGFLOAT:
		return decimal_text(span, t.spelling & core.NUMBER_KIND_MASK == CN_BIGFLOAT, buf)
	}
	return "", false
}

// The decimal digits of the integer or tag whose head `span` starts with, which need 21 bytes of `buf`.
@(private)
integer_text :: proc "contextless" (span: []u8, buf: []u8) -> (s: string, ok: bool) {
	major, arg, _ := head_of(span)
	if len(buf) < 21 {
		return "", false
	}
	switch {
	case major != 1:
		return string(buf[:spell.u64_text(raw_data(buf), arg)]), true
	case arg <= u64(max(i64)):
		return string(buf[:spell.i64_text(raw_data(buf), -1 - i64(arg))]), true
	}
	d := Digits{buf = buf[1:]}
	set_u64(&d, arg)
	mul_add(&d, 1, 1)
	return digits_text(&d, buf, true), true
}

@(private)
float_text :: proc "contextless" (span: []u8, buf: []u8) -> (s: string, ok: bool) {
	f := transmute(f64)float(span)
	if f - f != 0 {
		return "", true
	}
	if len(buf) < spell.F64_ROOM {
		return "", false
	}
	return string(buf[:spell.f64_text(raw_data(buf), f)]), true
}

// The text of a decimal fraction or a bigfloat whose array is `span`.
@(private)
decimal_text :: proc "contextless" (span: []u8, binary: bool, buf: []u8) -> (s: string, ok: bool) {
	pos := 1
	if span[0] & 31 != 31 {
		_, _, pos = head_of(span)
	}
	major, earg, ehl := head_of(span[pos:])
	exp := i64(min(earg, u64(max(i64) >> 1)))
	if major == 1 {
		exp = -1 - exp
	}
	if len(buf) < 2 {
		return "", false
	}
	d := Digits{buf = buf[1:]}
	negative, fit := mantissa_digits(span[pos + ehl:], &d)
	if !fit {
		return "", false
	}
	places := i64(0)
	if binary {
		if exp > EXPONENT_MAX || exp < -EXPONENT_MAX {
			return "", false
		}
		left, factor, step := exp, u32(2), 30
		if exp < 0 {
			left, factor, step, places = -exp, 5, 13, -exp
		}
		for left > 0 {
			k := min(left, i64(step))
			m := u32(1)
			for _ in 0 ..< k {
				m *= factor
			}
			if !mul_add(&d, m, 0) {
				return "", false
			}
			left -= k
		}
	}
	text := digits_text(&d, buf, negative)
	from := int(uintptr(raw_data(text)) - uintptr(raw_data(buf)))
	used := from + len(text)
	suffix: [24]u8
	w := 0
	switch {
	case binary && places > 0:
		suffix[0], suffix[1] = 'e', '-'
		w = 2 + spell.u64_text(raw_data(suffix[2:]), u64(places))
	case !binary:
		suffix[0] = 'e'
		w = 1 + spell.i64_text(raw_data(suffix[1:]), exp)
	}
	if used + w > len(buf) {
		return "", false
	}
	copy(buf[used:], suffix[:w])
	return string(buf[from:used + w]), true
}

// CBOR's `Readers.fact`: node `i`'s tag as its decimal digits, the tag nearest the item when several are stacked. The
// digits are in the temp allocator, since the span holds the tag's head and not its text.
@(private)
fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Name) -> (core.Fact_Value, bool) {
	if name != .Tag || len(doc.facts) == 0 {
		return {}, false
	}
	#reverse for f in core.all_facts(doc, i) {
		if f.role != .Tag || f.kind != .Number {
			continue
		}
		buf, failed := make([]u8, 21, context.temp_allocator)
		if failed != nil {
			return {}, false
		}
		digits, _ := integer_text(doc.src[f.lo:f.lo + u64(f.n)], buf)
		return {text = digits, numeric = true}, true
	}
	return {}, false
}
