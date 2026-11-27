// Structured JSON Schema Basic Output report writer (RFC / JSON Schema 2020-12 §12.4.2).
// Zero `context.temp_allocator`, zero `core:os`, WASM-clean.
package schema

import "base:runtime"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

Report_Options :: struct {
	file:      string,
	truncated: bool,
	indent:    u8,
	tab:       bool,
}

@(require_results)
write_basic_report :: proc(
	entries: []check.Check_Error,
	uri: string,
	bases: []rules.Base = nil,
	opts := Report_Options{},
	allocator := context.allocator,
) -> ([]u8, Error) {
	jw: Json_Writer
	if !jw_init(&jw, opts.indent, opts.tab, allocator) {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	jw_open_object(&jw)
	if opts.file != "" { jw_key(&jw, "file"); jw_string(&jw, opts.file) }
	jw_key(&jw, "valid"); jw_bool(&jw, len(entries) == 0)
	if len(entries) > 0 {
		jw_key(&jw, "errors")
		jw_open_array(&jw)
		for e in entries {
			jw_open_object(&jw)
			jw_key(&jw, "valid"); jw_bool(&jw, false)
			jw_key(&jw, "keywordLocation"); jw_string(&jw, e.keyword_location)
			if base, rest := base_of(uri, bases, e.keyword_path); base != "" && !through_ref(e.keyword_path) {
				frag := fragment_of(rest, allocator)
				abs := strings.concatenate({base, "#", frag}, allocator)
				jw_key(&jw, "absoluteKeywordLocation"); jw_string(&jw, abs)
				delete(abs, allocator)
				delete(frag, allocator)
			}
			jw_key(&jw, "instanceLocation"); jw_string(&jw, e.instance_location)
			msg := error_message(e, allocator)
			jw_key(&jw, "error"); jw_string(&jw, msg)
			delete(msg, allocator)
			jw_close_object(&jw)
		}
		jw_close_array(&jw)
	}
	if opts.truncated { jw_key(&jw, "truncated"); jw_bool(&jw, true) }
	jw_close_object(&jw)
	out, ok := jw_finish(&jw)
	if !ok { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	return out, {}
}

error_message :: proc(e: check.Check_Error, allocator := context.allocator) -> string {
	Msg :: struct { prefix, fallback: string, use_kw: bool }
	@(static, rodata) TABLE := [check.Error_Kind]Msg {
		.None              = {"ok", "", false},
		.Wrong_Kind        = {"expected ", "a different type", false},
		.Not_Allowed       = {"value is not allowed", "", false},
		.Below_Minimum     = {"number must be ", "at least minimum", false},
		.Above_Maximum     = {"number must be ", "at most maximum", false},
		.Not_Multiple      = {"number is not a multiple of divisor", "", false},
		.Too_Short         = {"string must have ", "at least minLength characters", false},
		.Too_Long          = {"string must have ", "at most maxLength characters", false},
		.No_Match          = {"string does not match pattern", "", false},
		.Pattern_Undecided = {"pattern match exceeded budget", "", false},
		.Bad_Format        = {"string does not match format", "", false},
		.Too_Few           = {"must have ", "at least minimum items", false},
		.Too_Many          = {"must have ", "at most maximum items", false},
		.Not_Unique        = {"array items must be unique", "", false},
		.Not_A_Member      = {"value does not match ", "enum", true},
		.Missing_Field     = {"missing required property", "", false},
		.No_Arm            = {"value did not match any branch of ", "anyOf", true},
		.Many_Arms         = {"value matched more than one branch of oneOf", "", false},
		.Duplicate_Key     = {"duplicate object key", "", false},
		.Exceeded          = {"validation budget exceeded", "", false},
		.Walk              = {"document walk error", "", false},
		.No_Memory         = {"out of memory", "", false},
		.Bad_Option        = {"invalid option", "", false},
		.Unsupported       = {"unsupported schema feature", "", false},
	}
	if e.kind == .Missing_Field && e.expected != "" {
		return strings.concatenate({"missing required property \"", e.expected, "\""}, allocator)
	}
	m := TABLE[e.kind]
	if m.fallback == "" { return strings.clone(m.prefix, allocator) }
	detail := e.keyword if m.use_kw else e.expected
	return strings.concatenate({m.prefix, detail if detail != "" else m.fallback}, allocator)
}

@(private)
base_of :: proc(uri: string, bases: []rules.Base, steps: []tape.Step) -> (base: string, rest: []tape.Step) {
	base, rest = uri, steps
	outer: for x in bases {
		if len(x.steps) > len(steps) || len(x.steps) <= len(steps) - len(rest) { continue }
		for s, k in x.steps { if s != steps[k] { continue outer } }
		base, rest = x.uri, steps[len(x.steps):]
	}
	return
}

@(private)
through_ref :: proc(steps: []tape.Step) -> bool {
	for i := 0; i < len(steps); i += 1 {
		name, named := steps[i].(tape.Name)
		if !named { continue }
		switch string(name) {
		case "$ref", "$dynamicRef", "$recursiveRef": return true
		case "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies": i += 1
		}
	}
	return false
}

@(private)
fragment_of :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> string {
	ptr, err := check.format_pointer(steps, allocator)
	if err != nil { return "" }
	defer delete(ptr, allocator)
	hex_digits := "0123456789ABCDEF"
	out := strings.builder_make(0, len(ptr), allocator)
	for c in transmute([]u8)ptr {
		if c <= ' ' || c >= 0x7f || strings.contains_rune(`"#%<>[\]^` + "`{|}", rune(c)) {
			esc := [3]u8{'%', hex_digits[c >> 4], hex_digits[c & 0xF]}
			strings.write_bytes(&out, esc[:])
		} else {
			strings.write_byte(&out, c)
		}
	}
	return strings.to_string(out)
}
