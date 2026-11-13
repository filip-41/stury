// The record entry points of the format package: a stream's documents are its records, under `.Concatenated`. A reader
// they open holds no record reads: a caller that builds or scans a record sets `it.docs = record_docs(spec)`.
package yaml

import "base:runtime"
import "core:io"
import core "../core"
import write "../core/write"
import records "../core/records"

// The reads of a record's value as `spec`: its build and its scan.
record_docs :: proc "contextless" (spec: Spec) -> ^records.Record_Docs {
	return &RECORD_DOCS
}

@(private, rodata)
RECORD_DOCS := records.Record_Docs {
	scan  = scan_record,
	build = build_document,
}

// Opens the documents of `src` as records from byte `at`, as `records.open` does with `as(spec, opts)`.
records_open :: proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_with(src, bound_as(spec, opts), &FRAMING, nil, framing, at, allocator)
}

// Returns the fault of each refused document of `src`, as `records.check` does with `as(spec, opts)`.
records_check :: proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, bound_as(spec, opts), framing, allocator, runner, at, &FRAMING)
}

// Hands the pieces of the documents of `src` to `task`, as `records.each` does with `as(spec, opts)`.
records_each :: #force_inline proc(src: []u8, spec: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(spec, opts), framing, task, data, runner, at, &FRAMING)
}

// Starts a token write, as `write.tokens_init` does with `as(spec)`.
tokens_init :: proc(t: ^write.Tokens, spec: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, bound_as(spec), opts, allocator, stream, &TOKENS)
}
