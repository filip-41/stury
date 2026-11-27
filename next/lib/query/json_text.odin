package query

import "core:encoding/base64"
import "core:math"
import "core:unicode/utf8"

// Values written as JSON text, with no recursion over their depth.

Json_Options :: struct {
	indent:    int,
	tab:       bool,
	sort_keys: bool,
	ascii:     bool,
	double:    proc(buf: []u8, f: f64) -> string,
	too_deep:  string,
}

@(private)
Write_Frame :: struct {
	v:     Value,
	c:     Cursor,
	keys:  [dynamic]Value,
	i:     int,
	first: bool,
}

@(require_results)
write_json :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value, opts: Json_Options = {}) -> Status {
	if t := type_of(v); t != .Array && t != .Object {
		return write_scalar(h, out, v, opts)
	}
	stack := make([dynamic]Write_Frame, 0, 8, h.allocator)
	defer {
		for &f in stack {
			drop_write_frame(h, &f)
		}
		delete(stack)
	}
	open_write(h, out, &stack, retain(v), opts) or_return
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		k, x: Value
		more: bool
		if f.keys != nil {
			if more = f.i < len(f.keys); more {
				k = retain(f.keys[f.i])
				x = member(h, f.v, text_of(k)) or_return
				f.i += 1
			}
		} else {
			k, x, more = cursor_next(h, &f.c) or_return
		}
		object := type_of(f.v) == .Object
		if !more {
			if !f.first {
				write_newline(h, out, opts, len(stack) - 1) or_return
			}
			put_byte(h, out, '}' if object else ']') or_return
			drop_write_frame(h, f)
			pop(&stack)
			continue
		}
		if !f.first {
			put_byte(h, out, ',') or_return
		}
		f.first = false
		write_newline(h, out, opts, len(stack)) or_return
		if object {
			s := write_text(h, out, text_of(k), opts.ascii)
			release(h, k)
			if s == .Ok { s = put_byte(h, out, ':') }
			if s == .Ok && (opts.indent > 0 || opts.tab) { s = put_byte(h, out, ' ') }
			if s != .Ok {
				release(h, x)
				return s
			}
		}
		if t := type_of(x); t == .Array || t == .Object {
			if len(stack) > depth_limit(h) {
				release(h, x)
				if opts.too_deep == "" {
					return fail(h, .Depth, .To_Text)
				}
				put_bytes(h, out, opts.too_deep) or_return
				continue
			}
			open_write(h, out, &stack, x, opts) or_return
			continue
		}
		s := write_scalar(h, out, x, opts)
		release(h, x)
		s or_return
	}
	return .Ok
}

@(private)
put_byte :: #force_inline proc(h: ^Heap, out: ^[dynamic]u8, c: u8) -> Status {
	_, err := append(out, c)
	return .Ok if err == nil else fail_memory(h)
}

@(private)
put_bytes :: #force_inline proc(h: ^Heap, out: ^[dynamic]u8, s: string) -> Status {
	_, err := append(out, s)
	return .Ok if err == nil else fail_memory(h)
}

@(private)
drop_write_frame :: proc(h: ^Heap, f: ^Write_Frame) {
	cursor_close(&f.c)
	drop_values(h, &f.keys)
	release(h, f.v)
	f^ = {}
}

@(private)
open_write :: proc(h: ^Heap, out: ^[dynamic]u8, stack: ^[dynamic]Write_Frame, v: Value, opts: Json_Options) -> Status {
	object := type_of(v) == .Object
	if length_of(h, v) == 0 {
		release(h, v)
		return put_bytes(h, out, "{}" if object else "[]")
	}
	if s := put_byte(h, out, '{' if object else '['); s != .Ok {
		release(h, v)
		return s
	}
	f := Write_Frame{v = v, first = true}
	if object && opts.sort_keys {
		keys, s := sorted_keys(h, v)
		if s != .Ok {
			release(h, v)
			return s
		}
		f.keys = keys
	} else {
		c, s := cursor_open(h, v)
		if s != .Ok {
			release(h, v)
			return s
		}
		f.c = c
	}
	if _, err := append(stack, f); err != nil {
		drop_write_frame(h, &f)
		return fail_memory(h)
	}
	return .Ok
}

@(private)
write_newline :: proc(h: ^Heap, out: ^[dynamic]u8, opts: Json_Options, depth: int) -> Status {
	if opts.indent == 0 && !opts.tab {
		return .Ok
	}
	put_byte(h, out, '\n') or_return
	ch: u8 = '\t' if opts.tab else ' '
	count := depth if opts.tab else depth * opts.indent
	for _ in 0 ..< count {
		put_byte(h, out, ch) or_return
	}
	return .Ok
}

@(private, require_results)
write_scalar :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value, opts: Json_Options = {}) -> Status {
	#partial switch type_of(v) {
	case .Absent, .Null: return put_bytes(h, out, "null")
	case .False:         return put_bytes(h, out, "false")
	case .True:          return put_bytes(h, out, "true")
	case .String:        return write_text(h, out, text_of(v), opts.ascii)
	case .Bytes:         return write_bytes_base64(h, out, bytes_of(v))
	case .Number:
		if v.kind == .Overlay {
			if txt, ok := overlay_number_literal(v); ok && json_number_text(txt) {
				return put_bytes(h, out, string(txt))
			}
		} else if v.kind == .Node {
			d := (^Doc_Block)(v.p)
			if d.doc.format == nil || .Binary not_in d.doc.format.caps {
				if b := node_bytes(v); json_number_text(b) {
					return put_bytes(h, out, string(b))
				}
			}
		}
		return write_number(h, out, v, opts.double)
	}
	return .Ok
}

