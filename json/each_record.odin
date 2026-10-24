package json

import "base:runtime"
import "core:bytes"
import core_pkg "../core"
import scan_pkg "scan"
import index_pkg "scan/index"

// Caller-owned threads for `each_record` and `validate_records`; `stury:host`'s `Batch_Pool` implements it.
Batch_Runner :: core_pkg.Batch_Runner

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
	run := Batch_Run{src = src, framing = framing, task = task, data = data, cursor = {runner = runner}, end = len(src)}
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
	run.cursor.slices = core_pkg.batch_slices(n)
	run.cursor.lanes = core_pkg.batch_lanes(runner, n)
	// Freed once the claims below have read them.
	defer delete(run.states)
	if framing == .Root_Entries && run.cursor.lanes > 1 {
		states, serr := make([]Slice_State, run.cursor.slices)
		if serr != nil {
			return Error{kind = .Out_Of_Memory}
		}
		run.states = states
		core_pkg.batch_fan(&run.cursor, batch_classify, &run)
		batch_settle(states)
	}
	core_pkg.batch_fan(&run.cursor, batch_claim, &run)
	return run.first.error
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
	lists, lerr := make([][dynamic]Record_Fault, core_pkg.batch_slices(len(src)), runtime.heap_allocator())
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
	if e, bad := validate(rec.bytes, {limits = limits}).?; bad {
		at := int(rec.at - piece.base)
		return scan_pkg.cut_by_next_byte(piece.src, at, at + len(rec.bytes), e, limits = limits)
	}
	return nil
}

@(private)
Batch_Run :: struct {
	src:        []byte,
	framing:    Framing,
	task:       proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data:       rawptr,
	cursor:     core_pkg.Batch_Cursor,
	// The records' span: the input, or the root's entries from after its open bracket to its close.
	lo, end:    int,
	keyed:      bool,
	// `.Root_Entries` on several threads: where strings and depth stand at each slice's start.
	states:     []Slice_State,
	classified: int,
	first:      core_pkg.First_Fault,
}

@(private)
Slice_State :: struct {
	balance:   index_pkg.Bracket_Balance,
	in_string: bool,
	depth:     int,
}

// Where slice `k` starts: at its offset, moved past backslashes, since the classes read a slice as though
// none precedes it. Past the last slice, the span's end.
@(private)
slice_start :: proc(run: ^Batch_Run, k: int) -> int {
	at := run.lo + k * core_pkg.BATCH_SLICE
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
	for k in core_pkg.slice_next(&run.classified, run.cursor.slices) {
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
	for s, n, k in core_pkg.cursor_next(&run.cursor) {
		// The offset past the span's end: the input's end for lines, one past the close bracket for root entries.
		none := run.end + int(run.framing == .Root_Entries)
		// A claim inside a long record starts no record, and its boundary search stops at the claim's end, so
		// only the claim the record starts in searches for that record's end.
		lo, hi := batch_boundary(run, s, slice_start(run, s + n)), none
		if lo < 0 {
			lo = none
		} else {
			if h := batch_boundary(run, s + n, run.end); h >= 0 {
				hi = h
			}
			core_pkg.cursor_skip_to(&run.cursor, batch_skip(run, s + n, hi))
		}
		piece := Records{src = run.src[:hi], pos = lo, framing = run.framing}
		if run.framing == .Root_Entries {
			// A piece's entries end at its last comma, or at the root's close bracket, `hi - 1` either way.
			piece = {src = run.src, pos = lo, framing = .Root_Entries, opened = true, end = hi - 1, keyed = run.keyed}
			piece.owed = lo != run.lo || hi - 1 != run.end
			piece.commas = index_pkg.comma_cursor(lo)
		}
		if !run.task(run.data, &piece, k) {
			core_pkg.cursor_stop(&run.cursor)
		}
		if e, bad := piece.err.(Error); bad {
			core_pkg.first_fault_note(&run.first, int(e.offset), e)
		}
	}
}

// Returns the offset where the records of slice `k` onward start, searching before `stop`. For lines, it is past
// the first line feed at or after the byte before the slice's offset. For `0x1E`, it is the first separator run
// starting at or after the offset. For root entries, it is past the first top-level comma at or after the offset.
// Slice 0 starts at the span's start. Returns -1 when no boundary is found.
@(private)
batch_boundary :: proc(run: ^Batch_Run, k, stop: int) -> int {
	src := run.src
	if k == 0 {
		return run.lo
	}
	at := slice_start(run, k)
	switch run.framing {
	case .NDJSON:
		if at < stop {
			if i := bytes.index_byte(src[at - 1:stop], '\n'); i >= 0 {
				return at + i
			}
		}
	case .JSON_Seq:
		for at < stop {
			i := bytes.index_byte(src[at:stop], 0x1E)
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
		if at < stop {
			st := run.states[k]
			c := index_pkg.comma_cursor(at, st.in_string, st.depth)
			if i := index_pkg.next_top_comma(&c, src[:stop]); i >= 0 {
				return i + 1
			}
		}
	}
	return -1
}

// The first slice past `from` whose boundary is still `hi`, the boundary of slice `from`.
@(private)
batch_skip :: proc(run: ^Batch_Run, from, hi: int) -> int {
	if run.framing != .Root_Entries {
		return (hi - run.lo) / core_pkg.BATCH_SLICE
	}
	// Slice `skip` must start at or before the comma at `hi - 1`, which a run of backslashes may move it past.
	skip := (hi - 1 - run.lo) / core_pkg.BATCH_SLICE
	for skip > from && slice_start(run, skip) > hi - 1 {
		skip -= 1
	}
	return skip
}
