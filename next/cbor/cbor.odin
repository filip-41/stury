package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// CBOR as RFC 8949, and the stricter specs `Spec` names. A text is one data item. A sequence of items (RFC 8742) is a
// framing of the records, not a spec.

// The rules an item is read by. `.Cbor` reads the well-formed items of RFC 8949 that a document holds: a map's keys
// are integers, text strings or byte strings, and the content of tags 0 to 5 and 24 fits the tag (0 a date-time text,
// 1 a number, 2 and 3 a byte string, 4 and 5 an array of an exponent and a mantissa, 24 a byte string). Another item
// is refused, as is every malformed one. `.Preferred` refuses an item not in preferred serialization (section 4.1): a
// head argument wider than its value needs, a float that a narrower float holds exactly, an indefinite length, and a
// bignum that fits an integer or starts with a zero byte. `.Deterministic` adds the sorted keys of section 4.2.1, with
// no key repeated and no NaN but `f97e00`, and `.Length_First` sorts the keys by length first, as section 4.2.3 does.
Spec :: enum u8 {
	Cbor,
	Preferred,
	Deterministic,
	Length_First,
}

// Options of a CBOR read. `budget` sets `depth` (a tag counts as a level), `nodes`, `memory` and `steps` (a step is one
// container). Only `.Invalid_Utf8` of `tolerate` has an effect. `format` takes no options and refuses any family's.
// `runner` is for `build` alone, which builds a long text in parts on its threads:
// every other read ignores it, as does a build of a text in `pieces`. Under `Budget.memory` a build with no runner is
// made on one thread, and one with a runner counts the blocks of its parts.
Options :: tape.Options

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Cbor          = {name = "cbor", id = ID, facts = {.Tag}, caps = {.Rewalk, .Binary}, dups = .Last, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Preferred     = {name = "cbor-preferred", id = ID + 1, facts = {.Tag}, caps = {.Rewalk, .Binary}, dups = .Last, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Deterministic = {name = "cbor-deterministic", id = ID + 2, facts = {.Tag}, caps = {.Rewalk, .Binary}, dups = .Last, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
	.Length_First  = {name = "cbor-length-first", id = ID + 3, facts = {.Tag}, caps = {.Rewalk, .Binary}, dups = .Last, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end},
}

// The format id of `.Cbor`, the others following it in `Spec` order.
@(private)
ID :: tape.Format_Id(7)

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// Returns the error in `src`, or nil when `src` is one item of `spec`. Allocates only for an item nesting past 1024
// levels, for its open levels, or for the state of `opts.pieces`. A text of more than one item is refused: read a
// sequence with `records_open`. Needs `READ_STACK` bytes of stack and faults on a thread with less. An optimized build
// with a constant `spec` links only that spec's walk.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Cbor, opts := Options{}, allocator := context.allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && opts.budget.steps == 0 && len(src) >= build.PARALLEL_FROM && tape.options_refused(&FORMATS[spec], opts) == nil && build.validate_dups(&FORMATS[spec], opts) {
		switch spec {
		case .Cbor:
			return validate_parallel(src, .Cbor, opts, allocator)
		case .Preferred:
			return validate_parallel(src, .Preferred, opts, allocator)
		case .Deterministic:
			return validate_parallel(src, .Deterministic, opts, allocator)
		case .Length_First:
			return validate_parallel(src, .Length_First, opts, allocator)
		}
	}
	lax := build.read_lax(opts)
	switch spec {
	case .Cbor:
		if lax {
			return validate_as(src, .Cbor, true, opts, allocator)
		}
		return validate_as(src, .Cbor, false, opts, allocator)
	case .Preferred:
		if lax {
			return validate_as(src, .Preferred, true, opts, allocator)
		}
		return validate_as(src, .Preferred, false, opts, allocator)
	case .Deterministic:
		if lax {
			return validate_as(src, .Deterministic, true, opts, allocator)
		}
		return validate_as(src, .Deterministic, false, opts, allocator)
	case .Length_First:
		if lax {
			return validate_as(src, .Length_First, true, opts, allocator)
		}
		return validate_as(src, .Length_First, false, opts, allocator)
	}
	runtime.panic_contextless("cbor: spec out of range")
}

