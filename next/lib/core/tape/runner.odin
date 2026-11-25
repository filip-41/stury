package tape

// Threads a caller lends to a read, which starts none of its own. A nil `^Runner` means the caller's thread alone.
// `host.Pool` supplies one.
//
//	- `start` runs `task(arg)` as a separate call on each of up to `n` of the `threads`. A call may start late or
//	  not at all.
//	- `finish` returns once no further call will start and every started call has returned.
//	- `start` and `finish` alternate, and both run on the calling thread. A runner runs one call at a time; callers
//	  must not share one concurrently across threads.
Runner :: struct {
	data:    rawptr,
	threads: int,
	start:   proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr),
	finish:  proc(data: rawptr),
}
