package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
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

// Options of a JSON read. `budget` sets `depth`, `nodes`, `memory` and `steps` (a step is one container). JSON has no
// options of its own, so its reads refuse any `format`. With `runner`, long whole texts run in parallel for `validate`,
// `build`, `unmarshal`, and independent-record framings; reads in `pieces` run on the calling thread. Under
// `Budget.memory` a build with no runner is made on one thread, and one with a runner counts the blocks of its parts.
Options :: tape.Options

// Whether a read may walk a value again from its first byte. A test build turns it off to read as a format without
// `.Rewalk`.
@(private)
REWALK :: #config(JSON_REWALK, true)

@(private)
CAPS :: tape.Caps{.Rewalk} when REWALK else tape.Caps{}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Json  = {name = "json", id = tape.FORMAT_ID_JSON, caps = CAPS, dups = .Last, bounds = quotes, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Jsonc = {name = "jsonc", id = tape.FORMAT_ID_JSON + 1, facts = tape.COMMENTS, caps = CAPS, dups = .Last, bounds = quotes, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Json5 = {name = "json5", id = tape.FORMAT_ID_JSON + 2, facts = tape.COMMENTS, caps = CAPS, dups = .Last, bounds = quotes, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
}

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
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
	hook.probe_stack(READ_STACK)
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && opts.format == nil && opts.budget.steps == 0 && len(src) >= build.PARALLEL_FROM {
		return validate_on_threads(src, spec, opts, allocator)
	}
	lax := build.read_lax(opts)
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
// much stack, and `allocator` is called on the calling thread only. The document and the error are those of a build on
// one thread. Under `Budget.memory` a build on a runner counts its parts' blocks, so it may build a text a build on one
// thread is refused, and a block it is refused has the text built on one thread.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Json, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	// A text with foreign options takes the whole-text build, which refuses them.
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && opts.format == nil && len(src) >= build.PARALLEL_FROM {
		return build_on_threads(src, spec, opts, allocator)
	}
	lax := build.read_lax(opts)
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
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
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
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
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
	if e := tape.options_refused(&FORMATS[S], opts); e != nil {
		return 0, e, false
	}
	hook.probe_stack(READ_STACK)
	ctx := context
	if opts.pieces != nil {
		return piece_read(src, S, opts, h, regs, allocator, &ctx, on)
	}
	if opts.budget.steps != 0 {
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
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, hook.no_hook)
	}
	return build.read_validate(src, &FORMATS[S], opts, allocator, WALK_LEVELS, walk)
}

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return build_pieces(src, S, opts, caller)
		}
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		on :: build.builder_hook_facts when S != .Json else build.builder_hook
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
	}
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, walk, build.builder_finish_dups)
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil && build.path_dups(&FORMATS[S], opts) {
			return scan_pieces(src, demand, S, read, opts, caller)
		}
	}
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.scanner_hook)
	}
	return build.read_scan(src, demand, &FORMATS[S], read, opts, caller, rewalk, node_bound, walk)
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	when LAX {
		if opts.pieces != nil && build.path_dups(&FORMATS[S], opts) {
			return find_pieces(src, path, S, read, opts, caller)
		}
	}
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.finder_hook)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, tape.number_respell, rewalk, walk)
}

// The most nodes a JSON text of `src` can make, at most `(len(src) + 1 + depth) / 2`, plus 16 of slack. Each node
// spends two bytes (a container its brackets, a key its colon, a scalar the comma or close after it), except a
// container left open and the token before a fault, which may spend one.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	return (u64(len(src)) + depth) / 2 + 16
}

// Walks `src` and returns the end of its root value or the error, and whether the walk used a rule of
// `opts.tolerate`. Only white space, and comments in a spec that has them, may follow the value.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	p := raw_data(src)
	p = kernel.skip_ws(p[spell.bom_length(src):], p[len(src):])
	r, took := walk_value(src, p, S, LAX, opts.tolerate, build.read_depth(opts), opts.budget.steps, h, regs, allocator, ctx, nil, on)
	at, e, _ := hook.walk_error(r, &RULES)
	return at, e, took
}
