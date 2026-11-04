// Threads kept between parallel calls, for the procedures that take a `core.Runner`.
package host

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import core "../core"

// Helper threads kept between calls, so a caller that makes many pays for starting them once. Pass `&pool.runner`.
//
//	- Helpers spin briefly after a call, when the calls come close together, then sleep.
//	- The caller owns the pool: `pool_init` starts the threads and `pool_destroy` joins them. It must not move
//	  between the two, and runs one call at a time.
Pool :: struct {
	runner:      core.Runner,
	helpers:     []Helper,
	// Helpers whose thread has been started or refused.
	settled:     int,
	// The current call, and how many helpers it was handed to.
	task:        proc(arg: rawptr),
	arg:         rawptr,
	handed:      int,
	// Handed helpers that have not returned or been taken back.
	pending:     int,
	// How many helpers each recent task gets, and when the current call started.
	widths:      [4]Width,
	current:     ^Width,
	began:       time.Tick,
	// When the last call finished, and whether idle helpers spin before they sleep: until the first call, and after
	// a call that came within `SPIN` of the one before.
	ended:       time.Tick,
	spin:        bool,
	// How many tasks are in a write (`writing`).
	in_write:    int,
}

// Tell the pool a task is (`on`) or is no longer in a write that may block on its reader, so that `finish` sleeps
// rather than yields for it once it has waited `STALL`.
writing :: proc(pool: ^Pool, on: bool) {
	sync.atomic_add(&pool.in_write, 1 if on else -1)
}

// A helper that has taken a task can still lose its core to another process, and the caller then waits for it. On
// a loaded host that wait outgrows what the extra helpers save. So each task's width shrinks by a quarter when the
// wait is over a quarter of the call, and grows by one after `CALM` calls in a row where it is under an eighth.
@(private)
Width :: struct {
	task:  proc(arg: rawptr),
	width: int,
	calm:  int,
}

@(private)
CALM :: 16
@(private)
WAIT_HIGH :: 4
@(private)
WAIT_LOW :: 8
@(private)
SHRINK :: 4

// How many looks `finish` spins for the helpers before it yields.
@(private)
FINISH_SPINS :: 64

// How long an idle helper spins before it sleeps: a sleeping thread takes longer to wake than a small call takes
// to run.
@(private)
SPIN :: 200 * time.Microsecond

// How long `finish` must have waited, with a helper in a write, before it sleeps in place of yielding: a
// compute-bound call ends sooner, and a write to a reader that lags lasts longer.
@(private)
STALL :: 1 * time.Millisecond

// How long `finish` sleeps between looks once it stalls on a write.
@(private)
FINISH_NAP :: 50 * time.Microsecond

@(private)
Helper :: struct {
	thread: ^thread.Thread,
	pool:   ^Pool,
	index:  int,
	ready:  sync.Futex,
}

// A helper's `ready`: parked, handed the pool's task, running it, or handed one `finish` took back before the
// helper woke.
@(private)
IDLE :: 0
@(private)
HANDED :: 1
@(private)
TAKEN :: 2
@(private)
REVOKED :: 3

// Start `workers - 1` parked threads (`workers <= 0` means one per core, the caller counted). A failed allocation
// returns its error and leaves a pool that runs calls on the caller alone.
//
//	- The caller starts two threads and each helper starts two more, so the caller does not wait for every start,
//	  and a call may begin before every helper has. A helper handed a call before it starts takes it as it starts.
//	- A helper the system refuses never runs: a call handed to it is taken back by `finish`.
//	- A pool with none still runs calls, on the caller alone.
pool_init :: proc(pool: ^Pool, workers := 0) -> runtime.Allocator_Error {
	pool^ = {runner = {data = pool, start = start, finish = finish}, spin = true}
	w := workers > 0 ? workers : os.get_processor_core_count()
	pool.helpers = make([]Helper, max(w - 1, 0), runtime.heap_allocator()) or_return
	pool.runner.threads = len(pool.helpers)
	for &h, i in pool.helpers {
		h = {pool = pool, index = i}
	}
	spawn_children(pool, -1)
	return nil
}

