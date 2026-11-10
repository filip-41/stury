package write

import "core:io"
import "core:strings"
import core ".."

// What a report of a check's entries says besides them. `uri` is the schema's root resource, the base of the absolute
// keyword locations, "" for none. `records` puts the index of the entry's record first in its instance location.
// `truncated` says entries past the check's limit were not kept.
Report :: struct {
	uri:       string,
	records:   bool,
	truncated: bool,
}

// The problem document's own members (RFC 9457). A `type` of "" is left out, which reads as `about:blank`.
Problem :: struct {
	type:   string,
	title:  string,
	status: int,
}

// Writes the JSON Schema basic output for `entries`: `valid`, then each entry as its `keywordLocation`, its
// `absoluteKeywordLocation` where the keywords did not pass a `$ref`, its `instanceLocation` and its `error`. A
// `truncated` member says the entries are not all of them.
write_basic :: proc(t: ^Tokens, entries: []core.Error_Entry, r := Report{}) -> core.Typed_Error_Kind {
	open_object(t)
	key(t, "valid")
	value_bool(t, len(entries) == 0)
	if len(entries) > 0 {
		key(t, "errors")
		open_array(t)
		for e in entries {
			open_object(t)
			location(t, "keywordLocation", e.keyword_path)
			if r.uri != "" && !through_ref(e.keyword_path) {
				key(t, "absoluteKeywordLocation")
				value_string(t, strings.concatenate({r.uri, "#", fragment_of(e.keyword_path)}, context.temp_allocator))
			}
			location(t, "instanceLocation", e.path, r.records, e.record)
			key(t, "error")
			value_string(t, core.entry_message(e))
			close(t)
		}
		close(t)
	}
	if r.truncated {
		key(t, "truncated")
		value_bool(t, true)
	}
	close(t)
	return t.err
}

// Writes a problem document for `entries`: `p`'s members, then `errors`, each entry's `pointer` to its value, its stable
// `code` and its `message`.
write_problem :: proc(t: ^Tokens, entries: []core.Error_Entry, p: Problem, r := Report{}) -> core.Typed_Error_Kind {
	open_object(t)
	if p.type != "" {
		key(t, "type")
		value_string(t, p.type)
	}
	key(t, "title")
	value_string(t, p.title)
	key(t, "status")
	value_int(t, i64(p.status))
	key(t, "errors")
	open_array(t)
	for e in entries {
		open_object(t)
		location(t, "pointer", e.path, r.records, e.record)
		key(t, "code")
		value_string(t, core.entry_code(e))
		key(t, "message")
		value_string(t, core.entry_message(e))
		close(t)
	}
	close(t)
	if r.truncated {
		key(t, "truncated")
		value_bool(t, true)
	}
	close(t)
	return t.err
}

// A member `name` whose value is `steps` as a JSON Pointer, led by the record index when `record` says so.
@(private)
location :: proc(t: ^Tokens, name: string, steps: []core.Step, record := false, index := i64(0)) {
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	if record {
		io.write_byte(w, '/')
		io.write_i64(w, index)
	}
	core.write_pointer(w, steps)
	key(t, name)
	value_string(t, strings.to_string(b))
}

// Whether the keywords lead through a `$ref`, whose target's own place the entry does not keep.
@(private)
through_ref :: proc(steps: []core.Step) -> bool {
	for s in steps {
		if name, named := s.(core.Name); named && name == "$ref" {
			return true
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
