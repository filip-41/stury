package core

import "core:sync"

// Threads a caller lends the formats' parallel procedures (`json.each_record`, `json.validate_records`,
// `csv.each_record`, `csv.validate`), which start none of their own. `stury:host`'s `Batch_Pool` is one.
//
//	- `start` runs `task(arg)` on up to `n` of the `threads`, each as its own call, which may begin late or
//	  not at all.
//	- `finish` returns once no call that has not begun will begin and every one that has has returned.
//	- `start` and `finish` alternate and run on the calling thread.
Batch_Runner :: struct {
	data:    rawptr,
	threads: int,
	start:   proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr),
	finish:  proc(data: rawptr),
}

// The most bytes a worker claims at a time. A claim starts at the first record boundary at or past its offset.
BATCH_CHUNK :: 128 * 1024

// Claims shrink toward the end of a batch, down to one slice, so the last pieces finish together.
BATCH_SLICE :: BATCH_CHUNK / 4

// The slices `n` bytes are cut into: a piece claims at least one.
batch_slices :: proc(n: int) -> int {
	return (n + BATCH_SLICE - 1) / BATCH_SLICE
}

// The threads a batch of `n` bytes takes: the caller and the runner's, each with at least a chunk.
batch_lanes :: proc(runner: ^Batch_Runner, n: int) -> int {
	return clamp(runner.threads + 1 if runner != nil else 1, 1, max(1, (n + BATCH_CHUNK - 1) / BATCH_CHUNK))
}

// A batch's slices, claimed a piece at a time in source order by the caller and the runner's threads.
Batch_Cursor :: struct {
	runner:  ^Batch_Runner,
	lanes:   int,
	slices:  int,
	// The next slice to claim in the low 32 bits, the next piece's number in the high 32.
	next:    u64,
	stopped: bool,
}

// `task(arg)` on the runner's threads and the caller, until each returns.
batch_fan :: proc(c: ^Batch_Cursor, task: proc(arg: rawptr), arg: rawptr) {
	if c.lanes > 1 {
		c.runner.start(c.runner.data, c.lanes - 1, task, arg)
	}
	task(arg)
	if c.lanes > 1 {
		c.runner.finish(c.runner.data)
	}
}

// The next slice number of a pass over the `slices` that every thread of a `batch_fan` takes a share of through
// `counted`, a counter that starts at 0. False once none are left.
slice_next :: proc(counted: ^int, slices: int) -> (k: int, ok: bool) {
	k = sync.atomic_add(counted, 1)
	return k, k < slices
}

// The next piece: its first slice, how many slices it takes, and its number. False once none are left or
// the cursor is stopped.
cursor_next :: proc(c: ^Batch_Cursor) -> (slice_no, count, piece_no: int, ok: bool) {
	for !sync.atomic_load(&c.stopped) {
		cur := sync.atomic_load(&c.next)
		slice_no, piece_no = int(cur & 0xFFFF_FFFF), int(cur >> 32)
		if slice_no >= c.slices {
			return
		}
		count = c.slices if c.lanes == 1 else clamp((c.slices - slice_no) / (2 * c.lanes), 1, BATCH_CHUNK / BATCH_SLICE)
		if _, took := sync.atomic_compare_exchange_weak(&c.next, cur, u64(piece_no + 1) << 32 | u64(slice_no + count)); took {
			return slice_no, count, piece_no, true
		}
	}
	return
}

// Move the cursor's slice up to `slice_no` when it is behind, keeping its piece number: the slices a piece
// ran past are its own.
cursor_skip_to :: proc(c: ^Batch_Cursor, slice_no: int) {
	for {
		seen := sync.atomic_load(&c.next)
		if int(seen & 0xFFFF_FFFF) >= slice_no {
			return
		}
		if _, swapped := sync.atomic_compare_exchange_weak(&c.next, seen, seen & ~u64(0xFFFF_FFFF) | u64(slice_no)); swapped {
			return
		}
	}
}

// No further piece is claimed.
cursor_stop :: proc(c: ^Batch_Cursor) {
	sync.atomic_store(&c.stopped, true)
}

// The noted fault of least `order`.
First_Fault :: struct {
	lock:  sync.Mutex,
	error: Maybe(Error),
	order: int,
}

first_fault_note :: proc(f: ^First_Fault, order: int, e: Error) {
	sync.lock(&f.lock)
	if f.error == nil || order < f.order {
		f.error, f.order = e, order
	}
	sync.unlock(&f.lock)
}
