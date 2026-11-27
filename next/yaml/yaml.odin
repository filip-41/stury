package yaml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Public YAML 1.2 entry points: `validate`, `build`, `find`, `scan`, `walk`, and `walk_next`.

@(private)
READ_STACK :: 48 * 1024

@(require_results)
validate :: #force_inline proc(src: []u8, spec := Spec.Yaml_1_2, opts := Options{}, allocator := context.allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Yaml_1_2:   return validate_as(src, .Yaml_1_2, true, opts, allocator) if lax else validate_as(src, .Yaml_1_2, false, opts, allocator)
	case .Yaml_Merge: return validate_as(src, .Yaml_Merge, true, opts, allocator) if lax else validate_as(src, .Yaml_Merge, false, opts, allocator)
	}
	runtime.panic_contextless("yaml: spec out of range")
}

@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Yaml_1_2, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Yaml_1_2:
		if lax { return build_as(src, .Yaml_1_2, true, opts, allocator) }
		return build_as(src, .Yaml_1_2, false, opts, allocator)
	case .Yaml_Merge:
		if lax { return build_as(src, .Yaml_Merge, true, opts, allocator) }
		return build_as(src, .Yaml_Merge, false, opts, allocator)
	}
	panic("yaml: spec out of range")
}

@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Yaml_1_2, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Yaml_1_2:
		if lax { return find_as(src, path, .Yaml_1_2, true, read, opts, allocator) }
		return find_as(src, path, .Yaml_1_2, false, read, opts, allocator)
	case .Yaml_Merge:
		if lax { return find_as(src, path, .Yaml_Merge, true, read, opts, allocator) }
		return find_as(src, path, .Yaml_Merge, false, read, opts, allocator)
	}
	panic("yaml: spec out of range")
}

@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Yaml_1_2, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	hook.probe_stack(READ_STACK)
	lax := build.read_lax(opts)
	switch spec {
	case .Yaml_1_2:
		if lax { return scan_as(src, demand, .Yaml_1_2, true, read, opts, allocator) }
		return scan_as(src, demand, .Yaml_1_2, false, read, opts, allocator)
	case .Yaml_Merge:
		if lax { return scan_as(src, demand, .Yaml_Merge, true, read, opts, allocator) }
		return scan_as(src, demand, .Yaml_Merge, false, read, opts, allocator)
	}
	panic("yaml: spec out of range")
}

walk :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return 0, e, false }
	hook.probe_stack(READ_STACK)
	ctx := context
	if opts.pieces != nil {
		return piece_read(src, S, opts, h, regs, allocator, &ctx, on, allow_empty = true, check_tail = true, allow_complex = true)
	}
	if opts.budget.steps != 0 {
		return walk_text(src, S, true, opts, h, regs, allocator, &ctx, on, 0, allow_empty = true, check_tail = true, allow_complex = true)
	}
	return walk_text(src, S, false, opts, h, regs, allocator, &ctx, on, 0, allow_empty = true, check_tail = true, allow_complex = true)
}

walk_next :: proc(src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (next_lo: u64, err: tape.Error, found: bool) {
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return lo, e, false }
	hook.probe_stack(READ_STACK)
	ctx := context
	end_pos: u64
	if opts.pieces != nil {
		_, err, _ = piece_read(src, S, opts, h, regs, allocator, &ctx, on, allow_empty = true, check_tail = false, allow_complex = true)
		return u64(len(src)), err, err == nil
	}
	if opts.budget.steps != 0 {
		_, err, _ = walk_text(src, S, true, opts, h, regs, allocator, &ctx, on, lo, allow_empty = true, check_tail = false, allow_complex = true, end_pos = &end_pos, found_out = &found)
	} else {
		_, err, _ = walk_text(src, S, false, opts, h, regs, allocator, &ctx, on, lo, allow_empty = true, check_tail = false, allow_complex = true, end_pos = &end_pos, found_out = &found)
	}
	return end_pos, err, found
}

@(private)
validate_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	when LAX { if opts.pieces != nil { return validate_pieces(src, S, opts, allocator) } }
	run :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return validate_stream(src, S, LAX, opts, h, regs, a, ctx)
	}
	return build.read_validate(src, &FORMATS[S], opts, allocator, -1, run)
}

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX { if opts.pieces != nil { return build_pieces(src, S, opts, caller) } }
	run :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, run, build.builder_finish_dups, 4)
}

@(private)
scan_as :: #force_no_inline proc(src: []u8, demand: ^tape.Demand, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX { if opts.pieces != nil && build.path_dups(&FORMATS[S], opts) { return scan_pieces(src, demand, S, read, opts, caller) } }
	run :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	return build.read_scan(src, demand, &FORMATS[S], read, opts, caller, nil, node_bound, run)
}

@(private)
find_as :: #force_no_inline proc(src: []u8, path: []tape.Step, $S: Spec, $LAX: bool, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	when LAX { if opts.pieces != nil && build.path_dups(&FORMATS[S], opts) { return find_pieces(src, path, S, read, opts, caller) } }
	run :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find(src, path, &FORMATS[S], read, opts, caller, respell_number, nil, run)
}

@(private)
respell_number :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	class, _, strict, _, _, _, _ := classify_number_lexical(src[lo:hi])
	#partial switch class {
	case .Inf:     return u16(Number_Spelling.Inf)
	case .Nan:     return u16(Number_Spelling.Nan)
	case .Hex:     return u16(Number_Spelling.Hex)
	case .Octal:   return u16(Number_Spelling.Octal)
	case .Decimal: return u16(Number_Spelling.Plain if strict else Number_Spelling.Decimal)
	}
	return 0
}

@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, _: u64) -> u64 {
	return u64(len(src)) + 16
}
