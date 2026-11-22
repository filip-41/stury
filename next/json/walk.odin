package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// JSON's walk, the one pass over a text that `validate` and `build` run. Its states are in states.odin, and the leaves
// they read tokens with in strings.odin, scalars.odin, whitespace.odin and members.odin.

// Open levels a read keeps in its frame. A deeper text moves them to memory from the read's allocator, so a `validate`
// within this depth allocates nothing.
WALK_LEVELS :: 1024

// Open levels a walk read again keeps in its frame, which is small as it borrows the walk it runs in.
@(private)
REWALK_LEVELS :: 64

// The most levels a walk holds, whose bytes an `int` counts.
@(private)
MAX_LEVELS :: u64(max(int) / size_of(u32))

// The bytes of a walk's frame, its open levels and its state. A replay's frame holds `REWALK_LEVELS` levels and no
// state.
#assert(size_of(Walk(.Json, hook.No_Hooks, false, hook.NO_HOOKS_CAPS)) + WALK_LEVELS * size_of(u32) <= 24 * 1024)

// The stack each read needs below its caller's frame, from its entry to its deepest call, with room for an allocator's
// calls. A thread with less faults on its guard page, as a read first reads this much of it a page at a time.
READ_STACK :: 48 * 1024

// The distance between the stack probe's reads, a guard page at the least: a page of 16 KiB on arm64 macOS, else 4 KiB.
@(private)
STACK_PAGE :: 16 * 1024 when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else 4 * 1024

#assert(READ_STACK % STACK_PAGE == 0)

// A walk's state outside its registers, for hook type `H` of capabilities `C`, its protocol's. A walk with `LAX` reads
// the rules of `tolerate` as taken, counts its containers within `Budget.steps` and reads a text in pieces, and one
// without refuses every rule, counts nothing and reads a whole text, with none of these in its code.
@(private)
Walk :: struct($S: Spec, $H: typeid, $LAX: bool, $C: hook.Capabilities) {
	base:      [^]u8,
	// The address one past the hook's room for nodes, for a hook with `.Rooms`, beside `base` as a token reads
	// both.
	rooms:     uintptr,
	hooks:     ^H,
	stack:     [^]u32, // per open level, its parent's close bracket in the low byte and gap slot above, restored at its close
	regs:      ^hook.Regs, // the hook's registers where the walk ended
	resume:    [^]u8, // where a string's first escape is, from the state that found it
	allocator: runtime.Allocator, // what `stack` grows in past the frame's levels
	depth:     u64, // levels `stack` and the hook hold
	limit:     u64, // `Budget.depth`
	room:      u64, // levels `stack` holds
	gap_lo:    u64, // where the gap being read started
	grow:      u64, // where the token that found the hook's room full starts
	gaps:      Gaps,
	owned:     bool, // `stack` is the allocator's
	tier:      kernel.Tier,
	tolerate:  tape.Tolerances, // set only with `LAX`
	tolerated: bool, // with `LAX`, the walk took a rule of `tolerate`
	rested:    bool, // with `.Skips`, the hook answered `Rest`, so the root's foot comments are not its
	// Leaves no gap, as Odin zeroes a struct with one that is declared `---`. The fields before `depth` are eight
	// pointers.
	_:         [3]u8,
	// With `LAX`, one more than the containers the walk may still open, 0 once it opened one past `Budget.steps`.
	steps:     [int(LAX)]u64,
	ctx:       ^runtime.Context, // the caller's, for the calls of `allocator`, nil only when the frame's levels suffice
	// With `LAX`, the text in pieces the walk reads a window of, nil for a whole text.
	piece:     [int(LAX)]^Piece_Walk,
}

