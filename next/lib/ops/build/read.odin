package build

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The reads of a whole text, `validate`, `build`, `find` and `scan`, over a format's walk. A format gives each its walk
// as `$walk`, a proc of its own that fixes its spec and walk variant at compile time and walks the text for the read's
// hook, and how many nodes a text of it can make as `$bound`. A read with a runtime spec picks the variant first, which
// `read_lax` decides.

// The open levels a build or scan keeps in its own frame. Past them the builder's stack is allocated from the read's
// allocator.
FRAME_DEPTH :: 1024

// The node capacity a build starts with: one node per this many bytes of the text.
BUILD_BYTES_PER_NODE :: 16

// The node capacity a scan starts with, which holds the answers of a few paths without growth.
SCAN_NODES :: 64

// Whether a read under `opts` needs the walk that counts `Budget.steps` and reads a text in pieces. Every walk takes
// tolerances.
read_lax :: #force_inline proc "contextless" (opts: tape.Options) -> bool {
	return opts.budget.steps != 0 || opts.pieces != nil
}

// Returns the error in `src`, or nil. A text no longer than `frame_levels` cannot nest past the walk's frame, so its
// walk is given no context to grow its levels in.
read_validate :: #force_inline proc(src: []u8, format: ^tape.Format, opts: tape.Options, caller: runtime.Allocator, frame_levels: int, $walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> tape.Error {
	if e := tape.options_refused(format, opts); e != nil {
		return e
	}
	if !validate_dups(format, opts) {
		return tape.Bad_Option{"dups"}
	}
	h: hook.No_Hooks
	regs: hook.Regs
	m: hook.Memory_Budget
	a := read_allocator(&m, opts, caller)
	err: tape.Error
	if len(src) > frame_levels {
		ctx := context
		_, err, _ = walk(src, opts, &h, &regs, a, &ctx)
	} else {
		_, err, _ = walk(src, opts, &h, &regs, a, nil)
	}
	return hook.memory_budget_error(&m, err)
}

// Builds the document of `src`, a text of `format`, which starts with room for a node per `bytes_per_node` bytes. `finish`
// settles the built document and on an error destroys it, as `builder_finish_dups` does for repeated keys.
read_build :: #force_inline proc(src: []u8, format: ^tape.Format, rules: ^tape.Rules, opts: tape.Options, caller: runtime.Allocator, $bound: proc "contextless" (src: []u8, depth: u64) -> u64, $walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^Builder, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool), $finish: proc(doc: ^tape.Document, opts: tape.Options, rules: ^tape.Rules) -> tape.Error, bytes_per_node := BUILD_BYTES_PER_NODE) -> (tape.Document, tape.Error) {
	if e := tape.options_refused(format, opts); e != nil {
		return {}, e
	}
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	depth := min(read_depth(opts), u64(len(src)))
	most := node_most(bound(src, depth), opts)
	frames: [FRAME_DEPTH]u64 = ---
	b: Builder = ---
	builder_start(&b, src, format, len(src) / bytes_per_node, most, frames[:min(depth, FRAME_DEPTH)], allocator, &m if opts.budget.memory != 0 else nil, counts = most)
	if b.err != nil {
		return {}, hook.memory_budget_error(&m, b.err)
	}
	regs := builder_regs(&b)
	root_close, err, tolerated := walk(src, opts, &b, &regs, allocator, &b.ctx)
	doc, e := builder_end(&b, regs, root_close, err, opts.dups == .Refuse, rules)
	if e == nil {
		e = finish(&doc, opts, rules)
	}
	e = read_end(&doc, e, &m, tolerated, caller)
	return doc, e
}

// The `finish` of a format whose objects hold keys: the document's repeated keys as `opts.dups` says.
builder_finish_dups :: proc(doc: ^tape.Document, opts: tape.Options, rules: ^tape.Rules) -> tape.Error {
	return builder_dups(doc, opts.dups, rules)
}

// Builds the document of the nodes of `src`, a text of `format`, that the paths of `demand` reach. `rewalk` walks a
// value again for the scanner.
read_scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, format: ^tape.Format, read: tape.Read_Options, opts: tape.Options, caller: runtime.Allocator, rewalk: Rewalk, $bound: proc "contextless" (src: []u8, depth: u64) -> u64, $walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^Scanner, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> (tape.Document, tape.Error) {
	if e := scan_refused(format, opts, demand); e != nil {
		return {}, e
	}
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	depth := min(read_depth(opts), u64(len(src)))
	most := node_most(bound(src, depth), opts)
	frames: [FRAME_DEPTH]u64 = ---
	room: Scan_Room = ---
	h: Scanner = ---
	if err := #force_inline scanner_start(&h, src, format, demand, opts.dups, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator, budget = &m if opts.budget.memory != 0 else nil); err != nil {
		return {}, hook.memory_budget_error(&m, err)
	}
	regs := builder_regs(&h.b)
	root_close, werr, tolerated := walk(src, opts, &h, &regs, allocator, &h.b.ctx)
	doc, e := #force_inline scanner_end(&h, regs, root_close, werr)
	e = read_end(&doc, e, &m, tolerated, caller)
	return doc, e
}

