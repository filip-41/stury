package csv

import "base:runtime"
import core_pkg "../core"

// A typed read of many records of one struct type, one row per call: `record_read_init` resolves the plan, the
// row shape and the header's columns once, and each `unmarshal` of it pulls the next record and reads it as
// `unmarshal` reads a row. A fault's offset is into that row's bytes; `record_read_at` gives the row's offset
// in the input.
//
// The pull is a `^Records` or a `^Record_Reader`, both caller-owned. The iterator frames the bytes with its own
// dialect, limits and strictness, so create it with the reader's: the reader never re-scans. Its `borrow_strings`
// binds the column table at init. The rest of the options apply at every row.
//
// It is a value: `record_read_init` allocates the reader's state on the heap, and `record_read_destroy` frees it
// with the plan the reader made. A copy shares both, so destroy it once.
Record_Read :: core_pkg.Record_Read(Unmarshal_Opts)

// What a `Record_Read`'s source holds: the pull, the column-bound row reader, and the row it last read. Its
// fields are the reader's own except `r`, which is this file's.
@(private)
Record_State :: struct {
	r:                 Reader,
	it:                ^Records, // nil for the streaming source
	rr:                ^Record_Reader,
	// The allocator the column table was made with: a slice freed with the allocator in force would go to a
	// different one.
	columns_allocator: runtime.Allocator,
	at:                u64,
	row:               int,
	// The scan skipped UTF-8 at creation, so its faults are not carried: every row is judged by itself.
	judge_each_row:    bool,
	// An earlier read was lazy, so a cell this row does not read may hold a fault the scan deferred: a strict
	// read judges every cell.
	lazy_seen:         bool,
}

// The state's own heap. Its lifetime is the reader's, not a row's.
@(private)
record_state_new :: proc() -> ^Record_State {
	return new(Record_State, runtime.heap_allocator())
}

@(private)
record_state_free :: proc(state: rawptr) {
	st := (^Record_State)(state)
	delete(st.r.columns, st.columns_allocator)
	delete(st.r.cols, st.columns_allocator)
	delete(st.r.required)
	delete(st.r.req_more)
	free(st, runtime.heap_allocator())
}

// The pull `next_record` reads: the stream's window when the source is a `Record_Reader`.
@(private)
record_state_pull :: proc(st: ^Record_State) -> (rec: Record, ok: bool) {
	if st.rr != nil {
		return next_record(st.rr)
	}
	return next_record(st.it)
}

@(private)
record_state_records :: proc(st: ^Record_State) -> ^Records {
	return &st.rr.it if st.rr != nil else st.it
}

// The fault that ended the pull: the window's, or the iterator's. Nil when it ended at the input's end.
@(private)
record_state_error :: proc(st: ^Record_State) -> Maybe(Error) {
	return st.rr.err if st.rr != nil else st.it.err
}

// The pull's fault as a read's refusal. A `.Syntax` offset is in the input, not in a row: no record framed it.
@(private)
record_framing_error :: proc(e: Error) -> Maybe(Unmarshal_Error) {
	#partial switch e.kind {
	case .Out_Of_Memory:
		return Unmarshal_Error{kind = .Out_Of_Memory}
	case .Bad_Option:
		return Unmarshal_Error{kind = .Bad_Option}
	}
	return Unmarshal_Error{kind = .Syntax, syntax = e.kind, offset = e.offset}
}

// Resolve the plan, the row shape and the header's columns, and read one row per `unmarshal`.
//
//	- The iterator's records are the rows: `record_read_init` consumes its header, or leaves the first record
//	  for the first read under `no_header`.
//	- `allocator` is the one each row's values are read with; the state and the plan the reader makes are the
//	  heap's. A plan made here is freed by `record_read_destroy`.
@(require_results)
record_read_init :: proc {
	record_read_init_records,
	record_read_init_reader,
}

