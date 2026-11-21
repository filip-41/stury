package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// JSON's walk, the one pass over a text that `validate` and `build` run. Its states are in states.odin, and the leaves
// they read tokens with in strings.odin, scalars.odin, whitespace.odin and members.odin.

// Open levels a walk keeps in its own frame before its stacks move to the heap.
@(private)
FRAME_DEPTH :: 1024

// A walk's state outside its registers.
@(private)
Walk :: struct($H: typeid) {
	base:   [^]u8,
	hooks:  ^H,
	stack:  [^]u32, // per open level, its parent's close bracket in the low byte and gap slot above, restored at its close
	regs:   ^tape.Hook_Regs, // the hook's registers where the walk ended
	depth:  u64, // levels `stack` and the hook hold
	limit:  u64, // `Budget.depth`
	resume: [^]u8, // where a string's first escape is, from the state that found it
	gap_lo: u64, // where the gap being read started
	gaps:   Gaps,
	owned:  bool, // `stack` is on the heap
	tier:   kernel.Tier,
}

// The kernel tier the states are built for. The floor, as the walk's 16-byte reads gain nothing from a wider tier.
@(private)
STATE_TIER :: kernel.Tier(0)

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// The result of walking the root value at `p`, past white space.
@(private)
walk_value :: #force_inline proc "contextless" (src: []u8, p: [^]u8, limit: u64, h: ^$H, regs: ^tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	stack: [FRAME_DEPTH]u32 = ---
	// Left unzeroed, as `gap_new_row` zeroes each row it makes.
	w: Walk(H) = ---
	w.base, w.hooks, w.stack, w.regs, w.limit, w.owned = raw_data(src), h, raw_data(stack[:]), regs, limit, false
	when ODIN_ARCH == .amd64 {
		w.tier = kernel.tier()
	}
	w.depth = held_depth(h, regs, min(limit, FRAME_DEPTH))
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
	when H == build.Builder {
		return min(room, u64(len(h.stack)) - regs.c)
	} else {
		return room
	}
}

when .Address in ODIN_SANITIZER_FLAGS {
	@(private)
	enter :: #force_no_inline proc "contextless" (p, end: [^]u8, w: ^Walk($H), hs: tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
		return st_value(p, end, 0, INDENT_START, w, hs.a, hs.b, hs.c, 0, GAPS, on)
	}
} else {
	@(private)
	enter :: #force_inline proc "contextless" (p, end: [^]u8, w: ^Walk($H), hs: tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
		return st_value(p, end, 0, INDENT_START, w, hs.a, hs.b, hs.c, 0, GAPS, on)
	}
}

@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, kind: tape.Kind, role: tape.Role, p, q: [^]u8, spelling: u16) -> tape.Action {
	a: tape.Action
	hs^, a = on(w.hooks, hs^, tape.Token{at(w, p), u32(intrinsics.ptr_sub(q, p)), kind, role, spelling})
	return a
}

// Emits the string whose opening quote is at `p` and that ends at `q`, one past its closing quote. Its token spans the
// bytes between the quotes.
@(private)
emit_string :: #force_inline proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, role: tape.Role, p, q: [^]u8, spelling: u16) -> tape.Action {
	return emit(w, on, hs, .String, role, p[1:], q[-1:], spelling | tape.SPELLING_QUOTED)
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($H), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

// Doubles the levels the walk and its hook hold, up to `limit`. Returns 0, or the outcome when the limit is reached or
// memory is refused.
@(private, cold)
deepen :: #force_no_inline proc "contextless" (w: ^Walk($H)) -> u8 {
	if w.depth >= w.limit {
		return tape.WALK_TOO_DEEP
	}
	want := min(w.limit, max(2 * w.depth, 16))
	when H == build.Builder {
		if !build.builder_deepen(w.hooks, int(want) + len(w.hooks.stack) - int(w.depth)) {
			return tape.WALK_NO_MEMORY
		}
	}
	size := int(want) * size_of(u32)
	stack := runtime.heap_resize(w.stack, size) if w.owned else runtime.heap_alloc(size, false)
	if stack == nil {
		return tape.WALK_NO_MEMORY
	}
	if !w.owned {
		intrinsics.mem_copy_non_overlapping(stack, w.stack, int(w.depth) * size_of(u32))
	}
	w.stack, w.owned, w.depth = ([^]u32)(stack), true, want
	return 0
}

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($H), hs: tape.Hook_Regs, p: [^]u8, kind: tape.Fault_Kind) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), u8(kind))
}

// The result `deepen` gave at the bracket `p`.
@(private, cold)
too_deep :: #force_no_inline proc "contextless" (w: ^Walk($H), hs: tape.Hook_Regs, p: [^]u8, outcome: u8) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), outcome)
}

@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($H), hs: tape.Hook_Regs, p: [^]u8) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), tape.WALK_STOPPED)
}

// The walk's result for a root value that ends at `p`.
@(private)
done :: #force_inline proc "contextless" (w: ^Walk($H), hs: tape.Hook_Regs, p: [^]u8) -> tape.Walk_Result {
	w.regs^ = hs
	return tape.walk_result(at(w, p), 0)
}
