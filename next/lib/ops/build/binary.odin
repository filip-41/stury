package build

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Shared cold planning, parallel validate/build/unmarshal-seam, piece-window, hook-protocol, and record-framing
// helpers for binary formats (CBOR and MessagePack). Hot decode loops stay format-local.

BINARY_WARM_BYTES  :: 256
BINARY_WARM_TRIES  :: 8
BINARY_GUESS_BYTES :: 4096

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

// What the innermost level of an absolute header pass took of the items completed in a relative chunk.
Binary_Receipt :: struct {
	closed: bool,
	wait0:  u64,
	items:  u64,
	child:  bool,
}

@(private = "file")
Binary_Cut :: hook.Piece_Cut

// Shared streaming piece state embedded by CBOR and MessagePack `Piece`.
Binary_Piece :: struct {
	using state:  hook.Piece_State,
	cut:          Binary_Cut,
	frames:       [dynamic]u8,
	outer:        Binary_Cut,
	outer_frames: [dynamic]u8,
	claims:       [dynamic][2]u64,
	held:         u64,
	holding:      bool,
	ended:        bool,
	more:         bool,
	refused:      bool,
}

// Hook used by binary record framing to capture a single map member key token and stop immediately.
Binary_Member_Key :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	key:      tape.Token,
}

binary_member_key_hook :: proc "contextless" (h: ^Binary_Member_Key, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.key = t
	return s, .Stop
}

// Walk step counter initialized from `Budget.steps` (one more than the containers the walk may open).
binary_steps_of :: #force_inline proc "contextless" (opts: tape.Options) -> u64 {
	return opts.budget.steps + 1 if opts.budget.steps != 0 && opts.budget.steps < max(u64) else max(u64)
}

// Next seam byte offset for an absolute binary header pass.
binary_seam_cut :: #force_inline proc "contextless" (plan: ^Binary_Plan($Level), n: u64) -> u64 {
	return max(u64) if len(plan.parts) == plan.want else n / u64(plan.want) * u64(len(plan.parts))
}

// Releases the arrays held by `plan`.
binary_plan_destroy :: proc(plan: ^Binary_Plan($Level)) {
	delete(plan.parts)
	delete(plan.seams)
	delete(plan.levels)
	delete(plan.kinds)
}

// Initializes `plan`'s arrays under `opts`'s memory budget and runs `plan_parts_fn` to split `src` into at most `want` parts.
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

// Guesses a synchronized start byte in `src[cut:stop]` for a relative binary header pass.
binary_guess_start :: proc(
	src: []u8,
	sm: ^$Rel_Pass,
	cut, stop: u64,
	$is_container: proc "contextless" (b: u8) -> bool,
	$start_rel: proc "contextless" (st: ^Rel_Pass, i: u64),
	$run_rel: proc(src: []u8, st: ^Rel_Pass, stop: u64) -> Binary_Pass_End,
) -> u64 {
	end := min(cut + BINARY_GUESS_BYTES, stop)
	tries := 0
	for at in cut ..< end {
		if is_container(src[at]) {
			start_rel(sm, at)
			if run_rel(src, sm, min(at + BINARY_WARM_BYTES, u64(len(src)))) == .Stopped {
				return sm.i
			}
			tries += 1
			if tries == BINARY_WARM_TRIES {
				break
			}
		}
	}
	tries_left := min(u64(BINARY_WARM_TRIES), stop - cut) if stop > cut else u64(0)
	for t in 0 ..< tries_left {
		start_rel(sm, cut + t)
		if run_rel(src, sm, min(cut + t + BINARY_WARM_BYTES, u64(len(src)))) == .Stopped {
			return sm.i
		}
	}
	return 0
}

