package jq

// JSON as the CLI reads it: as the library's `json.build` reads it, in every input, `fromjson`, --argjson,
// --jsonargs and --slurpfile. A fault is told in jq's form, `MESSAGE at line L, column C`, its message the
// library's sentence.

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:simd"
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

// JSON's whitespace.
is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// `src` as one text's document, its kinds stored as `store_inferred_kinds` does, or the fault that it is not one.
build_text :: proc(src: []byte, r: core_pkg.As, allocator := context.allocator) -> (doc: core_pkg.Document, fault: Maybe(core_pkg.Fault)) {
	doc, fault = judge_build(core_pkg.build(src, r, allocator = allocator))
	store_inferred_kinds(&doc)
	return
}

// A build's document `doc`, or the fault its error `err` tells.
judge_build :: proc(doc: core_pkg.Document, err: core_pkg.Error) -> (core_pkg.Document, Maybe(core_pkg.Fault)) {
	switch e in err {
	case nil:
		return doc, nil
	case core_pkg.Fault:
		if e.kind != .Duplicate_Key {
			return {}, e
		}
	case runtime.Allocator_Error, core_pkg.Document_Error, core_pkg.Path_Error, core_pkg.Typed_Error, core_pkg.Typed_Error_Kind:
	}
	return {}, core_pkg.Fault{kind = .No_Memory}
}

// Each value cell of `doc` that its format reads as a number, true or false under the document's handle, as `infer`
// does, takes that kind, so the interpreter reads a stored kind. A build's document is given it before a value reads it.
store_inferred_kinds :: #force_inline proc(doc: ^core_pkg.Document) {
	if doc.spelling != nil && doc.spelling.resolves != nil && doc.spelling.resolves(doc.as) {
		store_kinds(doc)
	}
}

@(cold, private = "file")
store_kinds :: proc(doc: ^core_pkg.Document) {
	for &n, i in doc.nodes {
		if n.kind == .Plain && n.role == .Value && n.n > 0 {
			if k := core_pkg.kind(doc, core_pkg.Node_Index(i)); k != .String {
				n.kind = k
			}
		}
	}
}

// `src` as one JSON text, or the fault that it is not one.
read_text :: proc(src: []byte, r: core_pkg.As) -> (Value, Maybe(core_pkg.Fault)) {
	d, fault := build_text(src, r)
	if fault != nil {
		return nil, fault
	}
	return document_value(d), nil
}

// `src` as one JSON text (`fromjson`), or jq's message for why it is not one.
read_json :: proc(src: string, r: core_pkg.As) -> (Value, string) {
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
	case f.rules == &json.RULES && f.detail == u8(json.Detail.Trailing) && core_pkg.validate(text[f.at:], r) == nil:
		msg = "Unexpected extra JSON values"
	case:
		msg = parse_message(text, f)
	}
	return nil, message.build("%s (while parsing '%s')", msg, shown)
}

// The library's fault `f` in `src` as jq tells a parse error: its message, `at EOF` when the text ended, then the line
// and 1-based column where jq's parser stands having read that byte, counting on from `line` and `column` (the bytes of
// its line before `src`): the byte the fault is at, or, at the end of the text, that last byte itself. A faulty newline
// is told at its own line and column, where jq's parser stands on the next line's column 0. A text ends at `text_end`
// in `src` (default: all of it), `src` may run on past it by the newline that ends its line.
parse_message :: proc(src: []byte, f: core_pkg.Fault, line := 1, column := 0, text_end := -1) -> string {
	at := min(int(f.at), len(src))
	eof := at >= (len(src) if text_end < 0 else text_end)
	l, c := line, column
	advance(&l, &c, src[:at])
	if !eof {
		c += 1
	}
	return message.build("%s%s at line %d, column %d", fault_sentence(f, string(src[at:])), " at EOF" if eof else "", l, c)
}

// The library's sentence for `f` (`core.write_fault_message`), but jq's for a text cut short (`rest`, the bytes from the
// fault, may be only space for a number with no digits yet), a bad number the library names no rule for, a nesting past
// the limit and a second text after the first.
fault_sentence :: proc(f: core_pkg.Fault, rest: string) -> string {
	switch {
	case f.kind == .Truncated && f.detail == 0 || f.kind == .Bad_Number && f.detail == 0 && len(strings.trim_space(rest)) == 0:
		return "Unfinished JSON term"
	case f.kind == .Bad_Number && f.detail == 0:
		return "Invalid numeric literal"
	case f.kind == .Too_Deep:
		return "Exceeds depth limit for parsing"
	case f.rules == &json.RULES && f.detail == u8(json.Detail.Trailing):
		return "Unexpected text after the JSON value"
	}
	b := strings.builder_make(context.temp_allocator)
	here := f
	here.at = 0
	core_pkg.write_fault_message(strings.to_writer(&b), transmute([]u8)rest, here)
	return strings.to_string(b)
}

// Move a line and column past `b`, as jq's parser counts them.
advance :: proc(line, column: ^int, b: []byte) {
	if nl := bytes.last_index_byte(b, '\n'); nl >= 0 {
		line^ += count_newlines(b[:nl + 1])
		column^ = len(b) - nl - 1
	} else {
		column^ += len(b)
	}
}

// The newlines in `b`: 64 bytes at a time into byte counters, which are summed before one can overflow.
count_newlines :: proc(b: []byte) -> (n: int) #no_bounds_check {
	V :: #simd[16]u8
	ROUNDS :: 255
	nl := V('\n')
	at := 0
	for at + 64 * ROUNDS <= len(b) {
		acc: [4]V
		for _ in 0 ..< ROUNDS {
			for k in 0 ..< 4 {
				acc[k] -= simd.lanes_eq(intrinsics.unaligned_load((^V)(&b[at + 16 * k])), nl)
			}
			at += 64
		}
		for v in acc {
			for c in transmute([16]u8)v {
				n += int(c)
			}
		}
	}
	for c in b[at:] {
		n += int(c == '\n')
	}
	return
}

// What jq says for a top-level number in a --seq record with no whitespace or separator after it.
TRUNCATED_NUMBER_NOTE :: "Potentially truncated top-level numeric value"
