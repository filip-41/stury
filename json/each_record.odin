package json

import "base:runtime"
import "core:bytes"
import "core:sync"
import scan_pkg "scan"
import index_pkg "scan/index"

// Threads a caller lends `each_record` and `validate_records`, which start none of their own.
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

// A record `validate_records` refuses: its bytes are src[lo:hi], and `err`'s offset is into `src`.
Record_Fault :: struct {
	lo, hi: u64,
	err:    Error,
}

// `task` on every piece of `src`, each a `Records` over whole records under `framing`.
//
//	- Pieces are numbered `k` from 0 in source order and handed out once each, possibly with no record.
//	- The caller and `runner`'s threads claim the pieces in turn, and each finds its own first and last
//	  record. Without `runner` the caller has one piece, the whole input.
//	- A piece's records carry offsets into `src`.
//	- Once a task returns false no further piece is claimed.
//	- The first framing fault in `src` of the pieces handed out is returned. A piece's own is also on its
//	  `err` when its task returns.
//	- Under `.Root_Entries` a scalar root has no pieces, and its fault under `validate` is returned.
//	- Scratch is `context.allocator`'s, from the calling thread only.
@(require_results)
each_record :: proc(
	src: []byte,
	framing: Framing,
	task: proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data: rawptr,
	runner: ^Batch_Runner = nil,
) -> Maybe(Error) {
	run := Batch_Run{src = src, framing = framing, task = task, data = data, runner = runner, end = len(src)}
	if framing == .Root_Entries {
		root := records(src, .Root_Entries)
		if !open_root(&root) {
			if e, bad := root.err.(Error); bad {
				return e
			}
			return nil
		}
		run.lo, run.end, run.keyed = root.pos, root.end, root.keyed
	}
	n := run.end - run.lo
	if n <= 0 {
		return nil
	}
	run.slices = batch_pieces_max(n)
	run.width = runner != nil ? runner.threads + 1 : 1
	run.width = clamp(run.width, 1, (n + BATCH_CHUNK - 1) / BATCH_CHUNK)
	// Freed once the claims below have read them.
	defer delete(run.states)
	if framing == .Root_Entries && run.width > 1 {
		states, serr := make([]Slice_State, run.slices)
		if serr != nil {
			return Error{kind = .Out_Of_Memory}
		}
		run.states = states
		batch_fan(&run, batch_classify)
		batch_settle(states)
	}
	batch_fan(&run, batch_claim)
	return run.fault
}

// Validate every record of `src` as `validate` checks it alone: the records it refuses, in source order,
// allocated with `allocator` (nil when there are none).
//
//	- Under `.Root_Entries` a record is checked with one level less nesting, since the root holds each
//	  entry.
//	- A framing fault is `err`, the first in `src`, and `faults` are then only the records before it.
//	- Records are validated on `runner`'s threads as `each_record` hands them out.
@(require_results)
validate_records :: proc(
	src: []byte,
	framing: Framing,
	runner: ^Batch_Runner = nil,
	allocator := context.allocator,
) -> (
	faults: []Record_Fault,
	err: Maybe(Error),
) {
	// One list per piece, in the heap: pieces run on every thread, and `allocator` may not be safe to share.
	lists, lerr := make([][dynamic]Record_Fault, batch_pieces_max(len(src)), runtime.heap_allocator())
	if lerr != nil {
		return nil, Error{kind = .Out_Of_Memory}
	}
	defer {
		for &l in lists {
			delete(l)
		}
		delete(lists, runtime.heap_allocator())
	}
	err = each_record(src, framing, validate_piece, &lists, runner)
	before := max(u64)
	if e, bad := err.?; bad {
		before = e.offset
	}
	total := 0
	for l in lists {
		for f in l {
			total += int(f.lo < before)
		}
	}
	if total == 0 {
		return
	}
	faults, lerr = make([]Record_Fault, total, allocator)
	if lerr != nil {
		return nil, Error{kind = .Out_Of_Memory}
	}
	at := 0
	for l in lists {
		for f in l {
			if f.lo < before {
				faults[at] = f
				at += 1
			}
		}
	}
	return
}

