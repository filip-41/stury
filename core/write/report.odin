package write

import "core:io"
import "core:strings"
import core ".."

// What a report of a check's entries says besides them. `records` puts the index of the entry's record first in its
// instance location. `truncated` says entries past the check's limit were not kept. `file` names the input the entries
// are of, "" for none.
Report :: struct {
	file:      string,
	records:   bool,
	truncated: bool,
}

// The problem document's own members (RFC 9457). A `type` of "" is left out, which reads as `about:blank`.
Problem :: struct {
	type:   string,
	title:  string,
	status: int,
}

// Writes a problem document for `entries`: `p`'s members, then `errors`, each entry's `pointer` to its value, its stable
// `code` and its `message`.
write_problem :: proc(t: ^Tokens, entries: []core.Error_Entry, p: Problem, r := Report{}) -> core.Typed_Error_Kind {
	open_object(t)
	report_file(t, r)
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
		report_location(t, "pointer", e.path, r.records, e.record, member_of(e))
		key(t, "code")
		value_string(t, core.entry_code(e))
		key(t, "message")
		value_string(t, report_message(e))
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

// Writes the `file` member of a report that names its input.
report_file :: proc(t: ^Tokens, r: Report) {
	if r.file != "" {
		key(t, "file")
		value_string(t, r.file)
	}
}

// The message of `e` as the reports tell it.
report_message :: proc(e: core.Error_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.write_entry_message(strings.to_writer(&b), e)
	return strings.to_string(b)
}

// The member a missing-member entry names, "" for any other entry.
@(private)
member_of :: proc(e: core.Error_Entry) -> string {
	name, named := e.operand.(string)
	return name if named && e.kind == .Missing_Field else ""
}

// Writes a member `name` whose value is `steps` as a JSON Pointer, led by the record index when `record` says so, and by
// `member` as a last step when it is not "".
report_location :: proc(t: ^Tokens, name: string, steps: []core.Step, record := false, index := i64(0), member := "") {
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	if record {
		io.write_byte(w, '/')
		io.write_i64(w, index)
	}
	core.write_pointer(w, steps)
	if member != "" {
		core.write_pointer(w, {core.Name(member)})
	}
	key(t, name)
	value_string(t, strings.to_string(b))
}
