package jq

// JSON as the CLI reads it: as the library's `json.validate` checks it, in every input, `fromjson`,
// --argjson, --jsonargs, --slurpfile and `stury check`, its digit and exponent caps lifted to what a number
// can hold (`lifted`; `check --strict-limits` keeps them).
// A fault is told in jq's form, `MESSAGE at line L, column C`, its message the library's kind.
//
// Also jq's readings of a program's text: numbers as decNumber reads them, a string's escapes, and bytes
// that are not UTF-8.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "../../../json/scan/walk"
import json "../../../json"
import enc "../../../json/encode"
import lex "../../../json/scan/lex"
import number "../../../json/scan/number"

// What reading the next input came to.
Parse_Status :: enum u8 {
	More, // no input is left
	Value,
	Error,
}

// The library's caps as the CLI reads JSON: digits and exponents to what a number can hold, and nesting to
// `--max-depth`, `json.MAX_DEPTH` unless the command line raises it, which it does before any input is read.
lifted := json.Limits {
	max_depth         = json.MAX_DEPTH,
	max_scalar_digits = walk.MAX_SCALAR_DIGITS_REPRESENTABLE,
	max_scalar_scale  = walk.MAX_SCALAR_SCALE_REPRESENTABLE,
}

// The grammar the CLI reads option JSON and `fromjson` in: `.Jsonc` under --jsonc, which the command line sets
// before it reads any, as it does `lifted.max_depth`.
read_dialect := json.Dialect.Json

// JSON's whitespace.
is_space :: walk.is_space

// json.build's document without its decoding: a `.Nodes` scan's rows, whose escaped strings and keys the
// readers decode on first read, so a filter pays only for those it reads. Its refusals are build's errors.
build_rows :: proc(
	src: []byte,
	dialect := json.Dialect.Json,
	limits := lifted,
	allocator := context.allocator,
) -> (
	doc: json.Document,
	err: Maybe(json.Error),
) {
	req: json.Request({.Nodes})
	req.dialect, req.limits, req.allocator = dialect, limits, allocator
	req.doc.rows.allocator = allocator
	if len(src) < 2 * 256 {
		reserve(&req.doc.rows, len(src) / 2 + 1)
	}
	switch e in json.scan(src, &req) {
	case json.Error:
		err = e
	case json.Request_Error:
		assert(e.capacity == .Node_Source_Bytes, "build_rows: an unexpected scan refusal")
		err = json.Error{kind = .Source_Too_Wide, offset = json.MAX_ROW_SOURCE}
	}
	if err == nil {
		doc = req.doc
		req.doc = {}
	}
	json.destroy(&req)
	return
}

// `src` as one JSON text, or the fault that it is not one.
read_text :: proc(src: []byte) -> (Value, Maybe(json.Error)) {
	d, err := build_rows(src, read_dialect)
	if err != nil {
		return nil, err
	}
	return document_value(d), nil
}

// --stream's events of a document, made one at a time as jq's streaming parser makes them: `[path, leaf]` for each
// scalar and empty container, and `[path]` after a container's last member, `path` ending with that member's step.
// Every member is walked, a repeated key's too. An event is made whole in the allocator of the call that makes it, as
// `input` under -n empties one each call. The document and the walk are the heap's.
Events :: struct {
	doc:     json.Document,
	frames:  [dynamic]Event_Frame, // the containers open, the root first
	started: bool,
}

@(private = "file")
Event_Frame :: struct {
	rows:  json.Members,
	array: bool,
	index: int, // the step of the member read last: an array's index,
	key:   string, // or an object's key
}

// The events of `doc`, built in the heap allocator, which `next_event` frees once it has made the last.
events_start :: proc(doc: json.Document) -> ^Events {
	e := new(Events, runtime.heap_allocator())
	e.doc = doc
	e.frames.allocator = runtime.heap_allocator()
	return e
}

// The next event, or false once the last has been made, when the events are freed.
next_event :: proc(e: ^Events) -> (Value, bool) {
	doc := &e.doc
	if !e.started {
		e.started = true
		if json.child_count(doc, json.ROOT) == 0 {
			return event(e, json.ROOT), true
		}
		push_frame(e, json.ROOT)
	}
	for len(e.frames) > 0 {
		f := &e.frames[len(e.frames) - 1]
		row, ok := json.children(&f.rows)
		if !ok {
			closing := event(e, json.NO_NODE)
			pop(&e.frames)
			return closing, true
		}
		if f.array {
			f.index += 1
		} else {
			f.key, _ = json.get_key(doc, row)
		}
		if json.child_count(doc, row) == 0 {
			return event(e, row), true
		}
		push_frame(e, row)
	}
	json.destroy(&e.doc)
	delete(e.frames)
	free(e, runtime.heap_allocator())
	return nil, false
}

@(private = "file")
push_frame :: proc(e: ^Events, n: json.Node) {
	kd, _ := json.kind(&e.doc, n)
	append(&e.frames, Event_Frame{rows = json.children(&e.doc, n), array = kd == .Array, index = -1})
}

