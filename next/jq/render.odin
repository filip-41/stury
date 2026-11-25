package jq

import "stury:lib/base/spell"
import "stury:lib/query"

// jq's words for the engine's values and errors.

@(private)
type_name :: proc(v: query.Value) -> string {
	switch query.type_of(v) {
	case .Absent, .Null:
		return "null"
	case .False, .True:
		return "boolean"
	case .Number:
		return "number"
	case .String:
		return "string"
	case .Array:
		return "array"
	case .Object:
		return "object"
	}
	return "null"
}

// `v` as jq's messages show a value (jv_dump_string_trunc into `size` bytes): compact JSON, cut to fit with "..." and
// the closing quote or bracket, a long string first cut to `size` characters. In the context allocator.
@(private)
brief :: proc(h: ^query.Heap, v: query.Value, size := 30) -> string {
	out := make([dynamic]u8)
	write_brief(h, &out, v, size)
	return string(out[:])
}

// Appends `v` as `brief` spells it to `out`.
@(private)
write_brief :: proc(h: ^query.Heap, out: ^[dynamic]u8, v: query.Value, size := 30) {
	from := len(out)
	if query.is_text(v) && len(query.text_of(v)) > size {
		s := query.text_of(v)
		_ = query.write_text(h, out, s[:codepoint_bytes(s, size)])
	} else if query.write_json(h, out, v, {double = jq_double, too_deep = TOO_DEEP}) != .Ok {
		query.clear_error(h)
	}
	s := string(out[from:])
	if len(s) < size {
		return
	}
	close := ""
	switch s[0] {
	case '"':
		close = `"`
	case '[':
		close = "]"
	case '{':
		close = "}"
	}
	resize(out, from + spell.char_start(s, size - 4 - len(close)))
	append(out, "...")
	append(out, close)
}

// The bytes of the first `n` code points of `s`.
@(private)
codepoint_bytes :: proc(s: string, n: int) -> int {
	return query.codepoint_offset(s, n)
}

// What jq writes in place of a container past the depth budget.
@(private)
TOO_DEEP :: "<skipped: too deep>"

// A double as jq 1.8.2 prints it: its shortest digits, in exponent form below 10^-4 or past 17 digits' worth, with a
// two-digit exponent at least, an infinity as the largest double, and NaN as null.
@(private)
jq_double :: proc(buf: []u8, f: f64) -> string {
	if f != f {
		return "null"
	}
	x := f
	if x > max(f64) {
		x = max(f64)
	} else if x < -max(f64) {
		x = -max(f64)
	}
	n := 0
	if x < 0 || x == 0 && transmute(u64)x >> 63 != 0 {
		if x != 0 {
			buf[0] = '-'
			n = 1
		}
		x = -x
	}
	if x == 0 {
		buf[n] = '0'
		return string(buf[:n + 1])
	}
	digits: [17]u8
	count, point := query.double_digits(x, &digits)
	if point <= -4 || point > count + 15 {
		buf[n] = digits[0]
		n += 1
		if count > 1 {
			buf[n] = '.'
			n += 1
			copy(buf[n:], digits[1:count])
			n += count - 1
		}
		e := point - 1
		buf[n] = 'e'
		buf[n + 1] = '-' if e < 0 else '+'
		n += 2
		e = abs(e)
		if e < 10 {
			buf[n] = '0'
			n += 1
		}
		tmp: [4]u8
		k := 0
		for {
			tmp[k] = u8('0' + e % 10)
			k += 1
			e /= 10
			if e == 0 {
				break
			}
		}
		for k > 0 {
			k -= 1
			buf[n] = tmp[k]
			n += 1
		}
		return string(buf[:n])
	}
	if point <= 0 {
		buf[n], buf[n + 1] = '0', '.'
		n += 2
		for _ in 0 ..< -point {
			buf[n] = '0'
			n += 1
		}
		copy(buf[n:], digits[:count])
		return string(buf[:n + count])
	}
	for i in 0 ..< max(count, point) {
		if i == point {
			buf[n] = '.'
			n += 1
		}
		buf[n] = digits[i] if i < count else '0'
		n += 1
	}
	return string(buf[:n])
}
