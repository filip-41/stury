package json

import "base:runtime"
import core "../core"
import typed "../core/typed"

// Reads `src`, one document, into `target`. An absent member keeps what `target` holds. See `docs/typed.md`. The form
// with no plan builds one with `context.allocator` and frees it before it returns, and a plan built once with
// `plan_make` is the form for many reads. A refusal leaves everything the read allocated reachable from `target`. A
// repeated key frees the text this read stored for a string member or a map entry, and leaves allocated any other
// value it replaces, a list, map, pointer or `any`, so a text not trusted to be free of repeats reads into an arena.
// A decoded key's text goes to `context.temp_allocator`.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Builds the plan of `T` for spec `spec` read with `opts`, as `typed.plan_make` does. A plan of any spec writes JSON.
plan_make :: proc(T: typeid, spec := Spec.Json, opts := Options{}, plan := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_as(T, as(spec, opts), plan, allocator)
	return made, core.error_of(err)
}

// The spelling's `plans`.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Error) {
	p, err := typed.plan_build(T, as, opts, allocator)
	p.marshal = marshal_text
	return p, err
}

@(private)
unmarshal_once :: proc(src: []u8, spec: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, spec, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := read_text(src, spec, opts, target, T, &plan, read, allocator, false)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_plan :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(read_text(src, spec, opts, target, T, plan, read, allocator, false))
}

// The plan's `read` and `check` of a whole text under the handle `as`.
@(private)
read_text_as :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	return read_text(src, Spec(as.spec), options_of(as), target, T, plan, read, allocator, false)
}

@(private)
check_text_as :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	return read_text(src, Spec(as.spec), options_of(as), target, T, plan, read, allocator, true)
}

@(private)
read_text :: proc(src: []u8, spec: Spec, opts: Options, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, $CHECK: bool) -> core.Typed_Error {
	// A text that nests deeper under a raised `max_depth` grows the frames as it goes.
	stack: [core.MAX_DEPTH + 2]typed.Frame = ---
	frames := stack[:]
	err: core.Typed_Error
	switch spec {
	case .Json:
		read_value(src, 0, u64(len(src)), .Json, target, T, plan, read, opts, frames, allocator, context.temp_allocator, &err, false, CHECK)
		return err
	case .Jsonc:
		read_value(src, 0, u64(len(src)), .Jsonc, target, T, plan, read, opts, frames, allocator, context.temp_allocator, &err, false, CHECK)
		return err
	case .Json5:
		read_value(src, 0, u64(len(src)), .Json5, target, T, plan, read, opts, frames, allocator, context.temp_allocator, &err, false, CHECK)
		return err
	}
	return {kind = .Bad_Option}
}

// Reads the document of `src[lo:cut]` into `target` with `frames`, one more than `opts` lets a text open, and stores
// its error in `err`, with every offset from `src`'s first byte. A record's read (`LINE`) walks it in place in `src`
// as `walk_line` does, and `cold` says only a read of `src[:cut]` tells its answer. The error goes out by pointer, as
// copies of it through the record reader's calls cost a record's read more than its tokens. The duplicate check's
// document lives in an arena on `scratch`, freed before the read, and `scratch` is the read's temp allocator.
@(private)
read_value :: proc(src: []u8, lo, cut: u64, $S: Spec, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, opts: Options, frames: []typed.Frame, allocator, scratch: runtime.Allocator, err: ^core.Typed_Error, $LINE: bool, $CHECK: bool) -> (cold: bool) {
	if read.dups == .Refuse && !stray_bom(src[lo:cut], lo, S) {
		arena := runtime.Arena{backing_allocator = scratch, minimum_block_size = 4096}
		defer runtime.arena_destroy(&arena)
		_, built := build_spec(src[lo:cut], S, opts, true, runtime.arena_allocator(&arena))
		core.move_document_error(&built, lo)
		if built.kind == .Walk || built.kind == .Duplicate_Key {
			err^ = {kind = .Walk if built.kind == .Walk else .Duplicate_Key, at = built.at, inner = built.inner}
			context.allocator = allocator
			typed.sink_refusal(read.sink, err^, CHECK)
			return
		}
		if built.kind != .None {
			err^ = {kind = .No_Memory}
			return
		}
	}
	H :: typed.Check when CHECK else typed.Reader
	h: H
	walk_opts := opts
	text := src if LINE else src[:cut]
	regs: core.Hook_Regs
	started: core.Typed_Error
	when CHECK {
		json_reader(&h.reader, untracked(&walk_opts), S)
		regs, started = typed.check_start(&h, text, plan, &SPELLING, T, target, read, untracked_frames(frames), allocator)
	} else {
		json_reader(&h, &walk_opts, S)
		regs, started = typed.read_start(&h, text, plan, &SPELLING, T, target, read, frames, allocator)
	}
	h.ctx.temp_allocator = scratch
	if started.kind != .None {
		err^ = started
		return
	}
	defer typed.read_release(&h, frames)
	when CHECK {
		on :: typed.on_token_check_spelled when S == .Json5 else typed.on_token_check
	} else {
		on :: typed.on_token_spelled when S == .Json5 else typed.on_token
	}
	fault: Maybe(core.Fault)
	when LINE {
		fault, cold = walk_line(src, lo, cut, S, opts, &h, &regs, on)
	} else {
		fault = walk_text(text, lo, S, opts, &h, &regs, on)
	}
	// `read_end` only reports, so a read with no fault and no refusal leaves `err` as it is.
	if fault != nil || h.first.kind != .None {
		err^ = typed.read_end(&h, regs, fault)
	}
	return
}

// A pointer to what outlives the read that holds it, hidden from the stack escape check, which cannot see through the
// base `Reader` of a `typed.Check` that the pointer stays within the call. Only the `Check` read uses it.
@(private)
untracked :: #force_inline proc "contextless" (p: ^$T) -> ^T {
	return (^T)(uintptr(p))
}

@(private)
untracked_frames :: #force_inline proc "contextless" (f: []typed.Frame) -> []typed.Frame {
	return ([^]typed.Frame)(untracked(raw_data(f)))[:len(f)]
}

// Points the typed reader `h` at JSON's walk under `opts`, which a union's tag scan walks with.
@(private)
json_reader :: #force_inline proc(h: ^typed.Reader, opts: ^Options, $S: Spec) {
	h.format = opts
	h.find_tag = proc(h: ^typed.Reader, at: u64) -> typed.Tag_Scan {
		s := typed.Tag_Scan{view = {src = h.src, as = h.plan.as}, name = h.plan.union_tag}
		_, s.fault = walk(h.src, at, S, (^Options)(h.format)^, &s, nil, typed.on_tag_token)
		return s
	}
}