// `[path, leaf]`, or `[path]` for NO_NODE, copied whole into the context's allocator.
@(private = "file")
event :: proc(e: ^Events, leaf: json.Node) -> Value {
	path := new_array(len(e.frames))
	for f in e.frames {
		append(&path.items, num(f64(f.index)) if f.array else Value(strings.clone(f.key)))
	}
	ev := new_array(2)
	append(&ev.items, path)
	if leaf == json.NO_NODE {
		return ev
	}
	v: Value
	switch kd, _ := json.kind(&e.doc, leaf); kd {
	case .Array:
		v = new_array()
	case .Object:
		v = new_object()
	case .Null, .False, .True, .Number, .String:
		#partial switch x in scalar(Ref{&e.doc, leaf}) {
		case Number:
			v = Number{f = x.f, lit = strings.clone(x.lit)}
		case string:
			v = strings.clone(x)
		case nil, bool:
			v = x
		}
	}
	append(&ev.items, v)
	return ev
}

// `src` as one JSON text (`fromjson`), or jq's message for why it is not one.
read_json :: proc(src: string) -> (Value, string) {
	text := transmute([]byte)src
	v, err := read_text(text)
	e, bad := err.?
	if !bad {
		return v, ""
	}
	shown := src
	if nul := strings.index_byte(src, 0); nul >= 0 {
		shown = src[:nul] // as C's %s prints it
	}
	// jq's own words where the fault says as much: no text at all, or a second one after the first.
	msg: string
	switch {
	case len(strings.trim(src, " \t\n\r")) == 0:
		msg = "Expected JSON value"
	case e.kind == .Trailing && json.validate(text[e.offset:], read_dialect, limits = lifted) == nil:
		msg = "Unexpected extra JSON values"
	case:
		msg = parse_message(text, e)
	}
	return nil, fmt.aprintf("%s (while parsing '%s')", msg, shown)
}

// The library's fault `e` in `src` as jq tells a parse error: its message (`what`, where jq words it its own way, and
// `at EOF` when the text ended), then the line and 1-based column of the byte the fault is at, or one past the last
// byte at the end, counting on from `line` and `column` (the bytes of its line before `src`): the one position `stury
// check` and the library's `error_position` report, a faulty newline's own line and column. jq's is where its parser
// stands having read that byte: the last byte's at the end, and the next line's column 0 for a newline. A text ends
// at `text_end` in `src` (default: all of it), `src` may run on past it by the newline that ends its line.
parse_message :: proc(src: []byte, e: json.Error, line := 1, column := 0, what := "", text_end := -1) -> string {
	at := min(int(e.offset), len(src))
	eof := at >= (len(src) if text_end < 0 else text_end)
	l, c := line, column
	advance(&l, &c, src[:at])
	c += 1
	return fmt.aprintf("%s%s at line %d, column %d", what if what != "" else FAULT_TEXT[e.kind], " at EOF" if eof else "", l, c)
}

// Move a line and column past `b`, as jq's parser counts them.
advance :: proc(line, column: ^int, b: []byte) {
	rest := b
	for i := bytes.index_byte(rest, '\n'); i >= 0; i = bytes.index_byte(rest, '\n') {
		line^ += 1
		column^ = 0
		rest = rest[i + 1:]
	}
	column^ += len(rest)
}

// What jq says for a top-level number in a --seq record with no whitespace or separator after it.
TRUNCATED_NUMBER_NOTE :: "Potentially truncated top-level numeric value"

// A sentence for each kind of fault the library finds in a text: jq's, where jq has one.
@(rodata)
FAULT_TEXT := [json.Error_Kind]string {
	.None = "Unknown fault",
	.Truncated = "Unfinished JSON term",
	.Bad_Char = "Unexpected character",
	.Bad_Escape = "Invalid escape",
	.Bad_Literal = "Invalid literal",
	.Bad_Number = "Invalid numeric literal",
	.Limit_Digits = "Number has too many digits",
	.Limit_Scale = "Number's exponent is out of range",
	.Too_Deep = "Exceeds depth limit for parsing",
	.Trailing = "Unexpected text after the JSON value",
	.Source_Too_Wide = "Input is too large to read",
	.Out_Of_Memory = "Out of memory",
	.Duplicate_Key = "Duplicate key",
	.Bad_Option = "Unsupported option",
	.Field_Count = "Record has the wrong number of fields",
	.Limit_Fields = "Record has too many fields",
	.Limit_Record = "Record is too long",
}

