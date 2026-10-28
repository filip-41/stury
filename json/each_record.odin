package json

import "core:bytes"
import core_pkg "../core"
import index_pkg "scan/index"

// Caller-owned threads for `each_record` and `validate_records`; `stury:host`'s `Batch_Pool` implements it.
Batch_Runner :: core_pkg.Batch_Runner

// core's `Record_Fault`.
Record_Fault :: core_pkg.Record_Fault

// `task` on every piece of `src`, each a `Records` over whole records under `opts.framing`; no other field is read.
//
//	- Pieces are numbered `k` from 0 in source order and handed out once each, possibly with no record.
//	- The caller and `runner`'s threads claim the pieces in turn, and each finds its own first and last
//	  record. Without `runner` the caller has one piece, the whole input.
//	- A piece's records carry offsets into `src`.
//	- Once a task returns false no further piece is claimed.
//	- The first framing fault in `src` of the pieces handed out is returned. A piece's own is also on its
//	  `err` when its task returns.
//	- Under `.Root_Entries` a scalar root has no pieces, and its fault under `validate` is returned.
//	- Under `.Concatenated` a piece starts after a line feed outside strings and brackets as counted from the
//	  input's start. From the first stray closing bracket or backslash outside a string, where that count
//	  parts from the texts `records` cuts, the records are one piece's.
//	- Scratch is `context.allocator`'s, from the calling thread only.
@(require_results)
each_record :: #force_inline proc(
	src: []byte,
	task: proc(data: ^$D, piece: ^Records, k: int) -> bool,
	data: ^D,
	opts := Record_Opts{},
	runner: ^Batch_Runner = nil,
) -> Maybe(Error) {
	return each_record_untyped(src, cast(proc(data: rawptr, piece: ^Records, k: int) -> bool)task, data, opts, runner)
}

