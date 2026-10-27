package core

import "base:runtime"
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

// Sizes `c` for a batch of `n` bytes: `batch_slices` slices and `batch_lanes` lanes, counting the caller. A
// format may claim fewer lanes or one whole-input piece, by setting `lanes` and `slices` after this.
batch_plan :: proc(c: ^Batch_Cursor, runner: ^Batch_Runner, n: int) {
	c.runner = runner
	c.slices = batch_slices(n)
	c.lanes = batch_lanes(runner, n)
}

// Returns where slice `k`'s records start, or -1 when none do.
Batch_Boundary :: proc(data: rawptr, k, stop: int) -> int

// Returns the first slice past `from` whose boundary is still `hi`, the boundary of slice `from`.
Batch_Skip :: proc(data: rawptr, from, hi: int) -> int

Batch_Piece :: proc(data: rawptr, lo, hi, k: int) -> (fault: Maybe(Error), go_on: bool)

// Batch_Driver is the claim loop of one batch: the caller and the runner's threads claim a planned
// `Batch_Cursor`'s pieces in source order, each format supplying a piece's bounds and what running one does.
// A callback runs a fixed number of times per piece (`boundary` twice, for its first and last record), never
// per record.
//
//	- The caller and the runner's threads claim pieces in turn, each finding its own first and last record.
//	- A claim inside a long record starts no record: its boundary search stops at the claim's end, so the
//	  claim the record starts in finds that record's end and skips the slices it covers.
//	- A `go_on` of false stops the claims, and `stop_on_fault` says whether a piece's fault does.
//	- The fault noted is the one at the lowest offset, or of the lowest piece under `rank_by_piece`, whichever
//	  thread finds it first.
Batch_Driver :: struct {
	cursor: Batch_Cursor,
	first: First_Fault,
	data:  rawptr,
	// The offset of slice 0's first byte.
	lo:     int,
	// The offset where a piece's records end when its next boundary is not found: the span's one-past-end.
	none:   int,
	boundary:   Batch_Boundary,
	// Nil when slice `k` starts at `lo + k * BATCH_SLICE`, so the slice holding `hi` is the first past it.
	skip:       Batch_Skip,
	piece:      Batch_Piece,
	rank_by_piece: bool,
	stop_on_fault: bool,
}

@(require_results)
batch_run :: proc(d: ^Batch_Driver) -> Maybe(Error) {
	batch_fan(&d.cursor, batch_claim, d)
	return d.first.error
}

@(private)
batch_claim :: proc(arg: rawptr) {
	d := (^Batch_Driver)(arg)
	for s, n, k in cursor_next(&d.cursor) {
		lo := d.boundary(d.data, s, s + n)
		hi := d.none
		if lo < 0 {
			lo = d.none
		} else {
			if h := d.boundary(d.data, s + n, d.cursor.slices); h >= 0 {
				hi = h
			}
			cursor_skip_to(&d.cursor, (hi - d.lo) / BATCH_SLICE if d.skip == nil else d.skip(d.data, s + n, hi))
		}
		fault, go_on := d.piece(d.data, lo, hi, k)
		if !go_on {
			cursor_stop(&d.cursor)
		}
		if e, bad := fault.?; bad {
			first_fault_note(&d.first, k if d.rank_by_piece else int(e.offset), e)
			if d.stop_on_fault {
				cursor_stop(&d.cursor)
			}
		}
	}
}

// A record a record batch refused: its bytes are `src[lo:hi]`, and `err`'s offset is into `src`, not into the
// record.
Record_Fault :: struct {
	lo, hi: u64,
	err:    Error,
}

// The refused records of a batch of pieces, one list per piece, numbered as the batch numbers them. The pieces
// run on every thread the caller lends and the caller's allocator need not be safe to share, so the lists are in
// the heap and only the piece's own task appends to its list. `fault_list_merge` makes the caller's slice.
Fault_List :: struct {
	lists: [][dynamic]Record_Fault,
	// A list that could not grow. The batch's faults are then incomplete, and the merge refuses rather than
	// return a list with faults missing.
	short: bool,
}

// `pieces` empty lists, in the heap. `pieces` must hold every piece the batch numbers: a piece claims at least
// one slice, so `batch_slices(len(src))` does.
@(require_results)
fault_list_init :: proc(pieces: int) -> (fl: Fault_List, err: Maybe(Error)) {
	lists, aerr := make([][dynamic]Record_Fault, pieces, runtime.heap_allocator())
	if aerr != nil {
		return {}, Error{kind = .Out_Of_Memory}
	}
	for &l in lists {
		l.allocator = runtime.heap_allocator()
	}
	return Fault_List{lists = lists}, nil
}

// Frees the lists, and their faults. The batch's faults are gone: `fault_list_merge` first.
fault_list_destroy :: proc(fl: ^Fault_List) {
	for &l in fl.lists {
		delete(l)
	}
	delete(fl.lists, runtime.heap_allocator())
	fl.lists = nil
}

// Appends `f` to piece `k`'s list. Only piece `k`'s own task calls it, so no lock is taken.
fault_list_add :: proc(fl: ^Fault_List, k: int, f: Record_Fault) {
	if _, aerr := append(&fl.lists[k], f); aerr != nil {
		sync.atomic_store(&fl.short, true)
	}
}

// The faults of every list, in piece order and then in list order: those whose record starts before `through`
// only, so a format whose framing fault ends the records a whole-text read reaches passes its offset, and one
// that lists every refused record passes `max(u64)`. One exact-size slice in `allocator`, nil when no fault
// stands.
@(require_results)
fault_list_merge :: proc(
	fl: ^Fault_List,
	through: u64,
	allocator: runtime.Allocator,
) -> (
	faults: []Record_Fault,
	err: Maybe(Error),
) {
	if sync.atomic_load(&fl.short) {
		return nil, Error{kind = .Out_Of_Memory}
	}
	total := 0
	for l in fl.lists {
		for f in l {
			total += int(f.lo < through)
		}
	}
	if total == 0 {
		return
	}
	out, aerr := make([]Record_Fault, total, allocator)
	if aerr != nil {
		return nil, Error{kind = .Out_Of_Memory}
	}
	at := 0
	for l in fl.lists {
		for f in l {
			if f.lo < through {
				out[at] = f
				at += 1
			}
		}
	}
	return out, nil
}