// The first value `path` reaches in `src`, a text of `format`, read with no document. `respell` gives the spelling of
// a number the walk gave unspelled, and `rewalk` walks a value again for the finder.
read_find :: #force_inline proc(src: []u8, path: []tape.Step, format: ^tape.Format, read: tape.Read_Options, opts: tape.Options, caller: runtime.Allocator, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, rewalk: proc "contextless" (h: ^Finder, lo: u64) -> hook.Walk_Result, $walk: proc "contextless" (src: []u8, opts: tape.Options, h: ^Finder, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> (tape.Span_Answer, tape.Error) {
	steps, refused := find_path(format, opts, path)
	if refused != nil {
		return {}, refused
	}
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	room: Find_Room = ---
	f: Finder
	if err := #force_inline finder_start(&f, src, format, steps, opts.dups, read, respell, rewalk, &room, allocator); err != nil {
		return {}, hook.memory_budget_error(&m, err)
	}
	defer finder_end(&f)
	regs: hook.Regs
	_, werr, tolerated := walk(src, opts, &f, &regs, allocator, &f.ctx)
	answer, err := finder_result(&f, werr, tolerated)
	return answer, hook.memory_budget_error(&m, err)
}

// Why a path read of `format` under `opts` is refused: an option the format refuses, or a repeated keys policy that
// `path_dups` refuses. Nil when it may go on. A document built by hand has no format, which refuses no option.
@(private)
path_read_refused :: #force_inline proc "contextless" (format: ^tape.Format, opts: tape.Options) -> tape.Error {
	if format != nil {
		tape.options_refused(format, opts) or_return
	}
	return nil if path_dups(format, opts) else tape.Bad_Option{"dups"}
}

// Whether a path read of `format` may take the repeated keys policy of `opts`. A path read takes one member of a key, so
// the build-only policies are refused, `.Refuse` unless the format judges it on the names it knows ahead.
path_dups :: #force_inline proc "contextless" (format: ^tape.Format, opts: tape.Options) -> bool {
	return opts.dups != .All && (opts.dups != .Refuse || names_ahead(format))
}

// Whether a validate of `format` may take the repeated keys policy of `opts`. It compares no keys, so `.Refuse` is
// refused unless the format judges it on the names it knows ahead.
validate_dups :: #force_inline proc "contextless" (format: ^tape.Format, opts: tape.Options) -> bool {
	return opts.dups != .Refuse || names_ahead(format)
}

@(private)
names_ahead :: #force_inline proc "contextless" (format: ^tape.Format) -> bool {
	return format != nil && .Names_Ahead in format.caps
}

// The allocator a read under `opts` allocates its blocks from: `allocator` counted through `m` when `Budget.memory` is
// set, else `allocator`.
read_allocator :: #force_inline proc "contextless" (m: ^hook.Memory_Budget, opts: tape.Options, allocator: runtime.Allocator) -> runtime.Allocator {
	if opts.budget.memory == 0 {
		return allocator
	}
	m^ = {backing = allocator, limit = opts.budget.memory}
	return hook.memory_budget(m)
}

// Finishes a build or scan with document `doc` and error `err`, and returns the error as `m` names it. On an error
// `doc` is zeroed. Otherwise `doc` is flagged `.Tolerated` when the text broke a rule its tolerances let it break, and
// its allocator is set to `caller`.
read_end :: #force_inline proc "contextless" (doc: ^tape.Document, err: tape.Error, m: ^hook.Memory_Budget, tolerated: bool, caller: runtime.Allocator) -> tape.Error {
	if err != nil {
		doc^ = {}
		return hook.memory_budget_error(m, err)
	}
	if tolerated {
		doc.flags += {.Tolerated}
	}
	doc.allocator = caller
	return nil
}

// The most nodes a read may make: `bound`, limited by `Budget.nodes`, by the 32-bit node index and by an `int` count of
// node bytes.
node_most :: #force_inline proc "contextless" (bound: u64, opts: tape.Options) -> int {
	budget := u64(opts.budget.nodes) if opts.budget.nodes != 0 else max(u64)
	return int(min(bound, budget, u64(tape.NO_NODE) - 1, u64(max(int) / size_of(tape.Node))))
}

// The levels a read under `opts` may nest, `Budget.depth` or the default.
read_depth :: #force_inline proc "contextless" (opts: tape.Options) -> u64 {
	return u64(opts.budget.depth) if opts.budget.depth != 0 else tape.DEFAULT_DEPTH
}

// One more than the containers a read under `opts` may open within `Budget.steps`, which its walk counts down, and the
// most a `u64` holds for no limit.
read_steps :: #force_inline proc "contextless" (opts: tape.Options) -> u64 {
	return opts.budget.steps + 1 if opts.budget.steps != 0 && opts.budget.steps < max(u64) else max(u64)
}

// What a path read whose answers are all settled, and which reads on to judge the rest of the text, answers token `t`:
// a container is judged with the rest of the text and no more tokens, and any other token passes.
@(private)
read_rest :: #force_inline proc "contextless" (t: tape.Token) -> hook.Action {
	return .Rest if t.role == .Value && (t.kind == .Array || t.kind == .Object) else .Next
}

// The entries a path read's ring keeps for a step reaching `reach` elements back from the end of an array in `src`. An
// element takes at least one byte, so a ring of more entries than the text has bytes holds nothing more. A read with no
// `rewalk` may read a text in pieces, whose length `src` does not bound.
@(private)
ring_entries :: #force_inline proc "contextless" (reach: u64, src: []u8, rewalk: bool) -> u64 {
	return min(reach, u64(len(src))) if rewalk else reach
}
