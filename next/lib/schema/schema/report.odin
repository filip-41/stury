// Structured JSON Schema Basic Output report writer (RFC / JSON Schema 2020-12 §12.4.2).
// Zero `context.temp_allocator`, zero `core:os`, WASM-clean.
package schema

import "base:runtime"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

// Extra metadata included in a Basic Output report.
Report_Options :: struct {
	file:      string,
	truncated: bool,
	indent:    u8,
	tab:       bool,
}

// Writes the JSON Schema Basic Output JSON for validation `entries`:
// `{ "valid": true|false, "errors": [ { "valid": false, "keywordLocation": ..., "absoluteKeywordLocation": ..., "instanceLocation": ..., "error": ... } ] }`.
@(require_results)
write_basic_report :: proc(
	entries: []check.Check_Error,
	uri: string,
	bases: []rules.Base = nil,
	opts := Report_Options{},
	allocator := context.allocator,
) -> (text: []u8, err: Error) {
	jw: Json_Writer
	if !jw_init(&jw, opts.indent, opts.tab, allocator) {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	jw_open_object(&jw)
	if opts.file != "" {
		jw_key(&jw, "file")
		jw_string(&jw, opts.file)
	}
	jw_key(&jw, "valid")
	jw_bool(&jw, len(entries) == 0)
	if len(entries) > 0 {
		jw_key(&jw, "errors")
		jw_open_array(&jw)
		for e in entries {
			jw_open_object(&jw)
			jw_key(&jw, "valid")
			jw_bool(&jw, false)
			jw_key(&jw, "keywordLocation")
			jw_string(&jw, e.keyword_location)
			if base, rest := base_of(uri, bases, e.keyword_path); base != "" && !through_ref(e.keyword_path) {
				frag := fragment_of(rest, allocator)
				abs := strings.concatenate({base, "#", frag}, allocator)
				jw_key(&jw, "absoluteKeywordLocation")
				jw_string(&jw, abs)
				delete(abs, allocator)
				delete(frag, allocator)
			}
			jw_key(&jw, "instanceLocation")
			jw_string(&jw, e.instance_location)
			jw_key(&jw, "error")
			msg := error_message(e, allocator)
			jw_string(&jw, msg)
			delete(msg, allocator)
			jw_close_object(&jw)
		}
		jw_close_array(&jw)
	}
	if opts.truncated {
		jw_key(&jw, "truncated")
		jw_bool(&jw, true)
	}
	jw_close_object(&jw)
	out, ok := jw_finish(&jw)
	if !ok {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	return out, {}
}

// Human-readable diagnostic message for a `check.Check_Error`, allocated from `allocator`.
error_message :: proc(e: check.Check_Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	switch e.kind {
	case .None:
		strings.write_string(&b, "ok")
	case .Wrong_Kind:
		strings.write_string(&b, "expected ")
		strings.write_string(&b, e.expected if e.expected != "" else "a different type")
	case .Not_Allowed:
		strings.write_string(&b, "value is not allowed")
	case .Below_Minimum:
		strings.write_string(&b, "number must be ")
		strings.write_string(&b, e.expected if e.expected != "" else "at least minimum")
	case .Above_Maximum:
		strings.write_string(&b, "number must be ")
		strings.write_string(&b, e.expected if e.expected != "" else "at most maximum")
	case .Not_Multiple:
		strings.write_string(&b, "number is not a multiple of divisor")
	case .Too_Short:
		strings.write_string(&b, "string must have ")
		strings.write_string(&b, e.expected if e.expected != "" else "at least minLength characters")
	case .Too_Long:
		strings.write_string(&b, "string must have ")
		strings.write_string(&b, e.expected if e.expected != "" else "at most maxLength characters")
	case .No_Match:
		strings.write_string(&b, "string does not match pattern")
	case .Pattern_Undecided:
		strings.write_string(&b, "pattern match exceeded budget")
	case .Bad_Format:
		strings.write_string(&b, "string does not match format")
	case .Too_Few:
		strings.write_string(&b, "must have ")
		strings.write_string(&b, e.expected if e.expected != "" else "at least minimum items")
	case .Too_Many:
		strings.write_string(&b, "must have ")
		strings.write_string(&b, e.expected if e.expected != "" else "at most maximum items")
	case .Not_Unique:
		strings.write_string(&b, "array items must be unique")
	case .Not_A_Member:
		strings.write_string(&b, "value does not match ")
		strings.write_string(&b, e.keyword if e.keyword != "" else "enum")
	case .Missing_Field:
		strings.write_string(&b, "missing required property")
		if e.expected != "" {
			strings.write_string(&b, " \"")
			strings.write_string(&b, e.expected)
			strings.write_byte(&b, '"')
		}
	case .No_Arm:
		strings.write_string(&b, "value did not match any branch of ")
		strings.write_string(&b, e.keyword if e.keyword != "" else "anyOf")
	case .Many_Arms:
		strings.write_string(&b, "value matched more than one branch of oneOf")
	case .Duplicate_Key:
		strings.write_string(&b, "duplicate object key")
	case .Exceeded:
		strings.write_string(&b, "validation budget exceeded")
	case .Walk:
		strings.write_string(&b, "document walk error")
	case .No_Memory:
		strings.write_string(&b, "out of memory")
	case .Bad_Option:
		strings.write_string(&b, "invalid option")
	case .Unsupported:
		strings.write_string(&b, "unsupported schema feature")
	}
	return strings.to_string(b)
}

// Innermost embedded schema resource whose keyword steps prefix `steps`, or the root `uri`.
@(private)
base_of :: proc(uri: string, bases: []rules.Base, steps: []tape.Step) -> (base: string, rest: []tape.Step) {
	base, rest = uri, steps
	outer: for x in bases {
		if len(x.steps) > len(steps) || len(x.steps) <= len(steps) - len(rest) {
			continue
		}
		for s, k in x.steps {
			if s != steps[k] {
				continue outer
			}
		}
		base, rest = x.uri, steps[len(x.steps):]
	}
	return
}

// Whether `steps` pass through a `$ref`, `$dynamicRef`, or `$recursiveRef`.
@(private)
through_ref :: proc(steps: []tape.Step) -> bool {
	for i := 0; i < len(steps); i += 1 {
		name, named := steps[i].(tape.Name)
		if !named {
			continue
		}
		switch string(name) {
		case "$ref", "$dynamicRef", "$recursiveRef":
			return true
		case "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies":
			i += 1
		}
	}
	return false
}

// Formats `steps` as a percent-encoded RFC 6901 URI fragment.
@(private)
fragment_of :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> string {
	ptr, err := check.format_pointer(steps, allocator)
	if err != nil {
		return ""
	}
	defer delete(ptr, allocator)
	hex_digits := "0123456789ABCDEF"
	out := strings.builder_make(0, len(ptr), allocator)
	for c in transmute([]u8)ptr {
		if c <= ' ' || c >= 0x7f || strings.contains_rune(`"#%<>[\]^` + "`{|}", rune(c)) {
			strings.write_byte(&out, '%')
			strings.write_byte(&out, hex_digits[c >> 4])
			strings.write_byte(&out, hex_digits[c & 0xF])
		} else {
			strings.write_byte(&out, c)
		}
	}
	return strings.to_string(out)
}
