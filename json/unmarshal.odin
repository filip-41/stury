package json

import "base:runtime"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import write "../core/write"

// Reads `src`, one document, into `target`. An absent member keeps what `target` holds. See `docs/typed.md`. The form
// with no plan builds one with `context.allocator` and frees it before it returns, and a plan built once with
// `plan_make` is the form for many reads. A refusal leaves everything the read allocated reachable from `target`. A
// repeated key frees the text this read stored for a string member or a map entry, and leaves allocated any other
// value it replaces, a list, map, pointer or `any`, so a text not trusted to be free of repeats reads into an arena.
// A decoded key's text goes to `context.temp_allocator`. `spec` links the walk of that spec alone.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Returns the typed reads of spec `S`, which `plan_make` takes to read and check a plan made from a type by that spec.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return reads_of(S)
}

// Returns the checks of spec `S` read with `opts`, which `model.compile` and `schema.bind` take: the reads of a plan made
// from a model or a description, and the handle of `S` its plans read by, as `as(S, opts)` gives it, which reaches the
// walk of `S` alone.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {checks_of(S), bound_as(S, opts)}
}

// Builds the plan of `T` for spec `spec` read with `opts`, as `typed.plan_make` does. A plan of any spec writes JSON.
// The plan reads only with `reads`, whose reads bind a spec and so the walk of that spec, and with none it reads
// through `unmarshal`, `check` and the handle's `typed.unmarshal_text`.
plan_make :: #force_inline proc(T: typeid, spec := Spec.Json, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_written(T, spec, opts, plan, reads, allocator)
	if err == nil && typed.plan_text_build(&made) == nil && typed.plan_has_value(&made) {
		typed.plan_destroy(&made)
		return {}, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	return made, err
}

// The plan of `plan_make` with no check that its reads build a `core.Value` member, which a write does not need.
@(private)
plan_written :: #force_inline proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Error) {
	made, refusal := typed.plan_build(T, plan_handle(spec, opts), plan, allocator)
	plan_bind(&made, reads)
	// A plan that is built holds no refusal to copy.
	if refusal.kind == .None {
		return made, nil
	}
	return made, core.error_of(refusal)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Json, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, plan_handle(spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made, nil)
	}
	return made, err
}

// The handle a plan holds: the plan's readers, which carry no `close_end` and no services, and the spec and option bytes.
@(private)
plan_handle :: proc "contextless" (spec: Spec, opts: Options) -> core.As {
	return {readers = &PLAN_READERS, max_depth = opts.max_depth, spec = u8(spec), tolerate = opts.tolerate, opts = {0 = u8(opts.refuse_non_finite)}}
}

// Gives a plan JSON's writer, the check of a `Raw` member and the token writer, and the reads `reads` holds.
@(private)
plan_bind :: proc(p: ^typed.Plan, reads: ^typed.Format_Reads) {
	p.marshal, p.raw, p.tokens = marshal_text, raw_check, &TOKENS
	p.value_text = write.value_text
	typed.plan_reads(p, reads)
}

// The spelling's `plans`.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as, opts, allocator)
	p.marshal, p.value_text = marshal_text, write.value_text
	return p, err
}

@(private)
unmarshal_once :: proc(src: []u8, $S: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, S, opts, reads = build_of(S))
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := read_text(src, S, opts, target, T, &plan, read, allocator, false)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(read_text(src, S, opts, target, T, plan, read, allocator, false))
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(read_text(src, S, options_of(plan.as), target, T, plan, read, allocator, true))
}

// Reads a whole text as the constant spec `S`.
@(private)
read_text :: proc(src: []u8, $S: Spec, opts: Options, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, $CHECK: bool) -> core.Typed_Refusal {
	// A text that nests deeper under a raised `max_depth` grows the frames as it goes.
	stack: [core.MAX_DEPTH + 2]typed.Frame = ---
	err: core.Typed_Refusal
	when CHECK {
		mark := typed.sink_mark(read.sink)
	}
	read_value(src, 0, u64(len(src)), S, target, T, plan, read, opts, stack[:], allocator, context.temp_allocator, &err, false, CHECK)
	when CHECK {
		// A check that noticed a repeat reads again, judging the repeats as `read.dups` says.
		if err.kind == .Duplicate_Key && read.repeats == .Notice && read.dups != .Refuse {
			own: typed.Sink
			judged := typed.rejudge(read, mark, untracked(&own), allocator)
			err = {}
			read_value(src, 0, u64(len(src)), S, target, T, plan, judged, opts, stack[:], allocator, context.temp_allocator, &err, false, CHECK)
			if judged.sink == untracked(&own) {
				err = typed.rejudged(untracked(&own), err)
			}
		}
	}
	return err
}

