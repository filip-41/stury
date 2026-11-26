package hook

import "base:intrinsics"
import "base:runtime"

// The open levels of a walk and its hook, for the walks that keep them in a frame and move them to memory of their own
// allocator once an item nests past it. A walk `W` has the fields `stack` (a pointer to its levels), `depth`, `limit`,
// `room`, `owned`, `allocator`, `ctx`, `hooks` and `rooms`, and reads the capabilities of its hook's protocol.

// The open levels the hook has room for, at most `room`.
held_depth :: #force_inline proc "contextless" (h: ^$H, regs: ^Regs, room: u64) -> u64 {
	when .Levels in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 0) {
		return min(room, u64(levels_held(h)) - regs.c)
	} else {
		return room
	}
}

// Doubles the levels the walk `w` and its hook hold, up to `w.limit`, at the walk's deepest level, with the hook's
// registers `hs` and the text at offset `at`. The hook is made to hold `held` more levels than the walk's new depth. A
// walk with a level in the hook for each of its own passes the levels open in the hook less its depth, and a walk with
// levels the hook has none for, as CBOR's tags, passes the levels open, which asks for at most its depth more than the
// hook needs. The walk's own levels move to its allocator only past the `room` of its frame. Returns 0, or the outcome
// when the limit is reached or memory is refused.
@(cold)
deepen :: #force_no_inline proc "contextless" (w: ^$W, hs: ^Regs, held: int, at: u64) -> u8 {
	if w.depth >= w.limit {
		return WALK_TOO_DEEP
	}
	want := min(w.limit, 2 * w.depth + 1)
	if want > u64(max(int) - max(held, 0)) || !levels_need(w, held + int(want), hs, at) || want > w.room && !levels_room(w, want) {
		return WALK_NO_MEMORY
	}
	w.depth = want
	return 0
}

// Makes the hook of walk `w` hold `want` levels for the container at `at`, with its registers `hs`, and moves the
// walk's `rooms` to the end of the hook's room, which growing the levels may move. False when memory is refused.
levels_need :: #force_inline proc "contextless" (w: ^$W, want: int, hs: ^Regs, at: u64) -> bool {
	H :: intrinsics.type_elem_type(intrinsics.type_field_type(W, "hooks"))
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 0)
	when .Levels in C {
		if levels_held(w.hooks) < want && !levels_grow(w.hooks, want, hs, at) {
			return false
		}
		when .Rooms in C {
			w.rooms = rooms_end(w.hooks)
		}
	}
	return true
}

// The levels of a walk `W` as `levels_scope` found them.
@(private = "file")
Levels_Saved :: struct($Stack: typeid) {
	stack:              Stack,
	depth, limit, room: u64,
	owned:              bool,
}

// Makes walk `w` read in its own levels from level `skip` on, which an inner walk of one item of it takes, and returns
// what `levels_leave` needs to give `w` its levels back.
levels_scope :: #force_inline proc "contextless" (w: ^$W, skip: u64) -> Levels_Saved(intrinsics.type_field_type(W, "stack")) {
	saved := Levels_Saved(intrinsics.type_field_type(W, "stack")){w.stack, w.depth, w.limit, w.room, w.owned}
	w.stack, w.depth, w.limit, w.room, w.owned = w.stack[skip:], w.depth - skip, w.limit - skip, w.room - skip, false
	return saved
}

// Gives `w` the levels `saved` holds, and the memory of the levels it grew since to its allocator.
levels_leave :: #force_inline proc "contextless" (w: ^$W, saved: Levels_Saved($Stack)) {
	if w.owned {
		levels_free(w)
	}
	w.stack, w.depth, w.limit, w.room, w.owned = saved.stack, saved.depth, saved.limit, saved.room, saved.owned
}

// Moves the levels of walk `w` to a block of its allocator that holds `want` of them, or returns false.
@(cold)
levels_room :: #force_no_inline proc "contextless" (w: ^$W, want: u64) -> bool {
	Level :: type_of(w.stack[0])
	if w.ctx == nil || want > u64(max(int) / size_of(Level)) {
		return false
	}
	block := levels_block(w.stack, w.owned, int(w.room) * size_of(Level), int(want) * size_of(Level), align_of(Level), int(w.depth) * size_of(Level), w.allocator, w.ctx)
	if block == nil {
		return false
	}
	w.stack, w.owned, w.room = ([^]Level)(block), true, want
	return true
}

// Gives the levels of walk `w` back to its allocator.
@(cold)
levels_free :: #force_no_inline proc "contextless" (w: ^$W) {
	levels_release(w.stack, int(w.room) * size_of(type_of(w.stack[0])), w.allocator, w.ctx)
}

// Non-generic cold helpers so allocator resize/copy/free code is emitted once across walk specializations.
// The block of `size` bytes in `allocator` that takes the levels of a walk: `old`, a block of `old_size` bytes from the
// allocator, resized when the walk `owned` it, else the `copy` bytes of its frame's levels copied in. Nil when memory
// is refused, and for a nil allocator, which gives no memory and no error.
@(private = "file")
levels_block :: proc "contextless" (old: rawptr, owned: bool, old_size, size, align, copy: int, allocator: runtime.Allocator, ctx: ^runtime.Context) -> rawptr {
	context = ctx^
	block: []u8
	err: runtime.Allocator_Error
	if owned {
		block, err = runtime.non_zero_mem_resize(old, old_size, size, align, allocator)
	} else {
		block, err = runtime.mem_alloc_non_zeroed(size, align, allocator)
	}
	if err != nil || block == nil {
		return nil
	}
	if !owned {
		intrinsics.mem_copy_non_overlapping(raw_data(block), old, copy)
	}
	return raw_data(block)
}

@(private = "file")
levels_release :: proc "contextless" (stack: rawptr, size: int, allocator: runtime.Allocator, ctx: ^runtime.Context) {
	context = ctx^
	runtime.mem_free_with_size(stack, size, allocator)
}

// The distance between the stack probe's reads, a guard page at the least: a page of 16 KiB on arm64 macOS, else 4 KiB.
@(private = "file")
STACK_PAGE :: 16 * 1024 when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else 4 * 1024

// Reads the `BYTES` below the stack pointer a page at a time from the top, so that on a thread with less stack a read
// faults on its guard page before its frames are written past it. WebAssembly's shadow stack has no guard page and
// traps at its base, which the frame alone reaches, so the probe reads nothing there.
@(no_sanitize_address)
probe_stack :: #force_no_inline proc "contextless" ($BYTES: uintptr) {
	#assert(BYTES % STACK_PAGE == 0)
	when ODIN_ARCH != .wasm32 && ODIN_ARCH != .wasm64p32 {
		sp := uintptr(intrinsics.stack_pointer())
		for k := uintptr(STACK_PAGE); k <= BYTES; k += STACK_PAGE {
			_ = intrinsics.volatile_load((^u8)(sp - k))
		}
	}
}
