// Layer-3 RFC 8259 JSON parser (into `write.Token_Tape`) and JSON writer (via `write.Out`),
// plus `rules.Value` -> `write.Token_Tape` conversion for format-independent checking and serialization.
// Zero format imports, zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, zero unbounded recursion.
package schema

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/rules"

// ============================================================================
// Minimal RFC 8259 JSON -> `tape.Document` (for embedded meta-schemas and VFS JSON bytes)
// ============================================================================

// Parses RFC 8259 JSON `src` into a `write.Token_Tape` and returns its `tape.Document`.
// The returned `tape` owns the document's backing storage; call `write.token_tape_drop(tt)` when done.
@(private)
parse_json_to_tape :: proc(src: []u8, tt: ^write.Token_Tape, allocator: runtime.Allocator) -> (doc: tape.Document, ok: bool) {
	if write.token_tape_start(tt, false, 0, allocator) != nil {
		return {}, false
	}
	p := Json_Parser{src = src, tt = tt, allocator = allocator}
	p.buf.allocator = allocator
	defer delete(p.buf)
	if !jp_value(&p) {
		write.token_tape_drop(tt)
		return {}, false
	}
	jp_ws(&p)
	if p.i != len(p.src) {
		write.token_tape_drop(tt)
		return {}, false
	}
	d, derr := write.token_tape_document(tt)
	if derr != nil {
		write.token_tape_drop(tt)
		return {}, false
	}
	return d, true
}

// Clones a `Token_Tape` document into a standalone owned `tape.Document` (so the `Token_Tape` can be dropped).
@(private)
parse_json_owned :: proc(src: []u8, allocator: runtime.Allocator) -> (doc: tape.Document, ok: bool) {
	tt: write.Token_Tape
	tmp, parsed := parse_json_to_tape(src, &tt, allocator)
	if !parsed {
		return {}, false
	}
	defer write.token_tape_drop(&tt)
	tmp.flags += {.Owns_Src}
	cloned, cerr := tape.clone_document(&tmp, allocator)
	if cerr != nil {
		return {}, false
	}
	return cloned, true
}

@(private = "file")
Json_Parser :: struct {
	src:       []u8,
	i:         int,
	tt:        ^write.Token_Tape,
	buf:       [dynamic]u8,
	allocator: runtime.Allocator,
}

@(private = "file")
jp_ws :: proc "contextless" (p: ^Json_Parser) {
	for p.i < len(p.src) {
		switch p.src[p.i] {
		case ' ', '\t', '\r', '\n':
			p.i += 1
		case:
			return
		}
	}
}

