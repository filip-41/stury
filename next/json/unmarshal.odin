package json

import core "../core"
import typed "../core/typed"

// Reads `src`, one document, into `target`. An absent member keeps what `target` holds. See `docs/typed.md`. The form
// with no plan builds and frees one for the call, and a plan built once with `plan_make` is the form for many reads.
// A refusal leaves everything the read allocated reachable from `target`.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Builds the plan of `T` for JSON's spelling, as `typed.plan_make` does.
plan_make :: proc(T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (typed.Plan, core.Unmarshal_Error) {
	return typed.plan_make(T, &SPELLING, opts, allocator)
}

@(private)
unmarshal_once :: proc(src: []u8, $S: Spec, target: ^$T, read := typed.Read_Options{}, opts := Options{}, allocator := context.allocator) -> core.Unmarshal_Error {
	plan, err := plan_make(T, allocator = context.temp_allocator)
	if err.kind != .None {
		return err
	}
	defer typed.plan_destroy(&plan)
	return unmarshal_plan(src, S, target, &plan, read, opts, allocator)
}

@(private)
unmarshal_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, opts := Options{}, allocator := context.allocator) -> core.Unmarshal_Error {
	if read.refuse_duplicates {
		doc, built := build(src, S, opts, true, context.temp_allocator)
		if built.kind == .Walk {
			return {kind = .Walk, at = built.at, inner = built.inner}
		}
		if built.kind == .Duplicate_Key {
			return {kind = .Duplicate_Key, at = built.at}
		}
		if built.kind != .None {
			return {kind = .Out_Of_Memory}
		}
		core.destroy(&doc)
	}
	h: typed.Reader
	walk_opts := opts
	h.format = &walk_opts
	h.find_tag = proc(h: ^typed.Reader, at: u64) -> typed.Tag_Scan {
		s := typed.Tag_Scan{spelling = &SPELLING, src = h.src, name = h.plan.union_tag}
		_, s.fault = walk(h.src, at, S, (^Options)(h.format)^, &s, nil, typed.on_tag_token)
		return s
	}
	stack: [core.MAX_DEPTH + 2]typed.Frame = ---
	frames := stack[:]
	if opts.max_depth > core.MAX_DEPTH {
		wide, failed := make([]typed.Frame, int(opts.max_depth) + 2, context.temp_allocator)
		if failed != nil {
			return {kind = .Out_Of_Memory}
		}
		frames = wide
	}
	regs, err := typed.read_start(&h, src, plan, &SPELLING, T, target, read, frames, allocator)
	if err.kind != .None {
		return err
	}
	when S == .Json5 {
		fault := walk_text(src, S, opts, &h, &regs, typed.on_token_spelled)
	} else {
		fault := walk_text(src, S, opts, &h, &regs, typed.on_token)
	}
	return typed.read_end(&h, regs, fault)
}
