package jq

import "base:runtime"
import "stury:lib/query"

// jq's `@name` formats and the texts of values.

@(private = "file", rodata)
DIGIT_PAIRS := "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"

@(private = "file")
dec_len_u64 :: #force_inline proc "contextless" (v: u64) -> int {
	n, x := 1, v
	for {
		if x < 10 { return n }
		if x < 100 { return n + 1 }
		if x < 1000 { return n + 2 }
		if x < 10000 { return n + 3 }
		x /= 10000
		n += 4
	}
}

@(private = "file")
int_to_text :: proc(h: ^query.Heap, x: i64) -> (query.Value, query.Status) #no_bounds_check {
	neg := x < 0
	mag := u64(0) - u64(x) if neg else u64(x)
	total := dec_len_u64(mag) + int(neg)
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
		p[at], p[at + 1] = DIGIT_PAIRS[r], DIGIT_PAIRS[r + 1]
	}
	if mag >= 10 {
		r := mag * 2
		p[at - 2], p[at - 1] = DIGIT_PAIRS[r], DIGIT_PAIRS[r + 1]
	} else {
		p[at - 1] = u8('0' + mag)
	}
	return v, .Ok
}

// `v` as JSON text, as jq's `tojson` writes it.
@(private)
to_json :: proc(h: ^query.Heap, v: query.Value) -> (query.Value, query.Status) {
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
	out := make([dynamic]u8, query.heap_allocator(h))
	defer delete(out)
	query.write_json(h, &out, v, {double = jq_double, too_deep = TOO_DEEP}) or_return
	return query.text_value(h, string(out[:]))
}

// `tostring`: a string as it is, anything else as JSON.
@(private)
to_text :: proc(h: ^query.Heap, v: query.Value) -> (query.Value, query.Status) {
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
	case "base64":
		if query.is_bytes(v) {
			return query.encode_base(h, string(query.bytes_of(v)), .Base64, true)
		}
	case "base32":
		if query.is_bytes(v) {
			return query.encode_base(h, string(query.bytes_of(v)), .Base32, true)
		}
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
		is_64 := name == "base64d"
		x, fault := query.decode_base(h, s, .Base64 if is_64 else .Base32) or_return
		if fault != .None {
			return query.NULL, cannot_decode(m, t, base_fault_text(fault, "base64" if is_64 else "base32"))
		}
		return x, .Ok
	}
	return query.NULL, raise_joined(m, name, " is not a valid format")
}

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
	append_all_str(&out, " ", why)
	return raise_owned_text(m, string(out[:]))
}

@(private)
escape_html :: proc(h: ^query.Heap, s: string) -> (query.Value, query.Status) {
	out, aerr := make([dynamic]u8, 0, len(s), query.heap_allocator(h))
	if aerr != nil {
		return query.NULL, query.fail(h, .Memory, .None)
	}
	defer delete(out)
	for c in transmute([]u8)s {
		err: runtime.Allocator_Error
		switch c {
		case '<':  _, err = append(&out, "&lt;")
		case '>':  _, err = append(&out, "&gt;")
		case '&':  _, err = append(&out, "&amp;")
		case '\'': _, err = append(&out, "&apos;")
		case '"':  _, err = append(&out, "&quot;")
		case:      _, err = append(&out, c)
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
	out := make([dynamic]u8, query.heap_allocator(h))
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
			} else {
				for c in transmute([]u8)s {
					switch c {
					case '\\': append(&out, `\\`)
					case '\t': append(&out, `\t`)
					case '\n': append(&out, `\n`)
					case '\r': append(&out, `\r`)
					case 0:    append(&out, `\0`)
					case:      append(&out, c)
					}
				}
			}
		case .Bytes:
			b64 := query.encode_base(h, string(query.bytes_of(x)), .Base64, true) or_return
			defer query.release(h, b64)
			if csv {
				append(&out, '"')
				append(&out, query.text_of(b64))
				append(&out, '"')
			} else {
				append(&out, query.text_of(b64))
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
	out := make([dynamic]u8, query.heap_allocator(h))
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
		case .Bytes:
			b64 := query.encode_base(h, string(query.bytes_of(x)), .Base64, true) or_return
			defer query.release(h, b64)
			append(&out, '\'')
			append(&out, query.text_of(b64))
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
	return raise_owned_text(m, string(out[:]))
}