@(private = "file")
jp_value :: proc(p: ^Json_Parser) -> bool {
	// Explicit stack for nested objects and arrays (zero unbounded recursion).
	Container :: enum u8 {
		Array,
		Object,
	}
	stack, serr := make([dynamic]Container, 0, 16, p.allocator)
	if serr != nil {
		return false
	}
	defer delete(stack)

	want_value := true
	for {
		jp_ws(p)
		if want_value {
			if p.i >= len(p.src) {
				return false
			}
			c := p.src[p.i]
			switch c {
			case '{':
				p.i += 1
				if write.token_tape_take(p.tt, .Object, "") != nil {
					return false
				}
				jp_ws(p)
				if p.i < len(p.src) && p.src[p.i] == '}' {
					p.i += 1
					if write.token_tape_take(p.tt, .Close, "") != nil {
						return false
					}
					want_value = false
				} else {
					if _, aerr := append(&stack, Container.Object); aerr != nil {
						return false
					}
					key, kok := jp_string(p)
					if !kok {
						return false
					}
					if write.token_tape_take(p.tt, .Key, key) != nil {
						return false
					}
					jp_ws(p)
					if p.i >= len(p.src) || p.src[p.i] != ':' {
						return false
					}
					p.i += 1
					want_value = true
				}
			case '[':
				p.i += 1
				if write.token_tape_take(p.tt, .Array, "") != nil {
					return false
				}
				jp_ws(p)
				if p.i < len(p.src) && p.src[p.i] == ']' {
					p.i += 1
					if write.token_tape_take(p.tt, .Close, "") != nil {
						return false
					}
					want_value = false
				} else {
					if _, aerr := append(&stack, Container.Array); aerr != nil {
						return false
					}
					want_value = true
				}
			case '"':
				s, sok := jp_string(p)
				if !sok {
					return false
				}
				if write.token_tape_take(p.tt, .String, s) != nil {
					return false
				}
				want_value = false
			case 't':
				if p.i + 4 > len(p.src) || string(p.src[p.i:p.i + 4]) != "true" {
					return false
				}
				p.i += 4
				if write.token_tape_take(p.tt, .True, "") != nil {
					return false
				}
				want_value = false
			case 'f':
				if p.i + 5 > len(p.src) || string(p.src[p.i:p.i + 5]) != "false" {
					return false
				}
				p.i += 5
				if write.token_tape_take(p.tt, .False, "") != nil {
					return false
				}
				want_value = false
			case 'n':
				if p.i + 4 > len(p.src) || string(p.src[p.i:p.i + 4]) != "null" {
					return false
				}
				p.i += 4
				if write.token_tape_take(p.tt, .Null, "") != nil {
					return false
				}
				want_value = false
			case '-', '0' ..= '9':
				num, nok := jp_number(p)
				if !nok {
					return false
				}
				if write.token_tape_take(p.tt, .Number, num) != nil {
					return false
				}
				want_value = false
			case:
				return false
			}
		} else {
			if len(stack) == 0 {
				return true
			}
			if p.i >= len(p.src) {
				return false
			}
			top := stack[len(stack) - 1]
			c := p.src[p.i]
			if top == .Array {
				if c == ',' {
					p.i += 1
					want_value = true
				} else if c == ']' {
					p.i += 1
					pop(&stack)
					if write.token_tape_take(p.tt, .Close, "") != nil {
						return false
					}
				} else {
					return false
				}
			} else {
				if c == ',' {
					p.i += 1
					jp_ws(p)
					key, kok := jp_string(p)
					if !kok {
						return false
					}
					if write.token_tape_take(p.tt, .Key, key) != nil {
						return false
					}
					jp_ws(p)
					if p.i >= len(p.src) || p.src[p.i] != ':' {
						return false
					}
					p.i += 1
					want_value = true
				} else if c == '}' {
					p.i += 1
					pop(&stack)
					if write.token_tape_take(p.tt, .Close, "") != nil {
						return false
					}
				} else {
					return false
				}
			}
		}
	}
}

@(private = "file")
jp_string :: proc(p: ^Json_Parser) -> (string, bool) {
	if p.i >= len(p.src) || p.src[p.i] != '"' {
		return "", false
	}
	p.i += 1
	start := p.i
	has_escape := false
	for p.i < len(p.src) {
		c := p.src[p.i]
		if c == '"' {
			if !has_escape {
				s := string(p.src[start:p.i])
				p.i += 1
				return s, utf8.valid_string(s)
			}
			break
		}
		if c < 0x20 {
			return "", false
		}
		if c == '\\' {
			has_escape = true
			break
		}
		p.i += 1
	}
	if !has_escape {
		return "", false
	}
	clear(&p.buf)
	if _, aerr := append(&p.buf, ..p.src[start:p.i]); aerr != nil {
		return "", false
	}
	for p.i < len(p.src) {
		c := p.src[p.i]
		if c == '"' {
			p.i += 1
			s := string(p.buf[:])
			return s, utf8.valid_string(s)
		}
		if c < 0x20 {
			return "", false
		}
		if c == '\\' {
			r, n := spell.string_escape(raw_data(p.src[p.i:]), len(p.src) - p.i)
			if n == 0 {
				return "", false
			}
			enc, en := utf8.encode_rune(r)
			if _, aerr := append(&p.buf, ..enc[:en]); aerr != nil {
				return "", false
			}
			p.i += n
			continue
		}
		if _, aerr := append(&p.buf, c); aerr != nil {
			return "", false
		}
		p.i += 1
	}
	return "", false
}

@(private = "file")
jp_number :: proc "contextless" (p: ^Json_Parser) -> (string, bool) {
	start := p.i
	if start >= len(p.src) {
		return "", false
	}
	base := raw_data(p.src)
	end := base[len(p.src):]
	q, _, err := tape.number_scan(base[start:], end, false, false)
	if err != .None {
		return "", false
	}
	n := int(uintptr(q) - uintptr(base)) - start
	if n <= 0 {
		return "", false
	}
	p.i = start + n
	return string(p.src[start:p.i]), true
}

// ============================================================================
// Canonical RFC 8259 decimal formatting helper
// ============================================================================

@(private = "file")
is_strict_json_number :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	base := raw_data(s)
	end := base[len(s):]
	q, _, err := tape.number_scan(base, end, false, false)
	return err == .None && uintptr(q) == uintptr(end)
}

