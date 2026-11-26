package jq

import "base:runtime"
import "stury:lib/query"

// jq's `@name` formats and the texts of values.

@(private = "file", rodata)
DIGIT_PAIRS := [200]u8 {
	'0', '0', '0', '1', '0', '2', '0', '3', '0', '4', '0', '5', '0', '6', '0', '7', '0', '8', '0', '9',
	'1', '0', '1', '1', '1', '2', '1', '3', '1', '4', '1', '5', '1', '6', '1', '7', '1', '8', '1', '9',
	'2', '0', '2', '1', '2', '2', '2', '3', '2', '4', '2', '5', '2', '6', '2', '7', '2', '8', '2', '9',
	'3', '0', '3', '1', '3', '2', '3', '3', '3', '4', '3', '5', '3', '6', '3', '7', '3', '8', '3', '9',
	'4', '0', '4', '1', '4', '2', '4', '3', '4', '4', '4', '5', '4', '6', '4', '7', '4', '8', '4', '9',
	'5', '0', '5', '1', '5', '2', '5', '3', '5', '4', '5', '5', '5', '6', '5', '7', '5', '8', '5', '9',
	'6', '0', '6', '1', '6', '2', '6', '3', '6', '4', '6', '5', '6', '6', '6', '7', '6', '8', '6', '9',
	'7', '0', '7', '1', '7', '2', '7', '3', '7', '4', '7', '5', '7', '6', '7', '7', '7', '8', '7', '9',
	'8', '0', '8', '1', '8', '2', '8', '3', '8', '4', '8', '5', '8', '6', '8', '7', '8', '8', '8', '9',
	'9', '0', '9', '1', '9', '2', '9', '3', '9', '4', '9', '5', '9', '6', '9', '7', '9', '8', '9', '9',
}

@(private = "file")
dec_len_u64 :: #force_inline proc "contextless" (v: u64) -> int {
	n := 1
	x := v
	for {
		if x < 10 {
			return n
		}
		if x < 100 {
			return n + 1
		}
		if x < 1000 {
			return n + 2
		}
		if x < 10000 {
			return n + 3
		}
		x /= 10000
		n += 4
	}
}

@(private = "file")
int_to_text :: proc(h: ^query.Heap, x: i64) -> (query.Value, query.Status) #no_bounds_check {
	neg := x < 0
	mag := u64(0) - u64(x) if neg else u64(x)
	digits := dec_len_u64(mag)
	total := digits + int(neg)
	v, p, s := query.make_text(h, total)
	if s != .Ok {
		return query.NULL, s
	}
	if neg {
		p[0] = '-'
	}
	at := total
	for mag >= 100 {
		q := mag / 100
		r := (mag - q * 100) * 2
		mag = q
		at -= 2
		p[at] = DIGIT_PAIRS[r]
		p[at + 1] = DIGIT_PAIRS[r + 1]
	}
	if mag >= 10 {
		r := mag * 2
		p[at - 2] = DIGIT_PAIRS[r]
		p[at - 1] = DIGIT_PAIRS[r + 1]
	} else {
		p[at - 1] = u8('0' + mag)
	}
	return v, .Ok
}

// `v` as JSON text, as jq's `tojson` writes it.
@(private)
to_json :: proc(h: ^query.Heap, v: query.Value) -> (res: query.Value, status: query.Status) {
	#partial switch v.kind {
	case .Absent, .Null:
		return query.text_borrowed("null"), .Ok
	case .True:
		return query.text_borrowed("true"), .Ok
	case .False:
		return query.text_borrowed("false"), .Ok
	case .Int:
		return int_to_text(h, v.i)
	}
	return to_json_slow(h, v)
}

@(private = "file")
to_json_slow :: #force_no_inline proc(h: ^query.Heap, v: query.Value) -> (res: query.Value, status: query.Status) {
	if v.kind == .Double {
		buf: [32]u8
		return query.text_value(h, jq_double(buf[:], v.f))
	}
	alloc := query.heap_allocator(h)
	out := make([dynamic]u8, alloc)
	defer delete(out)
	query.write_json(h, &out, v, {double = jq_double, too_deep = TOO_DEEP}) or_return
	return query.text_value(h, string(out[:]))
}

// `tostring`: a string as it is, anything else as JSON.
@(private)
to_text :: proc(h: ^query.Heap, v: query.Value) -> (res: query.Value, status: query.Status) {
	if query.is_text(v) {
		return query.retain(v), .Ok
	}
	return to_json(h, v)
}

// `v` in format `@name`.
@(private)
format_value :: proc(m: ^Machine, name: string, v: query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	switch name {
	case "text":
		return to_text(h, v)
	case "json":
		return to_json(h, v)
	case "csv", "tsv":
		return format_row(m, v, name == "csv")
	case "sh":
		return format_shell(m, v)
	}
	t := to_text(h, v) or_return
	defer query.release(h, t)
	s := query.text_of(t)
	switch name {
	case "html":
		return escape_html(h, s)
	case "uri":
		return query.percent_encode(h, s, "-_.~")
	case "urid":
		x, ok := query.percent_decode(h, s, false) or_return
		if !ok {
			return query.NULL, cannot_decode(m, t, "is not a valid uri encoding")
		}
		return x, .Ok
	case "base64":
		return query.encode_base(h, s, .Base64, true)
	case "base32":
		return query.encode_base(h, s, .Base32, true)
	case "base64d", "base32d":
		x, fault := query.decode_base(h, s, .Base64 if name == "base64d" else .Base32) or_return
		if fault != .None {
			return query.NULL, cannot_decode(m, t, base_fault_text(fault, "base64" if name == "base64d" else "base32"))
		}
		return x, .Ok
	}
	out := make([dynamic]u8, h.allocator)
	defer delete(out)
	append(&out, name)
	append(&out, " is not a valid format")
	msg := query.text_value(h, string(out[:])) or_return
	defer query.release(h, msg)
	return query.NULL, raise(h, msg)
}