// The kernel tier the states are built for. The floor, as the walk's 16-byte reads gain nothing from a wider tier.
@(private)
STATE_TIER :: kernel.Tier(0)

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// The result of walking the text `src` from its root value at `p`, past white space, with the walk's levels in
// `allocator` past its frame, called in context `ctx`, and whether it took a rule of `tolerate`, which only a walk with
// `LAX` reads. A hook with `.Walk` is given the walk, which its replays borrow. Its offset is where the root value
// ends, unless the walk stopped or faulted.
@(private)
walk_value :: #force_inline proc "contextless" (src: []u8, p: [^]u8, $S: Spec, $LAX: bool, tolerate: tape.Tolerances, limit, steps: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, pw: ^Piece_Walk, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]u32 = ---
	// Left unzeroed, as `gap_new_row` zeroes each row's `child` it makes and `gap_row_live` its slots.
	w: Walk(S, H, LAX, C) = ---
	walk_init(&w, src, raw_data(stack[:]), h, regs, allocator, ctx, limit, tolerate, steps)
	w.depth = held_depth(h, regs, min(w.limit, WALK_LEVELS))
	when .Walk in C {
		h.walk = &w
	}
	end := raw_data(src)[len(src):]
	r: hook.Walk_Result
	when LAX {
		w.piece[0] = pw
		if pw != nil {
			r = piece_walk(&w, pw, p, end, on)
		} else {
			r = enter(p, end, INDENT_START, &w, regs^, GAP_START, on)
		}
	} else {
		r = enter(p, end, INDENT_START, &w, regs^, GAP_START, on)
	}
	when LAX {
		// A foot read on from a run of comments was judged to the text's end, whose bytes before the window are gone.
		if pw == nil || !pw.foot {
			r = walk_tail(&w, r, end, on)
		}
	} else {
		r = walk_tail(&w, r, end, on)
	}
	when .Walk in C {
		h.walk = nil
	}
	when LAX {
		if u8(r) == hook.WALK_STOPPED && w.steps[0] == 0 {
			r = hook.walk_result(u64(r) >> 16, hook.WALK_STEPS)
		}
		if pw != nil {
			r = piece_end(&w, pw, r)
		}
	}
	if w.owned {
		levels_free(&w)
	}
	return r, w.tolerated when LAX else false
}

// Sets up walk `w` of `src` with its levels in `stack`, past the frame's in `allocator` called in context `ctx`, within
// `limit` levels, and with `LAX` the rules of `tolerate` and `steps` containers. The caller sets its depth.
@(private)
walk_init :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), src: []u8, stack: [^]u32, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, limit: u64, tolerate: tape.Tolerances, steps: u64) {
	w.base, w.hooks, w.stack, w.regs, w.allocator, w.ctx = raw_data(src), h, stack, regs, allocator, ctx
	w.limit, w.room, w.owned = min(limit, MAX_LEVELS), WALK_LEVELS, false
	when ODIN_ARCH == .amd64 {
		w.tier = kernel.tier()
	}
	when .Skips in C {
		w.rested = false
	}
	when LAX {
		w.tolerate, w.tolerated = tolerate, false
		w.steps[0] = steps + 1 if steps != 0 && steps < max(u64) else max(u64)
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	w.gaps.rows, w.gaps.live, w.gaps.misses = 1, 0, 0
	intrinsics.mem_zero(&w.gaps.child[0], GAP_MEMBERS)
}

// The walk's result `r` once what follows a root value that ended before `end` is judged.
@(private)
walk_tail :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), r: hook.Walk_Result, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	if u8(r) == 0 {
		if q := kernel.skip_ws(w.base[u64(r) >> 16:], end); q != end {
			return root_tail(w, w.base[u64(r) >> 16:], q, end, on)
		}
	}
	return r
}

// The result for what follows the root value that ends at `p`, past the white space up to `q`. In a spec past RFC 8259
// its comments are emitted once judged, those on the root's line inline and the rest as its foot.
@(private, cold)
root_tail :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, q, end: [^]u8, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	hs := w.regs^
	when LAX {
		if w.piece[0] != nil && w.piece[0].more {
			return piece_tail(w, p, q, end, on)
		}
	}
	when S != .Json {
		if opens_run(q, end, S) {
			r, _, kind := comment_run(q, end, false, S)
			if kind != .None {
				return fault(w, hs, r, kind)
			}
			if r < end {
				return fault(w, hs, r, .Bad_Char)
			}
			when H != hook.No_Hooks {
				when .Skips in C {
					if w.rested {
						return done(w, hs, p)
					}
				}
				// A comment is a fact, which takes no room, so its token answers no `Grow`.
				if last, stop := emit_comments(w, on, &hs, p, end, true, .Comment_Foot); stop {
					return stopped(w, hs, last)
				}
			}
			return done(w, hs, p)
		}
	}
	return fault(w, hs, q, .Bad_Char)
}

