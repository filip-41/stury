package jq

// JSON as the CLI reads it: as the library's `json.build` reads it, in every input, `fromjson`, --argjson,
// --jsonargs and --slurpfile. A fault is told in jq's form, `MESSAGE at line L, column C`, its message the
// library's sentence.

import "core:bytes"
import "core:strings"
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
	return message.build("%s%s at line %d, column %d", what if what != "" else fault_sentence(f, string(src[at:])), " at EOF" if eof else "", l, c)
}

// The library's sentence for `f`, but jq's for a text cut short (`rest`, the bytes from the fault, may be only space
// for a number with no digits yet), a bad number and a second text after the first.
fault_sentence :: proc(f: core_pkg.Fault, rest: string) -> string {
	switch {
	case f.kind == .Truncated || f.kind == .Bad_Number && len(strings.trim_space(rest)) == 0:
		return "Unfinished JSON term"
	case f.kind == .Bad_Number:
		return "Invalid numeric literal"
	case f.kind == .Trailing:
		return "Unexpected text after the JSON value"
	}
	return core_pkg.rule_of(f).message
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
