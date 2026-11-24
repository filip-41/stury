package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

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
	want := build.chunk_count(opts.runner, len(src))
	if want < 2 {
		return {}, nil, false
	}
	m: hook.Memory_Budget
	allocator := build.read_allocator(&m, opts, caller)
	plan := Plan {
		parts  = make([dynamic]build.Part, allocator),
		seams  = make([dynamic]Seam, allocator),
		levels = make([dynamic]Level(.Length_First), allocator),
		kinds  = make([dynamic]tape.Kind, allocator),
	}
	defer {
		delete(plan.parts)
		delete(plan.seams)
		delete(plan.levels)
		delete(plan.kinds)
	}
	if !plan_parts(src, S, want, &plan, opts.runner) || len(plan.parts) < 2 {
		return {}, nil, false
	}
	walk :: proc(src: []u8, parts: []build.Part, k: int, s: ^build.Segment, opts: Options, data: rawptr) {
		p := &parts[k]
		r, took := walk_part(src, p.from, p.to, S, opts, (^Plan)(data), k, &s.b, &s.regs)
		if k == len(parts) - 1 && u8(r) == 0 && u64(r) >> 16 < u64(len(src)) {
			r = fault(u64(r) >> 16, .Bad_Char, .Trailing)
		}
		p.close, p.err, _ = hook.walk_error(r, &RULES)
		p.tolerated = took
		if k < len(parts) - 1 {
			build.part_cut_short(p)
		}
	}
	return build.parts_build(src, &FORMATS[S], &RULES, plan.parts[:], opts, 0, 0, allocator, caller, walk, nil, &plan)
}

// Walks part `k` of `plan`, the bytes of `src` from `from` to `to`, for builder `h` with its registers `regs`, and
// returns the walk's result and whether it took a rule of the tolerances.
@(private)
walk_part :: proc "contextless" (src: []u8, from, to: int, $S: Spec, opts: Options, plan: ^Plan, k: int, h: ^build.Builder, regs: ^hook.Regs) -> (hook.Walk_Result, bool) {
	stack: [WALK_LEVELS]Level(S) = ---
	w: Walk(S, build.Builder, false, build.BUILDER_CAPS)
	walk_init(&w, src[:to], h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.whole, w.rooms = u64(len(src)), hook.rooms_end(h)
	// The builder holds a level for each container the plan counted in the part, so the walk grows none, and the
	// part nests no deeper than its frame.
	w.depth = min(w.limit, WALK_LEVELS)
	s := plan.seams[k]
	held := ([^]Level(S))(raw_data(plan.levels[s.at:]))
	intrinsics.mem_copy_non_overlapping(w.stack, held, int(s.d) * size_of(Level(S)))
	r := run(&w, u64(from), s.d, s.top, regs, build.builder_hook_facts)
	return r, w.tolerated
}
