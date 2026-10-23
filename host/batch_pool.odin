// Threads for the library's parallel procedures, which start none of their own.
package host

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import core_pkg "../core"

// Threads kept between batches, so a caller that runs many pays for starting them once. Pass `&pool.runner`
// to `json.each_record`, `json.validate_records`, `csv.each_record` or `csv.validate`.
//
//	- They spin briefly (200 microseconds) after a batch, then sleep.
//	- The caller owns the pool: `batch_pool_init` starts the threads and `batch_pool_destroy` joins them.
//	- It must not move between the two, and runs one batch at a time.
Batch_Pool :: struct {
	runner:      core_pkg.Batch_Runner,
	helpers:     []Batch_Helper,
	max_helpers: int,
	// The current call, and how many helpers it was handed to.
	task:        proc(arg: rawptr),
	arg:         rawptr,
	handed:      int,
	// Handed helpers that have not returned or been taken back.
	pending:     int,
	// How many helpers each recent task gets, and when the current call started.
	widths:      [4]Batch_Width,
	current:     ^Batch_Width,
	began:       time.Tick,
	// How many tasks are in a write (`batch_writing`).
	writing:     int,
}

// Tell the pool a task is (`on`) or is no longer in a write that may block on its reader, so that `finish`
// sleeps rather than yields for it once it has waited `BATCH_STALL`.
batch_writing :: proc(pool: ^Batch_Pool, on: bool) {
	sync.atomic_add(&pool.writing, 1 if on else -1)
}

// A helper that has taken a task can still lose its core to another process, and the caller then waits for
// it. On a loaded host that wait outgrows what the extra helpers save. So each task's width shrinks by a
// quarter when the wait is over a quarter of the call, and grows by one after `BATCH_CALM` calls in a row
// where it is under an eighth.
@(private)
Batch_Width :: struct {
	task:  proc(arg: rawptr),
	width: int,
	calm:  int,
}

@(private)
BATCH_CALM :: 16

// A call whose wait is over `span / BATCH_WAIT_HIGH` shrinks the width by `width / BATCH_SHRINK`, and one whose
// wait is under `span / BATCH_WAIT_LOW` counts as calm.
@(private)
BATCH_WAIT_HIGH :: 4
@(private)
BATCH_WAIT_LOW :: 8
@(private)
BATCH_SHRINK :: 4

// How many looks `batch_finish` spins for the helpers before it yields.
@(private)
BATCH_FINISH_SPINS :: 64

// How long an idle helper spins before it sleeps: a sleeping thread takes longer to wake than a small batch
// takes to run.
@(private)
BATCH_SPIN :: 200 * time.Microsecond

// How long `finish` must have waited, with a helper in a write, before it sleeps in place of yielding: a
// compute-bound batch ends sooner, and a write to a reader that lags lasts longer.
@(private)
BATCH_STALL :: 1 * time.Millisecond

// How long `batch_finish` sleeps between looks once it stalls on a write.
@(private)
BATCH_FINISH_NAP :: 50 * time.Microsecond

