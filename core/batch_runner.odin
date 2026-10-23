package core

import "core:sync"

// Batch_Runner is a set of caller-owned threads for the parallel procedures (`json.each_record`,
// `json.validate_records`, `csv.each_record`, `csv.validate`), which start no threads of their own.
// `stury:host`'s `Batch_Pool` implements it.
//
//	- `start` runs `task(arg)` as a separate call on each of up to `n` of the `threads`. A call may start late or
//	  not at all.
//	- `finish` returns once no further call will start and every started call has returned.
//	- `start` and `finish` alternate, and both run on the calling thread.
Batch_Runner :: struct {
	data:    rawptr,
	threads: int,
	start:   proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr),
	finish:  proc(data: rawptr),
}

// The most bytes a worker claims at a time. A claim starts at the first record boundary at or after its offset.
BATCH_CHUNK :: 128 * 1024

// The smallest claim. Claims shrink toward the end of a batch, down to one slice, so the last pieces finish
// together.
BATCH_SLICE :: BATCH_CHUNK / 4

// Returns the number of slices in `n` bytes. A piece claims at least one slice.
batch_slices :: proc(n: int) -> int {
	return (n + BATCH_SLICE - 1) / BATCH_SLICE
}

// Returns the number of threads for a batch of `n` bytes, counting the caller, with at least one chunk each.
batch_lanes :: proc(runner: ^Batch_Runner, n: int) -> int {
	return clamp(runner.threads + 1 if runner != nil else 1, 1, max(1, (n + BATCH_CHUNK - 1) / BATCH_CHUNK))
}

// Batch_Cursor is the claim state of a batch's slices. The caller and the runner's threads claim one piece at a
// time, in source order.
Batch_Cursor :: struct {
	runner:  ^Batch_Runner,
	lanes:   int,
	slices:  int,
	// The next slice to claim in the low 32 bits, the next piece's number in the high 32.
	next:    u64,
	stopped: bool,
}

// Runs `task(arg)` on the runner's threads and on the caller, and returns when every call has returned.
batch_fan :: proc(c: ^Batch_Cursor, task: proc(arg: rawptr), arg: rawptr) {
	if c.lanes > 1 {
		c.runner.start(c.runner.data, c.lanes - 1, task, arg)
	}
	task(arg)
	if c.lanes > 1 {
		c.runner.finish(c.runner.data)
	}
}

// Returns the next slice number of a pass over `slices` shared by every thread of a `batch_fan`. `counted` is
// the shared counter and starts at 0. Returns false once no slice is left.
slice_next :: proc(counted: ^int, slices: int) -> (k: int, ok: bool) {
	k = sync.atomic_add(counted, 1)
	return k, k < slices
}

// Claims the next piece and returns its first slice, its slice count and its number. Returns false once no
// slice is left or the cursor is stopped.
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

// Advances the cursor's next slice to `slice_no` when it is behind, keeping the piece number. A piece that read
// past its claim owns the slices it covered.
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

// Stops the cursor: no further piece is claimed.
cursor_stop :: proc(c: ^Batch_Cursor) {
	sync.atomic_store(&c.stopped, true)
}

// The noted fault with the lowest `order`.
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
