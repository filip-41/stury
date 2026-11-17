// The record entry points of the format package: a stream's documents are its records, under `.Concatenated`. A reader
// they open holds no record reads: a caller that builds or scans a record sets `it.docs = record_docs(spec)`.
package yaml

import "base:runtime"
import "core:io"
import core "../core"
import typed "../core/typed"
import cw "../core/write"
import records "../core/records"

// The reads of a record's value as `spec`: its build and its scan.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	return &RECORD_DOCS
}

@(private, rodata)
RECORD_DOCS := records.Record_Docs {
	scan  = scan_record,
	read  = proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal) -> bool {
		return records.read_built(it, target, T, plan, read, allocator, err, typed_build)
	},
	build = build_document,
}

// Opens the documents of `src` as records from byte `at`, as `records.open` does with `as(spec, opts)`, and under
// `.Entries` the members of the container `entries` names, from the root through members.
records_open :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator, entries: []string = nil) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), &FRAMING, nil, framing, at, allocator, entries)
}

// Returns the fault of each refused document of `src`, as `records.validate` does with `as(spec, opts)`.
records_validate :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.validate(src, bound_as(S, opts), framing, allocator, runner, at, &FRAMING)
}

// Hands the pieces of the documents of `src` to `task`, as `records.each` does with `as(spec, opts)`.
records_each :: #force_inline proc(src: []u8, $S: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(S, opts), framing, task, data, runner, at, &FRAMING)
}

// Opens the documents `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), &FRAMING, nil, framing, stream, at, allocator)
}

// Starts a token write, as `write.tokens_init` does with `as(spec, opts)`.
tokens_init :: proc(t: ^cw.Tokens, $S: Spec, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return cw.tokens_init(t, bound_as(S, opts), write, allocator, stream, &TOKENS)
}

// Writes `v` as spec `S`, as `write.write_value` does with `as(spec, opts)`.
write_value :: proc(v: core.Value, $S: Spec, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> (text: []u8, err: core.Error) {
	return cw.write_value(v, as(S, opts), write, allocator)
}

// Starts a writer of records, as `records.writer_init` does with `as(spec, opts)`.
writer_init :: proc(wr: ^records.Writer, w: io.Stream, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, write := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error_Kind {
	return records.writer_init(wr, w, bound_as(S, opts), framing, write, allocator, &TOKENS)
}

// Writes `list` as records, each by `plan`, as `records.marshal` does with `as(spec, opts)`.
records_marshal :: proc(list: []$E, plan: ^typed.Plan, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	return records.marshal(list, plan, as(S, opts), framing, write, allocator)
}

// Writes `list` as records to `w`, as `records.marshal_stream` does with `as(spec, opts)`.
records_marshal_stream :: proc(w: io.Stream, list: []$E, plan: ^typed.Plan, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, write := core.Write_Options{}) -> core.Error {
	return records.marshal_stream(w, list, plan, as(S, opts), framing, write)
}
