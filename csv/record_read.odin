package csv

import "base:runtime"
import core_pkg "../core"

// A typed read of many records of one struct type, core's `Record_Read`: `record_read_init` resolves the plan,
// the row shape and the header's columns once, and each `unmarshal` of it pulls the next record and reads it as
// `unmarshal` reads a row. A fault's offset is into that row's bytes; `record_read_at` gives the row's offset
// in the input.
//
// The pull is a `^Records` or a `^Record_Reader`, caller-owned: they must outlive the reader and not move. The
// iterator's records are the rows: `record_read_init` consumes its header, or leaves the first record for the
// first read under `no_header`. Its scan must be the one the reader's dialect, limits and strictness make
// (`.Bad_Option` otherwise; a `.Lazy` reader also takes a `.Strict` one), since the reader never re-scans.
//
// `dialect`, `limits`, `no_header`, `duplicates` and `borrow_strings` are bound at init. `strictness` and
// `unknown_fields` apply at every row.
//
// A fault that framed no row, and a `Record_Reader` whose reader failed (`.Syntax` `.Truncated` at the end of
// the bytes it gave; `read_err` is the cause), end the rows with their offset in the input and `record_read_at`
// 0. A refused row leaves the reader ready for the next.
Record_Read :: core_pkg.Record_Read(Unmarshal_Opts)

@(private)
Record_State :: struct {
	r:                 Reader,
	it:                ^Records, // nil for the streaming source
	rr:                ^Record_Reader,
	columns_allocator: runtime.Allocator,
	at:                u64,
	row:               int,
	// The scan skipped UTF-8, so its faults are not carried: every row is judged by itself. A `.Lazy` reader
	// over a scan that judged UTF-8 takes over its faults, which it judges in the cells a field reads.
	judge_each_row:    bool,
	// A lazy read happened (or the scan skipped UTF-8), so a `.Strict` read must judge every cell.
	lazy_seen:         bool,
}

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

// Why the pull stopped, as a read's refusal, or nil when it ended at the input's end.
@(private)
record_state_failure :: proc(st: ^Record_State) -> Maybe(Unmarshal_Error) {
	if st.rr == nil {
		return record_framing_error(st.it.err.?) if st.it.err != nil else nil
	}
	if e, faulted := st.rr.err.?; faulted {
		return record_framing_error(e)
	}
	if st.rr.read_err != nil {
		return Unmarshal_Error{kind = .Syntax, syntax = .Truncated, offset = st.rr.base + u64(st.rr.hi)}
	}
	return nil
}

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

// `allocator` is the one each row's values are read with; the state and the plan the reader makes are the
// heap's, freed by `record_read_destroy`.
@(require_results)
record_read_init :: proc {
	record_read_init_records,
	record_read_init_reader,
}

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
	want, ok := scan_setup(opts.dialect, opts.limits, opts.strictness)
	if !ok {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	have := (&rr.it if rr != nil else it).scan
	judging := want
	judging.mode -= {.Skip_Utf8}
	if have != want && !(opts.strictness == .Lazy && have == judging) {
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
	if err := row_reader(&state.r, core_pkg.record_read_plan(rd), false); err != nil {
		record_read_destroy(rd)
		return err
	}
	state.r.enum_ints = core_pkg.record_read_plan(rd).opts.enums == .Int
	recs := record_state_records(state)
	state.judge_each_row = .Skip_Utf8 in recs.scan.mode
	if opts.strictness == .Lazy && !state.judge_each_row {
		recs.carry.utf8 = max(int)
	}
	state.lazy_seen = opts.strictness == .Lazy || state.judge_each_row
	if opts.no_header {
		return nil
	}
	header, more := record_state_pull(state)
	if !more {
		if failure := record_state_failure(state); failure != nil {
			record_read_destroy(rd)
			return failure
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

record_read_destroy :: proc(rd: ^Record_Read) {
	core_pkg.record_read_destroy(rd)
}

// The offset in the input of the row the last read pulled; 0 before any.
@(require_results)
record_read_at :: proc(rd: ^Record_Read) -> u64 {
	if rd == nil {
		return 0
	}
	state := (^Record_State)(rd.source.state)
	return state == nil ? 0 : state.at
}

@(private)
record_source_read :: proc(state: rawptr, opts: ^Unmarshal_Opts, _: ^core_pkg.Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error) {
	st := (^Record_State)(state)
	rec, more := record_state_pull(st)
	if !more {
		st.at = 0
		if failure := record_state_failure(st); failure != nil {
			return failure
		}
		return Unmarshal_Error{kind = .Bad_Option}
	}
	st.at = rec.at
	st.r.src = rec.src
	row := st.row
	st.row += 1
	if st.r.columns == nil {
		context.allocator = st.columns_allocator
		if err := columns_in_order(&st.r, rec, opts.unknown_fields == .Refuse); err != nil {
			return record_row_error(st, err)
		}
	}
	recs := record_state_records(st)
	lazy := opts.strictness == .Lazy
	if lazy {
		st.lazy_seen = true
		if st.judge_each_row {
			recs.carry.utf8 = -1
		}
	} else if opts.strictness == .Strict && st.lazy_seen {
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

// `err`, a fault of the row just pulled, with its offset moved into the row's bytes. A cell is at a position of
// the bytes the row's fields index: the input, or the stream's window, whose first byte is at `rr.base`.
@(private)
record_row_error :: proc(st: ^Record_State, err: Maybe(Unmarshal_Error)) -> Maybe(Unmarshal_Error) {
	if e, faulted := err.?; faulted {
		lo := st.at - st.rr.base if st.rr != nil else st.at
		e.offset = e.offset - lo if e.offset >= lo else 0
		return e
	}
	return nil
}
