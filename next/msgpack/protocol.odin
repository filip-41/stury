package msgpack

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Walk hook protocol: container skip, keep, keep-stubs, rest, rewalk, and stack deepening.

@(private)
opened :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, a: hook.Action, start, at, d, top: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	when .Skips in C {
		#partial switch a {
		case .Skip:
			when .Windows in C {
				if s := w.piece[0]; s != nil {
					s.skip_open, s.skip_end = true, true
				}
			}
			r = pass_over(w, start, d, hs^)
		case .Rest:
			#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)))
			step_again(w)
			when .Windows in C {
				if s := w.piece[0]; s != nil {
					s.skip_open = true
				}
			}
			none: hook.Regs
			return run((^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS))(w), start, d, top, &none, hook.no_hook), true
		case .Keep, .Keep_Stubs:
			when .Keeps in C {
				when .Windows in C {
					if s := w.piece[0]; s != nil {
						s.skip_open, s.skip_end = true, true
					}
				}
				if a == .Keep {
					r = keep_over(w, start, d, hs, false)
				} else {
					r = keep_over(w, start, d, hs, true)
				}
			} else {
				return hook.walk_result(at, hook.WALK_STOPPED), true
			}
		case:
			return hook.walk_result(at, hook.WALK_STOPPED), true
		}
		if u8(r) != 0 {
			return r, true
		}
		end := u64(r) >> 16
		if give(w, hs, end_token(end), on) == .Stop {
			return hook.walk_result(end, hook.WALK_STOPPED), true
		}
		return r, false
	} else {
		return hook.walk_result(at, hook.WALK_STOPPED), true
	}
}

@(private, cold)
pass_over :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), start, d: u64, hs: hook.Regs) -> hook.Walk_Result {
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)))
	step_again(w)
	return judge_item(w, start, d, 0, 0, hs)
}

@(private)
judge_item :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), lo, d, d0, top0: u64, hs: hook.Regs) -> hook.Walk_Result {
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)))
	saved := hook.levels_scope(w, d)
	regs := hs
	r := run((^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS))(w), lo, d0, top0, &regs, hook.no_hook)
	hook.levels_leave(w, saved)
	return r
}

@(private)
keep_over :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), start, d: u64, hs: ^hook.Regs, $STUBS: bool, d0: u64 = 0, top0: u64 = 0, again := true) -> hook.Walk_Result {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
	Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
	when STUBS {
		return keep_through(Inner, intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 3), w, start, d, hs, d0, top0, again)
	} else {
		return keep_through(Inner, intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 2), w, start, d, hs, d0, top0, again)
	}
}

@(private)
keep_through :: #force_no_inline proc "contextless" ($Inner: typeid, $of: proc "contextless" (h: rawptr) -> rawptr, $keep: proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), w: ^Walk($S, $H, $LAX, $C), start, d: u64, hs: ^hook.Regs, d0, top0: u64, again: bool) -> hook.Walk_Result {
	IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, Inner, LAX, IC | C & WINDOWS)))
	on :: #force_inline proc "contextless" (h: ^Inner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
		return keep(h, s, t)
	}
	inner := (^Walk(S, Inner, LAX, IC | C & WINDOWS))(w)
	hooks := w.hooks
	saved := hook.levels_scope(w, d)
	inner.hooks = (^Inner)(of(hooks))
	if again {
		step_again(w)
	}
	when .Rooms in IC {
		inner.rooms = hook.rooms_end(inner.hooks)
	}
	r := run(inner, start, d0, top0, hs, on)
	hook.levels_leave(w, saved)
	w.hooks = hooks
	when .Rooms in C {
		w.rooms = hook.rooms_end(hooks)
	}
	return r
}

@(private)
step_again :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) {
	when LAX {
		w.steps[0] += 1
	}
}

@(private)
walk_again :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	_ = src
	#assert(.Rooms not_in C)
	levels: [REWALK_LEVELS]Level = ---
	saved := hook.levels_scope(w, 0)
	w.stack, w.limit, w.room = raw_data(levels[:]), MAX_LEVELS, REWALK_LEVELS
	w.depth = hook.held_depth(w.hooks, regs, REWALK_LEVELS)
	r := run(w, lo, 0, 0, regs, on)
	hook.levels_leave(w, saved)
	return r
}

@(private)
deepen :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, at: u64) -> u8 {
	r := hs^
	k := hook.deepen(w, &r, int(r.c), at)
	hs^ = r
	return k
}
