package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// JSON as RFC 8259, and the other specs `Spec` names.

// The grammar a JSON text follows.
Spec :: enum u8 {
	Json, // RFC 8259
	Jsonc, // JSON with comments and trailing commas
	Json5, // JSON5 1.0.0
}

// Options of a JSON read. `budget` sets `depth`, `nodes`, `memory` and `steps` (a step is one container).
Options :: tape.Options

@(private, rodata)
RULES := tape.Rules{"json", {}}

// Whether a read may walk a value again from its first byte. A test build turns it off to read as a format without
// `.Rewalk`.
@(private)
REWALK :: #config(JSON_REWALK, true)

@(private)
CAPS :: tape.Caps{.Rewalk} when REWALK else tape.Caps{}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Json  = {name = "json", id = 1, caps = CAPS, dups = .Last, bounds = quotes, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Jsonc = {name = "jsonc", id = 2, facts = tape.COMMENTS, caps = CAPS, dups = .Last, bounds = quotes, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Json5 = {name = "json5", id = 3, facts = tape.COMMENTS, caps = CAPS, dups = .Last, bounds = quotes, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
}

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

@(private, rodata)
READS := [Spec]tape.Reads {
	.Json  = {validate = validate_of, build = build_of, find = find_of, scan = scan_of},
	.Jsonc = {validate = validate_of, build = build_of, find = find_of, scan = scan_of},
	.Json5 = {validate = validate_of, build = build_of, find = find_of, scan = scan_of},
}

// The reads of `spec`, for a caller that picks the format at run time, to use with the handle `as` returns. Nil for a
// `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return &READS[spec] if spec <= max(Spec) else nil
}

// The quote bytes around token `t`: 1 on each side of a quoted string, 0 around any other scalar.
@(private)
quotes :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	q := u8(t.kind == .String && t.spelling & tape.SPELLING_QUOTED != 0)
	return q, q
}

// Returns the error in `src`, or nil when `src` is one text of `spec`. Only a text nesting past `WALK_LEVELS`
// allocates, for its open levels. Needs `READ_STACK` bytes of stack and faults on a thread with less. An optimized
// build with a constant `spec` links only that spec's walk.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Json, opts := Options{}, allocator := context.allocator) -> tape.Error {
	probe_stack()
	lax := opts.tolerate != {} || opts.budget.steps != 0 || opts.pieces != nil
	switch spec {
	case .Json:
		if lax {
			return validate_as(src, .Json, true, opts, allocator)
		}
		return validate_as(src, .Json, false, opts, allocator)
	case .Jsonc:
		if lax {
			return validate_as(src, .Jsonc, true, opts, allocator)
		}
		return validate_as(src, .Jsonc, false, opts, allocator)
	case .Json5:
		if lax {
			return validate_as(src, .Json5, true, opts, allocator)
		}
		return validate_as(src, .Json5, false, opts, allocator)
	}
	runtime.panic_contextless("json: spec out of range")
}

// Builds a document of every value in `src` read as `spec`, with keys as written and comments as facts, and the
// members of an object that repeat a key as `opts.dups` says. Its nodes point into `src`. Needs `READ_STACK` bytes of
// stack and faults on a thread with less. With `opts.runner` a long text is built on its threads, which each need as
// much stack, and `allocator` is called on the calling thread only.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Json, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	probe_stack()
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && len(src) >= PARALLEL_FROM {
		return build_on_threads(src, spec, opts, allocator)
	}
	lax := opts.tolerate != {} || opts.budget.steps != 0 || opts.pieces != nil
	switch spec {
	case .Json:
		if lax {
			return build_as(src, .Json, true, opts, allocator)
		}
		return build_as(src, .Json, false, opts, allocator)
	case .Jsonc:
		if lax {
			return build_as(src, .Jsonc, true, opts, allocator)
		}
		return build_as(src, .Jsonc, false, opts, allocator)
	case .Json5:
		if lax {
			return build_as(src, .Json5, true, opts, allocator)
		}
		return build_as(src, .Json5, false, opts, allocator)
	}
	panic("json: spec out of range")
}

// The first value `path` reaches in `src`, a text of `spec`, read with no document, or why none was reached.
// Allocates only for a path longer than `build.FIND_ROOM` steps, or one with negative indexes or slice ends whose
// arrays, open together, hold more than `build.FIND_ROOM` elements (then one entry per element of those arrays). A
// text nesting past `WALK_LEVELS` allocates too. Needs `READ_STACK` bytes of stack and faults on a thread with less.
// An optimized build with a constant `spec` links only that spec's walk.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Json, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	probe_stack()
	lax := opts.tolerate != {} || opts.budget.steps != 0 || opts.pieces != nil
	switch spec {
	case .Json:
		if lax {
			return find_as(src, path, .Json, true, read, opts, allocator)
		}
		return find_as(src, path, .Json, false, read, opts, allocator)
	case .Jsonc:
		if lax {
			return find_as(src, path, .Jsonc, true, read, opts, allocator)
		}
		return find_as(src, path, .Jsonc, false, read, opts, allocator)
	case .Json5:
		if lax {
			return find_as(src, path, .Json5, true, read, opts, allocator)
		}
		return find_as(src, path, .Json5, false, read, opts, allocator)
	}
	panic("json: spec out of range")
}

