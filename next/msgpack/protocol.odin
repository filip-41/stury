package msgpack

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

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
				r = keep_over(w, start, d, hs, false) if a == .Keep else keep_over(w, start, d, hs, true)
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
	NW :: Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(NW))
	go :: #force_inline proc "contextless" (w: ^NW, i, d, top: u64, hs: ^hook.Regs) -> hook.Walk_Result { return run(w, i, d, top, hs, hook.no_hook) }
	return build.binary_judge_item(w, (^NW)(w), lo, d, d0, top0, hs, go)
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
	IW :: Walk(S, Inner, LAX, IC | C & WINDOWS)
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(IW))
	on :: #force_inline proc "contextless" (h: ^Inner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) { return keep(h, s, t) }
	go :: #force_inline proc "contextless" (w: ^IW, i, d, top: u64, hs: ^hook.Regs) -> hook.Walk_Result { return run(w, i, d, top, hs, on) }
	return build.binary_keep_through(w, (^IW)(w), Inner, LAX, C, IC, of, go, start, d, hs, d0, top0, again)
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
	go :: #force_inline proc "contextless" (w: ^Walk(S, H, LAX, C), i, d, top: u64, hs: ^hook.Regs) -> hook.Walk_Result { return run(w, i, d, top, hs, on) }
	return build.binary_walk_again(w, Level, REWALK_LEVELS, MAX_LEVELS, lo, regs, go)
}

@(private)
deepen :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, at: u64) -> u8 {
	r := hs^
	k := hook.deepen(w, &r, int(r.c), at)
	hs^ = r
	return k
}
