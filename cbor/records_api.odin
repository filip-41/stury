// The record entry points of the package: a CBOR sequence (RFC 8742) read or written an item at a time. A constant
// `spec` binds CBOR's framing and the writer's spelling, so it links no pass it does not run, and a `spec` chosen at run
// time is the handle's `records.open`. A reader opened with a constant spec holds no record reads: a caller that builds
// a record sets `it.docs = record_docs(spec)`.
package cbor

import "base:runtime"
import "core:io"
import core "../core"
import cw "../core/write"
import records "../core/records"

// The reads of a record's value of `spec`: its build. Every spec shares them, since a reader's handle holds its spec.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	return &RECORD_DOCS
}

// Opens the items of `src` as records from byte `at`, as `records.open` does with `as(spec, opts)`: a sequence under
// `.Concatenated`, and under `.Entries` the members of the container `entries` names, from the root through members.
records_open :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator, entries: []string = nil) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), &FRAMING, nil, framing, at, allocator, entries)
}

// Opens the items `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), &FRAMING, nil, framing, stream, at, allocator)
}

// Returns the fault of each refused item of `src`, as `records.validate` does with `as(spec, opts)`.
records_validate :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.validate(src, bound_as(S, opts), framing, allocator, runner, at, &FRAMING)
}

// Hands the pieces of the items of `src` to `task`, as `records.each` does with `as(spec, opts)`.
records_each :: #force_inline proc(src: []u8, $S: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(S, opts), framing, task, data, runner, at, &FRAMING)
}

// Starts a token write, as `write.tokens_init` does with `as(spec, opts)`.
tokens_init :: proc(t: ^cw.Tokens, $S: Spec, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return cw.tokens_init(t, bound_as(S, opts), write, allocator, stream, &TOKENS)
}

// Starts a writer of records, as `records.writer_init` does with `as(spec, opts)`.
writer_init :: proc(wr: ^records.Writer, w: io.Stream, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, write := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error_Kind {
	return records.writer_init(wr, w, bound_as(S, opts), framing, write, allocator, &TOKENS)
}