// `each_record` with the task's data a `rawptr`, one body for every data type.
@(private, require_results)
each_record_untyped :: proc(
	src: []byte,
	task: proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data: rawptr,
	opts: Record_Opts,
	runner: ^Batch_Runner,
) -> Maybe(Error) {
	framing := opts.framing
	run := Batch_Run{src = src, framing = framing, cap = record_cap(opts), task = task, data = data, end = len(src), serial_from = max(int)}
	if opts.max_record_bytes < 0 {
		return Error{kind = .Bad_Option}
	}
	if framing == .Root_Entries {
		root := records(src, {framing = .Root_Entries})
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
	run.driver = {
		data = &run,
		lo = run.lo,
		none = run.end + int(framing == .Root_Entries),
		boundary = batch_boundary,
		skip = batch_skip if framing == .Root_Entries else nil,
		piece = batch_piece,
	}
	core_pkg.batch_plan(&run.driver.cursor, runner, n)
	// Freed once the claims below have read them.
	defer delete(run.states)
	// A cut must fall outside strings and brackets, which only a read from the start tells: each slice is read
	// under both guesses of whether it starts in a string, in parallel, and the guesses settled in order.
	if (framing == .Root_Entries || framing == .Concatenated) && run.driver.cursor.lanes > 1 {
		states, serr := make([]Slice_State, run.driver.cursor.slices)
		if serr != nil {
			return Error{kind = .Out_Of_Memory}
		}
		run.states = states
		core_pkg.batch_fan(&run.driver.cursor, batch_classify, &run)
		batch_settle(&run)
	}
	return core_pkg.batch_run(&run.driver)
}

// Validate every record of `src` as `validate` checks it alone under `opts.read`: the records it refuses, in source
// order, allocated with `allocator` (nil when there are none).
//
//	- Under `.Root_Entries` a record is checked with one level less nesting than `opts.limits` allows, since
//	  the root holds each entry.
//	- `err` is what ended the records, in either format: a fault the framing reports, which no record holds and
//	  past which no record is found, or `.Out_Of_Memory`. `faults` are then only the records before it. A fault
//	  in a record is never `err`.
//	- Records are validated on `runner`'s threads as `each_record` hands them out.
@(require_results)
validate_records :: proc(
	src: []byte,
	opts := Record_Opts{},
	runner: ^Batch_Runner = nil,
	allocator := context.allocator,
) -> (
	faults: []Record_Fault,
	err: Maybe(Error),
) {
	lists, lerr := core_pkg.fault_list_init(core_pkg.batch_slices(len(src)))
	if lerr != nil {
		return nil, lerr
	}
	defer core_pkg.fault_list_destroy(&lists)
	check := Record_Check{lists = &lists, opts = opts.read}
	if opts.framing == .Root_Entries {
		check.opts.limits.max_depth = (opts.limits.max_depth if opts.limits.max_depth > 0 else MAX_DEPTH) - 1
	}
	err = each_record(src, validate_piece, &check, opts, runner)
	// A framing fault ends the records a whole-text `validate` reaches, so only the records before it stand.
	through := max(u64)
	if e, bad := err.?; bad {
		through = e.offset
	}
	merged, merr := core_pkg.fault_list_merge(&lists, through, allocator)
	if merr != nil {
		return nil, merr
	}
	return merged, err
}

// What `validate_records` hands each piece: the fault lists, and the options a record is validated with.
@(private)
Record_Check :: struct {
	lists: ^core_pkg.Fault_List,
	opts:  Read_Opts,
}

@(private)
validate_piece :: proc(check: ^Record_Check, piece: ^Records, k: int) -> bool {
	for rec in next_record(piece) {
		if e, bad := validate_record(piece, rec, check.opts).?; bad {
			e.offset += rec.at
			core_pkg.fault_list_add(check.lists, k, Record_Fault{lo = rec.at, hi = rec.at + u64(len(rec.bytes)), err = e})
		}
	}
	return true
}

// `validate` of one record, its fault as the framing tells it (`judge_record`).
@(private)
validate_record :: proc(piece: ^Records, rec: Record, opts: Read_Opts) -> Maybe(Error) {
	if e, bad := validate(rec.bytes, opts).?; bad {
		_, err := judge_record(piece.src, rec, e, {read = opts})
		return err
	}
	return nil
}

@(private)
Batch_Run :: struct {
	src:        []byte,
	framing:    Framing,
	cap:        int,
	task:       proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data:       rawptr,
	driver:     core_pkg.Batch_Driver,
	// The records' span: the input, or the root's entries from after its open bracket to its close.
	lo, end:    int,
	keyed:      bool,
	// `.Root_Entries` and `.Concatenated` on several threads: where strings and depth stand at each slice's start.
	states:     []Slice_State,
	classified: int,
	// `.Concatenated`: the first slice where the depth counted parts from the texts' (`Bracket_Strays`); no
	// piece starts in it or past it.
	serial_from: int,
}

@(private)
Slice_State :: struct {
	balance:   index_pkg.Bracket_Balance,
	strays:    index_pkg.Bracket_Strays,
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
	if k > 0 && (run.framing == .Root_Entries || run.framing == .Concatenated) {
		for at < run.end && run.src[at - 1] == '\\' {
			at += 1
		}
	}
	return at
}

@(private)
batch_classify :: proc(arg: rawptr) {
	run := (^Batch_Run)(arg)
	for k in core_pkg.slice_next(&run.classified, run.driver.cursor.slices) {
		s := &run.states[k]
		slice := run.src[slice_start(run, k):slice_start(run, k + 1)]
		if run.framing == .Concatenated {
			s.balance, s.strays = index_pkg.bracket_balance_strays(slice)
		} else {
			s.balance = index_pkg.bracket_balance(slice)
		}
	}
}

// Where strings and depth stand at each slice's start, from the slices' balances under both guesses, up to the
// first slice whose strays part the count from the texts.
@(private)
batch_settle :: proc(run: ^Batch_Run) {
	in_string, depth := false, 0
	for &s, k in run.states {
		s.in_string, s.depth = in_string, depth
		low, escape := s.strays.low_outside, s.strays.escape_outside
		if in_string {
			low, escape = s.strays.low_inside, s.strays.escape_inside
		}
		if depth + low < 0 || escape {
			run.serial_from = k
			return
		}
		if in_string {
			depth += s.balance.inside
			in_string = !s.balance.ends_in_string
		} else {
			depth += s.balance.outside
			in_string = s.balance.ends_in_string
		}
	}
}

@(private)
batch_piece :: proc(data: rawptr, lo, hi, k: int) -> (fault: Maybe(Error), go_on: bool) {
	run := (^Batch_Run)(data)
	piece := Records{src = run.src[:hi], pos = lo, framing = run.framing, cap = run.cap}
	if run.framing == .Root_Entries {
		// A piece's entries end at its last comma, or at the root's close bracket, `hi - 1` either way.
		piece = {src = run.src, pos = lo, framing = .Root_Entries, opened = true, end = hi - 1, keyed = run.keyed, cap = run.cap}
		piece.owed = lo != run.lo || hi - 1 != run.end
		piece.commas = index_pkg.comma_cursor(lo)
	}
	go_on = run.task(run.data, &piece, k)
	return piece.err, go_on
}

@(private)
batch_boundary :: proc(data: rawptr, k, stop_slice: int) -> int {
	run := (^Batch_Run)(data)
	src := run.src
	if k == 0 {
		return run.lo
	}
	at := slice_start(run, k)
	stop := slice_start(run, stop_slice)
	switch run.framing {
	case .None:
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
	case .Concatenated:
		if k >= run.serial_from {
			return -1
		}
		if stop_slice > run.serial_from {
			stop = slice_start(run, run.serial_from)
		}
		if at < stop {
			st := run.states[k]
			c := index_pkg.comma_cursor(at, st.in_string, st.depth)
			if i := index_pkg.next_top_newline(&c, src[:stop]); i >= 0 {
				return i + 1
			}
		}
	}
	return -1
}

@(private)
batch_skip :: proc(data: rawptr, from, hi: int) -> int {
	run := (^Batch_Run)(data)
	// Slice `skip` must start at or before the comma at `hi - 1`, which a run of backslashes may move it past.
	skip := (hi - 1 - run.lo) / core_pkg.BATCH_SLICE
	for skip > from && slice_start(run, skip) > hi - 1 {
		skip -= 1
	}
	return skip
}
