// Threads kept between parallel calls, for the reads that take a `tape.Runner`.
package host

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "stury:lib/core/tape"

// Helper threads kept between calls, so a caller that makes many calls starts the threads once. Pass `&pool.runner`.
//
//	- Helpers spin briefly after a call, when the calls come close together, then sleep.
//	- The caller owns the pool. The first call starts the threads, so a pool that runs no call starts none, and
//	  `pool_destroy` joins them. The pool must not move between `pool_init` and `pool_destroy`, and runs one call at a
//	  time.
Pool :: struct {
	runner:  tape.Runner,
	helpers: []Helper,
	// How many helpers have been started or refused.
	settled: int,
	// The current call, and how many helpers it was handed to.
	task:    proc(arg: rawptr),
	arg:     rawptr,
	handed:  int,
	// Handed helpers that have not returned or been taken back.
	pending: int,
	// How many helpers each recent task gets, and when the current call started.
	widths:  [4]Width,
	current: ^Width,
	began:   time.Tick,
	// When the last call finished, and flags: whether the first non-empty call started helpers, whether idle helpers
	// spin before they sleep (true on the first call and when a call starts within `SPIN` of the previous end), and
	// single-flight active guard.
	ended:   time.Tick,
	spawned: bool,
	spin:    bool,
	active:  bool,
}

// A helper that has taken a task can lose its core to another process, and the caller then waits for it. On a loaded
// host that wait can exceed what the extra helpers save. Each task's width shrinks by a quarter when the wait is over
// a quarter of the call, and grows by one after `CALM` calm calls (reset on shrink).
@(private = "file")
Width :: struct {
	task:  proc(arg: rawptr),
	width: int,
	calm:  int,
}

// How long an idle helper spins before it sleeps: a sleeping thread takes longer to wake than a small call takes
// to run.
@(private = "file")
SPIN :: 200 * time.Microsecond

@(private = "file")
Helper :: struct {
	thread: ^thread.Thread,
	pool:   ^Pool,
	index:  int,
	ready:  sync.Futex,
}

// The states of a helper's `ready`: parked, handed the pool's task, or running it. `finish` sets a helper it takes a
// task back from to `IDLE`.
@(private = "file")
IDLE :: 0
@(private = "file")
HANDED :: 1
@(private = "file")
TAKEN :: 2

// Makes a pool of `workers - 1` helpers (for `workers <= 0`, one worker per core, counting the caller), whose threads
// the first call starts. A failed allocation returns its error and leaves a pool that runs calls on the caller alone.
//
//	- The caller starts two threads and each helper starts two more, so the caller does not wait for every start.
//	  A call may begin before every helper has started. A helper handed a call before it starts takes it when it
//	  starts.
//	- A helper the system refuses never runs: a call handed to it is taken back by `finish`.
//	- A pool with none still runs calls, on the caller alone.
pool_init :: proc(pool: ^Pool, workers := 0) -> runtime.Allocator_Error {
	pool^ = {runner = {data = pool, start = start, finish = finish}}
	w := workers > 0 ? workers : os.get_processor_core_count()
	pool.helpers = make([]Helper, max(w - 1, 0), runtime.heap_allocator()) or_return
	pool.runner.threads = len(pool.helpers)
	for &h, i in pool.helpers {
		h = {pool = pool, index = i}
	}
	return nil
}

// Starts the two children of helper `index` in the tree that also wakes them (`index` -1 is the caller), and the
// children of any child the system refuses to start.
@(private = "file")
spawn_children :: proc(pool: ^Pool, index: int) {
	// The pool allocates from the heap, never from the caller's arena.
	context.allocator = runtime.heap_allocator()
	for &h in pool.helpers[min(2 * index + 2, len(pool.helpers)):min(2 * index + 4, len(pool.helpers))] {
		h.thread = thread.create(helper_main)
		if h.thread != nil {
			h.thread.data = &h
			thread.start(h.thread)
		}
		sync.atomic_add(&pool.settled, 1)
		if h.thread == nil {
			spawn_children(pool, h.index)
		}
	}
}

// Stops the helper threads and frees what `pool_init` allocated. Call it once, after the last call has returned. The
// pool is not usable afterwards.
pool_destroy :: proc(pool: ^Pool) {
	// Until every start has been tried, a helper's `thread` does not show whether it runs.
	for pool.spawned && sync.atomic_load(&pool.settled) < len(pool.helpers) {
		thread.yield()
	}
	pool.task = nil
	for &h in pool.helpers {
		if h.thread != nil {
			sync.atomic_store(&h.ready, HANDED)
			sync.futex_signal(&h.ready)
		}
	}
	for &h in pool.helpers {
		if h.thread != nil {
			thread.destroy(h.thread)
		}
	}
	delete(pool.helpers, runtime.heap_allocator())
	pool^ = {}
}

