package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// JSON's walk, the one pass over a text that `validate` and `build` run. Its states are in states.odin, and the leaves
// they read tokens with in strings.odin, scalars.odin, whitespace.odin and members.odin.

// Open levels a walk keeps in its own frame, so a text within the default limit takes no memory, as `validate`
// takes no allocator. Only a deeper `Budget.depth` moves the levels past it to the heap.
@(private)
WALK_DEPTH :: tape.DEFAULT_DEPTH

// A walk's state outside its registers.
@(private)
Walk :: struct($S: Spec, $H: typeid) {
	base:   [^]u8,
	// The address one past the hook's room for nodes, for a hook with a `rooms` field, beside `base` as a token reads
	// both.
	rooms:  uintptr,
	hooks:  ^H,
	stack:  [^]u32, // per open level, its parent's close bracket in the low byte and gap slot above, restored at its close
	regs:   ^tape.Hook_Regs, // the hook's registers where the walk ended
	depth:  u64, // levels `stack` and the hook hold
	limit:  u64, // `Budget.depth`
	room:   u64, // levels `stack` holds
	gap_lo: u64, // where the gap being read started
	grow:   u64, // where the token that found the hook's room full starts
	gaps:   Gaps,
	resume: [^]u8, // where a string's first escape is, from the state that found it
	owned:  bool, // `stack` is on the heap
	tier:   kernel.Tier,
	// Leaves no gap on 32 and 64-bit targets, as Odin zeroes a struct with one that is declared `---`.
	_:      [(8 - (size_of(rawptr) + 2) % 8) % 8]u8,
}

// Whether the target has a heap for the walk's own memory, which JS, WASI and freestanding lack.
@(private)
HEAP :: ODIN_OS != .JS && ODIN_OS != .WASI && ODIN_OS != .Freestanding

// The kernel tier the states are built for. The floor, as the walk's 16-byte reads gain nothing from a wider tier.
@(private)
STATE_TIER :: kernel.Tier(0)

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// The result of walking the root value at `p`, past white space.
@(private)
walk_value :: #force_inline proc "contextless" (src: []u8, p: [^]u8, $S: Spec, limit: u64, h: ^$H, regs: ^tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	stack: [WALK_DEPTH]u32 = ---
	// Left unzeroed, as `gap_new_row` zeroes each row it makes.
	w: Walk(S, H) = ---
	w.base, w.hooks, w.stack, w.regs, w.limit, w.room, w.owned = raw_data(src), h, raw_data(stack[:]), regs, limit, WALK_DEPTH, false
	when ODIN_ARCH == .amd64 {
		w.tier = kernel.tier()
	}
	w.depth = held_depth(h, regs, min(limit, WALK_DEPTH))
	when intrinsics.type_has_field(H, tape.ROOMS_FIELD) {
		w.rooms = tape.rooms_end(h)
	}
	w.gaps.rows, w.gaps.misses = 1, 0
	intrinsics.mem_zero(&w.gaps.child[0], GAP_MEMBERS)
	r := enter(p, raw_data(src)[len(src):], &w, regs^, on)
	if w.owned {
		runtime.heap_free(w.stack)
	}
	return r
}

// The open levels the hook has room for, at most `room`.
@(private)
held_depth :: #force_inline proc "contextless" (h: ^$H, regs: ^tape.Hook_Regs, room: u64) -> u64 {
	when intrinsics.type_has_field(H, tape.LEVELS_FIELD) {
		return min(room, u64(tape.levels_held(h)) - regs.c)
	} else {
		return room
	}
}

when .Address in ODIN_SANITIZER_FLAGS {
	@(private)
	enter :: #force_no_inline proc "contextless" (p, end: [^]u8, w: ^Walk($S, $H), hs: tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
		return st_value(p, end, 0, INDENT_START, w, hs.a, hs.b, hs.c, GAP_START, on)
	}
} else {
	@(private)
	enter :: #force_inline proc "contextless" (p, end: [^]u8, w: ^Walk($S, $H), hs: tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
		return st_value(p, end, 0, INDENT_START, w, hs.a, hs.b, hs.c, GAP_START, on)
	}
}

// Judges the container at `p`, opened in the level `d` names with gap slot `m`, with no hooks, as the root of the same
// walk read as one with `No_Hooks` whose stack starts at that level. It learns into and predicts from the walk's own
// gaps and indent. Its result's offset is where the container ends, as a walk's root ends with no look at what follows
// it. It is a call because `#must_tail` cannot jump between walks.
@(private, cold)
pass_over :: #force_no_inline proc "contextless" (w: ^Walk($S, $H), p, end: [^]u8, d, ind: u64, hs: tape.Hook_Regs, m: u64) -> tape.Walk_Result {
	#assert(size_of(Walk(S, H)) == size_of(Walk(S, tape.No_Hooks)))
	slot := d >> 1
	stack, depth, limit, room, owned := w.stack, w.depth, w.limit, w.room, w.owned
	w.stack, w.depth, w.limit, w.room, w.owned = stack[slot:], depth - slot, limit - slot, room - slot, false
	r := st_value(p, end, 0, ind, (^Walk(S, tape.No_Hooks))(w), hs.a, hs.b, hs.c, m, tape.no_hook)
	if w.owned {
		runtime.heap_free(w.stack)
	}
	w.stack, w.depth, w.limit, w.room, w.owned = stack, depth, limit, room, owned
	return r
}

