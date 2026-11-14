// The records of HTML. An HTML text has no mark that ends it, since a browser reads every byte past `</html>` into the
// tree. Under `.Concatenated` the record is the whole text from the reader's position to the input's end, and an input
// of no bytes holds none. A stream's record is settled once its input has ended. A reader the entry points open holds
// no record reads. A caller that builds or scans a record sets `it.docs = record_docs(spec)`.
package html

import "base:runtime"
import "core:io"
import core "../core"
import cw "../core/write"
import records "../core/records"

// The framing of HTML texts, which a handle's `records` and the readers the entry points open reach.
@(private, rodata)
FRAMING := records.Framing_Services {
	next  = #partial {.Concatenated = next_text, .Entries = records.entries_next},
	judge = records.no_judge,
	tree  = build_handle,
	tree_state = member_state,
	close = records.entries_close,
}

// Frames the text at the reader's position, which is the rest of the input. The tree it builds as a text of its own
// judges it, as the record's build reads it.
@(private)
next_text :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	t, fault := build_tree(it.src[lo:], Spec(it.as.spec), options_of(it.as), 0, runtime.default_allocator())
	if f, bad := fault.?; bad {
		f.at += lo
		it.fault = f
		return
	}
	tree_destroy(&t)
	it.pos = u64(len(it.src))
	return {text = it.src[lo:], at = lo}, true
}

// The reads of a record's value: its build, which every spec shares. A scan of a record builds it.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	return &RECORD_DOCS
}

@(private, rodata)
RECORD_DOCS := records.Record_Docs {
	build = proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
		doc, err := build_spec(rec.text, Spec(it.as.spec), it.as, false, allocator)
		core.move_document_error(&err, rec.at)
		return doc, err
	},
}

// Opens `src` for its records, as `records.open` does with `as(spec, opts)`, and under `.Entries` the
// members of the container `entries` names, from the root through members.
records_open :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator, entries: []string = nil) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), &FRAMING, nil, framing, at, allocator, entries)
}

// Opens the text `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), &FRAMING, nil, framing, stream, at, allocator)
}

// Returns the fault of a refused text of `src`, as `records.validate` does with `as(spec, opts)`.
records_validate :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.validate(src, bound_as(S, opts), framing, allocator, runner, at, &FRAMING)
}

// Hands the text of `src` to `task` as one piece, as `records.each` does with `as(spec, opts)`.
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
