package toml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// TOML 1.0 and 1.1. A text is one table, its root, whose members the text may write apart: a header or a dotted key
// adds to a table defined earlier, so a read places each member by its path, and a key or a table defined twice is a
// fault of the text.

// The version of the language a text is read as. 1.1 adds forms and removes none, so a text of 1.0 reads alike under
// both. The additions are the `\e` and `\xHH` escapes, optional seconds in a time, and line ends, comments and a
// trailing comma inside an inline table.
Spec :: enum u8 {
	Toml_1_0,
	Toml_1_1,
}

// Options of a TOML read. `budget` sets `depth` (a table a header names counts as nested, as do arrays and inline
// tables), `nodes`, `memory` and `steps` (a step is one container). TOML takes no tolerance, as its grammar has no rule
// a read may break, and no `format` options, which a read refuses. `dups` takes any policy but `.All`, as a text with a
// repeated key is a fault, so no policy has a repeat to keep.
Options :: tape.Options

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Toml_1_0 = {name = "toml", id = ID + tape.Format_Id(Spec.Toml_1_0), facts = FACTS, caps = {.Names_Ahead}, dups = .Last, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end, fact_name = spelled_fact},
	.Toml_1_1 = {name = "toml-1.1", id = ID + tape.Format_Id(Spec.Toml_1_1), facts = FACTS, caps = {.Names_Ahead}, dups = .Last, bounds = bounds, decode = text_decoded, number = number_value, same_text = same_text, key_hash = key_hash, room = decode_room, close_end = close_end, fact_name = spelled_fact},
}

// The facts a TOML text holds: its comments, and in its nodes' spellings a date-time's type and how a value is written,
// which `spelled_fact` names.
@(private)
FACTS :: tape.COMMENTS + {.Tag, .Style}

// The format id of `.Toml_1_0`, the other following it.
@(private)
ID :: tape.FORMAT_ID_TOML

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// Returns the error in `src`, or nil when `src` is one text of `spec`. Reads the text into a tree of its tables in
// `allocator`, which it frees before it returns.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Toml_1_0, opts := Options{}, allocator := context.allocator) -> tape.Error {
	lax := build.read_lax(opts)
	switch spec {
	case .Toml_1_0:
		if lax {
			return validate_as(src, .Toml_1_0, true, opts, allocator)
		}
		return validate_as(src, .Toml_1_0, false, opts, allocator)
	case .Toml_1_1:
		if lax {
			return validate_as(src, .Toml_1_1, true, opts, allocator)
		}
		return validate_as(src, .Toml_1_1, false, opts, allocator)
	}
	runtime.panic_contextless("toml: spec out of range")
}

// Builds a document of `src` read as `spec`: the root table, each table one `Object` whose members are in the order
// the text first names them, wherever the text writes them, and comments as facts. Its nodes point into `src`. A key
// is never repeated, as a repeat is a fault, so `opts.dups` changes nothing.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Toml_1_0, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	lax := build.read_lax(opts)
	switch spec {
	case .Toml_1_0:
		if lax {
			return build_as(src, .Toml_1_0, true, opts, allocator)
		}
		return build_as(src, .Toml_1_0, false, opts, allocator)
	case .Toml_1_1:
		if lax {
			return build_as(src, .Toml_1_1, true, opts, allocator)
		}
		return build_as(src, .Toml_1_1, false, opts, allocator)
	}
	panic("toml: spec out of range")
}

// The first value `path` reaches in `src`, a text of `spec`, read with no document. Under `read.stop_early` the read
// takes statements only as far as its answer needs. A table no brace closes spans to where its last member's value
// ends, an empty one no byte, from where the statement that first names it ends its key: past the header for a table a
// header defines, and at the next key part's first byte for one a header's path or a dotted key passes through.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Toml_1_0, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	lax := build.read_lax(opts)
	switch spec {
	case .Toml_1_0:
		if lax {
			return find_as(src, path, .Toml_1_0, true, read, opts, allocator)
		}
		return find_as(src, path, .Toml_1_0, false, read, opts, allocator)
	case .Toml_1_1:
		if lax {
			return find_as(src, path, .Toml_1_1, true, read, opts, allocator)
		}
		return find_as(src, path, .Toml_1_1, false, read, opts, allocator)
	}
	panic("toml: spec out of range")
}

// Builds a document of the nodes of `src` that the paths of `demand` reach, read as `spec`, with `Demand.facts` the
// comments of its nodes.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Toml_1_0, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	lax := build.read_lax(opts)
	switch spec {
	case .Toml_1_0:
		if lax {
			return scan_as(src, demand, .Toml_1_0, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Toml_1_0, false, read, opts, allocator)
	case .Toml_1_1:
		if lax {
			return scan_as(src, demand, .Toml_1_1, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Toml_1_1, false, read, opts, allocator)
	}
	panic("toml: spec out of range")
}

// Walks `src` as `S` for hook `h` from its registers `regs`, the walk the reads above run. Returns the end of the text
// or the error, and whether the walk used a rule of `opts.tolerate`, which it never does. A stop of the hook is no
// error. The hook keeps the protocol `hook.check` checks, and has no `.Walk`.
walk :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (root_close: u64, err: tape.Error, tolerated: bool) {
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
	// Every text allocates its tree, so the walk is always given the context.
	return build.read_validate(src, &FORMATS[S], opts, allocator, -1, walk)
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
	// The walk sizes the document's room once the text is read, so it starts with the least.
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, walk, build.builder_finish_dups, max(int))
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return scan_pieces(src, demand, S, read, opts, caller)
		}
	}
	// A scan of a whole text holds no bytes, so the walk's order needs no `scattered`, and the walk passes a member no
	// path takes at its key.
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	return spelled_present(build.read_scan(src, demand, &FORMATS[S], read, opts, caller, nil, node_bound, walk))
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return find_pieces(src, path, S, read, opts, caller)
		}
	}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, respell, nil, walk)
}

// The most nodes a text of `src` can make, at most one a byte plus the root and slack: a key and its value take at
// least two bytes, a table a dotted key or a header's path makes takes its key part and the byte after it, and an
// array element takes at least a byte. Its depth bounds no more.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, _: u64) -> u64 {
	return u64(len(src)) + 16
}
