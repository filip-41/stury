package write

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
report_pointer :: proc(e: core.Error_Entry) -> string {
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
