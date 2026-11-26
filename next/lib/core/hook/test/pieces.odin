package hook_test

import "base:runtime"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

// `Open_Level.name` is widened to `int` so open-path offsets never wrap negative at 2 GiB.
#assert(type_of(hook.Open_Level{}.name) == int)

// A failing allocator that lets `allow` allocations/resizes succeed and refuses the next one with `.Out_Of_Memory`.
@(private = "file")
Fail_After :: struct {
	backing: runtime.Allocator,
	allow:   int,
}

@(private = "file")
fail_after_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Fail_After)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.allow <= 0 {
			return nil, .Out_Of_Memory
		}
		f.allow -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
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
	defer tape.destroy_pieces(&p)

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
	fa := Fail_After{backing = context.allocator, allow = 0}
	s.steps_buf.allocator = {fail_after_proc, &fa}
	defer s.steps_buf.allocator = p.allocator

	err := hook.piece_path(&p, src, &fmt)
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, p.open == nil)
}
