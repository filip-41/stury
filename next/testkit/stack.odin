#+build darwin, linux, freebsd, openbsd, netbsd
package testkit

import "base:runtime"
import "core:sys/posix"
import "core:testing"

// The stack a thread spends before its first read, on its start and the job's call.
THREAD_START :: 16 * 1024

Stack_Read :: #type proc(read: int, text: []u8) -> bool

@(private)
Stack_Job :: struct {
	ctx:  runtime.Context,
	run:  Stack_Read,
	read: int,
	text: []u8,
	ok:   bool,
}

@(private)
stack_job :: proc "c" (arg: rawptr) -> rawptr {
	job := (^Stack_Job)(arg)
	context = job.ctx
	job.ok = job.run(job.read, job.text)
	return nil
}

// Runs `run(read, text)` for each `read` below `reads`, each on a thread of `stack` bytes, and expects it to give true.
// A `stack` below the system's least thread stack (128 KiB on Linux arm64) is raised to it. `what` names the text in a
// failure.
expect_reads_on_thread :: proc(t: ^testing.T, stack: uint, reads: int, text: []u8, what: string, run: Stack_Read, loc := #caller_location) {
	size := stack
	if least := posix.sysconf(._THREAD_STACK_MIN); least > 0 {
		size = max(size, uint(least))
	}
	attr: posix.pthread_attr_t
	posix.pthread_attr_init(&attr)
	defer posix.pthread_attr_destroy(&attr)
	testing.expect_value(t, posix.pthread_attr_setstacksize(&attr, size), posix.Errno.NONE, loc = loc)
	for read in 0 ..< reads {
		job := Stack_Job{context, run, read, text, false}
		thread: posix.pthread_t
		testing.expect_value(t, posix.pthread_create(&thread, &attr, stack_job, &job), posix.Errno.NONE, loc = loc)
		posix.pthread_join(thread, nil)
		testing.expectf(t, job.ok, "read %d %s stack %d", read, what, size, loc = loc)
	}
}
