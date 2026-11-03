package jq

// JSON as the CLI reads it: as the library's `json.build` reads it, in every input, `fromjson`, --argjson,
// --jsonargs and --slurpfile. A fault is told in jq's form, `MESSAGE at line L, column C`, its message the
// library's sentence.
//
// Also jq's readings of a program's text: numbers as decNumber reads them, a string's escapes, and bytes
// that are not UTF-8.

import "core:bytes"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "../../../core/spell"
import core_pkg "../../../core"
import json "../../../json"
import "../message"

// What reading the next input came to.
Parse_Status :: enum u8 {
	More, // no input is left
	Value,
	Error,
}

// How the CLI reads a JSON text: the spec `--from` names, and `--max-depth`, 0 for the library's `MAX_DEPTH`.
Reading :: struct {
	spec:      json.Spec,
	max_depth: u32,
}

// JSON's whitespace.
is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// `src` as one text's document, or the fault that it is not one. A JSON5 `Infinity` or `NaN` is refused as a bad
// literal, since jq has no spelling for it.
build_text :: proc(src: []byte, r: Reading, allocator := context.allocator) -> (doc: core_pkg.Document, fault: Maybe(core_pkg.Fault)) {
	opts := json.Options{max_depth = r.max_depth}
	err: core_pkg.Document_Error
	switch r.spec {
	case .Json:
		doc, err = json.build(src, .Json, opts, allocator = allocator)
	case .Jsonc:
		doc, err = json.build(src, .Jsonc, opts, allocator = allocator)
	case .Json5:
		doc, err = json.build(src, .Json5, opts, allocator = allocator)
		if at, found := non_finite_at(&doc); found {
			core_pkg.destroy(&doc)
			return {}, core_pkg.Fault{at = at, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Literal)}
		}
	}
	switch err.kind {
	case .None:
		return doc, nil
	case .Walk:
		return {}, err.inner
	case .Duplicate_Key, .No_Memory, .Bad_Index, .Bad_Position, .Wrong_Container, .Bad_Value, .Bad_Fact, .Bad_Width, .Bad_Spec, .Conflicting_Edits, .Bad_Result:
	}
	return {}, core_pkg.Fault{kind = .No_Memory}
}

// Whether `src` is one text as `r` reads it, or the fault that it is not.
validate_text :: proc(src: []byte, r: Reading) -> Maybe(core_pkg.Fault) {
	opts := json.Options{max_depth = r.max_depth}
	switch r.spec {
	case .Json:
		return json.validate(src, .Json, opts)
	case .Jsonc:
		return json.validate(src, .Jsonc, opts)
	case .Json5:
		return json.validate(src, .Json5, opts)
	}
	return nil
}

// The offset of the first number of `doc` that is not finite and no JSON literal (JSON5's `Infinity` and `NaN`).
@(private = "file")
non_finite_at :: proc(doc: ^core_pkg.Document) -> (at: u64, found: bool) {
	for n, i in doc.nodes {
		if n.kind == .Number && n.role == .Value {
			f := node_number(doc, core_pkg.Node_Index(i))
			if f.lit == "" && f.f - f.f != 0 {
				return n.lo, true
			}
		}
	}
	return
}

// `src` as one JSON text, or the fault that it is not one.
read_text :: proc(src: []byte, r: Reading) -> (Value, Maybe(core_pkg.Fault)) {
	d, fault := build_text(src, r)
	if fault != nil {
		return nil, fault
	}
	return document_value(d), nil
}

// `src` as one JSON text (`fromjson`), or jq's message for why it is not one.
read_json :: proc(src: string, r: Reading) -> (Value, string) {
	text := transmute([]byte)src
	v, fault := read_text(text, r)
	f, bad := fault.?
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
	case f.kind == .Trailing && validate_text(text[f.at:], r) == nil:
		msg = "Unexpected extra JSON values"
	case:
		msg = parse_message(text, f)
	}
	return nil, message.build("%s (while parsing '%s')", msg, shown)
}

// The library's fault `f` in `src` as jq tells a parse error: its message (`what`, where jq words it its own way, and
// `at EOF` when the text ended), then the line and 1-based column where jq's parser stands having read that byte,
// counting on from `line` and `column` (the bytes of its line before `src`): the byte the fault is at, or, at the end
// of the text, that last byte itself. A faulty newline is told at its own line and column, where jq's parser stands on
// the next line's column 0. A text ends at `text_end` in `src` (default: all of it), `src` may run on past it by the
// newline that ends its line.
parse_message :: proc(src: []byte, f: core_pkg.Fault, line := 1, column := 0, what := "", text_end := -1) -> string {
	at := min(int(f.at), len(src))
	eof := at >= (len(src) if text_end < 0 else text_end)
	l, c := line, column
	advance(&l, &c, src[:at])
	if !eof {
		c += 1
	}
	return message.build("%s%s at line %d, column %d", what if what != "" else fault_sentence(f), " at EOF" if eof else "", l, c)
}