// Returns a strict RFC 8259 JSON number spelling for `raw` (normalizing `+1`, `.5`, `5.`, `01`).
// Uses `b` only when normalization is required.
@(private = "file")
canonical_json_number :: proc(raw: string, b: ^strings.Builder) -> (string, bool) {
	s := raw[1:] if len(raw) > 0 && raw[0] == '+' else raw
	if is_strict_json_number(s) {
		return s, true
	}
	if !rules.valid_decimal_text(s) {
		return "", false
	}
	strings.builder_reset(b)
	rules.write_decimal(b, rules.decimal_of(s))
	out := strings.to_string(b^)
	return out, is_strict_json_number(out)
}

// ============================================================================
// Unified `rules.Value` token emitter (`value_tokens`) -> `write.Token_Tape` & `Json_Writer`
// ============================================================================

// Streams `v` as write tokens into `sink` via `take` using an explicit heap stack (zero recursion).
// Delegates `Node_Ref` subtrees to `write.tokens_of` for XML `.Group`, DSV `Tabular_Ext`, `.Bytes`, and strict RFC 8259 numbers.
@(private = "file")
value_tokens :: proc(v: rules.Value, sink: ^$S, $take: proc(sink: ^S, kind: write.Token_Kind, text: string) -> write.Error, scratch: runtime.Allocator) -> write.Error {
	Frame_Kind :: enum u8 {
		Value,
		Key,
		Close,
	}
	Frame :: struct {
		kind: Frame_Kind,
		val:  rules.Value,
		key:  string,
	}
	stack, serr := make([dynamic]Frame, 0, 16, scratch)
	if serr != nil {
		return serr
	}
	defer delete(stack)
	if _, aerr := append(&stack, Frame{kind = .Value, val = v}); aerr != nil {
		return aerr
	}
	num_b := strings.builder_make(scratch)
	defer strings.builder_destroy(&num_b)
	buf: [128]u8 = ---

	for len(stack) > 0 {
		fr := pop(&stack)
		switch fr.kind {
		case .Close:
			take(sink, .Close, "") or_return
			continue
		case .Key:
			take(sink, .Key, fr.key) or_return
			continue
		case .Value:
		}
		if nr, is_ref := fr.val.(rules.Node_Ref); is_ref {
			if nr.doc == nil || nr.node == tape.NO_NODE || int(nr.node) >= len(nr.doc.nodes) {
				return write.Refused{}
			}
			write.tokens_of(nr.doc, nr.node, sink, take, scratch) or_return
			continue
		}
		switch rules.value_kind(fr.val) {
		case .Null:
			take(sink, .Null, "") or_return
		case .True:
			take(sink, .True, "") or_return
		case .False:
			take(sink, .False, "") or_return
		case .Number:
			raw_txt, owned, nok := rules.value_number_text(fr.val, buf[:], scratch)
			if !nok {
				return write.Refused{}
			}
			txt, cok := canonical_json_number(raw_txt, &num_b)
			if owned {
				delete(raw_txt, scratch)
			}
			if !cok {
				return write.Refused{}
			}
			take(sink, .Number, txt) or_return
		case .String:
			txt, owned, sok := rules.value_string(fr.val, buf[:], scratch)
			if !sok {
				return write.Refused{}
			}
			terr := take(sink, .String, txt)
			if owned {
				delete(txt, scratch)
			}
			if terr != nil {
				return terr
			}
		case .Array:
			take(sink, .Array, "") or_return
			if _, aerr := append(&stack, Frame{kind = .Close}); aerr != nil {
				return aerr
			}
			if av, is_arr := fr.val.([]rules.Value); is_arr {
				for i := len(av) - 1; i >= 0; i -= 1 {
					if _, aerr := append(&stack, Frame{kind = .Value, val = av[i]}); aerr != nil {
						return aerr
					}
				}
			}
		case .Object:
			take(sink, .Object, "") or_return
			if _, aerr := append(&stack, Frame{kind = .Close}); aerr != nil {
				return aerr
			}
			if ov, is_obj := fr.val.([]rules.Member_Value); is_obj {
				for i := len(ov) - 1; i >= 0; i -= 1 {
					if _, aerr := append(&stack, Frame{kind = .Value, val = ov[i].value}); aerr != nil {
						return aerr
					}
					if _, aerr := append(&stack, Frame{kind = .Key, key = ov[i].key}); aerr != nil {
						return aerr
					}
				}
			}
		}
	}
	return nil
}