@(require_results)
write_number :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value, double: proc(buf: []u8, f: f64) -> string = nil) -> Status {
	x := number_of(h, v) or_return
	defer release(h, x)
	if x.kind != .Double {
		return write_integer(h, out, x)
	}
	buf: [32]u8
	if double != nil {
		return put_bytes(h, out, double(buf[:], x.f))
	}
	if math.is_nan(x.f) || math.is_inf(x.f) {
		return put_bytes(h, out, "null")
	}
	return put_bytes(h, out, shortest_double(buf[:], x.f))
}

@(private)
shortest_double :: proc(buf: []u8, f: f64) -> string {
	n := 0
	if math.sign_bit(f) && f != 0 {
		buf[0] = '-'
		n = 1
	}
	if f == 0 {
		buf[n] = '0'
		return string(buf[:n + 1])
	}
	digits: [17]u8
	count, point := double_digits(abs(f), &digits)
	if point > -5 && point <= 17 {
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
	buf[n] = digits[0]
	n += 1
	if count > 1 {
		buf[n] = '.'
		n += 1
		copy(buf[n:], digits[1:count])
		n += count - 1
	}
	e := point - 1
	buf[n], buf[n + 1] = 'e', '-' if e < 0 else '+'
	n += 2
	e = abs(e)
	tmp: [4]u8
	k := 0
	for {
		tmp[k], k, e = u8('0' + e % 10), k + 1, e / 10
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

@(private)
json_number_text :: proc "contextless" (b: []u8) -> bool {
	i, n := int(len(b) > 0 && b[0] == '-'), len(b)
	if i >= n {
		return false
	}
	if b[i] == '0' {
		i += 1
	} else {
		if b[i] - '1' >= 9 {
			return false
		}
		for i < n && b[i] - '0' < 10 { i += 1 }
	}
	if i < n && b[i] == '.' {
		i += 1
		start := i
		for i < n && b[i] - '0' < 10 { i += 1 }
		if i == start { return false }
	}
	if i < n && b[i] | 0x20 == 'e' {
		i += 1 + int(i + 1 < n && (b[i + 1] == '+' || b[i + 1] == '-'))
		start := i
		for i < n && b[i] - '0' < 10 { i += 1 }
		if i == start { return false }
	}
	return i == n
}

// Writes raw bytes `data` as a quoted RFC 4648 standard base64 JSON string directly into `out`.
@(require_results)
write_bytes_base64 :: proc(h: ^Heap, out: ^[dynamic]u8, data: []u8) -> Status {
	enc_len := base64.encoded_len(data, base64.Encode_Options{})
	old_len := len(out)
	if aerr := resize(out, old_len + enc_len + 2); aerr != nil {
		return fail_memory(h)
	}
	out[old_len] = '"'
	if enc_len > 0 {
		if _, err := base64.encode_into_buf(out[old_len + 1 : old_len + 1 + enc_len], data, options = base64.Encode_Options{}); err != nil {
			resize(out, old_len)
			return fail_memory(h)
		}
	}
	out[old_len + 1 + enc_len] = '"'
	return .Ok
}

@(require_results)
write_text :: proc(h: ^Heap, out: ^[dynamic]u8, s: string, ascii := false) -> Status {
	HEX := "0123456789abcdef"
	put_byte(h, out, '"') or_return
	run := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c < 0x7F {
			i += 1
			continue
		}
		if c >= 0x80 {
			r, w := utf8.decode_rune_in_string(s[i:])
			if !ascii && r != utf8.RUNE_ERROR {
				i += w
				continue
			}
			put_bytes(h, out, s[run:i]) or_return
			if ascii {
				write_unicode_escape(h, out, r) or_return
			} else {
				put_bytes(h, out, "\uFFFD") or_return
			}
			i += w
			run = i
			continue
		}
		put_bytes(h, out, s[run:i]) or_return
		switch c {
		case '"':  put_bytes(h, out, `\"`) or_return
		case '\\': put_bytes(h, out, `\\`) or_return
		case '\n': put_bytes(h, out, `\n`) or_return
		case '\t': put_bytes(h, out, `\t`) or_return
		case '\r': put_bytes(h, out, `\r`) or_return
		case '\b': put_bytes(h, out, `\b`) or_return
		case '\f': put_bytes(h, out, `\f`) or_return
		case:
			esc := [6]u8{'\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15]}
			put_bytes(h, out, string(esc[:])) or_return
		}
		i += 1
		run = i
	}
	put_bytes(h, out, s[run:]) or_return
	return put_byte(h, out, '"')
}

@(private)
write_unicode_escape :: proc(h: ^Heap, out: ^[dynamic]u8, r: rune) -> Status {
	unit :: proc(h: ^Heap, out: ^[dynamic]u8, u: u32) -> Status {
		HEX := "0123456789abcdef"
		esc := [6]u8{'\\', 'u', HEX[u >> 12 & 15], HEX[u >> 8 & 15], HEX[u >> 4 & 15], HEX[u & 15]}
		return put_bytes(h, out, string(esc[:]))
	}
	if r < 0x10000 {
		return unit(h, out, u32(r))
	}
	x := u32(r) - 0x10000
	unit(h, out, 0xD800 + (x >> 10)) or_return
	return unit(h, out, 0xDC00 + (x & 0x3FF))
}
