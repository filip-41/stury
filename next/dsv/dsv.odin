package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Delimited texts in the grammars `Spec` names: CSV as RFC 4180, TSV and Plain. A text is an array of records, each an
// object whose keys are the header's cells, or under `Dsv_Options.no_header` an array of cells. A build keeps the
// records as a table, its header stored once.

// The grammar a delimited text follows.
Spec :: enum u8 {
	Csv, // RFC 4180: a cell whose first byte is a quote is quoted, and `""` inside it reads as `"`
	Tsv, // a quote is text, and a backslash escapes `t`, `n`, `r`, `0` or `\\`
	Plain, // no quotes and no escapes: a quote is text, and a cell cannot hold the delimiter, CR or LF
}

// Options of a delimited read. The format's own options are in `format` as a `tape.Dsv_Options`. `budget` sets `depth`,
// `nodes`, `memory` and `steps` (a step is the text or one record). With `runner`, long whole texts run in parallel for
// `validate`, `build`, `unmarshal`, and records; reads in `pieces` run on the calling thread. Under `Budget.memory` a
// build with no runner is made on one thread, and a build with a runner counts the blocks of its parts.
Options :: tape.Options

// Capabilities advertised by every delimited format handle.
CAPS :: tape.Caps{.Rewalk, .Names_Ahead}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Csv   = {name = "csv", id = FIRST_ID + tape.Format_Id(Spec.Csv), facts = FACTS, caps = CAPS, options = .Dsv, dups = .Last, bounds = quotes, decode = decode_csv, number = number_value, same_text = same_csv, key_hash = hash_csv, room = decode_room, close_end = close_csv},
	.Tsv   = {name = "tsv", id = FIRST_ID + tape.Format_Id(Spec.Tsv), facts = FACTS, caps = CAPS, options = .Dsv, dups = .Last, bounds = quotes, decode = decode_tsv, number = number_value, same_text = same_tsv, key_hash = hash_tsv, room = decode_room, close_end = close_tsv},
	.Plain = {name = "plain", id = FIRST_ID + tape.Format_Id(Spec.Plain), facts = FACTS, caps = CAPS, options = .Dsv, dups = .Last, bounds = quotes, decode = decode_plain, number = number_value, same_text = same_plain, key_hash = hash_plain, room = decode_room, close_end = close_plain},
}

// A comment line is a fact of the record after it, or of the root as its foot when it follows the last record.
@(private)
FACTS :: tape.Facts{.Comment, .Comment_Foot}

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// Returns the error in `src`, or nil when `src` is a valid text of `spec`. Allocates only for a walk that counts steps
// past a header of more than `FRAME_KEYS` cells, and for a text in `opts.pieces`, whose state `opts.pieces.allocator`
// holds. An optimized build with a constant `spec` links only that spec's walk.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Csv, opts := Options{}, allocator := context.allocator) -> tape.Error {
	switch spec {
	case .Csv:   return validate_as(src, .Csv, opts, allocator)
	case .Tsv:   return validate_as(src, .Tsv, opts, allocator)
	case .Plain: return validate_as(src, .Plain, opts, allocator)
	}
	runtime.panic_contextless("dsv: spec out of range")
}

// Builds a document of every record in `src` read as `spec`, as a table: each record is an object of its cells, whose
// keys are the header's, stored once, and comment lines become facts. A header that repeats a key gives a record's
// cells of it as `opts.dups` says, and `.Refuse` fails at the repeat. The nodes point into `src`. With `opts.runner` a
// long text is built in parts on its threads, and `allocator` is called on the calling thread only. The document and
// the error are those of a build on one thread. Under `Budget.memory` a build on a runner counts its parts' blocks, so
// it may build a text that a build on one thread refuses, and when it is refused a block the text is built on one
// thread. A text in `opts.pieces` is built on the calling thread, and gives the table so far with `pieces.so_far`.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Csv, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	switch spec {
	case .Csv:   return build_as(src, .Csv, opts, allocator)
	case .Tsv:   return build_as(src, .Tsv, opts, allocator)
	case .Plain: return build_as(src, .Plain, opts, allocator)
	}
	panic("dsv: spec out of range")
}

// The first value `path` reaches in `src`, a text of `spec`, read with no document, or why none was reached. A record
// is `.[i]`, a cell `.[i].name` by its header's key or `.[i][j]` without a header.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Csv, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	switch spec {
	case .Csv:   return find_as(src, path, .Csv, read, opts, allocator)
	case .Tsv:   return find_as(src, path, .Tsv, read, opts, allocator)
	case .Plain: return find_as(src, path, .Plain, read, opts, allocator)
	}
	panic("dsv: spec out of range")
}

