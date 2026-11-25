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
				write_newline(out, opts, len(stack) - 1) or_return
			}
			append(out, '}' if object else ']')
			drop_write_frame(h, f)
			pop(&stack)
			continue
		}
		if !f.first {
			append(out, ',')
		}
		f.first = false
		write_newline(out, opts, len(stack)) or_return
		if object {
			s := write_text(h, out, text_of(k), opts.ascii)
			release(h, k)
			if s != .Ok {
				release(h, x)
				return s
			}
			append(out, ':')
			if opts.indent > 0 || opts.tab {
				append(out, ' ')
			}
		}
		if t := type_of(x); t == .Array || t == .Object {
			if len(stack) > depth_limit(h) {
				release(h, x)
				if opts.too_deep == "" {
					return fail(h, .Depth, .To_Text)
				}
				append(out, opts.too_deep)
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
write_newline :: proc(out: ^[dynamic]u8, opts: Json_Options, depth: int) -> Status {
	if opts.indent == 0 && !opts.tab {
		return .Ok
	}
	append(out, '\n')
	if opts.tab {
		for _ in 0 ..< depth {
			append(out, '\t')
		}
		return .Ok
	}
	for _ in 0 ..< depth * opts.indent {
		append(out, ' ')
	}
	return .Ok
}

// Writes a scalar: a document's number as its literal when that is JSON's, any other as `write_number` does.
@(require_results)
write_scalar :: proc(h: ^Heap, out: ^[dynamic]u8, v: Value, opts: Json_Options = {}) -> Status {
	#partial switch type_of(v) {
	case .Absent, .Null:
		append(out, "null")
	case .False:
		append(out, "false")
	case .True:
		append(out, "true")
	case .String:
		return write_text(h, out, text_of(v), opts.ascii)
	case .Number:
		if v.kind == .Node {
			if b := node_bytes(v); json_number_text(b) {
				append(out, string(b))
				return .Ok
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
		append(out, double(buf[:], x.f))
		return .Ok
	}
	if math.is_nan(x.f) || math.is_inf(x.f) {
		append(out, "null")
		return .Ok
	}
	append(out, shortest_double(buf[:], x.f))
	return .Ok
}

// The shortest decimal of finite `f` that reads back as it, in `buf` (32 bytes): positional from 10^-5 to 10^17, else
// `d.ddde±x`.
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
	if _, err := append(out, '"'); err != nil {
		return fail_memory(h)
	}
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
			append(out, s[run:i])
			if ascii {
				write_unicode_escape(out, r)
			} else {
				append(out, "�")
			}
			i += w
			run = i
			continue
		}
		append(out, s[run:i])
		switch c {
		case '"':
			append(out, `\"`)
		case '\\':
			append(out, `\\`)
		case '\n':
			append(out, `\n`)
		case '\t':
			append(out, `\t`)
		case '\r':
			append(out, `\r`)
		case '\b':
			append(out, `\b`)
		case '\f':
			append(out, `\f`)
		case:
			append(out, `\u00`)
			append(out, HEX[c >> 4], HEX[c & 15])
		}
		i += 1
		run = i
	}
	append(out, s[run:])
	if _, err := append(out, '"'); err != nil {
		return fail_memory(h)
	}
	return .Ok
}

@(private)
write_unicode_escape :: proc(out: ^[dynamic]u8, r: rune) {
	HEX := "0123456789abcdef"
	unit :: proc(out: ^[dynamic]u8, u: u32, hex: string) {
		append(out, `\u`)
		append(out, hex[u >> 12 & 15], hex[u >> 8 & 15], hex[u >> 4 & 15], hex[u & 15])
	}
	if r < 0x10000 {
		unit(out, u32(r), HEX)
		return
	}
	x := u32(r) - 0x10000
	unit(out, 0xD800 + (x >> 10), HEX)
	unit(out, 0xDC00 + (x & 0x3FF), HEX)
}
