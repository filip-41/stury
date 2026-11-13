// The record entry points of the format package. A constant `spec` links the walks of that spec alone: it binds the
// spec's framing (`framing_of`) and the writer's spelling at compile time. A `spec` chosen at run time is the handle's
// `records.open` and links every spec's walk. A reader opened with a constant spec holds no record reads: a caller
// that reads, builds or scans a record sets `it.docs = record_docs(spec)`.
// `build` and `typed` are used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package json

import "base:runtime"
import "core:io"
import core "../core"
import build "../core/build"
import typed "../core/typed"
import records "../core/records"

// The reads of a record's value as spec `S`: its typed read, its build and its scan. Its checks are the plan's.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		scan = proc(it: ^records.Reader, h: ^build.Scan, last: ^core.Document, path: core.Path, read: core.Path_Options) -> (records.Record, core.Path_Error, bool) {
			return scan_record_spec(it, h, last, path, read, S)
		},
		read = proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal) -> bool {
			return read_spec(it, target, T, plan, read, allocator, err, S, false)
		},
		build = proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
			return build_record_spec(it, rec, allocator, S)
		},
		build_next = proc(it: ^records.Reader, b: ^build.Builder, regs: ^core.Hook_Regs) -> (records.Record, bool) {
			return build_next_spec(it, b, regs, S)
		},
	}
	return &d
}

// The checks of records as spec `S`, which a plan made with `checks_of(S)` holds in `typed.Plan.docs`.
@(private)
check_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	@(static, rodata) d := records.Record_Docs {
		check_read = proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal) -> bool {
			return read_spec(it, target, T, plan, read, allocator, err, S, true)
		},
		check_run = proc(it: ^records.Reader, plan: ^typed.Plan, read: typed.Read_Options, visit: records.Record_Visit, data: rawptr) {
			check_run_spec(it, plan, read, visit, data, S)
		},
		framing = proc "contextless" () -> ^records.Framing_Services {return framing_of(S)},
	}
	return &d
}

// Opens the records of `src` under `framing` from byte `at`, as `records.open` does with `as(spec, opts)`. Under
// `.Entries`, `entries` names the members that lead from the root to the container whose members are the records.
records_open :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Lines, at: u64 = 0, allocator := context.allocator, entries: []string = nil) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), framing_of(S), nil, framing, at, allocator, entries)
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

// Starts a writer of records, as `records.writer_init` does with `as(spec)`.
writer_init :: proc(wr: ^records.Writer, w: io.Stream, $S: Spec, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error_Kind {
	return records.writer_init(wr, w, bound_as(S), framing, opts, allocator, &TOKENS)
}
