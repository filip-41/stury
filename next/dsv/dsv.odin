package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Delimited texts: CSV as RFC 4180, TSV, and the plain spec `Spec` names. A text is an array of records, each an
// object whose keys are the header's cells, or under `Dsv_Options.no_header` an array of cells. A build keeps the
// records as a table, its header stored once.

// The grammar a delimited text follows.
Spec :: enum u8 {
	Csv, // RFC 4180: a cell whose first byte is a quote is quoted, and `""` inside it reads as `"`
	Tsv, // a quote is text, and a backslash escapes `t`, `n`, `r`, `0` or `\\`
	Plain, // no quotes and no escapes: a quote is text, and a cell cannot hold the delimiter, CR or LF
}

// Options of a delimited read, with its own in `format` as a `tape.Dsv_Options`. `budget` sets `depth`, `nodes`,
// `memory` and `steps` (a step is the text or one record).
Options :: tape.Options
Dsv_Options :: tape.Dsv_Options

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Csv   = {name = "csv", id = 4, facts = FACTS, caps = {.Rewalk}, options = .Dsv, dups = .Last, bounds = quotes, decode = decode_csv, number = number_value, same_text = same_csv, key_hash = hash_csv, room = decode_room, close_end = close_csv},
	.Tsv   = {name = "tsv", id = 5, facts = FACTS, caps = {.Rewalk}, options = .Dsv, dups = .Last, bounds = quotes, decode = decode_tsv, number = number_value, same_text = same_tsv, key_hash = hash_tsv, room = decode_room, close_end = close_tsv},
	.Plain = {name = "dsv", id = 6, facts = FACTS, caps = {.Rewalk}, options = .Dsv, dups = .Last, bounds = quotes, decode = decode_plain, number = number_value, same_text = same_plain, key_hash = hash_plain, room = decode_room, close_end = close_plain},
}

// A comment line is a fact of the record after it, or the root's foot past the last.
@(private)
FACTS :: tape.Facts{.Comment, .Comment_Foot}

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

@(private, rodata)
READS := [Spec]tape.Reads {
	.Csv   = {validate = validate_of, build = build_of, find = find_of, scan = scan_of, records = records_of},
	.Tsv   = {validate = validate_of, build = build_of, find = find_of, scan = scan_of, records = records_of},
	.Plain = {validate = validate_of, build = build_of, find = find_of, scan = scan_of, records = records_of},
}

// The reads of `spec`, for a caller that picks the format at run time, to use with the handle `as` returns. Nil for a
// `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return &READS[spec] if spec <= max(Spec) else nil
}

// Returns the error in `src`, or nil when `src` is one text of `spec`. Allocates only for a walk that counts steps
// past a header of more than `FRAME_KEYS` cells. An optimized build with a constant `spec` links only that spec's walk.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Csv, opts := Options{}, allocator := context.allocator) -> tape.Error {
	switch spec {
	case .Csv:
		return validate_as(src, .Csv, opts, allocator)
	case .Tsv:
		return validate_as(src, .Tsv, opts, allocator)
	case .Plain:
		return validate_as(src, .Plain, opts, allocator)
	}
	runtime.panic_contextless("dsv: spec out of range")
}

// Builds a document of every record in `src` read as `spec`, as a table: each record an object of its cells, whose
// keys are the header's, stored once, and comment lines as facts. A header that repeats a key gives a record's cells of
// it as `opts.dups` says, and `.Refuse` fails at the repeat. Its nodes point into `src`. The build runs on the calling thread,
// which is the only one that calls `allocator`, and a text is read whole.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Csv, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	switch spec {
	case .Csv:
		return build_as(src, .Csv, opts, allocator)
	case .Tsv:
		return build_as(src, .Tsv, opts, allocator)
	case .Plain:
		return build_as(src, .Plain, opts, allocator)
	}
	panic("dsv: spec out of range")
}

// The first value `path` reaches in `src`, a text of `spec`, read with no document, or why none was reached. A record
// is `.[i]`, a cell `.[i].name` by its header's key or `.[i][j]` without a header.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Csv, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	switch spec {
	case .Csv:
		return find_as(src, path, .Csv, read, opts, allocator)
	case .Tsv:
		return find_as(src, path, .Tsv, read, opts, allocator)
	case .Plain:
		return find_as(src, path, .Plain, read, opts, allocator)
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
	case .Csv:
		return scan_as(src, demand, .Csv, read, opts, allocator)
	case .Tsv:
		return scan_as(src, demand, .Tsv, read, opts, allocator)
	case .Plain:
		return scan_as(src, demand, .Plain, read, opts, allocator)
	}
	panic("dsv: spec out of range")
}

