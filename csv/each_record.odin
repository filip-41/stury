package csv

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:simd"
import core_pkg "../core"

// Threads a caller lends `each_record`, `validate` and `validate_records` (`stury:host`'s `Batch_Pool`
// is one).
Batch_Runner :: core_pkg.Batch_Runner

// A record `validate_records` refuses: its bytes are src[lo:hi], and `err`'s offset is into `src` (`core`'s
// type, so a caller using several formats writes one fault).
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
	run.driver = {
		cursor = {runner = runner},
		data = &run,
		none = len(src),
		boundary = batch_boundary,
		skip = batch_skip,
		piece = piece_task,
		// A piece's fault is ranked by its number: the first faulty piece, which is the fault `records` ends on.
		fault_rank = piece_fault_rank,
		// A fault ends the records after it, so the pieces past it are not claimed.
		stop_on_fault = true,
	}
	return run_batch(&run)
}

// Every record of `src` that `validate` refuses, in source order, each with its bytes src[lo:hi] and its
// fault's offset into `src`. `opts` is read as `validate` reads it.
//
//	- `err` is the first fault in `src`, which `validate` finds on the runner's threads; a clean text is that
//	  scan and no list at all.
//	- A refused record's bytes run from its first byte to the LF that ends its line, and the read resumes at the
//	  line after that: a refused record's end cannot be trusted, and the quote, escape and UTF-8 state before it
//	  is not carried over. The faults of the whole text are listed, whichever threads found the first one.
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
	err = validate(src, opts, runner)
	if err == nil {
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
		// The refused record starts at the open record's first byte; a field count or a limit names that byte
		// itself, which the read has already left behind. `.Out_Of_Memory` names no byte.
		lo := u64(read.rec_lo)
		if fault.kind != .Out_Of_Memory {
			lo = min(lo, fault.offset)
		}
		// Its bytes run to the LF that ends its line, or to the fault at the input's end, which no line follows.
		from := max(min(fault.offset, u64(len(src))), lo)
		line := bytes.index_byte(src[from:], '\n')
		hi := from
		if line >= 0 {
			hi = from + u64(line)
		}
		core_pkg.fault_list_add(&lists, 0, Record_Fault{lo = lo, hi = hi, err = fault})
		if line < 0 || int(hi) + 1 >= len(src) {
			break
		}
		resume_read(&read, src, int(hi) + 1)
	}
	merged, merr := core_pkg.fault_list_merge(&lists, max(u64), allocator)
	if merr != nil {
		return nil, merr
	}
	return merged, err
}

// `it`, whose read stopped on a fault, reading on from `at`, a line's first byte of a text that starts there.
// The field count it was judging against stands.
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
	run.driver = {
		cursor = {runner = runner},
		data = &run,
		none = len(src),
		boundary = batch_boundary,
		skip = batch_skip,
		piece = piece_validate,
		fault_rank = piece_fault_rank,
		stop_on_fault = true,
	}
	return run_batch(&run)
}

// Plans `run`'s pieces and claims them on the caller and the runner's threads; the first faulty piece's fault.
@(private)
run_batch :: proc(run: ^Batch_Run) -> Maybe(Error) {
	defer delete(run.parity, runtime.heap_allocator())
	batch_plan(run)
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
batch_plan :: proc(run: ^Batch_Run) {
	c := &run.driver.cursor
	c.lanes, c.slices = 1, 1
	lanes := core_pkg.batch_lanes(c.runner, len(run.src))
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
	slices := core_pkg.batch_slices(len(run.src))
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

// Runs the task on the piece of records from `lo` up to `hi`, numbered `k`, and frees its fields once it
// returns.
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

// `validate_span` of the piece of records from `lo` up to `hi`.
@(private)
piece_validate :: proc(data: rawptr, lo, hi: int, _: int) -> (fault: Maybe(Error), go_on: bool) {
	run := (^Batch_Run)(data)
	return validate_span(run.src[:hi], lo, run.width, run.scan), true
}

// The rank of a piece's fault: its number, so the batch returns the first faulty piece's.
@(private)
piece_fault_rank :: proc(_: rawptr, k: int, _: Error) -> int {
	return k
}

// Where the records from slice `k` on start: just past the first LF outside quotes at or after the byte before
// the slice's offset, or the input's end when there is none. Slice 0 starts at the input's first byte past
// its BOM. A piece ends at the next boundary, however far past the claim that is.
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

// The slice whose start is the piece's `hi`: a piece's records end at the first boundary past it.
@(private)
batch_skip :: proc(_: rawptr, _: int, hi: int) -> int {
	return hi / core_pkg.BATCH_SLICE
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