// Gives `m` completed items to the innermost level of absolute pass `st`, closing each exhausted frame.
binary_pass_complete :: proc "contextless" (st: ^$Abs_Pass, m: u64, $COUNT_MASK: u64, $FLAG_TAG: u64) -> (r: Binary_Receipt) {
	rem := m
	for rem > 0 {
		if st.d == 0 {
			r.closed = true
			return
		}
		waits := st.top & COUNT_MASK
		if rem < waits {
			st.top -= rem
			r.wait0, r.items = waits, rem - u64(r.child)
			return
		}
		rem -= waits
		when FLAG_TAG != 0 {
			st.c -= int(st.top & FLAG_TAG == 0)
		} else {
			st.c -= 1
		}
		st.d -= 1
		st.top = st.stack[st.d].frame
		rem += 1
		r.child = true
	}
	return
}

// Merges a relative chunk's counts into the active last part of `plan`.
binary_plan_add_counts :: #force_inline proc "contextless" (plan: ^Binary_Plan($Level), c: int, counts: Part) {
	part := &plan.parts[len(plan.parts) - 1]
	part.nodes += counts.nodes
	part.comments += counts.comments
	part.levels = max(part.levels, c + counts.levels)
}

// Pushes the containers left open by relative pass `sm` onto absolute pass `st` and advances `st.i`.
binary_plan_carry_open :: proc "contextless" (st: ^$Abs_Pass, sm: ^$Rel_Pass, $SEAM_LEVELS: u64, $FLAG_TAG: u64) -> bool {
	for j in 0 ..< sm.d {
		if st.d == SEAM_LEVELS {
			return false
		}
		frame := sm.stack[j + 1].frame if j + 1 < sm.d else sm.top
		lv := sm.stack[j]
		lv.frame = st.top
		st.stack[st.d] = lv
		st.d += 1
		st.top = frame
		when FLAG_TAG != 0 {
			st.c += int(frame & FLAG_TAG == 0)
		} else {
			st.c += 1
		}
	}
	st.i = sm.i
	return true
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

// Advances an absolute header pass from `st.d > 1` until `st.d == 1` (just after finishing a root-array element).
binary_advance_to_depth1 :: proc(
	src: []u8,
	st: ^$Abs_Pass,
	$Store_Level: typeid,
	$run_abs: proc(src: []u8, st: ^Abs_Pass, stop: u64, plan: ^Binary_Plan(Store_Level)) -> Binary_Pass_End,
) -> (pos, top: u64, ok: bool) {
	dummy: Binary_Plan(Store_Level)
	dummy_part: [1]Part
	dummy.parts = transmute([dynamic]Part)runtime.Raw_Dynamic_Array{data = raw_data(dummy_part[:]), len = 1, cap = 1}
	dummy.want = 1
	for st.d > 1 && st.i < u64(len(src)) {
		if run_abs(src, st, st.i + 1, &dummy) != .Stopped {
			return 0, 0, false
		}
	}
	return st.i, st.top, st.d == 1 && st.i < u64(len(src))
}

// Collects depth-1 element parts from `plan` into `out` for parallel root-array unmarshal.
binary_depth1_parts :: proc(
	src: []u8,
	plan: ^Binary_Plan($Store_Level),
	head_len: u64,
	out: []$Part_T,
	$Level: typeid,
	$FLAG_SKIP: u64,
	$advance_fn: proc(src: []u8, pos, d, top: u64, held: [^]Level) -> (u64, u64, bool),
) -> (n_parts: int, last_top: u64, ok: bool) {
	cur := int(head_len)
	for k in 1 ..< len(plan.parts) {
		s := plan.seams[k]
		pos := u64(plan.parts[k].from)
		top := s.top
		if s.d > 1 {
			held := ([^]Level)(raw_data(plan.levels[s.at:]))
			aok := false
			pos, top, aok = advance_fn(src, pos, s.d, s.top, held)
			if !aok {
				continue
			}
		}
		if s.d == 0 || top & FLAG_SKIP != 0 {
			continue
		}
		if int(pos) > cur && int(pos) < len(src) && n_parts + 1 < len(out) {
			out[n_parts] = {from = cur, to = int(pos)}
			n_parts += 1
			cur = int(pos)
			last_top = top
		}
	}
	if n_parts < 1 || cur >= len(src) {
		return 0, 0, false
	}
	out[n_parts] = {from = cur, to = len(src)}
	return n_parts + 1, last_top, true
}

// Converts a parallel typed-part walk result into `(err, astray)` for root-array parallel unmarshal.
binary_typed_part_verdict :: proc "contextless" (
	r: hook.Walk_Result,
	src_len: u64,
	to: int,
	end: bool,
	sp: int,
	rules: ^tape.Rules,
	trailing_detail: u8,
) -> (err: tape.Error, astray: bool) {
	r := r
	if end && u8(r) == 0 && u64(r) >> 16 < src_len {
		r = hook.walk_result(u64(r) >> 16, u8(tape.Fault_Kind.Bad_Char), trailing_detail)
	}
	_, err, _ = hook.walk_error(r, rules)
	if !end {
		if f, is_fault := err.(tape.Fault); is_fault && f.kind == .Truncated && f.at == u64(to) {
			return nil, false
		}
		if err == nil {
			return nil, true
		}
	} else if err == nil && (u64(r) >> 16 != u64(to) || sp != 1) {
		return nil, true
	}
	return err, false
}

// Validates `src` in parallel over `plan_fn`'s parts, falling back to `fallback_fn` on one thread.
binary_validate_parallel :: proc(
	src: []u8,
	opts: tape.Options,
	rules: ^tape.Rules,
	caller: runtime.Allocator,
	$Level: typeid,
	$plan_fn: proc(src: []u8, want: int, opts: tape.Options, backing: runtime.Allocator, plan: ^Binary_Plan(Level), m: ^hook.Memory_Budget) -> (runtime.Allocator, bool),
	$walk_fn: proc "contextless" (src: []u8, from, to: int, opts: tape.Options, plan: ^Binary_Plan(Level), k: int, h: ^hook.No_Hooks, regs: ^hook.Regs) -> (hook.Walk_Result, bool),
	$fallback_fn: proc(src: []u8, opts: tape.Options, caller: runtime.Allocator) -> tape.Error,
	$trailing_detail: u8,
) -> tape.Error {
	Job :: struct {
		src:   []u8,
		plan:  ^Binary_Plan(Level),
		opts:  tape.Options,
		rules: ^tape.Rules,
	}
	m: hook.Memory_Budget
	plan: Binary_Plan(Level)
	if _, ok := plan_fn(src, chunk_count(opts.runner, len(src)), opts, caller, &plan, &m); ok {
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
		done := true
		for p in plan.parts {
			if p.astray {
				done = false
				break
			}
			if p.err != nil {
				if _, is_oom := p.err.(runtime.Allocator_Error); is_oom {
					done = false
					break
				}
				return p.err
			}
		}
		if done {
			return nil
		}
	}
	one := opts
	one.runner = nil
	return fallback_fn(src, one, caller)
}

// Builds `src` in parallel over `plan_fn`'s parts, falling back to `fallback_fn` on one thread.
binary_build_parallel :: proc(
	src: []u8,
	f: ^tape.Format,
	rules: ^tape.Rules,
	opts: tape.Options,
	caller: runtime.Allocator,
	$Level: typeid,
	$plan_fn: proc(src: []u8, want: int, opts: tape.Options, backing: runtime.Allocator, plan: ^Binary_Plan(Level), m: ^hook.Memory_Budget) -> (runtime.Allocator, bool),
	$walk_fn: proc "contextless" (src: []u8, from, to: int, opts: tape.Options, plan: ^Binary_Plan(Level), k: int, h: ^Builder, regs: ^hook.Regs) -> (hook.Walk_Result, bool),
	$fallback_fn: proc(src: []u8, opts: tape.Options, caller: runtime.Allocator) -> (tape.Document, tape.Error),
	$trailing_detail: u8,
) -> (tape.Document, tape.Error) {
	if opts.budget.steps == 0 {
		m: hook.Memory_Budget
		plan: Binary_Plan(Level)
		if allocator, ok := plan_fn(src, chunk_count(opts.runner, len(src)), opts, caller, &plan, &m); ok {
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
			if doc, err, built := parts_build(src, f, rules, plan.parts[:], opts, 0, allocator, caller, part_walk, nil, &ctx); built {
				return doc, err
			}
		}
	}
	one := opts
	one.runner = nil
	return fallback_fn(src, one, caller)
}

// Frees buffers held by a `Binary_Piece` (embedded in `P`) and releases `p`.
binary_piece_free :: proc(p: ^tape.Pieces, $P: typeid) {
	s := (^P)(p.state)
	delete(s.frames)
	delete(s.outer_frames)
	delete(s.claims)
	hook.piece_release(p)
}

// Saves open walk frames into `s` before ending a piece window at `i`.
binary_piece_cut :: proc "contextless" (s: ^Binary_Piece, stack: [^]$Level, i, d, top: u64, passing: bool) -> hook.Walk_Result {
	s.cut = {i, d, top, passing}
	if !hook.piece_levels(&s.frames, stack, d) {
		return hook.walk_result(i, hook.WALK_NO_MEMORY)
	}
	return hook.walk_result(i, hook.WALK_MORE)
}

// Saves the outer walk frames around a nested `Skip`/`Keep`/`Pass` walk that hit a window boundary.
binary_piece_nest :: proc "contextless" (s: ^Binary_Piece, stack: [^]$Level, r: hook.Walk_Result, nest: hook.Nest, start, d, top: u64) -> hook.Walk_Result {
	s.nest = nest
	if nest == .Rest {
		return r
	}
	s.outer = {start, d, top, false}
	if !hook.piece_levels(&s.outer_frames, stack, d) {
		return hook.walk_result(start, hook.WALK_NO_MEMORY)
	}
	return r
}

// Handles an oversized container count in a window (deferring to `s.claims`) or parallel part (`whole`).
binary_count_short :: proc "contextless" (s: ^Binary_Piece, whole, i, hl, arg, pair: u64, count_too_large_detail: u8) -> hook.Walk_Result {
	if s != nil && s.more {
		need := max(u64) if arg > max(u64) >> 2 else i + hl + (arg << pair)
		context = runtime.default_context()
		if _, e := append(&s.claims, [2]u64{i, need}); e != nil {
			return hook.walk_result(i, hook.WALK_NO_MEMORY)
		}
		return 0
	}
	if whole > i + hl && arg <= (whole - i - hl) >> pair {
		return 0
	}
	return hook.walk_result(i, u8(tape.Fault_Kind.Truncated), count_too_large_detail)
}

// Records a scalar token in the open containers of a piece walk.
binary_piece_track_scalar :: #force_inline proc "contextless" (s: ^hook.Piece_State, t: tape.Token) -> bool #no_bounds_check {
	n := len(s.opened)
	if t.role == .Key {
		s.opened[n - 1].key, s.opened[n - 1].name = t, -1
		return true
	}
	if n > 0 {
		s.opened[n - 1].count += 1
		s.opened[n - 1].key.kind = .End
	}
	return true
}

