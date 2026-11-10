package write

import "base:runtime"
import "core:strings"
import core ".."

// What a report of a check's entries says besides them. `records` gives each entry a `record` member, the index of its
// record, beside a location that is the record's own. `truncated` says entries past the check's limit were not kept. `file` names the input the entries
// are of, "" for none.
Report :: struct {
	file:      string,
	records:   bool,
	truncated: bool,
}

// A problem document (RFC 9457). A `type` of "" is left out, which reads as `about:blank`. `errors` is what `problem`
// makes of a sink's entries, for any format's `marshal`, and `write_problem` writes its entries in its place.
Problem :: struct {
	type:   string `stury:"type,omitempty"`,
	title:  string,
	status: int,
	errors: []Problem_Error,
}

// One entry of a problem document: the JSON Pointer to the value, the stable code of the refusal and its message.
Problem_Error :: struct {
	pointer: string,
	code:    string,
	message: string,
}

// The problem document of `entries`, as a sink of a load, `validate` or a check holds them, with the strings it makes
// from `allocator`. The pointer of a missing member names the member.
problem :: proc(entries: []core.Error_Entry, title: string, status: int, type := "", allocator := context.allocator) -> (p: Problem, err: runtime.Allocator_Error) {
	p = {type = type, title = title, status = status}
	p.errors = make([]Problem_Error, len(entries), allocator) or_return
	for e, i in entries {
		x := &p.errors[i]
		x.code = core.entry_code(e)
		x.pointer = strings.clone(entry_pointer(e), allocator) or_return
		x.message = strings.clone(report_message(e), allocator) or_return
	}
	return
}

// Frees what `problem` made of `p`.
problem_destroy :: proc(p: Problem, allocator := context.allocator) {
	for e in p.errors {
		delete(e.pointer, allocator)
		delete(e.message, allocator)
	}
	delete(p.errors, allocator)
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
		key(t, "pointer")
		value_string(t, entry_pointer(e))
		report_record(t, r, e)
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

// The JSON Pointer to the value of `e`, in the temp allocator, which for a missing member names the member.
@(private)
entry_pointer :: proc(e: core.Error_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&b)
	core.write_pointer(w, e.path)
	if name, named := e.operand.(string); named && e.kind == .Missing_Field {
		core.write_pointer(w, {core.Name(name)})
	}
	return strings.to_string(b)
}

// Writes the `record` member of an entry of a report that tells its records.
report_record :: proc(t: ^Tokens, r: Report, e: core.Error_Entry) {
	if r.records {
		key(t, "record")
		value_int(t, e.record)
	}
}

// Writes a member `name` whose value is `steps` as a JSON Pointer.
report_location :: proc(t: ^Tokens, name: string, steps: []core.Step) {
	b := strings.builder_make(context.temp_allocator)
	core.write_pointer(strings.to_writer(&b), steps)
	key(t, name)
	value_string(t, strings.to_string(b))
}
