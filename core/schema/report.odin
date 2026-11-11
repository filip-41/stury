package schema

import "core:strings"
import core "../"
import "../rules"
import "../write"

// Writes the JSON Schema basic output for `entries`: `valid`, then each entry as its `keywordLocation`, its
// `absoluteKeywordLocation` where the keywords did not pass a reference, its `instanceLocation` and its `error`. With
// `r.records` an entry also has a `record` member, since a record's location is not part of the instance's. A
// `truncated` member says the entries are not all of them. `uri` is the schema's root resource, "" for none, and `bases`
// the resources embedded in it, the description's `bases`: an absolute keyword location starts at the innermost of them
// that holds the keyword.
write_basic :: proc(t: ^write.Tokens, entries: []core.Error_Entry, uri: string, r := write.Report{}, bases: []rules.Base = nil) -> core.Typed_Error_Kind {
	write.open_object(t)
	write.report_file(t, r)
	write.key(t, "valid")
	write.value_bool(t, len(entries) == 0)
	if len(entries) > 0 {
		write.key(t, "errors")
		write.open_array(t)
		for e in entries {
			write.open_object(t)
			write.key(t, "valid")
			write.value_bool(t, false)
			write.report_location(t, "keywordLocation", e.keyword_path)
			if base, rest := base_of(uri, bases, e.keyword_path); base != "" && !through_ref(e.keyword_path) {
				write.key(t, "absoluteKeywordLocation")
				write.value_string(t, strings.concatenate({base, "#", fragment_of(rest)}, context.temp_allocator))
			}
			write.report_location(t, "instanceLocation", e.path)
			write.report_record(t, r, e)
			write.key(t, "error")
			write.value_string(t, write.report_message(e))
			write.close(t)
		}
		write.close(t)
	}
	if r.truncated {
		write.key(t, "truncated")
		write.value_bool(t, true)
	}
	write.close(t)
	return t.err
}

// The resource whose URI an absolute keyword location of `steps` starts with, the innermost of `bases` whose steps begin
// `steps` or else the root's `uri`, and the steps from it.
@(private)
base_of :: proc(uri: string, bases: []rules.Base, steps: []core.Step) -> (base: string, rest: []core.Step) {
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

// Whether the keywords lead through a reference, whose target's own place the entry does not keep. A step is a keyword
// unless it is the name or index a keyword takes after it: the members of `properties`, `patternProperties`, `$defs`,
// `dependentSchemas` and `dependencies` and the entries of an array of schemas.
@(private)
through_ref :: proc(steps: []core.Step) -> bool {
	for i := 0; i < len(steps); i += 1 {
		name, named := steps[i].(core.Name)
		if !named {
			continue
		}
		switch name {
		case "$ref", "$dynamicRef", "$recursiveRef":
			return true
		case "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies":
			i += 1
		}
	}
	return false
}

// `steps` as a JSON Pointer in a URI fragment: a byte a fragment may not hold is written as `%` and its two hex digits.
@(private)
fragment_of :: proc(steps: []core.Step) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.write_pointer(strings.to_writer(&b), steps)
	out := strings.builder_make(context.temp_allocator)
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)strings.to_string(b) {
		if c <= ' ' || c >= 0x7f || strings.contains_rune(`"%<>\^`+"`{|}", rune(c)) {
			strings.write_byte(&out, '%')
			strings.write_byte(&out, hex[c >> 4])
			strings.write_byte(&out, hex[c & 15])
		} else {
			strings.write_byte(&out, c)
		}
	}
	return strings.to_string(out)
}
