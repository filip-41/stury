package testkit

import "base:runtime"
import "core:mem"

// An allocator over `backing` that refuses its `fail_at`th allocation, counting from 0, with `.Out_Of_Memory`. A
// negative `fail_at` refuses none. `count` is the allocations asked for, and `failed` whether one was refused, so a
// sweep over `fail_at` ends at the first run that refuses none.
Failing :: struct {
	backing: runtime.Allocator,
	count:   int,
	fail_at: int,
	failed:  bool,
}

failing_allocator :: proc(f: ^Failing) -> runtime.Allocator {
	return {failing_proc, f}
}

@(private)
failing_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Failing)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		f.count += 1
		if f.count - 1 == f.fail_at {
			f.failed = true
			return nil, .Out_Of_Memory
		}
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// What `sweep_failures` found: the runs it made, the allocations it refused, and the runs that ended with a block
// still live or freed twice, the first of them at `first_bad`, -1 when none did.
Sweep :: struct {
	runs, refused, bad: int,
	first_bad:          int,
}

// Runs `read` with a failing allocator over a tracking one for each `fail_at` from 0 up to the first run that refuses
// none. `read` frees what it made.
sweep_failures :: proc(read: proc(data: rawptr, a: runtime.Allocator), data: rawptr, limit := 4000) -> (s: Sweep) {
	s.first_bad = -1
	for n in 0 ..< limit {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		f := Failing{backing = mem.tracking_allocator(&track), fail_at = n}
		read(data, failing_allocator(&f))
		if len(track.allocation_map) != 0 || len(track.bad_free_array) != 0 {
			s.bad += 1
			if s.first_bad < 0 {
				s.first_bad = n
			}
		}
		mem.tracking_allocator_destroy(&track)
		s.runs += 1
		if !f.failed {
			break
		}
		s.refused += 1
	}
	return
}
