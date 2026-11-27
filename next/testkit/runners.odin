package testkit

import "base:runtime"
import "core:fmt"
import "core:sync"
import "stury:lib/core/tape"

// A runner of `threads` threads that runs no call, so the caller claims every chunk and part, as many as `threads`
// makes, each in turn.
serial_runner :: proc(threads: int) -> tape.Runner {
	return {threads = threads, start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {}, finish = proc(data: rawptr) {}}
}

// A serial runner of `threads` threads that counts every `start` call into `starts`.
counting_runner :: proc(threads: int, starts: ^int) -> tape.Runner {
	return {
		data    = starts,
		threads = threads,
		start   = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {
			(^int)(data)^ += 1
		},
		finish  = proc(data: rawptr) {},
	}
}

// Decodes a string of hex byte pairs, ignoring spaces, into `allocator`.
hex :: proc(text: string, allocator := context.temp_allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(text) / 2, allocator)
	hi := -1
	for c in text {
		if c == ' ' || c == '\t' || c == '\n' {
			continue
		}
		v := int(c - '0') if c >= '0' && c <= '9' else int(c - 'a' + 10) if c >= 'a' && c <= 'f' else int(c - 'A' + 10)
		if hi < 0 {
			hi = v
		} else {
			append(&out, u8(hi << 4 | v))
			hi = -1
		}
	}
	return out[:]
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

// The code of `err` a test compares: a fault's rule code, or a word for each other error.
code_of :: proc(err: tape.Error) -> string {
	switch e in err {
	case tape.Fault:
		return tape.fault_rule(e).code
	case tape.Exceeded:
		return fmt.tprintf("exceeded %v", e.kind)
	case tape.Bad_Option:
		return fmt.tprintf("bad option %s", e.option)
	case tape.Piece_Gap:
		return "piece gap"
	case runtime.Allocator_Error:
		return "memory"
	}
	return ""
}
