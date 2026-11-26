package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/ops/typed"

// Builds a long text on the threads of a `tape.Runner`. No byte of CBOR marks where an item starts, so a chunk of the
// text cannot find an item alone, and the walk of a part needs the frames the walk holds at its seam: the items each
// open container still waits for. The heads of a text do not depend on the items that hold them, so the chunks read
// them at once, each from a start it guesses, as a pass that keeps what it completes in the levels open before it, and
// one pass over the whole text reads only the heads between a chunk's end and the next chunk's guessed start and
// carries its frames over each chunk it reaches (`plan_chunks`). The first item past each cut of the text that is an
// element or a key, and not a tag's content, is a seam. The text between two seams is built by its own walk from the
// frames there, and the parts are joined (`build.segments_join`) into the document that a single walk would build.
//
// In a spec that orders keys a seam also keeps the last key of each open map. A relative pass keeps the spans of the
// last two items it completes in the levels before it, and the last key of the level that takes them is one of those
// two.
//
// A pass reads a head as the walk does and stops at the first head the walk refuses, so when the single walk accepts
// the text up to a seam, the walk from that seam continues it exactly, and the first part in text order whose walk does
// not reach the next seam gives the error the single walk would give. A plan that misreads the text is found by the
// walk of a part, which ends other than the plan has it, and the text is built on one thread. A text that nests past
// `SEAM_LEVELS`, a build under `Budget.steps` and a build that is refused memory are built on one thread. A build under
// `Budget.memory` counts the blocks its parts take, so it may build a text a build on one thread is refused.

@(private)
Validate_Job :: struct {
	src:  []u8,
	plan: ^Part_Plan,
	opts: Options,
}

@(private)
validate_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> tape.Error {
	err, done := validate_parts(src, S, opts, caller)
	if done {
		return err
	}
	one := opts
	one.runner = nil
	return validate_as(src, S, false, one, caller)
}

// Allocates and fills a `Part_Plan` for parallel `validate`, `build`, or `unmarshal` under `m`'s memory budget.
@(private)
plan_parallel :: proc(src: []u8, $S: Spec, want: int, opts: Options, backing: runtime.Allocator, plan: ^Part_Plan, m: ^hook.Memory_Budget) -> (allocator: runtime.Allocator, ok: bool) {
	if want < 2 {
		return {}, false
	}
	allocator = build.read_allocator(m, opts, backing)
	plan^ = {
		parts  = make([dynamic]build.Part, allocator),
		seams  = make([dynamic]Seam, allocator),
		levels = make([dynamic]Level(.Length_First), allocator),
		kinds  = make([dynamic]tape.Kind, allocator),
	}
	if !plan_parts(src, S, want, plan, opts.runner) || len(plan.parts) < 2 {
		destroy_plan(plan)
		return allocator, false
	}
	return allocator, true
}

@(private)
destroy_plan :: proc(plan: ^Part_Plan) {
	delete(plan.parts)
	delete(plan.seams)
	delete(plan.levels)
	delete(plan.kinds)
}

// Validates `src` in parts on the threads of `opts.runner`, returning `done` false to fall back to one thread.
@(private)
validate_parts :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (err: tape.Error, done: bool) {
	m: hook.Memory_Budget
	plan: Part_Plan
	_, ok := plan_parallel(src, S, build.chunk_count(opts.runner, len(src)), opts, caller, &plan, &m)
	if !ok {
		return nil, false
	}
	defer destroy_plan(&plan)
	task :: proc(arg: rawptr, k: int) {
		j := (^Validate_Job)(arg)
		p := &j.plan.parts[k]
		h: hook.No_Hooks
		regs: hook.Regs
		r, took := walk_part(j.src, p.from, p.to, S, j.opts, j.plan, k, &h, &regs, hook.no_hook)
		if k == len(j.plan.parts) - 1 && u8(r) == 0 && u64(r) >> 16 < u64(len(j.src)) {
			r = fault(u64(r) >> 16, .Bad_Char, .Trailing)
		}
		p.close, p.err, _ = hook.walk_error(r, &RULES)
		p.tolerated = took
		if k < len(j.plan.parts) - 1 {
			build.part_cut_short(p)
		}
	}
	vj := Validate_Job{src = src, plan = &plan, opts = opts}
	tape.fan_each(opts.runner, len(plan.parts), task, &vj)
	for p in plan.parts {
		if p.astray {
			return nil, false
		}
		if p.err != nil {
			if _, is_oom := p.err.(runtime.Allocator_Error); is_oom {
				return nil, false
			}
			return p.err, true
		}
	}
	return nil, true
}