// The result of walking the value at `lo` of `src` again for the hook of walk `w`, from the hook's registers `regs`,
// inside one of the hook's calls. The first walk judged the value within its depth limit. It reads in `w`, with levels
// of its own and no gaps, and leaves `w` as it found it. Its hook has no `.Rooms`.
@(private)
walk_again :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	#assert(.Rooms not_in C)
	levels: [REWALK_LEVELS]u32 = ---
	stack, wregs, resume, depth, limit, room, gap_lo, grow, owned := w.stack, w.regs, w.resume, w.depth, w.limit, w.room, w.gap_lo, w.grow, w.owned
	w.stack, w.regs, w.limit, w.room, w.owned = raw_data(levels[:]), regs, MAX_LEVELS, REWALK_LEVELS, false
	w.depth = held_depth(w.hooks, regs, REWALK_LEVELS)
	r := enter(raw_data(src)[lo:], raw_data(src)[len(src):], INDENT_START, w, regs^, GAP_OFF, on)
	if w.owned {
		levels_free(w)
	}
	w.stack, w.regs, w.resume, w.depth, w.limit, w.room, w.gap_lo, w.grow, w.owned = stack, wregs, resume, depth, limit, room, gap_lo, grow, owned
	return r
}

// Reads the `READ_STACK` bytes below the stack pointer a page at a time from the top, so that on a thread with less
// stack the read faults on its guard page before its frames are written past it. WebAssembly's shadow stack has no
// guard page and traps at its base, which the frame alone reaches, so the probe reads nothing there.
@(private, no_sanitize_address)
probe_stack :: #force_no_inline proc "contextless" () {
	when ODIN_ARCH != .wasm32 && ODIN_ARCH != .wasm64p32 {
		sp := uintptr(intrinsics.stack_pointer())
		for k := uintptr(STACK_PAGE); k <= READ_STACK; k += STACK_PAGE {
			_ = intrinsics.volatile_load((^u8)(sp - k))
		}
	}
}

// The open levels the hook has room for, at most `room`.
@(private)
held_depth :: #force_inline proc "contextless" (h: ^$H, regs: ^hook.Regs, room: u64) -> u64 {
	when .Levels in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0) {
		return min(room, u64(hook.levels_held(h)) - regs.c)
	} else {
		return room
	}
}

// Enters the walk at the value at `p`, at the indent and gap slot of the level it starts in. A call from a frame with a
// base pointer to a "preserve/none" state is wrong on arm64, as LLVM keeps the base pointer in x19, which the state
// does not preserve. The sanitizer's frames of `walk_value`, `pass_over` and `keep_through` have one, so in its builds
// this is a call of its own, whose frame has none.
when .Address in ODIN_SANITIZER_FLAGS {
	@(private)
	enter :: #force_no_inline proc "contextless" (p, end: [^]u8, ind: u64, w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
		return st_value(p, end, 0, ind, w, hs.a, hs.b, hs.c, m, on)
	}
} else {
	@(private)
	enter :: #force_inline proc "contextless" (p, end: [^]u8, ind: u64, w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
		return st_value(p, end, 0, ind, w, hs.a, hs.b, hs.c, m, on)
	}
}

// `enter` past a comma in the container `d` names, as a walk of a seam starts.
when .Address in ODIN_SANITIZER_FLAGS {
	@(private)
	enter_member :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
		return st_member_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
} else {
	@(private)
	enter_member :: #force_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, m: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
		return st_member_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, on)
	}
}

