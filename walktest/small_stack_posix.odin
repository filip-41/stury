#+build !windows
package walktest

import "core:testing"
import "core:sys/posix"

// Runs `work` on a thread of `SMALL_STACK` bytes and waits for it. `core:thread` takes the stack size the platform
// gives, so the thread is made here.
on_small_stack :: proc(t: ^testing.T, work: proc(t: ^testing.T)) {
	run :: proc "c" (data: rawptr) -> rawptr {
		job := (^Small_Stack_Work)(data)
		context = job.ctx
		job.work(job.t)
		return nil
	}
	job := Small_Stack_Work{t, context, work}
	attr: posix.pthread_attr_t
	posix.pthread_attr_init(&attr)
	defer posix.pthread_attr_destroy(&attr)
	if !testing.expect(t, posix.pthread_attr_setstacksize(&attr, SMALL_STACK) == .NONE, "the stack size is taken") {
		return
	}
	th: posix.pthread_t
	if !testing.expect(t, posix.pthread_create(&th, &attr, run, &job) == .NONE, "the thread starts") {
		return
	}
	posix.pthread_join(th)
}