@(private)
validate_piece :: proc(data: rawptr, piece: ^Records, k: int) -> bool {
	lists := (^[][dynamic]Record_Fault)(data)^
	list := &lists[k]
	list.allocator = runtime.heap_allocator()
	limits := Limits{max_depth = MAX_DEPTH - 1} if piece.framing == .Root_Entries else {}
	for rec in next_record(piece) {
		if e, bad := validate_record(piece, rec, limits).?; bad {
			e.offset += rec.at
			append(list, Record_Fault{lo = rec.at, hi = rec.at + u64(len(rec.bytes)), err = e})
		}
	}
	return true
}

// `validate` of one record. A record that ends inside a literal is `.Truncated` alone, but it was followed by
// the framing byte that finished it (when the input goes on), and `validate` of the document calls that
// `.Bad_Literal`: so it is validated with that byte, which shifts no offset.
@(private)
validate_record :: proc(piece: ^Records, rec: Record, limits: Limits) -> Maybe(Error) {
	if e, bad := validate(rec.bytes, limits = limits).?; bad {
		at := int(rec.at - piece.base)
		return scan_pkg.cut_by_next_byte(piece.src, at, at + len(rec.bytes), e, limits = limits)
	}
	return nil
}

// The most bytes a worker claims at a time. A claim starts at the first record boundary at or past its offset.
@(private)
BATCH_CHUNK :: 128 * 1024

// Claims shrink toward the end of a batch, down to one slice, so the last pieces finish together.
@(private)
BATCH_SLICE :: BATCH_CHUNK / 4

// The most pieces `each_record` cuts `n` bytes into: each claims at least a slice.
@(private)
batch_pieces_max :: proc(n: int) -> int {
	return (n + BATCH_SLICE - 1) / BATCH_SLICE
}

@(private)
Batch_Run :: struct {
	src:        []byte,
	framing:    Framing,
	task:       proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data:       rawptr,
	runner:     ^Batch_Runner,
	width:      int,
	// The records' span: the input, or the root's entries from after its open bracket to its close.
	lo, end:    int,
	keyed:      bool,
	slices:     int,
	// `.Root_Entries` on several threads: where strings and depth stand at each slice's start.
	states:     []Slice_State,
	classified: int,
	// The next slice to claim in the low 32 bits, the next piece's number in the high 32.
	next:       u64,
	stopped:    bool,
	lock:       sync.Mutex,
	fault:      Maybe(Error),
}

@(private)
Slice_State :: struct {
	balance:   index_pkg.Bracket_Balance,
	in_string: bool,
	depth:     int,
}

// `task` on the runner's threads and the caller, until each returns.
@(private)
batch_fan :: proc(run: ^Batch_Run, task: proc(arg: rawptr)) {
	if run.width > 1 {
		run.runner.start(run.runner.data, run.width - 1, task, run)
	}
	task(run)
	if run.width > 1 {
		run.runner.finish(run.runner.data)
	}
}

// Where slice `k` starts: at its offset, moved past backslashes, since the classes read a slice as though
// none precedes it. Past the last slice, the span's end.
@(private)
slice_start :: proc(run: ^Batch_Run, k: int) -> int {
	at := run.lo + k * BATCH_SLICE
	if at >= run.end {
		return run.end
	}
	if run.framing == .Root_Entries {
		for at < run.end && run.src[at - 1] == '\\' {
			at += 1
		}
	}
	return at
}

@(private)
batch_classify :: proc(arg: rawptr) {
	run := (^Batch_Run)(arg)
	for {
		k := sync.atomic_add(&run.classified, 1)
		if k >= run.slices {
			return
		}
		run.states[k].balance = index_pkg.bracket_balance(run.src[slice_start(run, k):slice_start(run, k + 1)])
	}
}

// Where strings and depth stand at each slice's start, from the slices' balances under both guesses.
@(private)
batch_settle :: proc(states: []Slice_State) {
	in_string, depth := false, 0
	for &s in states {
		s.in_string, s.depth = in_string, depth
		if in_string {
			depth += s.balance.inside
			in_string = !s.balance.ends_in_string
		} else {
			depth += s.balance.outside
			in_string = s.balance.ends_in_string
		}
	}
}