@(private)
build_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	doc, err, built := build_parts(src, S, opts, caller)
	if built {
		return doc, err
	}
	one := opts
	one.runner = nil
	if one.budget.steps != 0 {
		return build_as(src, S, true, one, caller)
	}
	return build_as(src, S, false, one, caller)
}

// Builds `src` in parts and returns its document and error, or `built` false for a text built on one thread.
@(private)
build_parts :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error, built: bool) {
	// The walk past `Budget.steps` stops past a container's head, whose length the parts' count cannot give.
	if opts.budget.steps != 0 {
		return {}, nil, false
	}
	m: hook.Memory_Budget
	plan: Part_Plan
	allocator, ok := plan_parallel(src, S, build.chunk_count(opts.runner, len(src)), opts, caller, &plan, &m)
	if !ok {
		return {}, nil, false
	}
	defer destroy_plan(&plan)
	walk :: proc(src: []u8, parts: []build.Part, k: int, s: ^build.Segment, opts: Options, data: rawptr) {
		p := &parts[k]
		r, took := walk_part(src, p.from, p.to, S, opts, (^Part_Plan)(data), k, &s.b, &s.regs, build.builder_hook_facts)
		if k == len(parts) - 1 && u8(r) == 0 && u64(r) >> 16 < u64(len(src)) {
			r = fault(u64(r) >> 16, .Bad_Char, .Trailing)
		}
		p.close, p.err, _ = hook.walk_error(r, &RULES)
		p.tolerated = took
		if k < len(parts) - 1 {
			build.part_cut_short(p)
		}
	}
	return build.parts_build(src, &FORMATS[S], &RULES, plan.parts[:], opts, 0, allocator, caller, walk, nil, &plan)
}

