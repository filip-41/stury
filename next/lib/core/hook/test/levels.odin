package hook_test

import "base:runtime"
import "core:testing"
import "stury:lib/core/hook"
import "stury:testkit"

@(private = "file")
Dummy_Walk :: struct {
	stack:     [^]u64,
	depth:     u64,
	limit:     u64,
	room:      u64,
	owned:     bool,
	allocator: runtime.Allocator,
	ctx:       ^runtime.Context,
	hooks:     ^hook.No_Hooks,
	rooms:     uintptr,
}

// `levels_room` rejects `want` whose byte size would overflow `int`, and `deepen` rejects `want` whose sum with `held`
// would overflow `int`, both without allocating or wrapping.
@(test)
levels_guards_int_overflow :: proc(t: ^testing.T) {
	testkit.deadline(t)
	ctx := context
	frame: [4]u64
	h: hook.No_Hooks
	w := Dummy_Walk{
		stack     = raw_data(frame[:]),
		depth     = 4,
		limit     = max(u64),
		room      = len(frame),
		allocator = context.allocator,
		ctx       = &ctx,
		hooks     = &h,
	}

	// `levels_room` rejects `want > max(int) / size_of(u64)`.
	too_many := u64(max(int) / size_of(u64)) + 1
	testing.expect(t, !hook.levels_room(&w, too_many))
	testing.expect(t, !w.owned && w.room == len(frame))

	// `deepen` rejects `want > max(int) - held` before `held + int(want)` can wrap.
	regs: hook.Regs
	testing.expect_value(t, hook.deepen(&w, &regs, max(int) - 1, 0), hook.WALK_NO_MEMORY)
	testing.expect_value(t, w.depth, u64(4))
	testing.expect(t, !w.owned)
}
