// The records of TOML. A TOML text is one document with no mark that ends it, so under `.Concatenated` the record is
// the whole text from the reader's position to the input's end, and an input of no bytes holds none. A stream's record
// is settled once its input has ended. A reader the entry points open holds no record reads: a caller that builds or
// scans a record sets `it.docs = record_docs(spec)`.
package toml

import "base:runtime"
import "core:io"
import core "../core"
import typed "../core/typed"
import cw "../core/write"
import records "../core/records"

// The framing of TOML texts, which a handle's `records` and the readers the entry points open reach.
@(private, rodata)
FRAMING := records.Framing_Services {
	next  = #partial {.Concatenated = next_text, .Entries = records.entries_next},
	judge = records.no_judge,
	tree  = build_handle,
	close = records.entries_close,
}

// Frames the text at the reader's position, the rest of the input, judged by the read of its table tree.
@(private)
next_text :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	p: Parser
	defer parser_destroy(&p)
	if !parser_init(&p, it.src, Spec(it.as.spec) == .Toml_1_1, depth_limit(options_of(it.as))) {
		it.fault = core.Fault{rules = &RULES, kind = .No_Memory}
		return
	}
	if !parse(&p, lo) {
		_, it.fault, _ = core.result_of(p.fail, &RULES)
		return
	}
	it.pos = u64(len(it.src))
	return {text = it.src[lo:], at = lo}, true
}

// The reads of a record's value as `spec`: its build. A scan of a record builds it, as every path read of TOML does.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	return records.built_docs(build_handle)
}

// Opens the text of `src` as a record from byte `at`, as `records.open` does with `as(spec, opts)`, and under
// `.Entries` the members of the container `entries` names, from the root through members.
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