// Loads saved piece frames into `w.stack` and sets `w.depth`.
binary_piece_load_frames :: proc "contextless" (w: ^$W, s: ^Binary_Piece) -> (inner, ok: bool) {
	inner = s.nest != .None && s.nest != .Rest
	base := s.outer.d if inner else 0
	held := base + s.cut.d
	if held > w.room && !hook.levels_room(w, held) {
		return inner, false
	}
	if inner {
		intrinsics.mem_copy_non_overlapping(w.stack, raw_data(s.outer_frames), len(s.outer_frames))
	}
	intrinsics.mem_copy_non_overlapping(w.stack[base:], raw_data(s.frames), len(s.frames))
	w.depth = held
	return inner, true
}

// Runs one binary piece-window read: begins/initializes `P`, dispatches `walk_fn`, prunes settled claims, checks
// count-too-large / trailing bytes, and updates `opts.pieces` for the next window or returns the final result.
binary_piece_read :: proc(
	src: []u8,
	opts: tape.Options,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	f: ^tape.Format,
	rules: ^tape.Rules,
	no_item_detail, count_too_large_detail, trailing_detail: u8,
	$P: typeid,
	$free_fn: proc(p: ^tape.Pieces),
	$walk_fn: proc "contextless" (text: []u8, opts: tape.Options, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context, s: ^P) -> hook.Walk_Result,
	$keep_fn: proc "contextless" (s: ^P, to: u64) -> u64,
) -> (root_close: u64, err: tape.Error, took: bool) {
	p := opts.pieces
	s, text, to, berr := hook.piece_begin(p, P, free_fn, src)
	if berr != nil {
		return 0, berr, false
	}
	s.more = !p.last
	if !s.started {
		s.started, s.steps = true, binary_steps_of(opts)
		lists := hook.piece_lists(p)
		s.frames.allocator, s.outer_frames.allocator, s.claims.allocator = lists, lists, lists
		s.opened.allocator, s.names.allocator, s.steps_buf.allocator = lists, lists, lists
	}
	r: hook.Walk_Result
	switch {
	case s.holding:
		r = hook.Walk_Result(s.held)
	case s.ended:
		r = hook.walk_result(s.cut.i, 0)
	case to == 0 && !s.more:
		p.more, p.open = false, nil
		return 0, tape.Fault{rules = rules, kind = .Truncated, detail = no_item_detail}, false
	case:
		r = walk_fn(text, opts, h, regs, allocator, ctx, s)
	}
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

// Shared `judge_item` body for binary hook protocols: scopes `w`'s levels at `d` and runs a hookless walk.
binary_judge_item :: #force_inline proc "contextless" (
	w: ^$W,
	no_hooks_w: ^$NW,
	lo, d, d0, top0: u64,
	hs: hook.Regs,
	$run_fn: proc "contextless" (w: ^NW, i, d, top: u64, hs: ^hook.Regs) -> hook.Walk_Result,
) -> hook.Walk_Result {
	saved := hook.levels_scope(w, d)
	regs := hs
	r := run_fn(no_hooks_w, lo, d0, top0, &regs)
	hook.levels_leave(w, saved)
	return r
}

