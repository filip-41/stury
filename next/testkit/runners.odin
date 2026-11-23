package testkit

import "base:runtime"
import "core:sync"
import "stury:lib/core/tape"

// A runner of `threads` threads that runs no call, so the caller claims every chunk and part, as many as `threads`
// makes, each in turn.
serial_runner :: proc(threads: int) -> tape.Runner {
	return {threads = threads, start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {}, finish = proc(data: rawptr) {}}
}

// An allocator that counts the calls made on a thread other than the one that made it, which a read promises to make
// none from.
Caller_Only :: struct {
	backing: runtime.Allocator,
	caller:  int,
	strays:  int,
}

// The allocator over `backing` that counts into `c` the calls from threads other than the calling one.
caller_only :: proc(c: ^Caller_Only, backing: runtime.Allocator) -> runtime.Allocator {
	c^ = {
		backing = backing,
		caller  = sync.current_thread_id(),
	}
	return {proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
			c := (^Caller_Only)(data)
			if sync.current_thread_id() != c.caller {
				sync.atomic_add(&c.strays, 1)
			}
			return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
		}, c}
}

// The cuts of a text of `n` bytes that give windows of `size` bytes.
cuts_by :: proc(n, size: int) -> []int {
	cuts := make([dynamic]int, context.temp_allocator)
	for k := size; k < n; k += size {
		append(&cuts, k)
	}
	return cuts[:]
}
