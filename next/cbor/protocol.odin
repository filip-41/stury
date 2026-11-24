package cbor

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The walk's half of the hook protocol past giving tokens: the actions a hook answers a container with, a walk read
// again inside a hook's call, and the levels a walk and its hook hold.

// Answers the action `a` other than `Next` a hook gave the container that opens at `start`, whose head ends at `at`, in
// the levels `d` deep whose innermost frame is `top`: `Stop`, a skip or a keep of it, or the rest of the item with no
// hook. Returns the walk's result with `done`, or else where the container ends, its `End` given, for the walk to go
// on past it.
@(private)
opened :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, a: hook.Action, start, at, d, top: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	when .Skips in C {
		#partial switch a {
		case .Skip:
			r = pass_over(w, start, d, hs^)
		case .Rest:
			// A walk's hooks are behind a pointer, so a walk with `No_Hooks` has the same layout.
			#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)))
			step_again(w)
			none: hook.Regs
			return run((^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS))(w), start, d, top, &none, hook.no_hook), true
		case .Keep, .Keep_Stubs:
			when .Keeps in C {
				if a == .Keep {
					r = keep_over(w, start, d, hs, false)
				} else {
					r = keep_over(w, start, d, hs, true)
				}
			}
		case:
			return hook.walk_result(at, hook.WALK_STOPPED), true
		}
		if u8(r) != 0 {
			return r, true
		}
		end := u64(r) >> 16
		if give(w, hs, end_token(end, w.src[start] & 31 == 31), on) == .Stop {
			return hook.walk_result(end, hook.WALK_STOPPED), true
		}
		return r, false
	} else {
		return hook.walk_result(at, hook.WALK_STOPPED), true
	}
}

// Judges the container at `start`, opened `d` levels deep, with no hooks, in the walk's own levels past `d`. Its
// result's offset is where the container ends.
@(private, cold)
pass_over :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), start, d: u64, hs: hook.Regs) -> hook.Walk_Result {
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)))
	step_again(w)
	return judge_item(w, start, d, 0, 0, hs)
}

// Judges with no hooks the item at `lo`, read in the levels `d0` deep past the walk's own `d` whose innermost frame is
// `top0`, 0 for an item that starts there. Its result's offset is where the item ends.
@(private)
judge_item :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), lo, d, d0, top0: u64, hs: hook.Regs) -> hook.Walk_Result {
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS)))
	saved := hook.levels_scope(w, d)
	regs := hs
	r := run((^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS | C & WINDOWS))(w), lo, d0, top0, &regs, hook.no_hook)
	hook.levels_leave(w, saved)
	return r
}

// Stores the container at `start` through the inner hook of the hook's `Keeps`, with its `Stubs` under `STUBS` and
// else its `Whole`, in the same walk read as one of the inner hook, as `pass_over` judges one. `hs` are the hook's
// registers, which leave it past the container.
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

// Walks the container at `start` with the inner hook of the hook's `Keeps`, and `keep` as the inner hook's proc, in
// `w`'s own levels past `d`. The inner walk takes its room from the inner hook before it starts, and `w` takes the
// hook's room again after it, since a hook with `.Rooms` is given a node only while its room has place for it. With
// `again` false, a walk of a text in pieces going on with a kept container in a later window, no step is counted
// again, and the walk goes on from `start` in the levels `d0` deep whose innermost frame is `top0`.
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

// Adds back the step the walk took for the container at the head it reads again from, as the second walk counts it
// again.
@(private)
step_again :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) {
	when LAX {
		w.steps[0] += 1
	}
}

// The result of walking the item at `lo` of `src` again for the hook of walk `w`, from the hook's registers `regs`,
// inside one of the hook's calls. The first walk judged the item within its depth limit. It reads in `w`, with levels
// of its own, and leaves `w` as it found it. Its hook has no `.Rooms`.
@(private)
walk_again :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	#assert(.Rooms not_in C)
	levels: [REWALK_LEVELS]Level(S) = ---
	saved := hook.levels_scope(w, 0)
	w.stack, w.limit, w.room = raw_data(levels[:]), MAX_LEVELS, REWALK_LEVELS
	w.depth = hook.held_depth(w.hooks, regs, REWALK_LEVELS)
	r := run(w, lo, 0, 0, regs, on)
	hook.levels_leave(w, saved)
	return r
}

// Doubles the levels the walk and its hook hold, at the walk's deepest level, with the hook's registers `hs` and the
// item at `at`. Each level the walk opens is one more of the hook's at most, and the hook's levels open past the walk's
// own base are among its `hs.c`. A tag is a level of the walk alone, so a tag that closes frees no level of the hook.
// Returns 0, or the outcome when the limit is reached or memory is refused.
@(private)
deepen :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, at: u64) -> u8 {
	r := hs^
	k := hook.deepen(w, &r, int(r.c), at)
	hs^ = r
	return k
}