// Shared `keep_through` body for binary hook protocols: scopes levels, swaps `hooks`/`rooms`, runs inner hook, restores.
binary_keep_through :: #force_inline proc "contextless" (
	w: ^$W,
	inner: ^$IW,
	$Inner: typeid,
	$LAX: bool,
	$C, $IC: hook.Capabilities,
	$of: proc "contextless" (h: rawptr) -> rawptr,
	$run_fn: proc "contextless" (w: ^IW, i, d, top: u64, hs: ^hook.Regs) -> hook.Walk_Result,
	start, d: u64,
	hs: ^hook.Regs,
	d0, top0: u64,
	again: bool,
) -> hook.Walk_Result {
	hooks := w.hooks
	saved := hook.levels_scope(w, d)
	inner.hooks = (^Inner)(of(hooks))
	if again {
		when LAX {
			w.steps[0] += 1
		}
	}
	when .Rooms in IC {
		inner.rooms = hook.rooms_end(inner.hooks)
	}
	r := run_fn(inner, start, d0, top0, hs)
	hook.levels_leave(w, saved)
	w.hooks = hooks
	when .Rooms in C {
		w.rooms = hook.rooms_end(hooks)
	}
	return r
}

// Shared `walk_again` body for binary hook protocols: borrows `w` with a small replay stack.
binary_walk_again :: #force_inline proc "contextless" (
	w: ^$W,
	$Level: typeid,
	$REWALK_LEVELS: int,
	$MAX_LEVELS: u64,
	lo: u64,
	regs: ^hook.Regs,
	$run_fn: proc "contextless" (w: ^W, i, d, top: u64, hs: ^hook.Regs) -> hook.Walk_Result,
) -> hook.Walk_Result {
	levels: [REWALK_LEVELS]Level = ---
	saved := hook.levels_scope(w, 0)
	w.stack, w.limit, w.room = raw_data(levels[:]), MAX_LEVELS, u64(REWALK_LEVELS)
	w.depth = hook.held_depth(w.hooks, regs, u64(REWALK_LEVELS))
	r := run_fn(w, lo, 0, 0, regs)
	hook.levels_leave(w, saved)
	return r
}