// The library's sentence for `f`, but jq's for a text cut short.
fault_sentence :: proc(f: core_pkg.Fault) -> string {
	return "Unfinished JSON term" if f.kind == .Truncated else core_pkg.rule_of(f).message
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

// `text` as decNumber reads a number (jv_number_with_literal): a sign, then digits with a point and an exponent,
// `Inf` or `Infinity`, or `NaN` with no payload. It returns false if it is none of them.
read_number :: proc(text: string) -> (Value, bool) {
	t := text
	neg := false
	if len(t) > 0 && (t[0] == '+' || t[0] == '-') {
		neg = t[0] == '-'
		t = t[1:]
	}
	if len(t) > 0 && t[0] | 0x20 >= 'a' && t[0] | 0x20 <= 'z' {
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
	}
	// Digits around an optional point, at least one, then an optional exponent (`.5` and `1.` count).
	if len(t) == 0 || t[0] == '-' || t[0] == '+' {
		return nil, false
	}
	if _, _, ok := spell.number_loose(transmute([]byte)t, 0, u64(len(t))); !ok {
		return nil, false
	}
	f, _ := strconv.parse_f64(text)
	return Number{f = f, lit = json_literal(text)}, true
}

// The bytes a one-letter escape stands for, 0 for a letter that is no escape.
@(private = "file", rodata)
ESCAPED := [256]u8 {
	'"'  = '"',
	'\\' = '\\',
	'/'  = '/',
	'b'  = '\b',
	'f'  = '\f',
	'n'  = '\n',
	'r'  = '\r',
	't'  = '\t',
}

// The body of a JSON string decoded into `out` as jq's JSON parser decodes it, or why it cannot be, in jq's
// words. A lone low surrogate, which only stury refuses, sets `stury_only_at` to its backslash's offset.
decode_string :: proc(out: ^strings.Builder, in_: string, stury_only_at: ^int = nil) -> string {
	s := transmute([]byte)in_
	for i := 0; i < len(s); {
		plain := i
		for i < len(s) && s[i] != '\\' && s[i] >= 0x20 {
			i += 1
		}
		strings.write_string(out, in_[plain:i])
		if i == len(s) {
			break
		}
		if s[i] != '\\' {
			return "Invalid string: control characters from U+0000 through U+001F must be escaped"
		}
		if i + 1 == len(s) {
			return "Expected escape character at end of string"
		}
		if b := ESCAPED[s[i + 1]]; b != 0 {
			strings.write_byte(out, b)
			i += 2
			continue
		}
		if s[i + 1] != 'u' {
			return "Invalid escape"
		}
		if len(s) - (i + 2) < 4 {
			return "Invalid \\uXXXX escape"
		}
		cp, hex_ok := spell.hex4(raw_data(s[i + 2:]))
		if !hex_ok {
			return "Invalid characters in \\uXXXX escape"
		}
		next := i + 6
		if spell.low_surrogate(cp) {
			if stury_only_at != nil {
				stury_only_at^ = i // the escape's backslash, where stury reports it
			}
			return "Invalid escape" // a lone low surrogate: jq makes it U+FFFD, stury refuses it as its JSON reader does
		}
		if spell.high_surrogate(cp) {
			if next + 6 > len(s) || s[next] != '\\' || s[next + 1] != 'u' {
				return "Invalid \\uXXXX\\uXXXX surrogate pair escape"
			}
			low, low_ok := spell.hex4(raw_data(s[next + 2:]))
			if !low_ok || !spell.low_surrogate(low) {
				return "Invalid \\uXXXX\\uXXXX surrogate pair escape"
			}
			cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
			next += 6
		}
		strings.write_rune(out, rune(cp))
		i = next
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
	run := 0 // s[run:i] is UTF-8 not yet written
	for i := 0; i < len(s); {
		if s[i] < 0x80 {
			i += 1
			continue
		}
		n, ok := utf8_next(s[i:])
		if !ok {
			strings.write_string(b, s[run:i])
			strings.write_rune(b, utf8.RUNE_ERROR)
			run = i + n
		}
		i += n
	}
	strings.write_string(b, s[run:])
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
