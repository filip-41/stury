// The record entry points of the format package. A constant `spec` links the passes of that spec alone: it binds the
// spec's framing (`framing_of`) and the writer's spelling at compile time. A `spec` chosen at run time is the handle's
// `records.open` and links every spec's passes. A reader opened with a constant spec holds no record reads: a caller
// that reads, builds or takes a cell of a record sets `it.docs = record_docs(spec)`.
// `typed` and `write` are used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package dsv

import "base:runtime"
import "core:io"
import core "../core"
import typed "../core/typed"
import write "../core/write"
import records "../core/records"

// The framing of records read as spec `S`: the pass that frames a row is the pass of `S`. It holds no record reads,
// which `record_docs(S)` gives.
@(private)
framing_of :: proc "contextless" ($S: Spec) -> ^records.Framing_Services {
	@(static, rodata) f := records.Framing_Services {
		next  = #partial {.Lines = proc(it: ^records.Reader) -> (records.Record, bool) {return next_row_spec(it, S)}},
		judge = proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {return nil},
		span  = proc(it: ^records.Reader, to: u64) -> (records.Record, bool) {return next_span_spec(it, to, S)},
		guess = guess_row,
		exact = exact_row,
		piece = piece_rows,
		whole = proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {return as, .Lines, 0},
		close = close_rows,
	}
	return &f
}

// The reads of a record's row as spec `S`: its typed read, its document and its cells. Its check read is the plan's.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		read = proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal) -> bool {
			return read_row_spec(it, target, T, plan, read, allocator, err, S, typed.Reader)
		},
		build = proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
			return build_row_spec(it, rec, allocator, S)
		},
		column = column_of,
		cell = proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8) -> (string, bool) {
			return cell_of_spec(it, rec, column, buf, S)
		},
		cells = proc(it: ^records.Reader, rec: records.Record, buf: []u8, upto: int) -> ([]write.Scalar, bool) {
			return cells_texts_spec(it, rec, buf, upto, S)
		},
	}
	return &d
}

// The check read of a record as spec `S`, which a plan made with `checks(S)` holds in `typed.Plan.docs`.
@(private)
check_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		check_read = proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal) -> bool {
			return read_row_spec(it, target, T, plan, read, allocator, err, S, typed.Check)
		},
		framing = proc "contextless" () -> ^records.Framing_Services {return framing_of(S)},
	}
	return &d
}

// Opens the records of `src` under `framing` from byte `at`, as `records.open` does with `as(spec, opts)`.
records_open :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Lines, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), framing_of(S), nil, framing, at, allocator)
}

// Opens the records `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Lines, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), framing_of(S), nil, framing, stream, at, allocator)
}

// Returns the fault of each refused record of `src`, as `records.check` does with `as(spec, opts)`.
records_check :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Lines, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.check(src, bound_as(S, opts), framing, allocator, runner, at, framing_of(S))
}

// Hands the pieces of the records of `src` to `task`, as `records.each` does with `as(spec, opts)`.
records_each :: #force_inline proc(src: []u8, $S: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(S, opts), framing, task, data, runner, at, framing_of(S))
}

// Starts a writer of records, as `records.writer_init` does with `as(spec, layout)`. `layout` is the delimiter, header,
// line end and inference the rows are written with.
writer_init :: proc(wr: ^records.Writer, w: io.Stream, $S: Spec, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator, layout := Options{}) -> core.Typed_Error_Kind {
	return records.writer_init(wr, w, bound_as(S, layout), framing, opts, allocator, &TOKENS)
}
