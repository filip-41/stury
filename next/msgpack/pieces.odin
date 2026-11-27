package msgpack

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Streaming piece-by-piece MessagePack walks across arbitrarily cut input windows.

@(private)
Cut :: hook.Piece_Cut

@(private)
Piece :: struct {
	using state:  hook.Piece_State,
	cut:          Cut,
	frames:       [dynamic]u8,
	outer:        Cut,
	outer_frames: [dynamic]u8,
	claims:       [dynamic][2]u64,
	held:         u64,
	holding:      bool,
	ended:        bool,
	more:         bool,
	refused:      bool,
	skip_open:    bool,
	skip_end:     bool,
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	delete(s.frames)
	delete(s.outer_frames)
	delete(s.claims)
	hook.piece_release(p)
}

@(private)
short :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), at, d, top: u64, passing: bool) -> hook.Walk_Result {
	when .Windows in C {
		if w.piece[0] != nil && w.piece[0].more {
			return piece_cut(w, at, d, top, passing)
		}
	}
	return fault(u64(len(w.src)), .Truncated)
}

@(private, cold)
count_short :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), i, hl, arg, pair: u64) -> hook.Walk_Result {
	when .Windows in C {
		if s := w.piece[0]; s != nil && s.more {
			if s.skip_open {
				return 0
			}
			need := max(u64) if arg > max(u64) >> 2 else i + hl + arg << pair
			context = runtime.default_context()
			if _, e := append(&s.claims, [2]u64{i, need}); e != nil {
				return hook.walk_result(i, hook.WALK_NO_MEMORY)
			}
			return 0
		}
	}
	if w.whole > i + hl && arg <= (w.whole - i - hl) >> pair {
		return 0
	}
	return fault(i, .Truncated, .Count_Too_Large)
}

@(private, cold)
piece_cut :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), i, d, top: u64, passing: bool) -> hook.Walk_Result {
	when .Windows in C {
		s := w.piece[0]
		s.cut = {i, d, top, passing}
		if !piece_levels(&s.frames, w.stack, d) {
			return hook.walk_result(i, hook.WALK_NO_MEMORY)
		}
	}
	return hook.walk_result(i, hook.WALK_MORE)
}

@(private)
piece_levels :: #force_inline proc "contextless" (frames: ^[dynamic]u8, stack: [^]Level, d: u64) -> bool {
	return hook.piece_levels(frames, stack, d)
}

@(private)
nest_of :: #force_inline proc "contextless" (a: hook.Action) -> hook.Nest {
	return hook.nest_of(a)
}

@(private)
nested :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), r: hook.Walk_Result, nest: hook.Nest, start, d, top: u64) -> hook.Walk_Result {
	when .Windows in C {
		if u8(r) == hook.WALK_MORE && w.piece[0] != nil {
			return piece_nest(w, r, nest, start, d, top)
		}
	}
	return r
}

@(private, cold)
piece_nest :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), r: hook.Walk_Result, nest: hook.Nest, start, d, top: u64) -> hook.Walk_Result {
	when .Windows in C {
		s := w.piece[0]
		s.nest = nest
		if nest == .Rest {
			return r
		}
		s.outer = {start, d, top, false}
		if !piece_levels(&s.outer_frames, w.stack, d) {
			return hook.walk_result(start, hook.WALK_NO_MEMORY)
		}
	}
	return r
}

@(private)
piece_track :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), s: ^Piece, t: tape.Token, d: u64) -> bool #no_bounds_check {
	if t.role > .Key {
		return true
	}
	if t.kind > .Plain || t.kind == .End {
		if t.kind == .End {
			if s.skip_end && d == 1 {
				s.skip_end = false
				return true
			}
		} else if s.skip_open {
			s.skip_open = false
			return true
		}
		return hook.piece_track_container(w.ctx, &s.state, &s.refused, t)
	}
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

@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^
	p := opts.pieces
	s, text, to, berr := hook.piece_begin(p, Piece, piece_free, src)
	if berr != nil {
		return 0, berr, false
	}
	s.more = !p.last
	if !s.started {
		s.started, s.steps = true, steps_of(opts)
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
		return 0, tape.Fault{rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Item)}, false
	case:
		r = piece_walk(text, S, opts, h, regs, allocator, ctx, on, s)
	}
	keep_fn :: proc "contextless" (s: ^Piece, to: u64) -> u64 {
		return to if s.holding || s.ended else s.cut.i
	}
	return build.binary_piece_finish(p, s, text, to, r, regs, &FORMATS[S], &RULES, u8(Detail.Count_Too_Large), u8(Detail.Trailing), keep_fn)
}

@(private)
piece_walk :: proc "contextless" (src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), s: ^Piece) -> (r: hook.Walk_Result) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level = ---
	w: Walk(S, H, true, C | WINDOWS)
	walk_init(&w, src, h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.allocator, w.ctx, w.steps, w.piece = allocator, ctx, {s.steps}, {s}
	inner := s.nest != .None && s.nest != .Rest
	base := s.outer.d if inner else 0
	held := base + s.cut.d
	if held > w.room && !hook.levels_room(&w, held) {
		return hook.walk_result(s.cut.i, hook.WALK_NO_MEMORY)
	}
	if inner {
		intrinsics.mem_copy_non_overlapping(w.stack, raw_data(s.outer_frames), len(s.outer_frames))
	}
	intrinsics.mem_copy_non_overlapping(w.stack[base:], raw_data(s.frames), len(s.frames))
	w.depth = held
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	when .Walk in C {
		h.walk = &w
	}
	cut, outer := s.cut, s.outer
	switch s.nest {
	case .None:
		r = run(&w, cut.i, cut.d, cut.top, regs, on, cut.passing)
	case .Rest:
		none: hook.Regs
		r = run((^Walk(S, hook.No_Hooks, true, hook.NO_HOOKS_CAPS | WINDOWS))(&w), cut.i, cut.d, cut.top, &none, hook.no_hook)
	case .Skip, .Pass:
		r = judge_item(&w, cut.i, outer.d, cut.d, cut.top, regs^)
	case .Keep, .Keep_Stubs:
		when .Keeps in C {
			if s.nest == .Keep {
				r = keep_over(&w, cut.i, outer.d, regs, false, cut.d, cut.top, false)
			} else {
				r = keep_over(&w, cut.i, outer.d, regs, true, cut.d, cut.top, false)
			}
		}
	}
	if inner && u8(r) == 0 {
		r = piece_past(&w, regs, u64(r) >> 16, on)
	}
	when .Walk in C {
		h.walk = nil
	}
	r = hook.steps_result(r, w.steps[0])
	s.steps = w.steps[0]
	s.tolerated ||= w.tolerated
	if w.owned {
		hook.levels_free(&w)
	}
	return
}

@(private)
piece_past :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), regs: ^hook.Regs, end: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	s := w.piece[0]
	nest := s.nest
	s.nest = .None
	d, top := s.outer.d, s.outer.top
	if nest != .Pass {
		if give(w, regs, end_token(end), on) == .Stop {
			return hook.walk_result(end, hook.WALK_STOPPED)
		}
	}
	if r := count_down(w, regs, end, &d, &top, on); r != 0 {
		return r
	}
	return run(w, end, d, top, regs, on)
}
