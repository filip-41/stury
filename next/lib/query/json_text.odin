package query

import "core:math"
import "core:unicode/utf8"

// Values written as JSON text, with no recursion over their depth.

Json_Options :: struct {
	indent:    int, // spaces per level, 0 for one line with no space
	tab:       bool, // a tab per level instead
	sort_keys: bool,
	ascii:     bool, // every code point past ASCII as `\u` escapes
	// How a double is written, into `buf` (32 bytes), nil for its shortest decimal, with an infinity or NaN as null.
	double:    proc(buf: []u8, f: f64) -> string,
	// Written in place of a container past the heap's depth, which is an error when empty.
	too_deep:  string,
}

@(private)
Write_Frame :: struct {
	v:     Value, // held
	c:     Cursor,
	keys:  [dynamic]Value, // under `sort_keys`, an object's keys in order
	i:     int,
	first: bool,
}

// Writes `v` as JSON to `out`, an absent value as null.
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
			if s == .Ok {
				s = put_byte(h, out, ':')
			}
			if s == .Ok && (opts.indent > 0 || opts.tab) {
				s = put_byte(h, out, ' ')
			}
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
	if _, err := append(out, c); err != nil {
		return fail_memory(h)
	}
	return .Ok
}

@(private)
put_bytes :: #force_inline proc(h: ^Heap, out: ^[dynamic]u8, s: string) -> Status {
	if _, err := append(out, s); err != nil {
		return fail_memory(h)
	}
	return .Ok
}

@(private)
drop_write_frame :: proc(h: ^Heap, f: ^Write_Frame) {
	cursor_close(&f.c)
	for k in f.keys {
		release(h, k)
	}
	delete(f.keys)
	release(h, f.v)
	f^ = {}
}

// Writes the opening of container `v`, held, and pushes its frame, or writes `[]` or `{}` for an empty one.
@(private)
open_write :: proc(h: ^Heap, out: ^[dynamic]u8, stack: ^[dynamic]Write_Frame, v: Value, opts: Json_Options) -> Status {
	object := type_of(v) == .Object
	if length_of(h, v) == 0 {
		release(h, v)
		_, err := append(out, "{}" if object else "[]")
		return .Ok if err == nil else fail_memory(h)
	}
	if _, err := append(out, '{' if object else '['); err != nil {
		release(h, v)
		return fail_memory(h)
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
	if opts.tab {
		for _ in 0 ..< depth {
			put_byte(h, out, '\t') or_return
		}
		return .Ok
	}
	for _ in 0 ..< depth * opts.indent {
		put_byte(h, out, ' ') or_return
	}
	return .Ok
}

// Writes a scalar: a document's number as its literal when that is JSON's, any other as `write_number` does.
@(private, require_results)
write_scalar :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value, opts: Json_Options = {}) -> Status {
	#partial switch type_of(v) {
	case .Absent, .Null:
		return put_bytes(h, out, "null")
	case .False:
		return put_bytes(h, out, "false")
	case .True:
		return put_bytes(h, out, "true")
	case .String:
		return write_text(h, out, text_of(v), opts.ascii)
	case .Number:
		if v.kind == .Node {
			if b := node_bytes(v); json_number_text(b) {
				return put_bytes(h, out, string(b))
			}
		}
		return write_number(h, out, v, opts.double)
	}
	return .Ok
}

// Writes number `v`: an integer in decimal, a double through `double` or else as its shortest decimal, with no
// exponent from 10^-5 to 10^17, and an infinity or NaN as null.
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

// The shortest decimal of finite `f` that reads back as it, in `buf` (32 bytes): positional from 10^-5 to 10^17, else
// `d.ddde±x`.
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
	buf[n] = 'e'
	buf[n + 1] = '-' if e < 0 else '+'
	n += 2
	e = abs(e)
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

// Whether `b` is a number as RFC 8259 spells one.
@(private)
json_number_text :: proc "contextless" (b: []u8) -> bool {
	i, n := 0, len(b)
	if i < n && b[i] == '-' {
		i += 1
	}
	if i >= n {
		return false
	}
	if b[i] == '0' {
		i += 1
	} else {
		if b[i] - '1' >= 9 {
			return false
		}
		for i < n && b[i] - '0' < 10 {
			i += 1
		}
	}
	if i < n && b[i] == '.' {
		i += 1
		start := i
		for i < n && b[i] - '0' < 10 {
			i += 1
		}
		if i == start {
			return false
		}
	}
	if i < n && b[i] | 0x20 == 'e' {
		i += 1
		if i < n && (b[i] == '+' || b[i] == '-') {
			i += 1
		}
		start := i
		for i < n && b[i] - '0' < 10 {
			i += 1
		}
		if i == start {
			return false
		}
	}
	return i == n
}

// Writes `s` as a JSON string: quote, backslash and control characters escaped, DEL as `\u007f`, ill-formed UTF-8 as
// U+FFFD, and with `ascii` each code point past ASCII as `\u` escapes.
@(require_results)
write_text :: proc(h: ^Heap, out: ^[dynamic]u8, s: string, ascii := false) -> Status {
	HEX := "0123456789abcdef"
	put_byte(h, out, '"') or_return
	run := 0
	i := 0
	for i < len(s) {
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
		case '"':
			put_bytes(h, out, `\"`) or_return
		case '\\':
			put_bytes(h, out, `\\`) or_return
		case '\n':
			put_bytes(h, out, `\n`) or_return
		case '\t':
			put_bytes(h, out, `\t`) or_return
		case '\r':
			put_bytes(h, out, `\r`) or_return
		case '\b':
			put_bytes(h, out, `\b`) or_return
		case '\f':
			put_bytes(h, out, `\f`) or_return
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
	HEX := "0123456789abcdef"
	unit :: proc(h: ^Heap, out: ^[dynamic]u8, u: u32, hex: string) -> Status {
		esc := [6]u8{'\\', 'u', hex[u >> 12 & 15], hex[u >> 8 & 15], hex[u >> 4 & 15], hex[u & 15]}
		return put_bytes(h, out, string(esc[:]))
	}
	if r < 0x10000 {
		return unit(h, out, u32(r), HEX)
	}
	x := u32(r) - 0x10000
	unit(h, out, 0xD800 + (x >> 10), HEX) or_return
	return unit(h, out, 0xDC00 + (x & 0x3FF), HEX)
}