// Whether more bytes follow the current window of a piece-streamed record reader.
binary_window_more :: #force_inline proc "contextless" (r: ^tape.Records) -> bool {
	return r.opts.pieces != nil && !r.opts.pieces.last
}

// Fast-path `.Concatenated` record framing for binary formats.
binary_record_frame_concat :: #force_inline proc "contextless" (r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
	n := u64(len(r.src))
	if r.pos >= n {
		if !binary_window_more(r) {
			r.at = .Done
		}
		return
	}
	return r.pos, n, true
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
	more := binary_window_more(r)
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

// Common `frame_tail` for binary record framing: refuses trailing bytes past the root item.
binary_frame_tail :: proc "contextless" (
	r: ^tape.Records,
	frame: ^Frame($L),
	rules: ^tape.Rules,
	trailing_detail, count_too_large_detail: u8,
) -> Frame_Step {
	if r.pos < u64(len(r.src)) {
		return binary_item_refused(r, frame, hook.walk_result(r.pos, u8(tape.Fault_Kind.Bad_Char), trailing_detail), rules, count_too_large_detail)
	}
	return .Wait if binary_window_more(r) else .Done
}

// Common `frame_pass` for binary record framing: skips/validates one off-path item via `walk_item_fn`.
binary_frame_pass :: proc(
	r: ^tape.Records,
	frame: ^Frame($L),
	steps: ^u64,
	depth, tagged: u64,
	allocator: runtime.Allocator,
	rules: ^tape.Rules,
	no_item_detail, count_too_large_detail: u8,
	$walk_item_fn: proc(src: []u8, lo: u64, lax: bool, opts: tape.Options, limit, steps: u64, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (hook.Walk_Result, bool, u64),
) -> Frame_Step {
	if depth == 0 && len(r.src) == 0 {
		return binary_item_refused(r, frame, hook.walk_result(0, u8(tape.Fault_Kind.Truncated), no_item_detail), rules, count_too_large_detail)
	}
	none: hook.No_Hooks
	regs: hook.Regs
	ctx := context
	limit := read_depth(r.opts) - depth - tagged
	res, _, left := walk_item_fn(r.src, r.pos, read_lax(r.opts), r.opts, limit, steps^, &none, &regs, allocator, &ctx)
	if u8(res) != 0 {
		return binary_item_refused(r, frame, res, rules, count_too_large_detail)
	}
	steps^, r.pos = left, u64(res) >> 16
	return .Done
}

// Common `record_walk` for binary record streams: walks one record, re-walks hooklessly if the hook stopped early,
// updates record state, and invokes `take_fn` to advance the enclosing container level.
binary_record_walk :: proc(
	r: ^$R,
	lo: u64,
	tagged: u64,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	rules: ^tape.Rules,
	count_too_large_detail: u8,
	$walk_h: proc "contextless" (src: []u8, lo: u64, opts: tape.Options, limit, steps: u64, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (hook.Walk_Result, bool, u64),
	$walk_none: proc "contextless" (src: []u8, lo: u64, opts: tape.Options, limit, steps: u64, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (hook.Walk_Result, bool, u64),
	$take_fn: proc(r: ^R),
) -> (walked: Record_Walk) {
	concatenated := r.framing == .Concatenated
	limit := read_depth(r.opts)
	if !concatenated {
		limit -= 1 + u64(len(r.path)) + tagged
	}
	steps := binary_steps_of(r.opts) if concatenated else r.steps
	res, tolerated, left := walk_h(r.src, lo, r.opts, limit, steps, h, regs, allocator, ctx)
	walked.res, walked.tolerated = res, tolerated || r.took
	end := res
	if u8(res) == hook.WALK_STOPPED {
		none: hook.No_Hooks
		none_regs: hook.Regs
		end, _, left = walk_none(r.src, lo, r.opts, limit, steps, &none, &none_regs, allocator, ctx)
	}
	if u8(end) != 0 {
		_ = binary_item_refused(&r.records, &r.frame, end, rules, count_too_large_detail)
		return
	}
	if !concatenated {
		r.steps = left
		take_fn(r)
	}
	r.took = false
	walked.hi, walked.ok = u64(end) >> 16, true
	r.pos, r.at = walked.hi, .After
	return
}
