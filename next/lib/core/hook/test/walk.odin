package hook_test

import "base:runtime"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

// `Open_Level.name` is widened to `int` so open-path offsets never wrap negative at 2 GiB.
#assert(type_of(hook.Open_Level{}.name) == int)

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

// When `piece_path` fails with OOM after an earlier window populated `p.open`, `p.open` is cleared to nil instead of
// dangling into freed `names` or resized `steps_buf`.
@(test)
piece_path_clears_open_on_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("alpha beta gamma")
	fmt := tape.Format{}

	p: tape.Pieces
	p.allocator = context.allocator
	defer tape.destroy(&p)

	s, serr := hook.piece_state(&p, hook.Piece_State)
	testing.expect_value(t, serr, nil)
	s.opened.allocator = p.allocator
	s.names.allocator = p.allocator
	s.steps_buf.allocator = p.allocator

	// Window 1: build a 1-step open path ("alpha"), populating `p.open` and `s.steps_buf`.
	_, aerr := append(&s.opened, hook.Open_Level{
		key    = {lo = 0, n = 5, kind = .String, role = .Key},
		count  = 1,
		name   = -1,
		object = true,
	})
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, hook.piece_path(&p, src, &fmt), nil)
	testing.expect_value(t, len(p.open), 1)
	testing.expect_value(t, p.open[0], tape.Step(tape.Name("alpha")))

	// Window 2: grow `s.opened` past `cap(s.steps_buf)` and fail specifically when `s.steps_buf` tries to grow inside
	// loop 2 (after `names` and `places` succeed and after `s.steps_buf` was cleared and partially written).
	need := cap(s.steps_buf) + 2
	for len(s.opened) < need {
		_, e := append(&s.opened, hook.Open_Level{
			key    = {lo = 6, n = 4, kind = .String, role = .Key},
			count  = 1,
			name   = -1,
			object = true,
		})
		testing.expect_value(t, e, nil)
	}

	// Route `s.steps_buf` through an allocator that immediately refuses growth so loop 2 writes into existing slots
	// and then OOMs on the growth append while `names` is freed by `defer`.
	fa := testkit.Failing{backing = context.allocator, fail_at = 0, sticky = true}
	s.steps_buf.allocator = testkit.failing_allocator(&fa)
	defer s.steps_buf.allocator = p.allocator

	err := hook.piece_path(&p, src, &fmt)
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, p.open == nil)
}
