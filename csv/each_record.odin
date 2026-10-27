package csv

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:simd"
import core_pkg "../core"

Batch_Runner :: core_pkg.Batch_Runner

// core's `Record_Fault`.
Record_Fault :: core_pkg.Record_Fault

// Runs `task` on every piece of `src`. Each piece is a `Records` over whole records of `src`, read with `opts` as
// `records` reads the whole input.
//
//	- Pieces are numbered `k` from 0 in source order. Each is handed out once and may hold no record.
//	- The caller and `runner`'s threads claim pieces in turn. Without `runner` there is one piece, the whole
//	  input. A dialect with quotes and a comment byte also gets one piece: only a read from the start can tell
//	  a comment line from a line inside a quoted field.
//	- A piece's records carry offsets into `src`, and their `src` is `src`.
//	- The returned fault is the one `records` would end on: that of the first piece holding a fault. A piece's
//	  own fault is on its `err` once its task has read it to the end.
//	- Once a task returns false or a piece ends on a fault, no further piece is claimed. Pieces past the
//	  faulty one that were already claimed still run, over records `records` would never reach.
//	- A piece's fields live on the heap until its task returns.
@(require_results)
each_record :: proc(
	src: []byte,
	task: proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data: rawptr,
	opts := Read_Opts{},
	runner: ^Batch_Runner = nil,
) -> Maybe(Error) {
	s, ok := scan_setup(opts.dialect, opts.limits, opts.strictness)
	if !ok {
		return Error{kind = .Bad_Option}
	}
	run := Batch_Run{src = src, scan = s, task = task, data = data}
	return run_batch(&run, runner, piece_task)
}

// Every record of `src` that `validate` refuses, in source order, each with its bytes src[lo:hi], which end
// before the line break that closes the record, and its fault's offset into `src`. `opts` is read as `validate`
// reads it.
//
//	- One fault per refused record, and `faults[0].err` is `validate`'s fault. A clean text is that scan and no
//	  list at all. The faults of the whole text are listed, whichever threads found the first one.
//	- A record ends at the LF that closes it outside quotes, or at the input's end.
//	- `err` is as in `json.validate_records`: a failure of the call, `.Bad_Option` or `.Out_Of_Memory`, where
//	  `faults` is nil. A fault of the text is never `err`: each is a record in `faults`.
//	- Allocates the list and `faults`, the latter with `allocator`.
@(require_results)
validate_records :: proc(
	src: []byte,
	opts := Read_Opts{},
	runner: ^Batch_Runner = nil,
	allocator := context.allocator,
) -> (
	faults: []Record_Fault,
	err: Maybe(Error),
) {
	s, ok := scan_setup(opts.dialect, opts.limits, opts.strictness)
	if !ok {
		return nil, Error{kind = .Bad_Option}
	}
	if validate(src, opts, runner) == nil {
		return
	}
	lists, lerr := core_pkg.fault_list_init(1)
	if lerr != nil {
		return nil, lerr
	}
	defer core_pkg.fault_list_destroy(&lists)
	read := records_of(src, s, runtime.heap_allocator())
	defer records_free(&read)
	for {
		for _ in next_record(&read) {
		}
		fault, bad := read.err.?
		if !bad {
			break
		}
		lo := u64(read.rec_lo)
		if fault.kind != .Out_Of_Memory {
			lo = min(lo, fault.offset)
		}
		hi, next := refused_end(&read, fault, int(lo))
		core_pkg.fault_list_add(&lists, 0, Record_Fault{lo = lo, hi = u64(hi), err = fault})
		if next >= len(src) {
			break
		}
		resume_read(&read, src, next)
	}
	merged, merr := core_pkg.fault_list_merge(&lists, max(u64), allocator)
	if merr != nil {
		return nil, merr
	}
	return merged, nil
}

