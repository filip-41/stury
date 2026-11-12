package walktest

import "core:testing"
import win "core:sys/windows"

// Runs `work` on a thread of `SMALL_STACK` bytes and waits for it. `core:thread` takes the stack size the platform
// gives, so the thread is made here.
on_small_stack :: proc(t: ^testing.T, work: proc(t: ^testing.T)) {
	run :: proc "system" (data: rawptr) -> win.DWORD {
		job := (^Small_Stack_Work)(data)
		context = job.ctx
		job.work(job.t)
		return 0
	}
	job := Small_Stack_Work{t, context, work}
	h := win.CreateThread(nil, SMALL_STACK, run, &job, win.STACK_SIZE_PARAM_IS_A_RESERVATION, nil)
	if !testing.expect(t, h != nil, "the thread starts") {
		return
	}
	win.WaitForSingleObject(h, win.INFINITE)
	win.CloseHandle(h)
}