// Puts in `e` the path from the root of the document of `src` to the key that starts at `at`, the innermost
// `MAX_ERROR_STEPS` of it. A name is a slice of `src`, or a decode from `allocator` where the key holds an escape.
@(private)
repeat_path :: proc(src: []u8, $S: Spec, opts: Options, at: u64, e: ^core.Typed_Refusal, allocator: runtime.Allocator) {
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 4096}
	defer runtime.arena_destroy(&arena)
	built, failed := build_spec(src, S, bound_as(S, opts), false, runtime.arena_allocator(&arena))
	if failed.kind != .None {
		return
	}
	doc := &built
	holds :: proc(doc: ^core.Document, i: core.Node_Index, at: u64) -> bool {
		s := core.span(doc, i)
		lo := u64(uintptr(raw_data(s)) - uintptr(raw_data(doc.src)))
		return at >= lo && at < lo + u64(len(s))
	}
	// The innermost steps, the step `n` at `n % MAX_ERROR_STEPS`.
	ring: [core.MAX_ERROR_STEPS]core.Step
	n := 0
	at_node := core.ROOT
	descend: for {
		if doc.nodes[at_node].kind == .Object {
			pairs := core.doc_pairs(doc, at_node)
			for key, val in core.doc_pair_next(&pairs) {
				on_key := holds(doc, key, at)
				if !on_key && !holds(doc, val, at) {
					continue
				}
				name, plain := core.doc_text(doc, key, nil)
				if plain {
					// A key with nothing to decode is a slice of the text, which the document reads in place.
					from := int(uintptr(raw_data(name)) - uintptr(raw_data(doc.src)))
					name = string(src[from:][:len(name)])
				} else {
					name, _ = core.text_clone(doc, key, allocator)
				}
				ring[n % len(ring)], n = core.Name(name), n + 1
				if on_key {
					break descend
				}
				at_node = val
				continue descend
			}
		} else if doc.nodes[at_node].kind == .Array {
			children := core.doc_children(doc, at_node)
			k := 0
			for child in core.doc_child_next(&children) {
				if holds(doc, child, at) {
					ring[n % len(ring)], n = core.Index(k), n + 1
					at_node = child
					continue descend
				}
				k += 1
			}
		}
		break
	}
	kept := min(n, len(ring))
	for i in 0 ..< kept {
		e.steps[i] = ring[(n - kept + i) % len(ring)]
	}
	e.n_steps, e.truncated = u8(kept), n > kept
}

// Reads the document of `src[lo:cut]` into `target` with `frames`, one more than `opts` lets a text open, and stores
// its error in `err`, with every offset from `src`'s first byte. A record's read (`LINE`) walks it in place in `src`
// as `walk_line` does, and `cold` says only a read of `src[:cut]` tells its answer. The error goes out by pointer, as
// copies of it through the record reader's calls cost a record's read more than its tokens. The duplicate check's
// document lives in an arena on `scratch`, freed before the read, and `scratch` is the read's temp allocator.
@(private)
read_value :: proc(src: []u8, lo, cut: u64, $S: Spec, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, opts: Options, frames: []typed.Frame, allocator, scratch: runtime.Allocator, err: ^core.Typed_Refusal, $LINE: bool, $CHECK: bool) -> (cold: bool) {
	if read.dups == .Refuse && !stray_bom(src[lo:cut], lo, S) {
		arena := runtime.Arena{backing_allocator = scratch, minimum_block_size = 4096}
		defer runtime.arena_destroy(&arena)
		_, built := build_spec(src[lo:cut], S, bound_as(S, opts), true, runtime.arena_allocator(&arena))
		core.move_document_error(&built, lo)
		if built.kind == .Walk || built.kind == .Duplicate_Key {
			err^ = {kind = .Walk if built.kind == .Walk else .Duplicate_Key, at = built.at, inner = built.inner}
			if built.kind == .Duplicate_Key {
				repeat_path(src[lo:cut], S, opts, built.at - lo, err, scratch)
			}
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
	started: core.Typed_Refusal
	when CHECK {
		json_reader(&h.reader, untracked(&walk_opts), S)
		regs, started = typed.check_start(&h, text, plan, bound_as(S, opts), T, target, read, untracked_frames(frames), allocator)
	} else {
		json_reader(&h, &walk_opts, S)
		regs, started = typed.read_start(&h, text, plan, bound_as(S, opts), T, target, read, frames, allocator, false)
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

// The plans' `replace`: reads `v`, spelled as JSON, through `h` at `regs`, with the spelling as the source and JSON's
// walk of that text in `h.find_tag`, nesting at most `depth` levels.
@(private)
read_replacement :: proc(h: ^typed.Check, regs: core.Hook_Regs, v: core.Value, depth: u32, $S: Spec) -> (text: []u8, back: core.Hook_Regs, action: core.Action) {
	err: core.Typed_Refusal
	if text, err = write.value_text(h.plan, v, context.temp_allocator); err.kind != .None {
		back, action = typed.refuse(h, regs, {kind = err.kind})
		return
	}
	opts := options_of(h.plan.as)
	opts.max_depth = min(opts.max_depth if opts.max_depth != 0 else core.MAX_DEPTH, depth)
	held, format, find_tag := h.src, h.format, h.find_tag
	json_reader(&h.reader, untracked(&opts), S)
	h.src = text
	on :: typed.on_token_check_spelled when S == .Json5 else typed.on_token_check
	back = regs
	q, _ := document_start(text, 0, S)
	_, fault, stopped := walk_from(text, q, S, opts, h, &back, on)
	h.src, h.format, h.find_tag = held, format, find_tag
	switch f, faulted := fault.?; {
	case faulted:
		// A text the writer spelled faults only past its depth.
		back, action = typed.refuse(h, regs, {kind = .Too_Deep if f.kind == .Too_Deep else .Walk, at = f.at})
	case stopped:
		action = .Stop
	case:
		back, action = regs, .Next
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
	h.find_tag = proc(h: ^typed.Reader, at: u64, name: string) -> typed.Tag_Scan {
		s := typed.Tag_Scan{view = {src = h.src, as = h.plan.as}, name = name}
		_, s.fault = walk(h.src, at, S, (^Options)(h.format)^, &s, nil, typed.on_tag_token)
		return s
	}
}