@(private)
value_to_tape :: proc(v: rules.Value, tt: ^write.Token_Tape, allocator: runtime.Allocator) -> (doc: tape.Document, ok: bool) {
	if write.token_tape_start(tt, false, 0, allocator) != nil {
		return {}, false
	}
	if value_tokens(v, tt, write.token_tape_take, allocator) != nil {
		write.token_tape_drop(tt)
		return {}, false
	}
	d, derr := write.token_tape_document(tt)
	if derr != nil {
		write.token_tape_drop(tt)
		return {}, false
	}
	return d, true
}

// ============================================================================
// Streaming JSON serializer (`Json_Writer`) backed by `write.Out`
// ============================================================================

@(private = "file")
JW_Container :: struct {
	first:     bool,
	is_object: bool,
}

@(private)
Json_Writer :: struct {
	out:       write.Out,
	indent:    u8,
	tab:       bool,
	depth:     int,
	stack:     [dynamic]JW_Container,
	need_val:  bool,
	allocator: runtime.Allocator,
	err:       Error_Kind,
}

@(private)
jw_init :: proc(w: ^Json_Writer, indent: u8 = 0, tab := false, allocator := context.allocator) -> bool {
	w^ = {indent = indent, tab = tab, allocator = allocator}
	if write.out_start(&w.out, allocator, {}, 1024) != nil {
		w.err = .No_Memory
		return false
	}
	w.stack.allocator = allocator
	return true
}

@(private)
jw_finish :: proc(w: ^Json_Writer) -> ([]u8, bool) {
	delete(w.stack)
	if w.err != .None {
		write.out_drop(&w.out)
		return nil, false
	}
	bytes, err := write.out_finish(&w.out)
	if err != nil {
		return nil, false
	}
	return bytes, true
}

@(private)
jw_drop :: proc(w: ^Json_Writer) {
	delete(w.stack)
	write.out_drop(&w.out)
	w^ = {}
}

@(private = "file")
jw_newline :: proc(w: ^Json_Writer) {
	if w.indent == 0 && !w.tab {
		return
	}
	write.put_byte(&w.out, '\n')
	if w.tab {
		for _ in 0 ..< w.depth {
			write.put_byte(&w.out, '\t')
		}
	} else {
		for _ in 0 ..< w.depth * int(w.indent) {
			write.put_byte(&w.out, ' ')
		}
	}
}

@(private = "file")
jw_before_item :: proc(w: ^Json_Writer) {
	if w.need_val {
		w.need_val = false
		return
	}
	if len(w.stack) == 0 {
		return
	}
	if w.stack[len(w.stack) - 1].first {
		w.stack[len(w.stack) - 1].first = false
		jw_newline(w)
	} else {
		write.put_byte(&w.out, ',')
		jw_newline(w)
	}
}

@(private)
jw_open_object :: proc(w: ^Json_Writer) {
	jw_before_item(w)
	write.put_byte(&w.out, '{')
	w.depth += 1
	if _, err := append(&w.stack, JW_Container{first = true, is_object = true}); err != nil && w.err == .None {
		w.err = .No_Memory
	}
}

@(private)
jw_close_object :: proc(w: ^Json_Writer) {
	empty := len(w.stack) > 0 && w.stack[len(w.stack) - 1].first
	if len(w.stack) > 0 {
		pop(&w.stack)
	}
	w.depth -= 1
	if !empty {
		jw_newline(w)
	}
	write.put_byte(&w.out, '}')
}

@(private)
jw_open_array :: proc(w: ^Json_Writer) {
	jw_before_item(w)
	write.put_byte(&w.out, '[')
	w.depth += 1
	if _, err := append(&w.stack, JW_Container{first = true, is_object = false}); err != nil && w.err == .None {
		w.err = .No_Memory
	}
}

@(private)
jw_close_array :: proc(w: ^Json_Writer) {
	empty := len(w.stack) > 0 && w.stack[len(w.stack) - 1].first
	if len(w.stack) > 0 {
		pop(&w.stack)
	}
	w.depth -= 1
	if !empty {
		jw_newline(w)
	}
	write.put_byte(&w.out, ']')
}

@(private)
jw_key :: proc(w: ^Json_Writer, name: string) {
	jw_before_item(w)
	jw_quoted(w, name)
	if w.indent > 0 || w.tab {
		write.put(&w.out, transmute([]u8)string(": "))
	} else {
		write.put_byte(&w.out, ':')
	}
	w.need_val = true
}

@(private)
jw_null :: proc(w: ^Json_Writer) {
	jw_before_item(w)
	write.put(&w.out, transmute([]u8)string("null"))
}

@(private)
jw_bool :: proc(w: ^Json_Writer, b: bool) {
	jw_before_item(w)
	s := "true" if b else "false"
	write.put(&w.out, transmute([]u8)s)
}

