package build

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Shared cold planning, parallel validate/build, piece-window finish, and record-framing drivers for binary formats
// (CBOR and MessagePack).

// Where a binary parallel part starts: `d` walk levels from `Binary_Plan.levels[at:]` and innermost frame `top`.
Binary_Seam :: struct {
	d, top: u64,
	at:     int,
}

// Planned parallel parts of a binary text, where each starts, and the container kinds open at each seam.
Binary_Plan :: struct($Level: typeid) {
	want:   int,
	parts:  [dynamic]Part,
	seams:  [dynamic]Binary_Seam,
	levels: [dynamic]Level,
	kinds:  [dynamic]tape.Kind,
}

// Outcome of a binary header pass: reached its stop, ended at an item boundary/refusal, or failed (OOM / nest limit).
Binary_Pass_End :: enum u8 {
	Stopped,
	Ended,
	Failed,
}

// Releases the arrays held by `plan`.
binary_plan_destroy :: proc(plan: ^Binary_Plan($Level)) {
	delete(plan.parts)
	delete(plan.seams)
	delete(plan.levels)
	delete(plan.kinds)
}

// Initializes `plan`'s arrays under `opts`'s memory budget and runs `plan_parts` to split `src` into at most `want` parts.
binary_plan_parallel :: proc(
	src: []u8,
	want: int,
	opts: tape.Options,
	backing: runtime.Allocator,
	plan: ^Binary_Plan($Level),
	m: ^hook.Memory_Budget,
	$plan_parts_fn: proc(src: []u8, want: int, plan: ^Binary_Plan(Level), runner: ^tape.Runner) -> bool,
) -> (allocator: runtime.Allocator, ok: bool) {
	if want < 2 {
		return {}, false
	}
	allocator = read_allocator(m, opts, backing)
	plan^ = {
		parts  = make([dynamic]Part, allocator),
		seams  = make([dynamic]Binary_Seam, allocator),
		levels = make([dynamic]Level, allocator),
		kinds  = make([dynamic]tape.Kind, allocator),
	}
	if !plan_parts_fn(src, want, plan, opts.runner) || len(plan.parts) < 2 {
		binary_plan_destroy(plan)
		return allocator, false
	}
	return allocator, true
}

// Runs parallel relative header passes over `want` chunks of `src`, then reconciles seams with one absolute pass.
binary_plan_chunks :: proc(
	src: []u8,
	want: int,
	plan: ^Binary_Plan($Level),
	runner: ^tape.Runner,
	$Rel_Pass: typeid,
	$Abs_Pass: typeid,
	$start_rel: proc "contextless" (st: ^Rel_Pass, i: u64),
	$start_abs: proc "contextless" (st: ^Abs_Pass, i: u64),
	$guess: proc(src: []u8, st: ^Rel_Pass, cut, stop: u64) -> u64,
	$run_rel: proc(src: []u8, st: ^Rel_Pass, stop: u64) -> Binary_Pass_End,
	$run_abs: proc(src: []u8, st: ^Abs_Pass, stop: u64, plan: ^Binary_Plan(Level)) -> Binary_Pass_End,
	$carry: proc(plan: ^Binary_Plan(Level), st: ^Abs_Pass, sm: ^Rel_Pass) -> (bool, bool),
) -> bool {
	Job :: struct {
		src:    []u8,
		want:   int,
		sums:   []Rel_Pass,
		starts: []u64,
		ends:   []Binary_Pass_End,
	}
	n := len(src)
	allocator := plan.parts.allocator
	sums, serr := make([]Rel_Pass, want, allocator)
	starts, terr := make([]u64, want, allocator)
	ends, eerr := make([]Binary_Pass_End, want, allocator)
	defer {
		delete(sums, allocator)
		delete(starts, allocator)
		delete(ends, allocator)
	}
	if serr != nil || terr != nil || eerr != nil {
		return false
	}
	job := Job{src = src, want = want, sums = sums, starts = starts, ends = ends}
	read_chunk :: proc(arg: rawptr, k: int) {
		j := (^Job)(arg)
		cut := u64(len(j.src) / j.want * k)
		stop := u64(len(j.src) / j.want * (k + 1)) if k + 1 < j.want else u64(len(j.src))
		sm := &j.sums[k]
		if k > 0 {
			j.starts[k] = guess(j.src, sm, cut, stop)
			if j.starts[k] == 0 {
				return
			}
		}
		start_rel(sm, j.starts[k])
		j.ends[k] = run_rel(j.src, sm, stop)
	}
	tape.fan_each(runner, want, read_chunk, &job)
	st: Abs_Pass = ---
	start_abs(&st, 0)
	chunks: for k := 0; k < want; k += 1 {
		if k == 0 || starts[k] != 0 {
			if st.i < starts[k] {
				switch run_abs(src, &st, starts[k], plan) {
				case .Failed:
					return false
				case .Ended:
					break chunks
				case .Stopped:
				}
			}
			if st.i == starts[k] {
				if ends[k] == .Failed {
					return false
				}
				ok, ended := carry(plan, &st, &sums[k])
				if !ok {
					return false
				}
				if ended || ends[k] == .Ended {
					break chunks
				}
				continue
			}
		}
		stop := u64(n / want * (k + 1)) if k + 1 < want else u64(n)
		if st.i < stop {
			switch run_abs(src, &st, stop, plan) {
			case .Failed:
				return false
			case .Ended:
				break chunks
			case .Stopped:
			}
		}
	}
	return true
}

