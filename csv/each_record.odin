package csv

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:simd"
import core_pkg "../core"
import "../core/bits"

// Threads a caller lends `each_record` and `validate` (`stury:host`'s `Batch_Pool` is one).
Batch_Runner :: core_pkg.Batch_Runner

// `task` on every piece of `src`, each a `Records` over whole records of `src` in `dialect`, judged at
// `strictness` and capped by `limits` as `records` judges the whole.
//
//	- Pieces are numbered `k` from 0 in source order and handed out once each, possibly with no record.
//	- The caller and `runner`'s threads claim the pieces in turn. Without `runner` the caller has one piece,
//	  the whole input, and so does a dialect with quotes and a comment byte, whose comment lines only a read
//	  from the start tells from a quoted field's lines.
//	- A piece's records carry offsets into `src`, and `src` is their `src`.
//	- The fault returned is the one `records` ends on, the first piece's that holds one. A piece's own is on
//	  its `err` when its task has read it to the end.
//	- Once a task returns false or a piece ends on a fault, no further piece is claimed. Pieces past the
//	  faulty one that were claimed before it ended still run, over records `records` never reaches.
//	- A piece's fields are held in the heap, until its task returns.
@(require_results)
each_record :: proc(
	src: []byte,
	dialect: Dialect,
	task: proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data: rawptr,
	runner: ^Batch_Runner = nil,
	strictness := Strictness.Strict,
	limits := Limits{},
) -> Maybe(Error) {
	s, ok := scan_setup(dialect, limits, strictness)
	if !ok {
		return Error{kind = .Bad_Option}
	}
	run := Batch_Run{src = src, scan = s, task = task, data = data, cursor = {runner = runner}}
	defer delete(run.parity, runtime.heap_allocator())
	batch_plan(&run)
	core_pkg.batch_fan(&run.cursor, proc(arg: rawptr) {batch_claim((^Batch_Run)(arg), false)}, &run)
	return run.first.error
}

// `validate` on `runner`'s threads and the caller, a piece each at a time.
@(private)
validate_pieces :: proc(src: []byte, s: Scan, runner: ^Batch_Runner) -> Maybe(Error) {
	run := Batch_Run{src = src, scan = s, cursor = {runner = runner}}
	defer delete(run.parity, runtime.heap_allocator())
	batch_plan(&run)
	core_pkg.batch_fan(&run.cursor, proc(arg: rawptr) {batch_claim((^Batch_Run)(arg), true)}, &run)
	return run.first.error
}

@(private)
Batch_Run :: struct {
	src:     []byte,
	scan:    Scan,
	// Every record's field count, the first record's, read before the pieces are: 0 when ragged.
	width:   int,
	// `each_record`'s, nil for `validate`.
	task:    proc(data: rawptr, piece: ^Records, k: int) -> bool,
	data:    rawptr,
	cursor:  core_pkg.Batch_Cursor,
	// Under `Quoting.Quotes`: whether an odd count of quotes comes before each slice.
	parity:  []u8,
	counted: int,
	// The first piece that ended on a fault.
	first:   core_pkg.First_Fault,
}

