// The record entry points of the package: a CBOR sequence (RFC 8742) read or written an item at a time. A constant
// `spec` binds CBOR's framing and the writer's spelling, so it links no pass it does not run, and a `spec` chosen at run
// time is the handle's `records.open`. A reader opened with a constant spec holds no record reads: a caller that builds
// a record sets `it.docs = record_docs(spec)`.
package cbor

import "base:runtime"
import "core:io"
import core "../core"
import write "../core/write"
import records "../core/records"

// The reads of a record's value of `spec`: its build. Every spec shares them, since a reader's handle holds its spec.
record_docs :: proc "contextless" (spec: Spec) -> ^records.Record_Docs {
	return &RECORD_DOCS
}

// Opens the items of `src` as records from byte `at`, as `records.open` does with `as(spec, opts)`. A sequence takes
// `.Concatenated` alone.
records_open :: proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_with(src, bound_as(spec, opts), &FRAMING, nil, framing, at, allocator)
}

// Opens the items `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(spec, opts), &FRAMING, nil, framing, stream, at, allocator)
}

// Returns the fault of each refused item of `src`, as `records.check` does with `as(spec, opts)`.
records_check :: proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, bound_as(spec, opts), framing, allocator, runner, at, &FRAMING)
}

// Starts a token write, as `write.tokens_init` does with `as(spec)`.
tokens_init :: proc(t: ^write.Tokens, spec: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, bound_as(spec), opts, allocator, stream, &TOKENS)
}