// Stores the container at `p` whole through the inner hook the hook's `keeps` field names, in the same walk read as
// that hook's, as `pass_over` judges one. `hs` are the hook's registers, which leave it past the container.
@(private)
keep_over :: #force_inline proc "contextless" (w: ^Walk($S, $H), p, end: [^]u8, d, ind: u64, hs: ^tape.Hook_Regs, m: u64) -> tape.Walk_Result {
	return keep_through(
		intrinsics.type_polymorphic_record_parameter_value(type_of(w.hooks.keeps), 0),
		w, p, end, d, ind, hs, m,
	)
}

@(private)
keep_through :: #force_no_inline proc "contextless" ($on: proc "contextless" (h: ^$Inner, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), w: ^Walk($S, $H), p, end: [^]u8, d, ind: u64, hs: ^tape.Hook_Regs, m: u64) -> tape.Walk_Result {
	slot := d >> 1
	stack, depth, limit, room, owned := w.stack, w.depth, w.limit, w.room, w.owned
	w.stack, w.depth, w.limit, w.room, w.owned = stack[slot:], depth - slot, limit - slot, room - slot, false
	when intrinsics.type_has_field(Inner, tape.ROOMS_FIELD) {
		w.rooms = tape.rooms_end((^Inner)(w.hooks))
	}
	r := st_value(p, end, 0, ind, (^Walk(S, Inner))(w), hs.a, hs.b, hs.c, m, on)
	hs^ = w.regs^
	if w.owned {
		runtime.heap_free(w.stack)
	}
	w.stack, w.depth, w.limit, w.room, w.owned = stack, depth, limit, room, owned
	return r
}

// Gives the hook the token from `p` to `q`, or answers `Grow` for a node the hook's room has no place for.
@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, kind: tape.Kind, role: tape.Role, p, q: [^]u8, spelling: u16) -> tape.Action {
	return emit_token(w, on, hs, tape.Token{at(w, p), u32(intrinsics.ptr_sub(q, p)), kind, role, spelling})
}

@(private)
emit_token :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, t: tape.Token) -> tape.Action {
	when intrinsics.type_has_field(H, tape.ROOMS_FIELD) {
		if t.kind != .End && t.role <= .Key && uintptr(hs.a) == w.rooms {
			w.grow = t.lo
			return .Grow
		}
	}
	return give(w, on, hs, t)
}

// Gives the hook token `t`, for which the hook's room has place.
@(private)
give :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, t: tape.Token) -> tape.Action {
	a: tape.Action
	hs^, a = on(w.hooks, hs^, t)
	return a
}

// Whether `emit` answered `Grow`, which it gives only for a hook with a `rooms` field.
@(private)
grows :: #force_inline proc "contextless" ($H: typeid, a: tape.Action) -> bool {
	when intrinsics.type_has_field(H, tape.ROOMS_FIELD) {
		return a == .Grow
	} else {
		return false
	}
}

// Grows the hook's room after `Grow`, or returns false.
@(private)
grow_room :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: ^tape.Hook_Regs) -> bool {
	when intrinsics.type_has_field(H, tape.ROOMS_FIELD) {
		if !tape.rooms_grow(w.hooks, hs, w.grow) {
			return false
		}
		w.rooms = tape.rooms_end(w.hooks)
	}
	return true
}

// Emits the string whose opening quote is at `p` and that ends at `q`, one past its closing quote. Its token spans the
// bytes between the quotes.
@(private)
emit_string :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, role: tape.Role, p, q: [^]u8, spelling: u16) -> tape.Action {
	return emit(w, on, hs, .String, role, p[1:], q[-1:], spelling | tape.SPELLING_QUOTED)
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

// Doubles the levels the walk and its hook hold, up to `limit`, at the walk's deepest level with `open` levels open
// in its hook. The walk's own levels move to the heap only past the `room` of its frame. Returns 0, or the outcome when
// the limit is reached or memory is refused.
@(private, cold)
deepen :: #force_no_inline proc "contextless" (w: ^Walk($S, $H), open: u64) -> u8 {
	if w.depth >= w.limit {
		return tape.WALK_TOO_DEEP
	}
	want := min(w.limit, max(2 * w.depth, 16))
	if want > u64(max(int) / size_of(u64)) {
		return tape.WALK_NO_MEMORY
	}
	// Each level the walk adds opens one more in the hook at most.
	when intrinsics.type_has_field(H, tape.LEVELS_FIELD) {
		if hook := int(open + want - w.depth); tape.levels_held(w.hooks) < hook && !tape.levels_grow(w.hooks, hook) {
			return tape.WALK_NO_MEMORY
		}
	}
	if want > w.room {
		when !HEAP {
			return tape.WALK_NO_MEMORY
		}
		size := int(want) * size_of(u32)
		stack := runtime.heap_resize(w.stack, size) if w.owned else runtime.heap_alloc(size, false)
		if stack == nil {
			return tape.WALK_NO_MEMORY
		}
		if !w.owned {
			intrinsics.mem_copy_non_overlapping(stack, w.stack, int(w.depth) * size_of(u32))
		}
		w.stack, w.owned, w.room = ([^]u32)(stack), true, want
	}
	w.depth = want
	return 0
}

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: tape.Hook_Regs, p: [^]u8, kind: tape.Fault_Kind) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), u8(kind))
}

// The result `deepen` gave at the bracket `p`.
@(private, cold)
too_deep :: #force_no_inline proc "contextless" (w: ^Walk($S, $H), hs: tape.Hook_Regs, p: [^]u8, outcome: u8) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), outcome)
}

@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: tape.Hook_Regs, p: [^]u8) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), tape.WALK_STOPPED)
}

// The walk's result for a root value that ends at `p`.
@(private)
done :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: tape.Hook_Regs, p: [^]u8) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), 0)
}
