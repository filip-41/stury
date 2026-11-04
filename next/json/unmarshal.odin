package json

import "base:runtime"
import core "../core"
import typed "../core/typed"

// Reads `src`, one document, into `target`. An absent member keeps what `target` holds. See `docs/typed.md`. The form
// with no plan builds and frees one for the call, and a plan built once with `plan_make` is the form for many reads.
// A refusal leaves everything the read allocated reachable from `target`.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Builds the plan of `T` for JSON's spelling, as `typed.plan_make` does.
plan_make :: proc(T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Typed_Error) {
	plan, err := typed.plan_make(T, &SPELLING, opts, allocator)
	plan.marshal = marshal_text
	return plan, err
}

@(private)
unmarshal_once :: proc(src: []u8, $S: Spec, target: ^$T, read := typed.Read_Options{}, opts := Options{}, allocator := context.allocator) -> core.Typed_Error {
	plan, err := plan_make(T, allocator = context.temp_allocator)
	if err.kind != .None {
		return err
	}
	defer typed.plan_destroy(&plan)
	err = unmarshal_plan(src, S, target, &plan, read, opts, allocator)
	typed.own_names(&err)
	typed.own_collected(read.collect)
	return err
}

@(private)
unmarshal_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, opts := Options{}, allocator := context.allocator) -> core.Typed_Error {
	stack: [core.MAX_DEPTH + 2]typed.Frame = ---
	frames := stack[:]
	if need := core.reserve_depth(opts.max_depth, len(src)) + 2; need > len(stack) {
		wide, failed := make([]typed.Frame, need, context.temp_allocator)
		if failed != nil {
			return {kind = .Out_Of_Memory}
		}
		frames = wide
	}
	err: core.Typed_Error
	read_value(src, 0, u64(len(src)), S, target, T, plan, read, opts, frames, allocator, context.temp_allocator, &err, false)
	return err
}

// Reads the document of `src[lo:cut]` into `target` with `frames`, one more than `opts` lets a text open, and stores
// its error in `err`, with every offset from `src`'s first byte. A record's read (`LINE`) walks it in place in `src`
// as `walk_line` does, and `cold` says only a read of `src[:cut]` tells its answer. The error goes out by pointer, as
// copies of it through the record reader's calls cost a record's read more than its tokens. The duplicate check's
// document lives in an arena on `scratch`, freed before the read, and `scratch` is the read's temp allocator.
@(private)
read_value :: proc(src: []u8, lo, cut: u64, $S: Spec, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, opts: Options, frames: []typed.Frame, allocator, scratch: runtime.Allocator, err: ^core.Typed_Error, $LINE: bool) -> (cold: bool) {
	// A BOM past the input's first byte is the read's `Bad_Char`, in a spec where it is no whitespace, and `build` of
	// the text from `lo` would pass over it.
	if read.refuse_duplicates && (lo == 0 || S == .Json5 || core.text_start(src[lo:cut], 0) == 0) {
		arena := runtime.Arena{backing_allocator = scratch, minimum_block_size = 4096}
		defer runtime.arena_destroy(&arena)
		_, built := build_spec(src[lo:cut], S, opts, true, runtime.arena_allocator(&arena))
		if built.kind == .Walk {
			built.inner.at += lo
			err^ = {kind = .Walk, at = built.at + lo, inner = built.inner}
			return
		}
		if built.kind == .Duplicate_Key {
			err^ = {kind = .Duplicate_Key, at = built.at + lo}
			return
		}
		if built.kind != .None {
			err^ = {kind = .Out_Of_Memory}
			return
		}
	}
	h: typed.Reader
	walk_opts := opts
	json_reader(&h, &walk_opts, S)
	text := src if LINE else src[:cut]
	regs, started := typed.read_start(&h, text, plan, &SPELLING, T, target, read, frames, allocator)
	h.ctx.temp_allocator = scratch
	if started.kind != .None {
		err^ = started
		return
	}
	on :: typed.on_token_spelled when S == .Json5 else typed.on_token
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

// Points the typed reader `h` at JSON's walk under `opts`, which a union's tag scan walks with.
@(private)
json_reader :: #force_inline proc(h: ^typed.Reader, opts: ^Options, $S: Spec) {
	h.format = opts
	h.find_tag = proc(h: ^typed.Reader, at: u64) -> typed.Tag_Scan {
		s := typed.Tag_Scan{spelling = &SPELLING, src = h.src, name = h.plan.union_tag}
		_, s.fault = walk(h.src, at, S, (^Options)(h.format)^, &s, nil, typed.on_tag_token)
		return s
	}
}