@(private)
jw_uint :: proc(w: ^Json_Writer, n: u64) {
	jw_before_item(w)
	buf: [32]u8 = ---
	s := strconv.write_uint(buf[:], n, 10)
	write.put(&w.out, transmute([]u8)s)
}

@(private)
jw_int :: proc(w: ^Json_Writer, n: i64) {
	jw_before_item(w)
	buf: [32]u8 = ---
	s := strconv.write_int(buf[:], n, 10)
	write.put(&w.out, transmute([]u8)s)
}

@(private)
jw_number :: proc(w: ^Json_Writer, raw: string) {
	jw_before_item(w)
	write.put(&w.out, transmute([]u8)raw)
}

@(private)
jw_string :: proc(w: ^Json_Writer, s: string) {
	jw_before_item(w)
	jw_quoted(w, s)
}

@(private)
jw_quoted :: proc(w: ^Json_Writer, s: string) {
	hex_digits := "0123456789abcdef"
	write.put_byte(&w.out, '"')
	start := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x80 {
			r, sz := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && sz == 1 {
				if i > start {
					write.put(&w.out, transmute([]u8)s[start:i])
				}
				write.put(&w.out, transmute([]u8)string("\uFFFD"))
				i += 1
				start = i
			} else {
				i += sz
			}
			continue
		}
		if c >= 0x20 && c != '"' && c != '\\' {
			i += 1
			continue
		}
		if i > start {
			write.put(&w.out, transmute([]u8)s[start:i])
		}
		switch c {
		case '"':  write.put(&w.out, transmute([]u8)string(`\"`))
		case '\\': write.put(&w.out, transmute([]u8)string(`\\`))
		case '\b': write.put(&w.out, transmute([]u8)string(`\b`))
		case '\f': write.put(&w.out, transmute([]u8)string(`\f`))
		case '\n': write.put(&w.out, transmute([]u8)string(`\n`))
		case '\r': write.put(&w.out, transmute([]u8)string(`\r`))
		case '\t': write.put(&w.out, transmute([]u8)string(`\t`))
		case:
			esc := [6]u8{'\\', 'u', '0', '0', hex_digits[c >> 4], hex_digits[c & 0xF]}
			write.put(&w.out, esc[:])
		}
		i += 1
		start = i
	}
	if start < len(s) {
		write.put(&w.out, transmute([]u8)s[start:])
	}
	write.put_byte(&w.out, '"')
}

@(private = "file")
jw_take_token :: proc(w: ^Json_Writer, kind: write.Token_Kind, text: string) -> write.Error {
	switch kind {
	case .Null:
		jw_null(w)
	case .True:
		jw_bool(w, true)
	case .False:
		jw_bool(w, false)
	case .Number:
		jw_number(w, text)
	case .String:
		jw_string(w, text)
	case .Key:
		jw_key(w, text)
	case .Array:
		jw_open_array(w)
	case .Object:
		jw_open_object(w)
	case .Close:
		if len(w.stack) > 0 && w.stack[len(w.stack) - 1].is_object {
			jw_close_object(w)
		} else {
			jw_close_array(w)
		}
	}
	if w.err == .No_Memory {
		return runtime.Allocator_Error.Out_Of_Memory
	}
	if w.out.err != nil {
		return w.out.err
	}
	return nil
}

// Writes a `rules.Value` as JSON into `w` via unified `value_tokens` (explicit heap stack, zero recursion).
@(private)
jw_value :: proc(w: ^Json_Writer, v: rules.Value, scratch: runtime.Allocator) -> bool {
	if terr := value_tokens(v, w, jw_take_token, scratch); terr != nil {
		if _, is_alloc := terr.(runtime.Allocator_Error); is_alloc {
			w.err = .No_Memory
		} else if w.err == .None {
			w.err = .Unsupported
		}
		return false
	}
	if w.out.err != nil && w.err == .None {
		w.err = .No_Memory
	}
	return w.err == .None && w.out.err == nil
}

// Serializes `v` to compact (or indented) JSON bytes allocated from `allocator`.
value_to_json :: proc(v: rules.Value, indent: u8 = 0, tab := false, allocator := context.allocator, scratch := context.allocator) -> ([]u8, bool) {
	jw: Json_Writer
	if !jw_init(&jw, indent, tab, allocator) {
		return nil, false
	}
	if !jw_value(&jw, v, scratch) {
		jw_drop(&jw)
		return nil, false
	}
	return jw_finish(&jw)
}
