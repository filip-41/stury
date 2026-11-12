// The records of HTML. An HTML text has no mark that ends it, since a browser reads every byte past `</html>` into the
// tree, so under `.Concatenated` the record is the whole text from the reader's position to the input's end, and an
// input of no bytes holds none. A stream's record is settled once its input has ended. A constant `spec` binds the
// framing (`framing_of`) at compile time, and a `spec` chosen at run time is the handle's `records.open`. A reader
// opened with a constant spec holds no record reads: a caller that builds or scans a record sets
// `it.docs = record_docs(spec)`.
package html

import "base:runtime"
import "core:io"
import core "../core"
import records "../core/records"

// The framing of spec `S`'s texts, which a handle's `records` and a reader of a constant spec reach.
@(private)
framing_of :: proc "contextless" ($S: Spec) -> ^records.Framing_Services {
	@(static, rodata) f := records.Framing_Services {
		next  = #partial {.Concatenated = proc(it: ^records.Reader) -> (records.Record, bool) {return next_text(it, S)}},
		judge = proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {return nil},
	}
	return &f
}

// Frames the text at the reader's position, the rest of the input, judged by the tree it builds as a text of its own,
// as the record's build reads it.
@(private)
next_text :: proc(it: ^records.Reader, $S: Spec) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	t, fault := build_tree(it.src[lo:], S, options_of(it.as), 0, runtime.default_allocator())
	if f, bad := fault.?; bad {
		f.at += lo
		it.fault = f
		return
	}
	tree_destroy(&t)
	it.pos = u64(len(it.src))
	return {text = it.src[lo:], at = lo}, true
}

// The reads of a record's value as spec `S`: its build. A scan of a record builds it.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		build = proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
			doc, err := build_spec(rec.text, S, it.as, false, allocator)
			core.move_document_error(&err, rec.at)
			return doc, err
		},
	}
	return &d
}

// Opens `src` for its records, as `records.open` does with `as(spec, opts)`.
records_open :: proc {records_open_bound, records_open_chosen}

@(private)
records_open_bound :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), framing_of(S), nil, framing, at, allocator)
}

@(private)
records_open_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open(src, as(spec, opts), framing, at, allocator)
}

// Opens the text `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc {records_open_stream_bound, records_open_stream_chosen}

@(private)
records_open_stream_bound :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), framing_of(S), nil, framing, stream, at, allocator)
}

@(private)
records_open_stream_chosen :: #force_inline proc(input: io.Reader, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream(input, as(spec, opts), framing, stream, at, allocator)
}

// Returns the fault of a refused text of `src`, as `records.check` does with `as(spec, opts)`.
records_check :: proc {records_check_bound, records_check_chosen}

@(private)
records_check_bound :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, bound_as(S, opts), framing, allocator, runner, at, framing_of(S))
}

@(private)
records_check_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, as(spec, opts), framing, allocator, runner, at)
}

// Hands the text of `src` to `task` as one piece, as `records.each` does with `as(spec, opts)`.
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