// Hands the task to the first `n` helpers, none for a negative `n` or a nil task, then wakes two. Each helper wakes
// two more once it starts, so the caller makes two wakes, not one per helper.
@(private = "file")
start :: proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {
	pool := (^Pool)(data)
	assert(!sync.atomic_exchange(&pool.active, true), "host.Pool runs one call at a time")
	pool.began = time.tick_now()
	sync.atomic_store(&pool.spin, pool.ended == {} || time.tick_diff(pool.ended, pool.began) < SPIN)
	pool.task, pool.arg = task, arg
	// A helper that takes a nil task stops, which is how `pool_destroy` ends them.
	if task != nil {
		pool.current = width_of(pool, task)
		pool.handed = clamp(n, 0, pool.current.width)
	} else {
		pool.current = nil
		pool.handed = 0
	}
	sync.atomic_store(&pool.pending, pool.handed)
	for &h in pool.helpers[:pool.handed] {
		sync.atomic_store(&h.ready, HANDED)
	}
	for &h in pool.helpers[:min(2, pool.handed)] {
		sync.futex_signal(&h.ready)
	}
	if !pool.spawned && pool.handed > 0 {
		pool.spawned = true
		spawn_children(pool, -1)
	}
}

// Takes back every handed task whose helper has not started, because waiting for it to wake would cost more than the
// call, then waits for the rest and adapts the width to how long that took.
@(private = "file")
finish :: proc(data: rawptr) {
	FINISH_SPINS :: 64
	pool := (^Pool)(data)
	for &h in pool.helpers[:pool.handed] {
		if _, took := sync.atomic_compare_exchange_strong(&h.ready, HANDED, IDLE); took {
			sync.atomic_sub(&pool.pending, 1)
		}
	}
	waited := time.tick_now()
	for spins := 0; sync.atomic_load(&pool.pending) > 0; spins += 1 {
		if spins < FINISH_SPINS {
			intrinsics.cpu_relax()
		} else {
			thread.yield()
		}
	}
	if pool.current != nil {
		adapt_width(pool, time.tick_since(pool.began), time.tick_since(waited))
	}
	pool.ended = time.tick_now()
	sync.atomic_store(&pool.active, false)
}

// Shrinks the current task's width when the call spent too long in `wait` of its `span`, and grows it after `CALM`
// calm calls (reset on shrink).
@(private = "file")
adapt_width :: proc(pool: ^Pool, span, wait: time.Duration) {
	CALM :: 16
	WAIT_HIGH :: 4
	WAIT_LOW :: 8
	SHRINK :: 4
	// A call that handed fewer helpers than the width says nothing about the width. A width of 0 is not shrunk, since
	// below 0 the next call would hand out a negative count of helpers.
	w := &pool.current.width
	if pool.handed != w^ {
		return
	}
	if wait * WAIT_HIGH > span && w^ > 0 {
		w^ -= max(w^ / SHRINK, 1)
		pool.current.calm = 0
	} else if wait * WAIT_LOW < span {
		pool.current.calm += 1
		if pool.current.calm >= CALM {
			w^ = min(w^ + 1, len(pool.helpers))
			pool.current.calm = 0
		}
	}
}

// The width record of `task`, or a new one, all helpers wide, in place of the oldest of the four.
@(private = "file")
width_of :: proc(pool: ^Pool, task: proc(arg: rawptr)) -> ^Width {
	for &w in pool.widths {
		if w.task == task {
			return &w
		}
	}
	copy(pool.widths[1:], pool.widths[:len(pool.widths) - 1])
	pool.widths[0] = {task = task, width = len(pool.helpers)}
	return &pool.widths[0]
}

@(private = "file")
helper_main :: proc(t: ^thread.Thread) {
	h := (^Helper)(t.data)
	pool := h.pool
	spawn_children(pool, h.index)
	for {
		if sync.atomic_load(&h.ready) == IDLE {
			park(&h.ready, sync.atomic_load(&pool.spin))
		}
		if _, took := sync.atomic_compare_exchange_strong(&h.ready, HANDED, TAKEN); !took {
			continue
		}
		if pool.task == nil {
			return
		}
		for j in 2 * h.index + 2 ..< min(2 * h.index + 4, pool.handed) {
			kid := &pool.helpers[j]
			if sync.atomic_load(&kid.ready) == HANDED {
				sync.futex_signal(&kid.ready)
			}
		}
		pool.task(pool.arg)
		// Set to idle before the helper counts as done, so the next `start` cannot hand it a task that this store
		// overwrites.
		sync.atomic_store(&h.ready, IDLE)
		sync.atomic_sub(&pool.pending, 1)
	}
}

// Waits for `ready` to leave `IDLE`: spins for `SPIN` first when `spin` is set, then sleeps.
@(private = "file")
park :: proc(ready: ^sync.Futex, spin: bool) {
	began := time.tick_now()
	for spins := 0; sync.atomic_load(ready) == IDLE; spins += 1 {
		if spins % 64 == 0 && (!spin || time.tick_since(began) > SPIN) {
			sync.futex_wait(ready, IDLE)
			return
		}
		intrinsics.cpu_relax()
	}
}
