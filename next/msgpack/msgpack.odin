package msgpack

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Wire-format rules a MessagePack item is read by:
// - `.Msgpack`: standard MessagePack (rejecting never-used `0xc1`, invalid UTF-8 unless `.Invalid_Utf8` tolerated,
//   malformed Timestamp `ext -1`, truncated payloads, trailing bytes, and non-scalar keys).
// - `.Compact`: canonical shortest encoding (shortest integer, binary, string, array, map, ext head,
//   binary64->binary32 narrowing when lossless, and shortest 32/64/96-bit Timestamp encoding).
Spec :: enum u8 {
	Msgpack,
	Compact,
}

Options :: tape.Options

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Msgpack = {
		name      = "msgpack",
		id        = ID,
		facts     = {.Tag},
		caps      = {.Rewalk, .Binary},
		dups      = .Last,
		bounds    = bounds,
		decode    = text_decoded,
		number    = number_value,
		same_text = same_text,
		key_hash  = key_hash,
		room      = decode_room,
		close_end = close_end,
		fact_name = spelled_fact,
	},
	.Compact = {
		name      = "msgpack-compact",
		id        = ID + 1,
		facts     = {.Tag},
		caps      = {.Rewalk, .Binary},
		dups      = .Last,
		bounds    = bounds,
		decode    = text_decoded,
		number    = number_value,
		same_text = same_text,
		key_hash  = key_hash,
		room      = decode_room,
		close_end = close_end,
		fact_name = spelled_fact,
	},
}

// Local Format_Id base for MessagePack specs (leaving ID 15 for HTML alongside YAML's 14..15).
@(private)
ID :: tape.Format_Id(16)

// Returns the `tape.Format` handle of `spec`, or nil when out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// Validates that `src` is a single well-formed MessagePack item under `spec`.
@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Msgpack, opts := Options{}, allocator := context.allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	if spec <= max(Spec) && opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && opts.budget.steps == 0 && len(src) >= build.PARALLEL_FROM && tape.options_refused(&FORMATS[spec], opts) == nil && build.validate_dups(&FORMATS[spec], opts) {
		switch spec {
		case .Msgpack:
			return validate_parallel(src, .Msgpack, opts, allocator)
		case .Compact:
			return validate_parallel(src, .Compact, opts, allocator)
		}
	}
	lax := build.read_lax(opts)
	switch spec {
	case .Msgpack:
		if lax {
			return validate_as(src, .Msgpack, true, opts, allocator)
		}
		return validate_as(src, .Msgpack, false, opts, allocator)
	case .Compact:
		if lax {
			return validate_as(src, .Compact, true, opts, allocator)
		}
		return validate_as(src, .Compact, false, opts, allocator)
	}
	runtime.panic_contextless("msgpack: spec out of range")
}

// Builds a `tape.Document` from the MessagePack item in `src`.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Msgpack, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	if spec <= max(Spec) && opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && len(src) >= build.PARALLEL_FROM && tape.options_refused(&FORMATS[spec], opts) == nil {
		switch spec {
		case .Msgpack:
			return build_parallel(src, .Msgpack, opts, allocator)
		case .Compact:
			return build_parallel(src, .Compact, opts, allocator)
		}
	}
	lax := build.read_lax(opts)
	switch spec {
	case .Msgpack:
		if lax {
			return build_as(src, .Msgpack, true, opts, allocator)
		}
		return build_as(src, .Msgpack, false, opts, allocator)
	case .Compact:
		if lax {
			return build_as(src, .Compact, true, opts, allocator)
		}
		return build_as(src, .Compact, false, opts, allocator)
	}
	panic("msgpack: spec out of range")
}

// Finds the first value reached by `path` in `src` without materializing a full document.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Msgpack, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Msgpack:
		if lax {
			return find_as(src, path, .Msgpack, true, read, opts, allocator)
		}
		return find_as(src, path, .Msgpack, false, read, opts, allocator)
	case .Compact:
		if lax {
			return find_as(src, path, .Compact, true, read, opts, allocator)
		}
		return find_as(src, path, .Compact, false, read, opts, allocator)
	}
	panic("msgpack: spec out of range")
}

// Scans `src` according to `demand` into a partial document containing only demanded paths and their facts.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Msgpack, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Msgpack:
		if lax {
			return scan_as(src, demand, .Msgpack, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Msgpack, false, read, opts, allocator)
	case .Compact:
		if lax {
			return scan_as(src, demand, .Compact, true, read, opts, allocator)
		}
		return scan_as(src, demand, .Compact, false, read, opts, allocator)
	}
	panic("msgpack: spec out of range")
}

// Walks `src` as `S` for hook `h` from initial registers `regs`.
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
	walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, hook.no_hook)
	}
	return build.read_validate(src, &FORMATS[S], opts, allocator, WALK_LEVELS, walk_fn)
}

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return build_pieces(src, S, opts, caller)
		}
	}
	walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, walk_fn, build.builder_finish_dups)
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
	walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.scanner_hook)
	}
	return build.read_scan(src, demand, &FORMATS[S], read, opts, caller, rewalk, node_bound, walk_fn)
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
	walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.finder_hook)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, respell, rewalk, walk_fn)
}
