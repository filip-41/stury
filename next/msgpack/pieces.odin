package msgpack

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Streaming piece-by-piece MessagePack walks across arbitrarily cut input windows.

@(private)
Piece :: struct {
	using base: build.Binary_Piece,
	skip_open:  bool,
	skip_end:   bool,
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	build.binary_piece_free(p, Piece)
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
	piece: ^build.Binary_Piece
	when .Windows in C {
		if s := w.piece[0]; s != nil {
			if s.more && s.skip_open {
				return 0
			}
			piece = &s.base
		}
	}
	return build.binary_count_short(piece, w.whole, i, hl, arg, pair, u8(Detail.Count_Too_Large))
}

@(private, cold)
piece_cut :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), i, d, top: u64, passing: bool) -> hook.Walk_Result {
	when .Windows in C {
		return build.binary_piece_cut(&w.piece[0].base, w.stack, i, d, top, passing)
	}
	return hook.walk_result(i, hook.WALK_MORE)
}

@(private)
nest_of :: #force_inline proc "contextless" (a: hook.Action) -> hook.Nest { return hook.nest_of(a) }

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
		return build.binary_piece_nest(&w.piece[0].base, w.stack, r, nest, start, d, top)
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
	return build.binary_piece_track_scalar(&s.state, t)
}

@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^
	walk_fn :: proc "contextless" (text: []u8, opts: Options, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context, s: ^Piece) -> hook.Walk_Result {
		return piece_walk(text, S, opts, h, regs, a, ctx, on, s)
	}
	keep_fn :: proc "contextless" (s: ^Piece, to: u64) -> u64 {
		return to if s.holding || s.ended else s.cut.i
	}
	return build.binary_piece_read(src, opts, h, regs, allocator, ctx, &FORMATS[S], &RULES, u8(Detail.No_Item), u8(Detail.Count_Too_Large), u8(Detail.Trailing), Piece, piece_free, walk_fn, keep_fn)
}

@(private)
piece_walk :: proc "contextless" (src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), s: ^Piece) -> (r: hook.Walk_Result) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level = ---
	w: Walk(S, H, true, C | WINDOWS)
	walk_init(&w, src, h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.allocator, w.ctx, w.steps, w.piece = allocator, ctx, {s.steps}, {s}
	inner, ok := build.binary_piece_load_frames(&w, &s.base)
	if !ok {
		return hook.walk_result(s.cut.i, hook.WALK_NO_MEMORY)
	}
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
