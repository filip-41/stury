package model

import "base:runtime"
import "core:strings"
import core ".."
import write "../write"

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
		x.pointer = strings.clone(write.report_pointer(e), allocator) or_return
		x.message = strings.clone(write.report_message(e), allocator) or_return
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
write_problem :: proc(t: ^write.Tokens, entries: []core.Error_Entry, p: Problem, r := write.Report{}) -> core.Typed_Error_Kind {
	write.open_object(t)
	write.report_file(t, r)
	if p.type != "" {
		write.key(t, "type")
		write.value_string(t, p.type)
	}
	write.key(t, "title")
	write.value_string(t, p.title)
	write.key(t, "status")
	write.value_int(t, i64(p.status))
	write.key(t, "errors")
	write.open_array(t)
	for e in entries {
		write.open_object(t)
		write.key(t, "pointer")
		write.value_string(t, write.report_pointer(e))
		write.report_record(t, r, e)
		write.key(t, "code")
		write.value_string(t, core.entry_code(e))
		write.key(t, "message")
		write.value_string(t, write.report_message(e))
		write.close(t)
	}
	write.close(t)
	if r.truncated {
		write.key(t, "truncated")
		write.value_bool(t, true)
	}
	write.close(t)
	return t.err
}