@(private)
refused_end :: proc(it: ^Records, fault: Error, lo: int) -> (hi, next: int) {
	src := it.src
	switch {
	case it.ended:
		return len(src), len(src)
	case fault.kind != .Out_Of_Memory && int(fault.offset) < it.rec_lo:
		return record_end(src, lo, it.rec_lo - 1), it.rec_lo
	}
	quoted := .Unquoted not_in it.scan.mode && !(.Comments in it.scan.mode && lo < len(src) && src[lo] == it.scan.comment)
	in_quote := false
	for i in lo ..< len(src) {
		switch src[i] {
		case '"':
			if quoted && !(fault.kind == .Bad_Char && i == int(fault.offset)) {
				in_quote = !in_quote
			}
		case '\n':
			if !in_quote {
				return record_end(src, lo, i), i + 1
			}
		}
	}
	return len(src), len(src)
}

@(private)
record_end :: #force_inline proc(src: []byte, lo, lf: int) -> int {
	return lf - 1 if lf > lo && src[lf - 1] == '\r' else lf
}

// The field count `it` was judging against stands.
@(private)
resume_read :: proc(it: ^Records, src: []byte, at: int) {
	fields, width := it.fields, it.width
	it^ = records_of(src, it.scan, runtime.heap_allocator())
	it.fields, it.width = fields, width
	clear(&it.fields)
	set_limit(it)
	it.block, it.field_lo, it.rec_lo = at - 64, at, at
}

// `validate` split across `runner`'s threads and the caller, one piece per claim.
@(private)
validate_pieces :: proc(src: []byte, s: Scan, runner: ^Batch_Runner) -> Maybe(Error) {
	run := Batch_Run{src = src, scan = s}
	return run_batch(&run, runner, piece_validate)
}

@(private)
run_batch :: proc(run: ^Batch_Run, runner: ^Batch_Runner, piece: core_pkg.Batch_Piece) -> Maybe(Error) {
	run.driver = {data = run, none = len(run.src), boundary = batch_boundary, piece = piece, rank_by_piece = true, stop_on_fault = true}
	defer delete(run.parity, runtime.heap_allocator())
	split_plan(run, runner)
	return core_pkg.batch_run(&run.driver)
}

@(private)
Batch_Run :: struct {
	src:     []byte,
	scan:    Scan,
	// The field count every record must have: the first record's, read before the pieces. 0 when ragged.
	width:   int,
	// `each_record`'s task, nil for `validate`.
	task:    proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data:    rawptr,
	driver:  core_pkg.Batch_Driver,
	// Under `Quoting.Quotes`: whether an odd count of quotes comes before each slice.
	parity:  []u8,
	counted: int,
}

// How many lanes the run takes, and where its pieces may start. There is one piece, the whole input, when
// there is no runner, too little input, a dialect that cannot be split, no first record to read the width
// from, or no memory for the quote parities.
//
// A piece starts just past an LF outside quotes, where the scan state equals the state at the input's start:
// a field and a line start there, and no quote, CR or escape is open. Under `Quoting.None` every LF
// qualifies. Under `Quoting.Quotes` every quote opens or closes (a doubled `""` is a close then an open), so
// up to the first fault the quote state at a byte is the parity of the quotes before it, and an LF after an
// even count of quotes qualifies. Quotes in a comment line do not count, so a comment byte under quotes
// forces one piece.
@(private)
split_plan :: proc(run: ^Batch_Run, runner: ^Batch_Runner) {
	c := &run.driver.cursor
	core_pkg.batch_plan(c, runner, len(run.src))
	lanes, slices := c.lanes, c.slices
	c.lanes, c.slices = 1, 1
	if lanes == 1 || .Comments in run.scan.mode && .Unquoted not_in run.scan.mode {
		return
	}
	if !run.scan.ragged {
		width, ok := first_width(run.src, run.scan)
		if !ok {
			return
		}
		run.width = width
	}
	if .Unquoted not_in run.scan.mode {
		parity, err := make([]u8, slices, runtime.heap_allocator())
		if err != nil {
			return
		}
		run.parity, c.lanes = parity, lanes
		core_pkg.batch_fan(c, batch_count_quotes, run)
		odd := u8(0)
		for &p in parity {
			p, odd = odd, odd ~ p
		}
	}
	c.lanes, c.slices = lanes, slices
}