// Start helper `index`'s two children in the tree that also wakes them, `index` -1 being the caller, and the
// children of one the system refuses.
@(private)
spawn_children :: proc(pool: ^Pool, index: int) {
	// The pool's own bookkeeping is heap-owned, never the caller's arena.
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

// Stop the helper threads and free what `pool_init` allocated. Call it once, after the last call has returned.
// The pool is not usable afterwards.
pool_destroy :: proc(pool: ^Pool) {
	// Until every start has been tried, a helper's `thread` may not yet tell whether it runs.
	for sync.atomic_load(&pool.settled) < len(pool.helpers) {
		thread.yield()
	}
	pool.task = nil
	// Each helper counts itself out as it stops.
	live := 0
	for h in pool.helpers {
		live += int(h.thread != nil)
	}
	sync.atomic_store(&pool.pending, live)
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
	assert(pool.pending == 0)
	delete(pool.helpers, runtime.heap_allocator())
	pool^ = {}
}

// Hand the task to the first `n` helpers, none for a negative `n`, then wake two. Each helper wakes two more once it starts, so the caller
// pays for two wakes, not one per helper.
@(private)
start :: proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {
	pool := (^Pool)(data)
	pool.began = time.tick_now()
	sync.atomic_store(&pool.spin, pool.ended != {} && time.tick_diff(pool.ended, pool.began) < SPIN)
	pool.task, pool.arg = task, arg
	pool.current = width_of(pool, task)
	pool.handed = clamp(n, 0, pool.current.width)
	sync.atomic_store(&pool.pending, pool.handed)
	for &h in pool.helpers[:pool.handed] {
		sync.atomic_store(&h.ready, HANDED)
	}
	for &h in pool.helpers[:min(2, pool.handed)] {
		sync.futex_signal(&h.ready)
	}
}

// Take back every handed task a helper has not started, since waiting for it to wake would cost more than the
// call, then wait for the rest and adapt the width to how long that took.
@(private)
finish :: proc(data: rawptr) {
	pool := (^Pool)(data)
	for &h in pool.helpers[:pool.handed] {
		if _, took := sync.atomic_compare_exchange_strong(&h.ready, HANDED, REVOKED); took {
			sync.atomic_sub(&pool.pending, 1)
		}
	}
	waited := time.tick_now()
	wait_done(pool, waited)
	adapt_width(pool, time.tick_since(pool.began), time.tick_since(waited))
	pool.ended = time.tick_now()
}

// Wait until no handed task is pending: spin first, then yield, and sleep once a helper stalls on a write.
@(private)
wait_done :: proc(pool: ^Pool, waited: time.Tick) {
	for spins := 0; sync.atomic_load(&pool.pending) > 0; spins += 1 {
		if spins < FINISH_SPINS {
			intrinsics.cpu_relax()
		} else if sync.atomic_load(&pool.in_write) > 0 && time.tick_since(waited) > STALL {
			// A helper still writing after this long waits on the reader (a full pipe), not on a core:
			// yielding would burn one for as long as the reader takes.
			time.sleep(FINISH_NAP)
		} else {
			thread.yield()
		}
	}
}

// Shrink the current task's width when the call spent too long in `wait` of its `span`, and grow it after `CALM`
// calm calls in a row.
@(private)
adapt_width :: proc(pool: ^Pool, span, wait: time.Duration) {
	// A call the caller held below the width says nothing about it. A width of none has nothing to shrink: below
	// none, the next call hands out a negative count of helpers.
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

// The width `task` has learned, or a fresh one, all helpers wide, in place of the oldest.
@(private)
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

@(private)
helper_main :: proc(t: ^thread.Thread) {
	h := (^Helper)(t.data)
	pool := h.pool
	spawn_children(pool, h.index)
	for {
		switch sync.atomic_load(&h.ready) {
		case IDLE:
			park(&h.ready, sync.atomic_load(&pool.spin))
			continue
		case REVOKED:
			sync.atomic_compare_exchange_strong(&h.ready, REVOKED, IDLE)
			continue
		}
		if _, took := sync.atomic_compare_exchange_strong(&h.ready, HANDED, TAKEN); !took {
			continue
		}
		if pool.task == nil {
			sync.atomic_sub(&pool.pending, 1)
			return
		}
		for j in 2 * h.index + 2 ..< min(2 * h.index + 4, pool.handed) {
			kid := &pool.helpers[j]
			if sync.atomic_load(&kid.ready) == HANDED {
				sync.futex_signal(&kid.ready)
			}
		}
		pool.task(pool.arg)
		// Parked before it counts as done, so the next `start` cannot hand it a task this overwrites.
		sync.atomic_store(&h.ready, IDLE)
		sync.atomic_sub(&pool.pending, 1)
	}
}

// Wait for `ready` to leave `IDLE`: spin for `SPIN` first when `spin`, then sleep.
@(private)
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
