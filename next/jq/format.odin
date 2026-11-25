package jq

import "core:strconv"
import "stury:lib/query"

// jq's `@name` formats and the texts of values.

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
		buf: [32]u8
		return query.text_value(h, strconv.write_int(buf[:], v.i, 10))
	case .Double:
		buf: [32]u8
		return query.text_value(h, jq_double(buf[:], v.f))
	}
	out := make([dynamic]u8, h.allocator)
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
	out := make([dynamic]u8, 0, len(s), h.allocator)
	defer delete(out)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '<':
			append(&out, "&lt;")
		case '>':
			append(&out, "&gt;")
		case '&':
			append(&out, "&amp;")
		case '\'':
			append(&out, "&apos;")
		case '"':
			append(&out, "&quot;")
		case:
			append(&out, s[i])
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
	out := make([dynamic]u8, h.allocator)
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
	out := make([dynamic]u8, h.allocator)
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