@(private)
validate_as :: #force_no_inline proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	if _, refused := pass_options(S, opts); refused != nil {
		return refused
	}
	if build.read_lax(opts) {
		return validate_walk(src, S, true, opts, allocator)
	}
	return validate_walk(src, S, false, opts, allocator)
}

@(private)
validate_walk :: #force_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		p, _ := pass_options(S, opts)
		return walk_text(src, S, LAX, p, h, regs, a, ctx, hook.no_hook, nil, opts.budget.steps)
	}
	return build.read_validate(src, &FORMATS[S], opts, allocator, 0, walk)
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	if _, refused := pass_options(S, opts); refused != nil {
		return {}, refused
	}
	if build.read_lax(opts) {
		return find_walk(src, path, S, true, read, opts, caller)
	}
	return find_walk(src, path, S, false, read, opts, caller)
}

@(private)
find_walk :: #force_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_record_again((^Pass(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		p, _ := pass_options(S, opts)
		return walk_text(src, S, LAX, p, h, regs, a, ctx, build.finder_hook, nil, opts.budget.steps)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, respell, rewalk, walk)
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	if _, refused := pass_options(S, opts); refused != nil {
		return {}, refused
	}
	if build.read_lax(opts) {
		return scan_walk(src, demand, S, true, read, opts, caller)
	}
	return scan_walk(src, demand, S, false, read, opts, caller)
}

@(private)
scan_walk :: #force_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		p, _ := pass_options(S, opts)
		return walk_text(src, S, LAX, p, h, regs, a, ctx, build.scanner_columns_hook, nil, opts.budget.steps)
	}
	return build.read_scan(src, demand, &FORMATS[S], read, opts, caller, nil, node_bound, walk)
}

// The most nodes a delimited text of `src` can make, at most `3 * len(src)`, plus 8 of slack. A record spends a byte
// per cell, its delimiter or line end, and makes a node per cell and its key, and one for itself.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	return 3 * u64(len(src)) + 8
}

@(private)
decode_csv :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) {return decode_cell(src, t, buf, .Csv)}
@(private)
decode_tsv :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) {return decode_cell(src, t, buf, .Tsv)}
@(private)
decode_plain :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) {return decode_cell(src, t, buf, .Plain)}
@(private)
same_csv :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {return same_cells(src, t, other, o, .Csv)}
@(private)
same_tsv :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {return same_cells(src, t, other, o, .Tsv)}
@(private)
same_plain :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {return same_cells(src, t, other, o, .Plain)}
@(private)
hash_csv :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {return cell_hash(src, t, .Csv)}
@(private)
hash_tsv :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {return cell_hash(src, t, .Tsv)}
@(private)
hash_plain :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {return cell_hash(src, t, .Plain)}
@(private)
close_csv :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {return close_end(doc, at, .Csv)}
@(private)
close_tsv :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {return close_end(doc, at, .Tsv)}
@(private)
close_plain :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {return close_end(doc, at, .Plain)}

// The byte just past record `at`'s line end, CR LF included, or past its last cell at the text's end. A record kept
// whole ends past its last cell. One a path read kept only part of is read from its first byte to the first line end
// outside a quoted cell. The root ends at `root_close`. False for a record of a `.Held` document, which holds no byte
// between its nodes.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, $S: Spec) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	src := doc.src
	node := doc.nodes[at]
	p: u64
	if node.spelling & tape.CONTAINER_PARTIAL == 0 && node.n > 1 {
		last := doc.nodes[at + tape.Node_Index(node.n) - 1]
		_, tail := quotes(src, last)
		p = last.lo + u64(last.n) + u64(tail)
	} else {
		p = node.lo
		quoted := false
		for p < u64(len(src)) && (quoted || src[p] != '\n' && src[p] != '\r') {
			when S == .Csv {
				quoted ~= src[p] == '"'
			}
			p += 1
		}
	}
	if p < u64(len(src)) && src[p] == '\r' {
		p += 1
	}
	if p < u64(len(src)) && src[p] == '\n' {
		p += 1
	}
	return p, true
}
