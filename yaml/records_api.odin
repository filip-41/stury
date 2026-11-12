// The record entry points of the format package: a stream's documents are its records, under `.Concatenated`. A
// constant `spec` binds the spec's framing (`framing_of`) and the writer's spelling at compile time. A `spec` chosen at
// run time is the handle's `records.open`. A reader opened with a constant spec holds no record reads: a caller that
// builds or scans a record sets `it.docs = record_docs(spec)`.
// `write` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package yaml

import "base:runtime"
import "core:io"
import core "../core"
import write "../core/write"
import records "../core/records"

// The reads of a record's value as spec `S`: its build and its scan.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		scan  = scan_record,
		build = build_document,
	}
	return &d
}

// Opens the documents of `src` as records from byte `at`, as `records.open` does with `as(spec, opts)`.
records_open :: proc {records_open_bound, records_open_chosen}

@(private)
records_open_bound :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), framing_of(S), nil, framing, at, allocator)
}

@(private)
records_open_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open(src, as(spec, opts), framing, at, allocator)
}

// Opens the documents `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc {records_open_stream_bound, records_open_stream_chosen}

@(private)
records_open_stream_bound :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), framing_of(S), nil, framing, stream, at, allocator)
}

@(private)
records_open_stream_chosen :: #force_inline proc(input: io.Reader, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream(input, as(spec, opts), framing, stream, at, allocator)
}

// Returns the fault of each refused document of `src`, as `records.check` does with `as(spec, opts)`.
records_check :: proc {records_check_bound, records_check_chosen}

@(private)
records_check_bound :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, bound_as(S, opts), framing, allocator, runner, at, framing_of(S))
}

@(private)
records_check_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, as(spec, opts), framing, allocator, runner, at)
}

// Hands the pieces of the documents of `src` to `task`, as `records.each` does with `as(spec, opts)`.
records_each :: proc {records_each_bound, records_each_chosen}

@(private)
records_each_bound :: #force_inline proc(src: []u8, $S: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(S, opts), framing, task, data, runner, at, framing_of(S))
}

// A group's two forms may not both be generic over the task's data, so a spec chosen at run time takes the data as a
// `rawptr`.
@(private)
records_each_chosen :: #force_inline proc(src: []u8, spec: Spec, framing: core.Framing, task: proc(data: rawptr, piece: ^records.Reader, k: int) -> bool, data: rawptr, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, as(spec, opts), framing, cast(proc(data: ^u8, piece: ^records.Reader, k: int) -> bool)task, (^u8)(data), runner, at)
}

// Starts a token write, as `write.tokens_init` does with `as(spec)`.
tokens_init :: proc {tokens_init_bound, tokens_init_chosen}

@(private)
tokens_init_bound :: proc(t: ^write.Tokens, $S: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, bound_as(S), opts, allocator, stream, &TOKENS)
}

@(private)
tokens_init_chosen :: #force_inline proc(t: ^write.Tokens, spec: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, as(spec), opts, allocator, stream)
}