// Walks part `k` of `plan`, the bytes of `src` from `from` to `to`, for hook `h` with its registers `regs`, and
// returns the walk's result and whether it took a rule of the tolerances.
@(private)
walk_part :: proc "contextless" (src: []u8, from, to: int, $S: Spec, opts: Options, plan: ^Part_Plan, k: int, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level(S) = ---
	w: Walk(S, H, false, C)
	walk_init(&w, src[:to], h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.whole = u64(len(src))
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	// The hook holds a level for each container the plan counted in the part, so the walk grows none, and the
	// part nests no deeper than its frame.
	w.depth = min(w.limit, WALK_LEVELS)
	s := plan.seams[k]
	held := ([^]Level(S))(raw_data(plan.levels[s.at:]))
	intrinsics.mem_copy_non_overlapping(w.stack, held, int(s.d) * size_of(Level(S)))
	r := run(&w, u64(from), s.d, s.top, regs, on)
	return r, w.tolerated
}

// Parallel typed unmarshal for root CBOR arrays using `plan_parts` seams aligned to depth 1.
@(private)
unmarshal_parallel :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $REFUSE: bool, read: Unmarshal_Options, opts: Options, caller: runtime.Allocator) -> (tape.Error, bool) {
	if len(src) == 0 || src[0] >> 5 != 4 || (src[0] != 0x9f && src[0] & 31 >= 28) {
		return nil, false
	}
	if !typed.parallel_list_ready(target, T, &FORMATS[S], TAG, opts, read, caller) {
		return nil, false
	}
	// Determine the root array head length (supports both definite and indefinite arrays).
	head_len: u64
	if src[0] == 0x9f {
		head_len = 1
	} else {
		arg, hl, ok := read_head(src, 0, src[0] & 31)
		if !ok || arg == 0 {
			return nil, false
		}
		head_len = hl
	}
	want := min(build.chunk_count(opts.runner, len(src)), typed.MAX_PARALLEL_PARTS)
	m: hook.Memory_Budget
	plan: Part_Plan
	scratch := typed.parallel_scratch_backing(opts, caller)
	if _, pok := plan_parallel(src, S, want, opts, scratch, &plan, &m); !pok {
		return nil, false
	}
	defer destroy_plan(&plan)
	// Collect depth-1 element seams from the plan; advance seams inside an element to the next depth-1 boundary.
	parts: [typed.MAX_PARALLEL_PARTS]typed.Parallel_Part
	last_top: u64
	cur := int(head_len)
	n_parts := 0
	for k in 1 ..< len(plan.parts) {
		s := plan.seams[k]
		pos := u64(plan.parts[k].from)
		top := s.top
		if s.d > 1 {
			// Advance past the rest of the current depth-1 element using a head pass.
			st: Pass(S, false)
			st.i, st.d, st.top = pos, s.d, s.top
			held := ([^]Level(S))(raw_data(plan.levels[s.at:]))
			intrinsics.mem_copy_non_overlapping(&st.stack[0], held, int(s.d) * size_of(Level(S)))
			ok := false
			pos, top, ok = advance_to_depth1(src, S, &st)
			if !ok {
				continue
			}
		}
		if s.d == 0 || top & (FLAG_OBJECT | FLAG_TAG) != 0 {
			continue
		}
		if int(pos) > cur && int(pos) < len(src) && n_parts + 1 < len(parts) {
			parts[n_parts] = {from = cur, to = int(pos)}
			n_parts += 1
			cur = int(pos)
			last_top = top
		}
	}
	if n_parts < 1 || cur >= len(src) {
		return nil, false
	}
	parts[n_parts] = {from = cur, to = len(src)}
	n_parts += 1
	destroy_plan(&plan)
	plan = {}
	H :: typed.Refusing_Reader when REFUSE else typed.Text_Reader
	Typed_Data :: struct {
		src:      []u8,
		opts:     Options,
		n_parts:  int,
		last_top: u64,
	}
	walk_part_typed :: proc(k: int, p: typed.Parallel_Part, hk: ^H, regs: ^hook.Regs, data: rawptr) -> typed.Part_Result {
		d := (^Typed_Data)(data)
		C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
		on :: #force_inline proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
			if t.role == .Tag {
				note_epoch(&h.epoch, h.base, t)
			}
			when REFUSE {
				return typed.refusing_hook(h, s, t, number_in_place)
			} else {
				return typed.text_hook(h, s, t, number_in_place)
			}
		}
		stack: [WALK_LEVELS]Level(S) = ---
		stack[0] = {}
		w: Walk(S, H, false, C)
		walk_init(&w, d.src[:p.to], hk, raw_data(stack[:]), min(build.read_depth(d.opts), MAX_LEVELS), WALK_LEVELS, d.opts)
		w.whole = u64(len(d.src))
		w.depth = min(w.limit, WALK_LEVELS)
		end := k == d.n_parts - 1
		top := d.last_top if end else indefinite_frame(0)
		r := run(&w, u64(p.from), 1, top, regs, on)
		if end && u8(r) == 0 && u64(r) >> 16 < u64(len(d.src)) {
			r = fault(u64(r) >> 16, .Bad_Char, .Trailing)
		}
		_, err, _ := hook.walk_error(r, &RULES)
		if !end {
			if f, is_fault := err.(tape.Fault); is_fault && f.kind == .Truncated && f.at == u64(p.to) {
				err = nil
			} else if err == nil {
				return {astray = true}
			}
		} else if err == nil && (u64(r) >> 16 != u64(p.to) || hk.sp != 1) {
			return {astray = true}
		}
		return {err = err}
	}
	td := Typed_Data{src = src, opts = opts, n_parts = n_parts, last_top = last_top}
	return typed.read_parallel_list(src, target, T, &FORMATS[S], &RULES, TAG, opts, read, caller, parts[:n_parts], H, walk_part_typed, &td)
}

// Advances a CBOR head pass from `st.d > 1` until `st.d == 1` (just after finishing the current root-array element).
@(private)
advance_to_depth1 :: proc(src: []u8, $S: Spec, st: ^Pass(S, false)) -> (pos, top: u64, ok: bool) {
	// Step one item at a time by setting stop = st.i + 1 until `d <= 1`.
	dummy: Part_Plan
	dummy_part: [1]build.Part
	dummy.parts = slice_as_dyn(dummy_part[:])
	dummy.want = 1
	for st.d > 1 && st.i < u64(len(src)) {
		if plan_run(src, S, false, st, st.i + 1, &dummy) != .Stopped {
			return 0, 0, false
		}
	}
	return st.i, st.top, st.d == 1 && st.i < u64(len(src))
}

@(private)
slice_as_dyn :: #force_inline proc "contextless" (s: []build.Part) -> [dynamic]build.Part {
	return transmute([dynamic]build.Part)runtime.Raw_Dynamic_Array{data = raw_data(s), len = len(s), cap = len(s)}
}