// Judges the container at `p`, opened in the level `d` names with gap slot `m`, with no hooks, as the root of the same
// walk read as one with `No_Hooks` whose stack starts at that level. It learns into and predicts from the walk's own
// gaps and indent. Its result's offset is where the container ends, as a walk's root ends with no look at what follows
// it. It is a call because `#must_tail` cannot jump between walks.
@(private, cold)
pass_over :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8, d, ind: u64, hs: hook.Regs, m: u64) -> hook.Walk_Result {
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS)))
	when LAX {
		w.steps[0] += 1 // the container's step, taken again as its bracket is read again
	}
	slot := d >> 1
	stack, depth, limit, room, owned := w.stack, w.depth, w.limit, w.room, w.owned
	w.stack, w.depth, w.limit, w.room, w.owned = stack[slot:], depth - slot, limit - slot, room - slot, false
	r := enter(p, end, ind, (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w), hs, m, hook.no_hook)
	if w.owned {
		levels_free(w)
	}
	w.stack, w.depth, w.limit, w.room, w.owned = stack, depth, limit, room, owned
	return r
}

// Stores the container at `p` through the inner hook of the hook's `Keeps`, with its `Stubs` under `STUBS` and else its
// `Whole`, in the same walk read as one of the inner hook, as `pass_over` judges one. `hs` are the hook's registers,
// which leave it past the container.
@(private)
keep_over :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8, d, ind: u64, hs: ^hook.Regs, m: u64, $STUBS: bool) -> hook.Walk_Result {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
	Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
	when STUBS {
		return keep_through(Inner, intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 3), w, p, end, d, ind, hs, m)
	} else {
		return keep_through(Inner, intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 2), w, p, end, d, ind, hs, m)
	}
}

// The inner walk reads the inner hook's room when it starts, and the walk the hook's room when it ends, as a hook with
// `.Rooms` is given a node only while its room has place for it, in every walk.
@(private)
keep_through :: #force_no_inline proc "contextless" ($Inner: typeid, $of: proc "contextless" (h: rawptr) -> rawptr, $keep: proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8, d, ind: u64, hs: ^hook.Regs, m: u64) -> hook.Walk_Result {
	IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
	#assert(size_of(Walk(S, H, LAX, C)) == size_of(Walk(S, Inner, LAX, IC)))
	on :: #force_inline proc "contextless" (h: ^Inner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
		return keep(h, s, t)
	}
	inner := (^Walk(S, Inner, LAX, IC))(w)
	hooks := w.hooks
	slot := d >> 1
	stack, depth, limit, room, owned := w.stack, w.depth, w.limit, w.room, w.owned
	w.stack, w.depth, w.limit, w.room, w.owned = stack[slot:], depth - slot, limit - slot, room - slot, false
	inner.hooks = (^Inner)(of(hooks))
	when LAX {
		w.steps[0] += 1 // the container's step, taken again as its bracket is read again
	}
	when .Rooms in IC {
		w.rooms = hook.rooms_end(inner.hooks)
	}
	r := enter(p, end, ind, inner, hs^, m, on)
	hs^ = w.regs^
	if w.owned {
		levels_free(w)
	}
	w.hooks = hooks
	when .Rooms in C {
		w.rooms = hook.rooms_end(hooks)
	}
	w.stack, w.depth, w.limit, w.room, w.owned = stack, depth, limit, room, owned
	return r
}

// Gives the hook the token from `p` to `q`, or answers `Grow` for a node the hook's room has no place for.
@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, kind: tape.Kind, role: tape.Role, p, q: [^]u8, spelling: u16) -> hook.Action {
	return emit_token(w, on, hs, tape.Token{at(w, p), u32(intrinsics.ptr_sub(q, p)), kind, role, spelling})
}

@(private)
emit_token :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, t: tape.Token) -> hook.Action {
	when .Rooms in C {
		if t.kind != .End && t.role <= .Key && uintptr(hs.a) == w.rooms && !piece_passes(w) {
			w.grow = t.lo
			return .Grow
		}
	}
	return give(w, on, hs, t)
}

// Gives the hook token `t`, for which the hook's room has place. A walk with `LAX` takes a step of `Budget.steps` per
// container, and stops at the first past it with no token.
@(private)
give :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, t: tape.Token) -> hook.Action {
	when LAX {
		if w.piece[0] != nil {
			return give_piece(w, w.piece[0], on, hs, t)
		}
		if t.kind > .Plain && t.kind != .End {
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				return .Stop
			}
		}
	}
	a: hook.Action
	hs^, a = on(w.hooks, hs^, t)
	return a
}