// Builds a document of the nodes of `src` that the paths of `demand` reach, read as `spec`, with each path's answers in
// document order, which `tape.answer` gives, and with `Demand.facts` the comments of its nodes. A value a path ends at
// is kept as the path's grain says. Containers off the paths are validated and not stored. With `read.stop_early` the
// walk ends once no answer can be added or removed, and the text past it is not read. Its nodes point into `src`.
// Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Json, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	probe_stack()
	lax := opts.tolerate != {} || opts.budget.steps != 0 || opts.pieces != nil
	switch spec {
	case .Json:
		if lax {
			return scan_as(src, demand, .Json, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Json, false, read, opts, allocator)
	case .Jsonc:
		if lax {
			return scan_as(src, demand, .Jsonc, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Jsonc, false, read, opts, allocator)
	case .Json5:
		if lax {
			return scan_as(src, demand, .Json5, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Json5, false, read, opts, allocator)
	}
	panic("json: spec out of range")
}

// Walks `src` as `S` for hook `h` from its registers `regs`, the walk the reads above run. Returns where its root value
// ends or the error, and whether the walk used a rule of `opts.tolerate`. A stop of the hook is no error. The hook
// keeps the protocol `hook.check` checks, and has no `.Walk`, as a replay is the reads' own. Needs `READ_STACK` bytes
// of stack and faults on a thread with less.
walk :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	probe_stack()
	ctx := context
	if opts.pieces != nil {
		return piece_read(src, S, opts, h, regs, allocator, &ctx, on)
	}
	if opts.tolerate != {} || opts.budget.steps != 0 {
		return walk_text(src, S, true, opts, h, regs, allocator, &ctx, on)
	}
	return walk_text(src, S, false, opts, h, regs, allocator, &ctx, on)
}

@(private)
validate_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	when LAX {
		if opts.pieces != nil {
			return validate_pieces(src, S, opts, allocator)
		}
	}
	h: hook.No_Hooks
	regs: hook.Regs
	m: hook.Memory_Budget
	a := read_allocator(&m, opts, allocator)
	err: tape.Error
	// Only a text longer than the frame's levels can nest past them, so only it copies the context its growth runs in.
	if len(src) > WALK_LEVELS {
		ctx := context
		_, err, _ = walk_text(src, S, LAX, opts, &h, &regs, a, &ctx, hook.no_hook)
	} else {
		_, err, _ = walk_text(src, S, LAX, opts, &h, &regs, a, nil, hook.no_hook)
	}
	return hook.memory_budget_error(&m, err)
}

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return build_pieces(src, S, opts, caller)
		}
	}
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	limit := depth_limit(opts)
	depth := min(limit, u64(len(src)))
	most := node_most(node_bound(src, depth), opts)
	frames: [FRAME_DEPTH]u64 = ---
	b: build.Builder = ---
	build.builder_start(&b, src, &FORMATS[S], len(src) / BUILD_BYTES_PER_NODE, most, frames[:min(depth, FRAME_DEPTH)], allocator, &m if opts.budget.memory != 0 else nil)
	if b.err != nil {
		return {}, hook.memory_budget_error(&m, b.err)
	}
	regs := build.builder_regs(&b)
	on :: build.builder_hook_facts when S != .Json else build.builder_hook
	root_close, err, tolerated := walk_text(src, S, LAX, opts, &b, &regs, allocator, &b.ctx, on)
	doc, e := build.builder_end(&b, regs, root_close, err)
	if e == nil {
		e = build.builder_dups(&doc, opts.dups, &RULES)
	}
	e = read_end(&doc, e, &m, tolerated, caller)
	return doc, e
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	if read.dups == .Refuse || read.dups == .All {
		// A path read takes one member of a key, so the build-only policies are refused.
		return {}, tape.Fault{rules = &RULES, kind = .Bad_Option}
	}
	when LAX {
		if opts.pieces != nil {
			return scan_pieces(src, demand, S, read, opts, caller)
		}
	}
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	limit := depth_limit(opts)
	depth := min(limit, u64(len(src)))
	most := node_most(node_bound(src, depth), opts)
	frames: [FRAME_DEPTH]u64 = ---
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	room: build.Scan_Room = ---
	h: build.Scanner = ---
	if err := build.scanner_start(&h, src, &FORMATS[S], demand, read, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator); err != nil {
		return {}, hook.memory_budget_error(&m, err)
	}
	regs := build.builder_regs(&h.b)
	root_close, werr, tolerated := walk_text(src, S, LAX, opts, &h, &regs, allocator, &h.b.ctx, build.scanner_hook)
	doc, e := build.scanner_end(&h, regs, root_close, werr)
	e = read_end(&doc, e, &m, tolerated, caller)
	return doc, e
}