// A thread start slower than this pauses initial helper spawning until calm batches ask for more. The define
// is for the ThreadSanitizer smoke (Makefile), whose loaded host would otherwise stop the pool short of every core.
@(private)
BATCH_START_BUDGET :: time.Duration(#config(BATCH_START_BUDGET_US, 250)) * time.Microsecond

@(private)
Batch_Helper :: struct {
	thread: ^thread.Thread,
	pool:   ^Batch_Pool,
	index:  int,
	ready:  sync.Futex,
}

// A helper's `ready`: parked, handed the pool's task, running it, or handed one `finish` took back before the
// helper woke.
@(private)
BATCH_IDLE :: 0
@(private)
BATCH_HANDED :: 1
@(private)
BATCH_TAKEN :: 2
@(private)
BATCH_REVOKED :: 3

// Start `workers - 1` parked threads (`workers <= 0` means one per core).
//
//	- Fewer start initially when the system refuses one, or when starting one took over
//	  `BATCH_START_BUDGET` (remaining slots are started lazily across calm runs).
//	- A pool with none still runs batches, on the caller alone.
batch_pool_init :: proc(pool: ^Batch_Pool, workers := 0) {
	pool^ = {}
	w := workers > 0 ? workers : os.get_processor_core_count()
	helpers, herr := make([]Batch_Helper, max(w - 1, 0), runtime.heap_allocator())
	if herr != nil {
		return
	}
	pool.helpers = helpers[:0]
	pool.max_helpers = len(helpers)
	for _ in helpers {
		t := time.tick_now()
		if !batch_spawn_one(pool) || time.tick_since(t) > BATCH_START_BUDGET {
			break
		}
	}
	pool.runner = {data = pool, threads = len(pool.helpers), start = batch_start, finish = batch_finish}
}

@(private)
batch_spawn_one :: proc(pool: ^Batch_Pool) -> bool {
	if len(pool.helpers) >= pool.max_helpers {
		return false
	}
	// The pool's own bookkeeping is heap-owned, never the caller's arena. The caller's allocator is back in
	// place on every return.
	prev := context.allocator
	context.allocator = runtime.heap_allocator()
	defer context.allocator = prev
	idx := len(pool.helpers)
	h := &raw_data(pool.helpers)[idx]
	h^ = {pool = pool, index = idx}
	h.thread = thread.create(batch_helper)
	if h.thread == nil {
		return false
	}
	h.thread.data = h
	thread.start(h.thread)
	pool.helpers = raw_data(pool.helpers)[:idx + 1]
	pool.runner.threads = idx + 1
	return true
}

// Stop the pool's helper threads and free what `batch_pool_init` allocated. Call it once, after the last
// batch has returned. The pool is not usable afterwards.
batch_pool_destroy :: proc(pool: ^Batch_Pool) {
	pool.task = nil
	for &h in pool.helpers {
		sync.atomic_store(&h.ready, BATCH_HANDED)
		sync.futex_signal(&h.ready)
	}
	for &h in pool.helpers {
		thread.destroy(h.thread)
	}
	if pool.max_helpers > 0 {
		delete(raw_data(pool.helpers)[:pool.max_helpers], runtime.heap_allocator())
	}
	pool^ = {}
}

// Hand the task to the first `n` helpers, then wake two. Each helper wakes two more once it starts, so the
// caller pays for two wakes, not one per helper.
@(private)
batch_start :: proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {
	pool := (^Batch_Pool)(data)
	pool.began = time.tick_now()
	pool.task, pool.arg = task, arg
	pool.current = batch_width(pool, task)
	pool.handed = min(n, pool.current.width)
	sync.atomic_store(&pool.pending, pool.handed)
	for &h in pool.helpers[:pool.handed] {
		sync.atomic_store(&h.ready, BATCH_HANDED)
	}
	for &h in pool.helpers[:min(2, pool.handed)] {
		sync.futex_signal(&h.ready)
	}
}

// Take back every handed task a helper has not started, since waiting for it to wake would cost more than
// the batch, then wait for the rest and adapt the width to how long that took.
@(private)
batch_finish :: proc(data: rawptr) {
	pool := (^Batch_Pool)(data)
	for &h in pool.helpers[:pool.handed] {
		if _, took := sync.atomic_compare_exchange_strong(&h.ready, BATCH_HANDED, BATCH_REVOKED); took {
			sync.atomic_sub(&pool.pending, 1)
		}
	}
	waited := time.tick_now()
	batch_wait_done(pool, waited)
	batch_adapt_width(pool, time.tick_since(pool.began), time.tick_since(waited))
}

// Wait until no handed task is pending: spin first, then yield, and sleep once a helper stalls on a write.
@(private)
batch_wait_done :: proc(pool: ^Batch_Pool, waited: time.Tick) {
	for spins := 0; sync.atomic_load(&pool.pending) > 0; spins += 1 {
		if spins < BATCH_FINISH_SPINS {
			intrinsics.cpu_relax()
		} else if sync.atomic_load(&pool.writing) > 0 && time.tick_since(waited) > BATCH_STALL {
			// A helper still writing after this long waits on the reader (a full pipe), not on a core:
			// yielding would burn one for as long as the reader takes.
			time.sleep(BATCH_FINISH_NAP)
		} else {
			thread.yield()
		}
	}
}

// Shrink the current task's width when the call spent too long in `wait` of its `span`, and grow it after
// `BATCH_CALM` calm calls in a row.
@(private)
batch_adapt_width :: proc(pool: ^Batch_Pool, span, wait: time.Duration) {
	// A call the caller held below the width says nothing about it. A width of none has nothing to shrink:
	// below none, the next call hands out a negative count of helpers.
	w := &pool.current.width
	if pool.handed != w^ {
		return
	}
	if wait * BATCH_WAIT_HIGH > span && w^ > 0 {
		w^ -= max(w^ / BATCH_SHRINK, 1)
		pool.current.calm = 0
	} else if wait * BATCH_WAIT_LOW < span {
		pool.current.calm += 1
		if pool.current.calm >= BATCH_CALM {
			if w^ == len(pool.helpers) && len(pool.helpers) < pool.max_helpers {
				batch_spawn_one(pool)
			}
			w^ = min(w^ + 1, len(pool.helpers))
			pool.current.calm = 0
		}
	}
}

// The width `task` has learned, or a fresh one, all helpers wide, in place of the oldest.
@(private)
batch_width :: proc(pool: ^Batch_Pool, task: proc(arg: rawptr)) -> ^Batch_Width {
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
batch_helper :: proc(t: ^thread.Thread) {
	h := (^Batch_Helper)(t.data)
	pool := h.pool
	for {
		switch sync.atomic_load(&h.ready) {
		case BATCH_IDLE:
			batch_park(&h.ready)
			continue
		case BATCH_REVOKED:
			sync.atomic_compare_exchange_strong(&h.ready, BATCH_REVOKED, BATCH_IDLE)
			continue
		}
		if _, took := sync.atomic_compare_exchange_strong(&h.ready, BATCH_HANDED, BATCH_TAKEN); !took {
			continue
		}
		if pool.task == nil {
			return
		}
		for j in 2 * h.index + 2 ..< min(2 * h.index + 4, pool.handed) {
			kid := &pool.helpers[j]
			if sync.atomic_load(&kid.ready) == BATCH_HANDED {
				sync.futex_signal(&kid.ready)
			}
		}
		pool.task(pool.arg)
		// Parked before it counts as done, so the next `batch_start` cannot hand it a task this overwrites.
		sync.atomic_store(&h.ready, BATCH_IDLE)
		sync.atomic_sub(&pool.pending, 1)
	}
}

// Wait for `ready` to leave `BATCH_IDLE`: spin for `BATCH_SPIN` first, then sleep.
@(private)
batch_park :: proc(ready: ^sync.Futex) {
	start := time.tick_now()
	for spins := 0; sync.atomic_load(ready) == BATCH_IDLE; spins += 1 {
		if spins % 64 == 0 && time.tick_since(start) > BATCH_SPIN {
			sync.futex_wait(ready, BATCH_IDLE)
			return
		}
		intrinsics.cpu_relax()
	}
}