// Plans up to `want` parts of `src` into `plan` via `chunks_fn`, then closes the last part and computes open counts.
binary_plan_parts :: proc(
	src: []u8,
	want: int,
	plan: ^Binary_Plan($Level),
	runner: ^tape.Runner,
	$chunks_fn: proc(src: []u8, want: int, plan: ^Binary_Plan(Level), runner: ^tape.Runner) -> bool,
) -> bool {
	plan.want = want
	if _, e := append(&plan.parts, Part{}); e != nil {
		return false
	}
	if _, e := append(&plan.seams, Binary_Seam{}); e != nil {
		return false
	}
	if !chunks_fn(src, want, plan, runner) {
		return false
	}
	plan.parts[len(plan.parts) - 1].to = len(src)
	parts_opens(plan.parts[:], plan.kinds[:])
	return true
}

// Appends a seam at byte `i` with open levels `stack` and innermost frame `top` into `plan`.
binary_plan_seam :: proc(
	plan: ^Binary_Plan($Store_Level),
	i, top: u64,
	c: int,
	stack: []$Level,
	$FLAG_OBJECT: u64,
	$FLAG_TAG: u64,
) -> bool {
	at := len(plan.levels)
	if resize(&plan.levels, at + len(stack)) != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(&plan.levels[at], raw_data(stack), len(stack) * size_of(Level))
	kinds := len(plan.kinds)
	for m in 1 ..= len(stack) {
		frame := stack[m].frame if m < len(stack) else top
		when FLAG_TAG != 0 {
			if frame & FLAG_TAG != 0 {
				continue
			}
		}
		if _, e := append(&plan.kinds, tape.Kind.Object if frame & FLAG_OBJECT != 0 else .Array); e != nil {
			return false
		}
	}
	if _, e := append(&plan.seams, Binary_Seam{d = u64(len(stack)), top = top, at = at}); e != nil {
		return false
	}
	_, e := append(&plan.parts, Part{from = int(i), opens_at = kinds, opens_n = len(plan.kinds) - kinds, levels = c})
	return e == nil
}