// `text` as decNumber reads a number (jv_number_with_literal): a sign, then digits with a point and an exponent,
// `Inf` or `Infinity`, or `NaN` with no payload. It returns false if it is none of them.
read_number :: proc(text: string) -> (Value, bool) {
	t := text
	neg := false
	if len(t) > 0 && (t[0] == '+' || t[0] == '-') {
		neg = t[0] == '-'
		t = t[1:]
	}
	lower := strings.to_lower(t, context.temp_allocator)
	switch {
	case lower == "inf" || lower == "infinity":
		return Number{f = math.inf_f64(-1 if neg else 1)}, true
	case strings.has_prefix(lower, "nan") || strings.has_prefix(lower, "snan"):
		payload := lower[3:] if lower[0] == 'n' else lower[4:]
		if strings.trim_left(payload, "0") != "" {
			return nil, false
		}
		return Number{f = math.nan_f64()}, true
	}
	// Digits around an optional point, at least one, then an optional exponent: the library's loose number
	// reading (`.5` and `1.` count).
	if lexed := number.lex_number_span(transmute([]byte)t, 0, u64(len(t))); !lexed.whole || t[0] == '-' {
		return nil, false
	}
	f, _ := strconv.parse_f64(text)
	return Number{f = f, lit = enc.bounded_literal(text[1:] if text[0] == '+' else text)}, true
}

// The body of a JSON string decoded into `out` as jq's JSON parser decodes it, or why it cannot be. The
// escapes and their hex digits are read with the library's tables. A lone low surrogate, which only stury
// refuses, sets `stury_only_at` to its backslash's offset.
decode_string :: proc(out: ^strings.Builder, in_: string, stury_only_at: ^int = nil) -> string {
	s := transmute([]byte)in_
	for i := 0; i < len(s); {
		c := s[i]
		i += 1
		if c != '\\' {
			if c < 0x20 {
				return "Invalid string: control characters from U+0000 through U+001F must be escaped"
			}
			strings.write_byte(out, c)
			continue
		}
		if i >= len(s) {
			return "Expected escape character at end of string"
		}
		c = s[i]
		i += 1
		if b := lex.ESC_BYTE[c]; b != 0 {
			strings.write_byte(out, b)
			continue
		}
		if c != 'u' {
			return "Invalid escape"
		}
		if i + 4 > len(s) {
			return "Invalid \\uXXXX escape"
		}
		cp, hex := lex.hex4(s, u64(i))
		if !hex {
			return "Invalid characters in \\uXXXX escape"
		}
		i += 4
		if 0xd800 <= cp && cp <= 0xdbff {
			low: u32
			pair := i + 6 <= len(s) && s[i] == '\\' && s[i + 1] == 'u'
			if pair {
				low, pair = lex.hex4(s, u64(i + 2))
			}
			if !pair || !(0xdc00 <= low && low <= 0xdfff) {
				return "Invalid \\uXXXX\\uXXXX surrogate pair escape"
			}
			i += 6
			cp = 0x10000 + ((cp - 0xd800) << 10 | (low - 0xdc00))
		}
		if 0xdc00 <= cp && cp <= 0xdfff {
			if stury_only_at != nil {
				stury_only_at^ = i - 6 // the escape's backslash, where stury reports it
			}
			return "Invalid escape" // a lone low surrogate: jq makes it U+FFFD, stury refuses it as its JSON reader does
		}
		strings.write_rune(out, rune(cp))
	}
	return ""
}

// `s` as jq makes a string of it: each sequence that is not UTF-8, as far as jvp_utf8_next reads it,
// one U+FFFD.
valid_utf8 :: proc(s: string) -> string {
	b := strings.builder_make()
	write_valid_utf8(&b, s)
	return strings.to_string(b)
}

write_valid_utf8 :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); {
		n, ok := utf8_next(s[i:])
		if ok {
			strings.write_string(b, s[i:i + n])
		} else {
			strings.write_rune(b, utf8.RUNE_ERROR)
		}
		i += n
	}
}

// The length of the sequence `s` starts with as jvp_utf8_next reads it, and whether it is UTF-8: a bad
// lead byte alone, a lead byte with what continues it, or all that is left when `s` ends first.
utf8_next :: proc(s: string) -> (n: int, ok: bool) {
	c := s[0]
	switch {
	case c < 0x80:
		return 1, true
	case c < 0xc2 || c > 0xf4:
		return 1, false
	}
	n = utf8_length(c)
	if n > len(s) {
		return len(s), false
	}
	cp := rune(c) & (0x1f if n == 2 else 0x0f if n == 3 else 0x07)
	for i in 1 ..< n {
		if s[i] & 0xc0 != 0x80 {
			return i, false
		}
		cp = cp << 6 | rune(s[i] & 0x3f)
	}
	first := [5]rune{0, 0, 0x80, 0x800, 0x10000}
	return n, cp >= first[n] && !(0xd800 <= cp && cp <= 0xdfff) && cp <= 0x10ffff
}

// The length of the UTF-8 sequence lead byte `c` begins: 1 to 4, or 0 for a byte that begins none.
utf8_length :: proc(c: byte) -> int {
	switch c {
	case 0x00 ..= 0x7f:
		return 1
	case 0xc2 ..= 0xdf:
		return 2
	case 0xe0 ..= 0xef:
		return 3
	case 0xf0 ..= 0xf4:
		return 4
	}
	return 0
}