// Claim pieces until none are left. A piece whose last record reaches past the slices after it moves the
// counter past them, since no record starts there.
@(private)
batch_claim :: proc(arg: rawptr) {
	run := (^Batch_Run)(arg)
	for !sync.atomic_load(&run.stopped) {
		cur := sync.atomic_load(&run.next)
		s, k := cursor_unpack(cur)
		if s >= run.slices {
			return
		}
		n := run.slices if run.width == 1 else clamp((run.slices - s) / (2 * run.width), 1, BATCH_CHUNK / BATCH_SLICE)
		if _, took := sync.atomic_compare_exchange_weak(&run.next, cur, cursor_pack(s + n, k + 1)); !took {
			continue
		}
		lo := batch_boundary(run, s)
		hi := batch_boundary(run, s + n)
		skip := batch_skip(run, s + n, hi)
		cursor_skip_to(run, skip)
		piece := Records{src = run.src[:hi], pos = lo, framing = run.framing}
		if run.framing == .Root_Entries {
			// A piece's entries end at its last comma, or at the root's close bracket, `hi - 1` either way.
			piece = {src = run.src, pos = lo, framing = .Root_Entries, opened = true, end = hi - 1, keyed = run.keyed}
			piece.owed = lo != run.lo || hi - 1 != run.end
			piece.commas = index_pkg.comma_cursor(lo)
		}
		if !run.task(run.data, &piece, k) {
			sync.atomic_store(&run.stopped, true)
		}
		if e, bad := piece.err.(Error); bad {
			sync.lock(&run.lock)
			if f, has := run.fault.?; !has || e.offset < f.offset {
				run.fault = e
			}
			sync.unlock(&run.lock)
		}
	}
}

// `Batch_Run.next` packs the next slice to claim (low 32 bits) with the next piece's number (high 32).
@(private = "file")
cursor_pack :: #force_inline proc "contextless" (slice_no, piece_no: int) -> u64 {
	return u64(piece_no) << 32 | u64(slice_no)
}

@(private = "file")
cursor_unpack :: #force_inline proc "contextless" (cur: u64) -> (slice_no, piece_no: int) {
	return int(cur & 0xFFFF_FFFF), int(cur >> 32)
}

// Move the cursor's slice up to `slice_no` when it is behind, keeping its piece number: the slices a piece
// ran past are its own.
@(private = "file")
cursor_skip_to :: proc(run: ^Batch_Run, slice_no: int) {
	for {
		seen := sync.atomic_load(&run.next)
		s, k := cursor_unpack(seen)
		if s >= slice_no {
			return
		}
		if _, swapped := sync.atomic_compare_exchange_weak(&run.next, seen, cursor_pack(slice_no, k)); swapped {
			return
		}
	}
}

// Where the records from slice `k` on start. For lines, past the first line feed at or after its offset's
// previous byte. For `0x1E`, at the first run that starts at or after its offset. For the root's entries,
// past the first comma of the root's at or after it. Slice 0 starts at the span's start. With no boundary
// found, the result is the input's end, or past the root's close bracket.
@(private)
batch_boundary :: proc(run: ^Batch_Run, k: int) -> int {
	src := run.src
	if k == 0 {
		return run.lo
	}
	at := slice_start(run, k)
	switch run.framing {
	case .NDJSON:
		if at < run.end {
			if i := bytes.index_byte(src[at - 1:run.end], '\n'); i >= 0 {
				return at + i
			}
		}
	case .JSON_Seq:
		for at < run.end {
			i := bytes.index_byte(src[at:run.end], 0x1E)
			if i < 0 {
				break
			}
			at += i
			if src[at - 1] != 0x1E {
				return at
			}
			for at < run.end && src[at] == 0x1E {
				at += 1
			}
		}
	case .Root_Entries:
		if at < run.end {
			st := run.states[k]
			c := index_pkg.comma_cursor(at, st.in_string, st.depth)
			if i := index_pkg.next_top_comma(&c, src[:run.end]); i >= 0 {
				return i + 1
			}
		}
		return run.end + 1
	}
	return run.end
}

// The first slice past `from` whose boundary is still `hi`, the boundary of slice `from`.
@(private)
batch_skip :: proc(run: ^Batch_Run, from, hi: int) -> int {
	if run.framing != .Root_Entries {
		return (hi - run.lo) / BATCH_SLICE
	}
	// Slice `skip` must start at or before the comma at `hi - 1`, which a run of backslashes may move it past.
	skip := (hi - 1 - run.lo) / BATCH_SLICE
	for skip > from && slice_start(run, skip) > hi - 1 {
		skip -= 1
	}
	return skip
}