// Builds a document of every item in `src` read as `spec`, with keys as written and tags as facts, and the members of
// a map that repeat a key as `opts.dups` says. Its nodes point into `src`. An integer key reads as its decimal digits
// and a byte string key as the base64 of its payload, and a key keeps its kind, so `1` and `"1"` are two keys. A number
// node reads as a `spell.Number` and its text is its value in decimal, a bignum with every digit and a decimal
// fraction or bigfloat as `<digits>e<exponent>`, and none past `BIGNUM_BYTES_MAX` payload bytes or an exponent past
// `EXPONENT_MAX`. With `opts.runner` a long text is built on its threads, and `allocator` is called on the calling
// thread only. The document and the error are those of a build on one thread. Under `Budget.memory` a build on a runner
// counts its parts' blocks, so it may build a text a build on one thread is refused, and a block it is refused has the
// text built on one thread. Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Cbor, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	// A text with foreign options takes the whole-text build, which refuses them.
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && len(src) >= build.PARALLEL_FROM && tape.options_refused(&FORMATS[spec], opts) == nil {
		switch spec {
		case .Cbor:
			return build_parallel(src, .Cbor, opts, allocator)
		case .Preferred:
			return build_parallel(src, .Preferred, opts, allocator)
		case .Deterministic:
			return build_parallel(src, .Deterministic, opts, allocator)
		case .Length_First:
			return build_parallel(src, .Length_First, opts, allocator)
		}
	}
	lax := build.read_lax(opts)
	switch spec {
	case .Cbor:
		if lax {
			return build_as(src, .Cbor, true, opts, allocator)
		}
		return build_as(src, .Cbor, false, opts, allocator)
	case .Preferred:
		if lax {
			return build_as(src, .Preferred, true, opts, allocator)
		}
		return build_as(src, .Preferred, false, opts, allocator)
	case .Deterministic:
		if lax {
			return build_as(src, .Deterministic, true, opts, allocator)
		}
		return build_as(src, .Deterministic, false, opts, allocator)
	case .Length_First:
		if lax {
			return build_as(src, .Length_First, true, opts, allocator)
		}
		return build_as(src, .Length_First, false, opts, allocator)
	}
	panic("cbor: spec out of range")
}

// The first value `path` reaches in `src`, an item of `spec`, read with no document, or why none was reached. Allocates
// only for levels past 1024 and, in pieces, for the answer's open path. Needs `READ_STACK` bytes of stack and faults on
// a thread with less.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Cbor, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Cbor:
		if lax {
			return find_as(src, path, .Cbor, true, read, opts, allocator)
		}
		return find_as(src, path, .Cbor, false, read, opts, allocator)
	case .Preferred:
		if lax {
			return find_as(src, path, .Preferred, true, read, opts, allocator)
		}
		return find_as(src, path, .Preferred, false, read, opts, allocator)
	case .Deterministic:
		if lax {
			return find_as(src, path, .Deterministic, true, read, opts, allocator)
		}
		return find_as(src, path, .Deterministic, false, read, opts, allocator)
	case .Length_First:
		if lax {
			return find_as(src, path, .Length_First, true, read, opts, allocator)
		}
		return find_as(src, path, .Length_First, false, read, opts, allocator)
	}
	panic("cbor: spec out of range")
}

// Builds a document of the nodes of `src` that the paths of `demand` reach, read as `spec`, with `Demand.facts` the
// tags of its nodes. `opts.runner` has no effect on it. Needs `READ_STACK` bytes of stack and faults on a thread with
// less.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Cbor, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Cbor:
		if lax {
			return scan_as(src, demand, .Cbor, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Cbor, false, read, opts, allocator)
	case .Preferred:
		if lax {
			return scan_as(src, demand, .Preferred, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Preferred, false, read, opts, allocator)
	case .Deterministic:
		if lax {
			return scan_as(src, demand, .Deterministic, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Deterministic, false, read, opts, allocator)
	case .Length_First:
		if lax {
			return scan_as(src, demand, .Length_First, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Length_First, false, read, opts, allocator)
	}
	panic("cbor: spec out of range")
}

// Walks `src` as `S` for hook `h` from its registers `regs`, the walk the reads above run. Returns where its item ends
// or the error, and whether the walk used a rule of `opts.tolerate`. A stop of the hook is no error. The hook keeps the
// protocol `hook.check` checks, and has no `.Walk`, as a replay is the reads' own. Needs `READ_STACK` bytes of stack
// and faults on a thread with less.
walk :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.probe_stack(READ_STACK)
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	if e := tape.options_refused(&FORMATS[S], opts); e != nil {
		return 0, e, false
	}
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
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.builder_hook_facts)
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
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, respell, rewalk, walk)
}