// Whether `emit` answered `Grow`, which it gives only for a hook with `.Rooms`.
@(private)
grows :: #force_inline proc "contextless" ($C: hook.Capabilities, a: hook.Action) -> bool {
	when .Rooms in C {
		return a == .Grow
	} else {
		return false
	}
}

// Grows the hook's room after `Grow`, or returns false.
@(private)
grow_room :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs) -> bool {
	when LAX && .Keeps in C {
		if piece_keeps(w) {
			return piece_grow_inner(w, hs)
		}
	}
	when .Rooms in C {
		if !hook.rooms_grow(w.hooks, hs, w.grow) {
			return false
		}
		w.rooms = hook.rooms_end(w.hooks)
	}
	return true
}

// Emits the string whose opening quote is at `p` and that ends at `q`, one past its closing quote. Its token spans the
// bytes between the quotes.
@(private)
emit_string :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), hs: ^hook.Regs, role: tape.Role, p, q: [^]u8, spelling: u16) -> hook.Action {
	return emit(w, on, hs, .String, role, p[1:], q[-1:], spelling | tape.SPELLING_QUOTED)
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

// Doubles the levels the walk and its hook hold, up to `limit`, at the walk's deepest level with `open` levels open
// in its hook. The walk's own levels move to its allocator only past the `room` of its frame. Returns 0, or the outcome
// when the limit is reached or memory is refused.
@(private, cold)
deepen :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), open: u64) -> u8 {
	if w.depth >= w.limit {
		return hook.WALK_TOO_DEEP
	}
	want := min(w.limit, 2 * w.depth + 1)
	// Each level the walk adds opens one more in the hook at most.
	when .Levels in C {
		if want_held := int(open + want - w.depth); hook.levels_held(w.hooks) < want_held && !hook.levels_grow(w.hooks, want_held) {
			return hook.WALK_NO_MEMORY
		}
	}
	if want > w.room && !levels_room(w, want) {
		return hook.WALK_NO_MEMORY
	}
	w.depth = want
	return 0
}

// Moves the walk's levels to a block of its allocator that holds `want` of them, or returns false.
@(private, cold)
levels_room :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), want: u64) -> bool {
	{
		context = w.ctx^
		size := int(want) * size_of(u32)
		stack: []u8
		err: runtime.Allocator_Error
		if w.owned {
			stack, err = runtime.non_zero_mem_resize(w.stack, int(w.room) * size_of(u32), size, align_of(u32), w.allocator)
		} else {
			stack, err = runtime.mem_alloc_non_zeroed(size, align_of(u32), w.allocator)
		}
		// A nil allocator gives no memory and no error.
		if err != nil || stack == nil {
			return false
		}
		if !w.owned {
			intrinsics.mem_copy_non_overlapping(raw_data(stack), w.stack, int(w.depth) * size_of(u32))
		}
		w.stack, w.owned, w.room = ([^]u32)(raw_data(stack)), true, want
	}
	return true
}

// Gives the walk's levels back to its allocator.
@(private, cold)
levels_free :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C)) {
	context = w.ctx^
	runtime.mem_free_with_size(w.stack, int(w.room) * size_of(u32), w.allocator)
}

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, p: [^]u8, kind: tape.Fault_Kind) -> hook.Walk_Result {
	w.regs^ = hs
	return hook.walk_result(at(w, p), u8(kind))
}

// The result `deepen` gave at the bracket `p`.
@(private, cold)
too_deep :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, p: [^]u8, outcome: u8) -> hook.Walk_Result {
	w.regs^ = hs
	return hook.walk_result(at(w, p), outcome)
}

@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, p: [^]u8) -> hook.Walk_Result {
	w.regs^ = hs
	return hook.walk_result(at(w, p), hook.WALK_STOPPED)
}

// The walk's result for a root value that ends at `p`.
@(private)
done :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: hook.Regs, p: [^]u8) -> hook.Walk_Result {
	w.regs^ = hs
	return hook.walk_result(at(w, p), 0)
}