// The field count of the first record of `src`, or false when it has none, or a fault comes first.
@(private)
first_width :: proc(src: []byte, s: Scan) -> (width: int, ok: bool) {
	it := records_of(src, s, runtime.heap_allocator())
	defer records_free(&it)
	rec := next_slice_record(&it) or_return
	return len(rec.fields), true
}

@(private)
batch_count_quotes :: proc(arg: rawptr) {
	run := (^Batch_Run)(arg)
	for k in core_pkg.slice_next(&run.counted, len(run.parity)) {
		run.parity[k] = quote_parity(run.src[k * core_pkg.BATCH_SLICE:min((k + 1) * core_pkg.BATCH_SLICE, len(run.src))])
	}
}

// 1 when `src` holds an odd count of quotes.
@(private)
quote_parity :: proc(src: []byte) -> u8 {
	acc: core_pkg.V
	q := core_pkg.V('"')
	i := 0
	for ; i + 64 <= len(src); i += 64 {
		p := raw_data(src[i:])
		acc ~= simd.lanes_eq(core_pkg.load(p), q) ~ simd.lanes_eq(core_pkg.load(p[16:]), q) ~ simd.lanes_eq(core_pkg.load(p[32:]), q) ~ simd.lanes_eq(core_pkg.load(p[48:]), q)
	}
	odd := intrinsics.count_ones(core_pkg.pack4(acc, {}, {}, {}))
	for ; i < len(src); i += 1 {
		odd += u64(src[i] == '"')
	}
	return u8(odd & 1)
}

@(private)
piece_task :: proc(data: rawptr, lo, hi, k: int) -> (fault: Maybe(Error), go_on: bool) {
	run := (^Batch_Run)(data)
	piece := records_of(run.src[:hi], run.scan, runtime.heap_allocator())
	piece.block, piece.field_lo, piece.rec_lo = lo - 64, lo, lo
	piece.width = run.width
	go_on = run.task(run.data, &piece, k)
	fault = piece.err
	records_free(&piece)
	return
}

@(private)
piece_validate :: proc(data: rawptr, lo, hi: int, _: int) -> (fault: Maybe(Error), go_on: bool) {
	run := (^Batch_Run)(data)
	return validate_span(run.src[:hi], lo, run.width, run.scan), true
}

// Where the records from slice `k` on start: just past the first LF outside quotes at or after the byte before
// the slice's offset, or the input's end when there is none. Slice 0 starts at the input's first byte past
// its BOM.
@(private)
batch_boundary :: proc(data: rawptr, k, _: int) -> int {
	run := (^Batch_Run)(data)
	src := run.src
	if k == 0 {
		return core_pkg.bom_len(src)
	}
	at := k * core_pkg.BATCH_SLICE
	if k >= run.driver.cursor.slices || at >= len(src) {
		return len(src)
	}
	if run.parity == nil {
		i := bytes.index_byte(src[at - 1:], '\n')
		return at + i if i >= 0 else len(src)
	}
	odd := run.parity[k] != 0
	if src[at - 1] == '\n' && !odd {
		return at
	}
	i := outside_lf(src, at, odd)
	return i + 1 if i >= 0 else len(src)
}

// The first LF outside quotes at or after `from`, or -1. `odd` says whether `from` is inside quotes.
@(private)
outside_lf :: proc(src: []byte, from: int, odd: bool) -> int {
	in_quote := ~u64(0) if odd else 0
	tail: [64]u8 = ---
	for pos := from; pos < len(src); pos += 64 {
		p, _ := core_pkg.block_at(src, pos, &tail)
		v := [4]core_pkg.V{core_pkg.load(p), core_pkg.load(p[16:]), core_pkg.load(p[32:]), core_pkg.load(p[48:])}
		q, n := core_pkg.pack4x2(core_pkg.eq4(v, '"'), core_pkg.eq4(v, '\n'))
		instr := core_pkg.prefix_xor(q) ~ in_quote
		if lf := n & ~instr; lf != 0 {
			return pos + int(intrinsics.count_trailing_zeros(lf))
		}
		in_quote = u64(i64(instr) >> 63)
	}
	return -1
}