// The allocator a read under `opts` allocates its blocks from: `allocator` counted through `m` when `Budget.memory` is
// set, else `allocator`.
@(private)
read_allocator :: #force_inline proc "contextless" (m: ^hook.Memory_Budget, opts: Options, allocator: runtime.Allocator) -> runtime.Allocator {
	if opts.budget.memory == 0 {
		return allocator
	}
	m^ = {backing = allocator, limit = opts.budget.memory}
	return hook.memory_budget(m)
}

// Finishes a build or scan with document `doc` and error `err`, and returns the error as `m` names it. On an error
// `doc` is zeroed. Otherwise `doc` is flagged `.Tolerated` when the text broke a rule its tolerances let it break, and
// its allocator is set to `caller`.
@(private)
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

// The open levels a build or scan keeps in its own frame. Past them the builder's stack is allocated from the read's
// allocator.
@(private)
FRAME_DEPTH :: 1024

// The node capacity a build starts with: one node per this many bytes of the text.
@(private)
BUILD_BYTES_PER_NODE :: 16

// The node capacity a scan starts with, which holds the answers of a few paths without growth.
@(private)
SCAN_NODES :: 64

// The most nodes a text of `src` can make, at most `(len(src) + 1 + depth) / 2`, plus 16 of slack. Each node spends
// two bytes (a container its brackets, a key its colon, a scalar the comma or close after it), except a container
// left open and the token before a fault, which may spend one.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	return (u64(len(src)) + depth) / 2 + 16
}

// The most nodes a read may make: `bound`, limited by `Budget.nodes`, by the 32-bit node index and by an `int` count of
// node bytes.
@(private)
node_most :: #force_inline proc "contextless" (bound: u64, opts: Options) -> int {
	budget := u64(opts.budget.nodes) if opts.budget.nodes != 0 else max(u64)
	return int(min(bound, budget, u64(tape.NO_NODE) - 1, u64(max(int) / size_of(tape.Node))))
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	if read.dups == .Refuse || read.dups == .All {
		// A path read takes one member of a key, so the build-only policies are refused.
		return {}, tape.Fault{rules = &RULES, kind = .Bad_Option}
	}
	when LAX {
		if opts.pieces != nil {
			return find_pieces(src, path, S, read, opts, caller)
		}
	}
	m: hook.Memory_Budget
	allocator := read_allocator(&m, opts, caller)
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	room: build.Find_Room = ---
	f: build.Finder
	if err := build.finder_start(&f, src, &FORMATS[S], path, read, respell, rewalk, &room, allocator); err != nil {
		return {}, hook.memory_budget_error(&m, err)
	}
	defer build.finder_end(&f)
	regs: hook.Regs
	_, werr, tolerated := walk_text(src, S, LAX, opts, &f, &regs, allocator, &f.ctx, build.finder_hook)
	if werr != nil {
		return {}, hook.memory_budget_error(&m, werr)
	}
	if f.refused {
		return {}, hook.memory_budget_error(&m, runtime.Allocator_Error.Out_Of_Memory)
	}
	answer := build.finder_answer(&f)
	answer.tolerated = tolerated
	return answer, nil
}

@(private)
depth_limit :: #force_inline proc "contextless" (opts: Options) -> u64 {
	return u64(opts.budget.depth) if opts.budget.depth != 0 else tape.DEFAULT_DEPTH
}

// Walks `src` and returns the end of its root value or the error, and whether the walk used a rule of
// `opts.tolerate`. Only white space, and comments in a spec that has them, may follow the value. A walk without `LAX`
// uses no tolerance.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	p := raw_data(src)
	p = kernel.skip_ws(p[bom_length(src):], p[len(src):])
	r, took := walk_value(src, p, S, LAX, opts.tolerate, depth_limit(opts), opts.budget.steps, h, regs, allocator, ctx, nil, on)
	at, e, _ := hook.walk_error(r, &RULES)
	return at, e, took
}

// The length of the UTF-8 byte order mark that starts `src`, 0 for none.
@(private)
bom_length :: #force_inline proc "contextless" (src: []u8) -> int {
	return 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
}
