package jq

// JSON as jq reads it, in every input and in `fromjson`: as the library's `json.build` reads it, with a fault told in
// jq's form, `MESSAGE at line L, column C`, its message the library's sentence.

import "core:fmt"
import "core:strings"
import core_pkg "../core"
import json "../json"

// What reading the next input came to: no input is left (`End`), a value, or an error.
Input_Status :: enum u8 {
	End,
	Value,
	Error,
}

// `src` as one JSON text (`fromjson`), or jq's message for why it is not one.
@(private)
read_json :: proc(src: string, r: core_pkg.As) -> (core_pkg.Value, string) {
	text := transmute([]byte)src
	d, fault := core_pkg.refuse_key_clash(core_pkg.build(text, r))
	f, bad := fault.?
	if !bad {
		return core_pkg.document_value(d), ""
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
	return nil, fmt.aprintf("%s (while parsing '%s')", msg, shown)
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
	core_pkg.advance_position(&l, &c, src[:at])
	if !eof {
		c += 1
	}
	return fmt.aprintf("%s%s at line %d, column %d", fault_sentence(f, string(src[at:])), " at EOF" if eof else "", l, c)
}

// The library's sentence for `f` (`core.write_fault_message`), but jq's for a text cut short (`rest`, the bytes from the
// fault, may be only space for a number with no digits yet), a bad number the library names no rule for, a nesting past
// the limit and a second text after the first.
@(private)
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