// Builds a document of the nodes of `src` that the paths of `demand` reach, read as `spec`, with each path's answers in
// document order, which `tape.answer` gives. A record it keeps holds each cell's key beside it. Records off the paths
// are validated and not stored. With `read.stop_early` the walk ends once no answer can be added or removed, and the
// text past it is not read. Its nodes point into `src`.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Csv, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	switch spec {
	case .Csv:   return scan_as(src, demand, .Csv, read, opts, allocator)
	case .Tsv:   return scan_as(src, demand, .Tsv, read, opts, allocator)
	case .Plain: return scan_as(src, demand, .Plain, read, opts, allocator)
	}
	panic("dsv: spec out of range")
}

@(private)
check_read_opts :: #force_inline proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	if _, refused := pass_options(S, opts); refused != nil {
		return refused
	}
	return refuse_repeat(src, S, opts, allocator)
}

@(private)
validate_as :: #force_no_inline proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	check_read_opts(src, S, opts, allocator) or_return
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && opts.budget.steps == 0 && len(src) >= build.PARALLEL_FROM {
		return validate_parallel(src, S, opts, allocator)
	}
	return validate_walk(src, S, true, opts, allocator) if build.read_lax(opts) else validate_walk(src, S, false, opts, allocator)
}

@(private)
validate_walk :: #force_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	when LAX {
		if opts.pieces != nil {
			return validate_pieces(src, S, opts, allocator)
		}
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, options_resolved(S, opts), h, regs, a, ctx, hook.no_hook, nil, opts.budget.steps)
	}
	return build.read_validate(src, &FORMATS[S], opts, allocator, 0, walk)
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	if e := check_read_opts(src, S, opts, caller); e != nil {
		return {}, e
	}
	if build.read_lax(opts) {
		return find_walk(src, path, S, true, read, opts, caller)
	}
	return find_walk(src, path, S, false, read, opts, caller)
}

@(private)
find_walk :: #force_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return find_pieces(src, path, S, read, opts, caller)
		}
	}
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_record_again((^Pass(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, options_resolved(S, opts), h, regs, a, ctx, build.finder_hook, nil, opts.budget.steps)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, tape.number_respell, rewalk, walk)
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	if e := check_read_opts(src, S, opts, caller); e != nil {
		return {}, e
	}
	if build.read_lax(opts) {
		return scan_walk(src, demand, S, true, read, opts, caller)
	}
	return scan_walk(src, demand, S, false, read, opts, caller)
}

@(private)
scan_walk :: #force_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return scan_pieces(src, demand, S, read, opts, caller)
		}
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, options_resolved(S, opts), h, regs, a, ctx, build.scanner_key_skip_hook, nil, opts.budget.steps)
	}
	return build.read_scan(src, demand, &FORMATS[S], read, opts, caller, nil, node_bound, walk)
}

// The most nodes a delimited text of `src` can make: `3 * len(src)` plus 8 of slack. A cell takes a byte, its delimiter
// or line end, and makes two nodes, itself and its key. A record makes one more for itself.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	return 3 * u64(len(src)) + 8
}

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	if _, refused := pass_options(S, opts); refused != nil {
		return {}, refused
	}
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && len(src) >= build.PARALLEL_FROM {
		return build_parallel(src, S, opts, caller)
	}
	if build.read_lax(opts) {
		return build_walk(src, S, true, opts, caller)
	}
	return build_walk(src, S, false, opts, caller)
}

@(private)
build_walk :: #force_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return build_pieces(src, S, opts, caller)
		}
	}
	walk :: proc "contextless" (src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		context = ctx^
		p := options_resolved(S, opts)
		room: [FRAME_KEYS]tape.Token = ---
		head: Head
		if !p.no_header {
			err: tape.Error
			if head.keys, err = header_keys(header_cells(src, S, p.delim, p.comment), room[:], a, ctx); err != nil {
				return 0, err, false
			}
		}
		defer if len(head.keys) > len(room) {
			delete(head.keys, a)
		}
		root_close, err, tolerated := walk_text(src, S, LAX, p, build.rows_of(h), regs, a, ctx, build.builder_hook_rows, &head, opts.budget.steps)
		if err == nil && len(head.keys) > 0 {
			err = store_header(h, a, head)
		}
		return root_close, repeat_first(err, src, S, p, head.keys, opts, a), tolerated
	}
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, walk, finish_built, BUILD_BYTES_PER_NODE)
}