// How many lanes the run takes, and where its pieces may start. One piece, the whole input, when there is
// no runner, too little input, a dialect no split can serve, no first record to take the width from, or no
// memory for the quote parities.
//
// A piece starts past an LF outside quotes, where the scan's state is the input's start's: a field and a
// line start there, and no quote, CR or escape is open. Under `Quoting.None` every LF is one. Under
// `Quoting.Quotes` the scan's quote state at a byte is the parity of the quotes before it, on any input up
// to its first fault, since every quote opens or closes (a doubled `""` is a close and an open): so an LF
// after an even count of quotes is one. A comment line holds quotes that count for nothing, so a comment
// byte under quotes leaves only the whole input.
@(private)
batch_plan :: proc(run: ^Batch_Run) {
	run.cursor.lanes, run.cursor.slices = 1, 1
	s := run.scan
	lanes := core_pkg.batch_lanes(run.cursor.runner, len(run.src))
	if lanes == 1 || .Comments in s.mode && .Unquoted not_in s.mode {
		return
	}
	if !s.ragged {
		width, ok := first_width(run.src, s)
		if !ok {
			return
		}
		run.width = width
	}
	slices := core_pkg.batch_slices(len(run.src))
	if .Unquoted not_in s.mode {
		parity, err := make([]u8, slices, runtime.heap_allocator())
		if err != nil {
			return
		}
		run.parity, run.cursor.lanes = parity, lanes
		core_pkg.batch_fan(&run.cursor, batch_count_quotes, run)
		odd := u8(0)
		for &p in parity {
			p, odd = odd, odd ~ p
		}
	}
	run.cursor.lanes, run.cursor.slices = lanes, slices
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
	acc: bits.V
	q := bits.V('"')
	i := 0
	for ; i + 64 <= len(src); i += 64 {
		p := raw_data(src[i:])
		acc ~= simd.lanes_eq(bits.load(p), q) ~ simd.lanes_eq(bits.load(p[16:]), q) ~ simd.lanes_eq(bits.load(p[32:]), q) ~ simd.lanes_eq(bits.load(p[48:]), q)
	}
	odd := intrinsics.count_ones(bits.pack4(acc, {}, {}, {}))
	for ; i < len(src); i += 1 {
		odd += u64(src[i] == '"')
	}
	return u8(odd & 1)
}

// Claim pieces until none are left. A piece whose last record reaches past the slices after it moves the
// counter past them, since no record starts there. `VALIDATE` is constant so that `each_record` links no
// `validate_span`.
@(private)
batch_claim :: proc(run: ^Batch_Run, $VALIDATE: bool) {
	fields := make([dynamic]Field, runtime.heap_allocator())
	defer delete(fields)
	for s, n, k in core_pkg.cursor_next(&run.cursor) {
		lo := batch_boundary(run, s)
		hi := batch_boundary(run, s + n)
		core_pkg.cursor_skip_to(&run.cursor, hi / core_pkg.BATCH_SLICE)
		fault: Maybe(Error)
		when VALIDATE {
			fault = validate_span(run.src[:hi], lo, run.width, run.scan)
		} else {
			piece := records_of(run.src[:hi], run.scan, runtime.heap_allocator())
			piece.block, piece.field_lo, piece.rec_lo = lo - 64, lo, lo
			piece.width, piece.fields = run.width, fields
			if !run.task(run.data, &piece, k) {
				core_pkg.cursor_stop(&run.cursor)
			}
			fault = piece.err
			fields = piece.fields
			clear(&fields)
		}
		if e, bad := fault.?; bad {
			core_pkg.first_fault_note(&run.first, k, e)
			core_pkg.cursor_stop(&run.cursor)
		}
	}
}

// Where the records from slice `k` on start: past the first LF outside quotes at or after the slice's
// offset's previous byte, or the input's end when there is none. Slice 0 starts at the input's first byte
// past its BOM.
@(private)
batch_boundary :: proc(run: ^Batch_Run, k: int) -> int {
	src := run.src
	if k == 0 {
		return core_pkg.bom_len(src)
	}
	at := k * core_pkg.BATCH_SLICE
	if k >= run.cursor.slices || at >= len(src) {
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

// The first LF at or after `from` outside quotes, where `odd` says `from` is inside them, or -1.
@(private)
outside_lf :: proc(src: []byte, from: int, odd: bool) -> int {
	in_quote := ~u64(0) if odd else 0
	tail: [64]u8 = ---
	for pos := from; pos < len(src); pos += 64 {
		p, _ := bits.block_at(src, pos, &tail)
		v := [4]bits.V{bits.load(p), bits.load(p[16:]), bits.load(p[32:]), bits.load(p[48:])}
		q, n := bits.pack4x2(bits.eq4(v, '"'), bits.eq4(v, '\n'))
		instr := bits.prefix_xor(q) ~ in_quote
		if lf := n & ~instr; lf != 0 {
			return pos + int(intrinsics.count_trailing_zeros(lf))
		}
		in_quote = u64(i64(instr) >> 63)
	}
	return -1
}