// What jq says is wrong with a base 64 or 32 text.
@(private)
base_fault_text :: proc(fault: query.Decode_Fault, base: string) -> string {
	if fault == .Lone_Digit {
		return "trailing base64 byte found"
	}
	return "is not valid base64 data" if base == "base64" else "is not valid base32 data"
}

@(private)
cannot_decode :: proc(m: ^Machine, t: query.Value, why: string) -> query.Status {
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	typed(m.h, &out, t)
	append(&out, " ")
	append(&out, why)
	msg, s := query.text_value(m.h, string(out[:]))
	if s != .Ok {
		return s
	}
	defer query.release(m.h, msg)
	return raise(m.h, msg)
}

@(private)
escape_html :: proc(h: ^query.Heap, s: string) -> (res: query.Value, status: query.Status) {
	alloc := query.heap_allocator(h)
	out, aerr := make([dynamic]u8, 0, len(s), alloc)
	if aerr != nil {
		return query.NULL, query.fail(h, .Memory, .None)
	}
	defer delete(out)
	for i in 0 ..< len(s) {
		err: runtime.Allocator_Error
		switch s[i] {
		case '<':
			_, err = append(&out, "&lt;")
		case '>':
			_, err = append(&out, "&gt;")
		case '&':
			_, err = append(&out, "&amp;")
		case '\'':
			_, err = append(&out, "&apos;")
		case '"':
			_, err = append(&out, "&quot;")
		case:
			_, err = append(&out, s[i])
		}
		if err != nil {
			return query.NULL, query.fail(h, .Memory, .None)
		}
	}
	return query.text_value(h, string(out[:]))
}

// `@csv` or `@tsv` of an array.
@(private)
format_row :: proc(m: ^Machine, v: query.Value, csv: bool) -> (res: query.Value, status: query.Status) {
	h := m.h
	if query.type_of(v) != .Array {
		return query.NULL, raise_typed(m, v, " cannot be csv-formatted, only an array can be" if csv else " cannot be tsv-formatted, only an array can be")
	}
	a := query.built(h, v) or_return
	defer query.release(h, a)
	alloc := query.heap_allocator(h)
	out := make([dynamic]u8, alloc)
	defer delete(out)
	for x, i in query.items_of(a) {
		if i > 0 {
			append(&out, ',' if csv else '\t')
		}
		switch query.type_of(x) {
		case .Absent, .Null:
		case .False:
			append(&out, "false")
		case .True:
			append(&out, "true")
		case .Number:
			query.write_number(h, &out, x, jq_double) or_return
		case .String:
			s := query.text_of(x)
			if csv {
				append(&out, '"')
				for c in transmute([]u8)s {
					if c == '"' {
						append(&out, '"')
					}
					append(&out, c)
				}
				append(&out, '"')
				break
			}
			for c in transmute([]u8)s {
				switch c {
				case '\\':
					append(&out, `\\`)
				case '\t':
					append(&out, `\t`)
				case '\n':
					append(&out, `\n`)
				case '\r':
					append(&out, `\r`)
				case 0:
					append(&out, `\0`)
				case:
					append(&out, c)
				}
			}
		case .Array, .Object:
			return query.NULL, raise_typed(m, x, " is not valid in a csv row" if csv else " is not valid in a tsv row")
		}
	}
	return query.text_value(h, string(out[:]))
}

// `@sh`: a string quoted for a POSIX shell, or an array's scalars each so, spaced.
@(private)
format_shell :: proc(m: ^Machine, v: query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	a := v
	if query.type_of(v) != .Array {
		a = query.make_array(h, 1) or_return
		query.append_owned(h, &a, query.retain(v)) or_return
	} else {
		a = query.built(h, v) or_return
	}
	defer query.release(h, a)
	alloc := query.heap_allocator(h)
	out := make([dynamic]u8, alloc)
	defer delete(out)
	for x, i in query.items_of(a) {
		if i > 0 {
			append(&out, ' ')
		}
		#partial switch query.type_of(x) {
		case .Array, .Object:
			return query.NULL, raise_typed(m, x, " can not be escaped for shell")
		case .String:
			append(&out, '\'')
			for c in transmute([]u8)query.text_of(x) {
				if c == '\'' {
					append(&out, `'\''`)
				} else {
					append(&out, c)
				}
			}
			append(&out, '\'')
		case:
			query.write_json(h, &out, x, {double = jq_double, too_deep = TOO_DEEP}) or_return
		}
	}
	return query.text_value(h, string(out[:]))
}

// Raises jq's message `type (value)` then `why`.
@(private)
raise_typed :: proc(m: ^Machine, v: query.Value, why: string) -> query.Status {
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	typed(m.h, &out, v)
	append(&out, why)
	msg, s := query.text_value(m.h, string(out[:]))
	if s != .Ok {
		return s
	}
	defer query.release(m.h, msg)
	return raise(m.h, msg)
}
