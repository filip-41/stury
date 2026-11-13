// The records of TOML. A TOML text is one document with no mark that ends it, so under `.Concatenated` the record is
// the whole text from the reader's position to the input's end, and an input of no bytes holds none. A stream's record
// is settled once its input has ended. A reader the entry points open holds no record reads: a caller that builds or
// scans a record sets `it.docs = record_docs(spec)`.
package toml

import "base:runtime"
import "core:io"
import core "../core"
import records "../core/records"

// The framing of TOML texts, which a handle's `records` and the readers the entry points open reach.
@(private, rodata)
FRAMING := records.Framing_Services {
	next  = #partial {.Concatenated = next_text},
	judge = proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {return nil},
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
record_docs :: proc "contextless" (spec: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		build = build_record,
	}
	return &d
}

@(private)
build_record :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_text(rec.text, it.as, allocator)
	core.move_document_error(&err, rec.at)
	return doc, err
}

// Opens the text of `src` as a record from byte `at`, as `records.open` does with `as(spec, opts)`.
records_open :: proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_with(src, bound_as(spec, opts), &FRAMING, nil, framing, at, allocator)
}

// Opens the text `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(spec, opts), &FRAMING, nil, framing, stream, at, allocator)
}

// Returns the fault of a refused text of `src`, as `records.check` does with `as(spec, opts)`.
records_check :: proc(src: []u8, spec: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, bound_as(spec, opts), framing, allocator, runner, at, &FRAMING)
}

// Hands the text of `src` to `task` as one piece, as `records.each` does with `as(spec, opts)`.
records_each :: #force_inline proc(src: []u8, spec: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(spec, opts), framing, task, data, runner, at, &FRAMING)
}