// `record_read_init` over an input's framed records.
@(require_results)
record_read_init_records :: proc(
	rd: ^Record_Read,
	$T: typeid,
	it: ^Records,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> Maybe(Unmarshal_Error) {
	if it == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	return record_read_init_source(rd, T, it, nil, opts, plan, allocator)
}

// `record_read_init` over a stream's window.
@(require_results)
record_read_init_reader :: proc(
	rd: ^Record_Read,
	$T: typeid,
	rr: ^Record_Reader,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> Maybe(Unmarshal_Error) {
	if rr == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	return record_read_init_source(rd, T, nil, rr, opts, plan, allocator)
}

@(private)
record_read_init_source :: proc(
	rd: ^Record_Read,
	$T: typeid,
	it: ^Records,
	rr: ^Record_Reader,
	opts: Unmarshal_Opts,
	plan: ^Type_Plan,
	allocator: runtime.Allocator,
) -> Maybe(Unmarshal_Error) {
	if rd == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	record_read_destroy(rd)
	// A dialect or limit the scanner refuses is refused here, as `unmarshal` refuses it before any byte.
	if _, ok := scan_setup(opts.dialect, opts.limits, .Structural if opts.strictness == .Structural else .Strict); !ok {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	state := record_state_new()
	if state == nil {
		return Unmarshal_Error{kind = .Out_Of_Memory}
	}
	state.it, state.rr = it, rr
	state.columns_allocator = context.allocator
	state.r.allocator = allocator
	state.r.dialect = opts.dialect
	state.r.borrow = opts.borrow_strings
	source := core_pkg.Record_Source(Unmarshal_Opts){
		state = state,
		read = record_source_read,
		destroy = record_state_free,
		format = csv_plan_format(),
	}
	base: ^core_pkg.Type_Plan
	if plan != nil {
		base = &plan.base
	}
	if err := core_pkg.record_read_init(rd, T, source, opts, base, runtime.heap_allocator()); err != nil {
		return err
	}
	if err := row_reader(&state.r, rd.plan, false); err != nil {
		record_read_destroy(rd)
		return err
	}
	state.r.enum_ints = rd.plan.opts.enums == .Int
	recs := record_state_records(state)
	if opts.strictness == .Lazy {
		// The scan defers its UTF-8 faults to the reader, which judges the cells a field reads. A scan that skips
		// them carries none, so each row is judged alone.
		if .Skip_Utf8 in recs.scan.mode {
			state.judge_each_row = true
		} else {
			recs.carry.utf8 = max(int)
		}
		state.lazy_seen = true
	}
	if opts.no_header {
		return nil
	}
	header, more := record_state_pull(state)
	if !more {
		if e, faulted := record_state_error(state).?; faulted {
			record_read_destroy(rd)
			return record_framing_error(e)
		}
		// No header and no fault: an input with no record at all is an empty table.
		return nil
	}
	state.r.src = header.src
	if opts.strictness == .Lazy && recs.carry.utf8 <= int(header.fields[len(header.fields) - 1].hi) {
		if err := judge_utf8(&state.r, recs, header, -1); err != nil {
			record_read_destroy(rd)
			return err
		}
	}
	if err := read_header(&state.r, header, opts.unknown_fields == .Refuse, opts.duplicates); err != nil {
		record_read_destroy(rd)
		return err
	}
	return nil
}

// Free the plan the reader made, the column table and the state, and clear the handle. `csv.destroy` and a copy
// of the handle share the reader, so destroy it once.
record_read_destroy :: proc(rd: ^Record_Read) {
	core_pkg.record_read_destroy(rd)
}

// The offset of the row the last read pulled, from the input's first byte. A reader that has pulled none is at
// 0. A fault's offset is into the row's bytes, so adding this says where it is in the input.
@(require_results)
record_read_at :: proc(rd: ^Record_Read) -> u64 {
	if rd == nil {
		return 0
	}
	state := (^Record_State)(rd.source.state)
	return state == nil ? 0 : state.at
}

// Pull the next row and read it. The end of the input is `.Bad_Option`; a fault that framed no row is `.Syntax`
// at its offset in the input.
@(private)
record_source_read :: proc(state: rawptr, opts: ^Unmarshal_Opts, _: ^core_pkg.Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error) {
	st := (^Record_State)(state)
	rec, more := record_state_pull(st)
	if !more {
		if e, faulted := record_state_error(st).?; faulted {
			return record_framing_error(e)
		}
		return Unmarshal_Error{kind = .Bad_Option}
	}
	st.at = rec.at
	st.r.src = rec.src
	// The row's index, for the path, counts the rows the pull has yielded, read or refused.
	row := st.row
	st.row += 1
	if st.r.columns == nil {
		// `no_header`: column k is the struct's field k.
		if err := columns_in_order(&st.r, rec, opts.unknown_fields == .Refuse); err != nil {
			return record_row_error(st, err)
		}
	}
	recs := record_state_records(st)
	lazy := opts.strictness == .Lazy
	if lazy {
		st.lazy_seen = true
		// A skipped scan carries no fault: each row is judged by itself.
		if st.judge_each_row {
			recs.carry.utf8 = -1
		}
	} else if st.lazy_seen {
		if err := judge_utf8(&st.r, recs, rec, -1); err != nil {
			return record_row_error(st, err)
		}
	}
	cells := rec.fields
	if lazy || st.r.dialect.ragged {
		if trimmed, err := record_cells(&st.r, recs, rec, row, lazy, opts.unknown_fields == .Refuse); err != nil {
			return record_row_error(st, err)
		} else {
			cells = trimmed
		}
	}
	if kind, at, name, refused := read_row(&st.r, cells, dest); refused {
		return record_row_error(st, cell_error(kind, at, row, core_pkg.Name(name)))
	}
	return nil
}

// `err`, a fault of the row just pulled, with its offset moved into the row's bytes.
@(private)
record_row_error :: proc(st: ^Record_State, err: Maybe(Unmarshal_Error)) -> Maybe(Unmarshal_Error) {
	if e, faulted := err.?; faulted {
		e.offset = e.offset - st.at if e.offset >= st.at else 0
		return e
	}
	return nil
}