// Validates `src` in parallel over `plan_fn`'s parts, returning `done = false` to fall back to one thread.
binary_validate_parts :: proc(
	src: []u8,
	opts: tape.Options,
	rules: ^tape.Rules,
	caller: runtime.Allocator,
	$Level: typeid,
	$plan_fn: proc(src: []u8, want: int, opts: tape.Options, backing: runtime.Allocator, plan: ^Binary_Plan(Level), m: ^hook.Memory_Budget) -> (runtime.Allocator, bool),
	$walk_fn: proc "contextless" (src: []u8, from, to: int, opts: tape.Options, plan: ^Binary_Plan(Level), k: int, h: ^hook.No_Hooks, regs: ^hook.Regs) -> (hook.Walk_Result, bool),
	$trailing_detail: u8,
) -> (err: tape.Error, done: bool) {
	Job :: struct {
		src:   []u8,
		plan:  ^Binary_Plan(Level),
		opts:  tape.Options,
		rules: ^tape.Rules,
	}
	m: hook.Memory_Budget
	plan: Binary_Plan(Level)
	_, ok := plan_fn(src, chunk_count(opts.runner, len(src)), opts, caller, &plan, &m)
	if !ok {
		return nil, false
	}
	defer binary_plan_destroy(&plan)
	task :: proc(arg: rawptr, k: int) {
		j := (^Job)(arg)
		p := &j.plan.parts[k]
		h: hook.No_Hooks
		regs: hook.Regs
		r, took := walk_fn(j.src, p.from, p.to, j.opts, j.plan, k, &h, &regs)
		if k == len(j.plan.parts) - 1 && u8(r) == 0 && u64(r) >> 16 < u64(len(j.src)) {
			r = hook.walk_result(u64(r) >> 16, u8(tape.Fault_Kind.Bad_Char), trailing_detail)
		}
		p.close, p.err, _ = hook.walk_error(r, j.rules)
		p.tolerated = took
		if k < len(j.plan.parts) - 1 {
			part_cut_short(p)
		}
	}
	vj := Job{src = src, plan = &plan, opts = opts, rules = rules}
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

// Builds `src` in parallel over `plan_fn`'s parts, returning `built = false` to fall back to one thread.
binary_build_parts :: proc(
	src: []u8,
	f: ^tape.Format,
	rules: ^tape.Rules,
	opts: tape.Options,
	caller: runtime.Allocator,
	$Level: typeid,
	$plan_fn: proc(src: []u8, want: int, opts: tape.Options, backing: runtime.Allocator, plan: ^Binary_Plan(Level), m: ^hook.Memory_Budget) -> (runtime.Allocator, bool),
	$walk_fn: proc "contextless" (src: []u8, from, to: int, opts: tape.Options, plan: ^Binary_Plan(Level), k: int, h: ^Builder, regs: ^hook.Regs) -> (hook.Walk_Result, bool),
	$trailing_detail: u8,
) -> (doc: tape.Document, err: tape.Error, built: bool) {
	if opts.budget.steps != 0 {
		return {}, nil, false
	}
	m: hook.Memory_Budget
	plan: Binary_Plan(Level)
	allocator, ok := plan_fn(src, chunk_count(opts.runner, len(src)), opts, caller, &plan, &m)
	if !ok {
		return {}, nil, false
	}
	defer binary_plan_destroy(&plan)
	Ctx :: struct {
		plan:  ^Binary_Plan(Level),
		rules: ^tape.Rules,
	}
	part_walk :: proc(src: []u8, parts: []Part, k: int, s: ^Segment, opts: tape.Options, data: rawptr) {
		c := (^Ctx)(data)
		p := &parts[k]
		r, took := walk_fn(src, p.from, p.to, opts, c.plan, k, &s.b, &s.regs)
		if k == len(parts) - 1 && u8(r) == 0 && u64(r) >> 16 < u64(len(src)) {
			r = hook.walk_result(u64(r) >> 16, u8(tape.Fault_Kind.Bad_Char), trailing_detail)
		}
		p.close, p.err, _ = hook.walk_error(r, c.rules)
		p.tolerated = took
		if k < len(parts) - 1 {
			part_cut_short(p)
		}
	}
	ctx := Ctx{plan = &plan, rules = rules}
	return parts_build(src, f, rules, plan.parts[:], opts, 0, allocator, caller, part_walk, nil, &ctx)
}

// Finishes a binary piece-window walk: prunes settled claims, applies count-too-large and trailing-byte checks,
// and updates `p` for the next window or returns the final result.
binary_piece_finish :: proc(
	p: ^tape.Pieces,
	s: ^$P,
	text: []u8,
	to: u64,
	r: hook.Walk_Result,
	regs: ^hook.Regs,
	f: ^tape.Format,
	rules: ^tape.Rules,
	count_too_large_detail, trailing_detail: u8,
	$keep_fn: proc "contextless" (s: ^P, to: u64) -> u64,
) -> (root_close: u64, err: tape.Error, took: bool) {
	r := r
	if s.refused {
		r = hook.walk_result(to, hook.WALK_NO_MEMORY)
	}
	hook.piece_claims_prune(&s.claims, to)
	if len(s.claims) > 0 {
		if !s.more {
			r = hook.walk_result(s.claims[0][0], u8(tape.Fault_Kind.Truncated), count_too_large_detail)
		} else if u8(r) != hook.WALK_MORE {
			s.holding, s.held, r = true, u64(r), hook.walk_result(to, hook.WALK_MORE)
		}
	} else if s.holding {
		s.holding = false
	}
	if u8(r) == 0 && !s.holding {
		if end := u64(r) >> 16; end < to {
			r = hook.walk_result(end, u8(tape.Fault_Kind.Bad_Char), trailing_detail)
		} else if s.more {
			s.ended, s.cut.i, r = true, end, hook.walk_result(to, hook.WALK_MORE)
		}
	}
	took = s.tolerated
	if u8(r) == hook.WALK_MORE {
		s.regs = regs^
		p.more, p.at, p.keep = true, to, keep_fn(s, to)
		if e := hook.piece_path(p, text, f); e != nil {
			return 0, e, took
		}
		return 0, nil, took
	}
	p.more, p.open = false, nil
	root_close, err, _ = hook.walk_error(r, rules)
	return root_close, err, took
}

// Common validation and initialization for binary `records_open` (CBOR / MessagePack).
binary_records_init :: proc(
	r: ^tape.Records,
	frame: ^Frame($L),
	src: []u8,
	framing: tape.Framing,
	f: ^tape.Format,
	opts: tape.Options,
	path: []tape.Step,
	release: proc(r: ^tape.Records),
) {
	r.src, r.framing, r.opts = src, framing, opts
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	r.path = path
	if err := tape.options_refused(f, opts); err != nil {
		r.err, r.at = err, .Done
	} else if err = records_path_refused(f, framing, path, opts); err != nil {
		r.err, r.at = err, .Done
	} else if framing == .Lines || framing == .Seq {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	} else if e := frame_init(frame, path); e != nil {
		r.err, r.at = e, .Done
	}
	r.release = release
}

// Common `item_refused` verdict for binary record framing (checks window-more truncation and passed container claims).
@(cold)
binary_item_refused :: proc "contextless" (
	r: ^tape.Records,
	frame: ^Frame($L),
	res: hook.Walk_Result,
	rules: ^tape.Rules,
	count_too_large_detail: u8,
) -> Frame_Step {
	more := r.opts.pieces != nil && !r.opts.pieces.last
	if more && u8(res) == u8(tape.Fault_Kind.Truncated) {
		return .Wait
	}
	res := res
	for k in 0 ..< frame.depth {
		if lv := frame_level(frame, k); lv.need > u64(len(r.src)) {
			if more {
				return .Wait
			}
			res = hook.walk_result(lv.head, u8(tape.Fault_Kind.Truncated), count_too_large_detail)
			break
		}
	}
	_, r.err, _ = hook.walk_error(res, rules)
	r.at = .Done
	return .Fault
}
