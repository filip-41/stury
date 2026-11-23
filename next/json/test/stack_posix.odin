#+build darwin, linux, freebsd, openbsd, netbsd
package json_tests

import "base:runtime"
import "core:sys/posix"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The stack a thread spends before its first read, on its start and the job's call.
THREAD_START :: 16 * 1024

Stack_Job :: struct {
	ctx:  runtime.Context,
	read: int,
	text: []u8,
	ok:   bool,
}

stack_job :: proc "c" (arg: rawptr) -> rawptr {
	job := (^Stack_Job)(arg)
	context = job.ctx
	opts := json.Options{budget = {depth = 200_000}}
	switch job.read {
	case 0:
		job.ok = json.validate(job.text, opts = opts) == nil
	case 1:
		doc, err := json.build(job.text, opts = opts)
		job.ok = err == nil
		tape.destroy(&doc)
	case 2:
		answer, err := json.find(job.text, {tape.Index(-2)}, opts = opts)
		job.ok = err == nil && answer.outcome == .Found
	case 3:
		d, _ := tape.demand_of({{tape.Index(-2)}, {tape.All{}}})
		r, err := json.scan(job.text, &d, opts = opts)
		job.ok = err == nil && answered(&r) == 3
		tape.destroy(&r)
		tape.destroy(&d)
	}
	return nil
}

// Runs each read on a thread of `stack` bytes over a text nesting `depth` levels, and a value in it read again. A
// `stack` below the system's least thread stack (128 KiB on Linux arm64) is raised to it.
expect_reads_on_thread :: proc(t: ^testing.T, stack: uint, depth: int) {
	size := stack
	if least := posix.sysconf(._THREAD_STACK_MIN); least > 0 {
		size = max(size, uint(least))
	}
	attr: posix.pthread_attr_t
	posix.pthread_attr_init(&attr)
	defer posix.pthread_attr_destroy(&attr)
	testing.expect_value(t, posix.pthread_attr_setstacksize(&attr, size), posix.Errno.NONE)
	for objects in ([]bool{false, true}) {
		text := transmute([]u8)nested_in_root(depth, objects)
		for read in 0 ..< 4 {
			job := Stack_Job{context, read, text, false}
			thread: posix.pthread_t
			testing.expect_value(t, posix.pthread_create(&thread, &attr, stack_job, &job), posix.Errno.NONE)
			posix.pthread_join(thread, nil)
			testing.expectf(t, job.ok, "read %d objects %v depth %d stack %d", read, objects, depth, size)
		}
	}
}

// Each read runs on a thread with the stack it states, over a text nesting past the frame and a value read again.
@(test)
reads_run_in_the_stack_they_state :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_reads_on_thread(t, json.READ_STACK + THREAD_START, 4 * json.WALK_LEVELS)
}

// A thread of one MiB reads a text of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack. The makefile runs it at every optimization level, as a frame's size depends on it.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_reads_on_thread(t, 1 << 20, 100_000)
}
