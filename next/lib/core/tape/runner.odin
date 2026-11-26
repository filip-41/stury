package tape

import "base:intrinsics"

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

// What `fan_each` shares: the next index to claim, the count of them and the argument given to each task.
@(private = "file")
Fan_Each :: struct {
	next, count: int,
	arg:         rawptr,
}

// Runs `task(arg, k)` once for each `k` below `count`, on the calling thread and on the threads of `runner`, each thread
// claiming the next index while any is left. The calls share the work through `arg`. Specializing on `$task` gives each
// workload a distinct trampoline address so `host.Pool` tracks per-task adaptive widths independently.
fan_each :: proc(runner: ^Runner, count: int, $task: proc(arg: rawptr, k: int), arg: rawptr) {
	each := Fan_Each{count = count, arg = arg}
	fan(runner, proc(arg: rawptr) {
			e := (^Fan_Each)(arg)
			for {
				k := intrinsics.atomic_add(&e.next, 1)
				if k >= e.count {
					return
				}
				task(e.arg, k)
			}
		}, &each)
}

// Runs `task(arg)` on the calling thread and on the threads of `runner`, and returns once every call has. The calls
// share the work through `arg`, as only the caller's call is certain to run.
fan :: proc(runner: ^Runner, task: proc(arg: rawptr), arg: rawptr) {
	runner.start(runner.data, runner.threads, task, arg)
	task(arg)
	runner.finish(runner.data)
}
