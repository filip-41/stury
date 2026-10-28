package json

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// A typed read of many JSON records of one type: `unmarshal` of it pulls the next record of a `Records` and reads
// its bytes as `unmarshal` of those bytes would. The contract is `core.Record_Read`'s. `record_read_at` gives the
// record's offset in the input, as `Record.at` does.
//
// The pull is a `^Records` or a `^Record_Reader`, caller-owned: it must outlive the reader and not move, as the
// reader's state points at it. A fault that framed no record is `.Syntax`, and a `Record_Reader` whose reader
// failed ends the records with `.Syntax` `.Truncated` at the end of the bytes it gave (`read_err` is the cause),
// both with their offset in the input and `record_read_at` 0. Over a pushed reader (`records_pushed`) `more` is also
// false, with no `err`, where it wants a window (`record_carry`); once pushed, the reads go on.
Record_Read :: core_pkg.Record_Read(Unmarshal_Opts)

// What a `Record_Read`'s source holds. The run, `base` and `q` are bound to `bound_plan` and `bound_opts`, so no
// pointer into the handle is kept.
@(private)
Record_State :: struct {
	run:        walk.Shape_Run,
	q:          ^scan_pkg.Query_Ctx,
	it:         ^Records, // nil for a `Record_Reader`
	rr:         ^Record_Reader,
	bound_plan: ^core_pkg.Type_Plan, // nil until the first read
	bound_opts: Unmarshal_Opts,      // the options the run, `base` and `q` are bound under
	lazy:       bool,
	descends:   bool,                // the typed descent may take a record under `bound_opts`
	base:       scan_pkg.Scanner,
	ctx_words:  [size_of(scan_pkg.Query_Ctx) / 8]u64,
	frames:     [MAX_DEPTH]walk.Shape_Frame,
	wide:       [walk.SHAPE_WIDE_WORDS]u64,
}

// The heap's, not the read's allocator: a caller reads records into an arena freed whole while the state outlives it.
@(private)
record_state_free :: proc(state: rawptr) {
	free((^Record_State)(state), runtime.heap_allocator())
}

// `allocator` is the one each record is read with; the state and a plan the reader makes are the heap's.
@(require_results)
record_read_init :: proc(
	rd: ^Record_Read,
	$T: typeid,
	pull: $P,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator: runtime.Allocator,
) -> Maybe(Unmarshal_Error) where P == ^Records || P == ^Record_Reader {
	if rd == nil || pull == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	core_pkg.record_read_destroy(rd)
	if record_opts_refused(opts) {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	state := new(Record_State, runtime.heap_allocator())
	if state == nil {
		return Unmarshal_Error{kind = .Out_Of_Memory}
	}
	when P == ^Records {
		state.it = pull
	} else {
		state.rr = pull
	}
	source := core_pkg.Record_Source(Unmarshal_Opts){
		state = state,
		read = record_source_read,
		destroy = record_state_free,
		format = json_plan_format,
	}
	if err := core_pkg.record_read_init(rd, T, source, opts, plan, runtime.heap_allocator()); err != nil {
		return err
	}
	state.run = walk.Shape_Run{
		frames = &state.frames,
		wide = state.wide[:],
		allocator = allocator,
	}
	state.q = (^scan_pkg.Query_Ctx)(&state.ctx_words)
	return nil
}

// The offset of the record the last read pulled, from the input's first byte. 0 before the first read.
record_read_at :: core_pkg.record_read_at

@(private)
record_source_read :: #force_inline proc(state: rawptr, opts: ^Unmarshal_Opts, plan: ^core_pkg.Type_Plan, dest: rawptr, at: ^u64) -> (more: bool, err: Maybe(Unmarshal_Error)) {
	st := (^Record_State)(state)
	rec: Record
	ok: bool
	if st.rr != nil {
		rec, ok = next_record(st.rr)
	} else {
		rec, ok = next_record(st.it)
	}
	if !ok {
		// No record is read: the frame is the input's.
		at^ = 0
		return false, core_pkg.record_state_failure(st)
	}
	at^ = rec.at
	return true, read_record(st, rec.bytes, opts, plan, dest)
}

// Whether two option values are bitwise equal. Padding is part of the compare: `bound_opts` is a bitwise copy of
// the options it was bound under, so a mismatch in padding only rebinds.
@(private)
record_opts_same :: #force_inline proc(a, b: ^Unmarshal_Opts) -> bool {
	WORDS :: size_of(Unmarshal_Opts) / size_of(u64)
	#assert(size_of(Unmarshal_Opts) % size_of(u64) == 0)
	x, y := (^[WORDS]u64)(a), (^[WORDS]u64)(b)
	diff: u64
	#unroll for i in 0 ..< WORDS {
		diff |= x[i] ~ y[i]
	}
	return diff == 0
}

// A record starts with no typed fault, no open key and no lazy probe carried over. A string's escape facts are
// reset by the string leaf.
@(private)
read_record :: #force_inline proc(st: ^Record_State, src: []byte, opts: ^Unmarshal_Opts, plan: ^core_pkg.Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error) {
	if plan != st.bound_plan || !record_opts_same(opts, &st.bound_opts) {
		if record_opts_refused(opts^) {
			return Unmarshal_Error{kind = .Bad_Option}
		}
		record_bind(st, plan, opts)
	}
	run := &st.run
	run.src = src
	run.fault = .None
	run.skip_pays = false
	if st.descends {
		// Under the lazy gate the probe is the same one `read_planned` runs; below it, nothing is skipped.
		if !st.lazy || u64(len(src)) < scan_pkg.SHAPE_LAZY_MIN_BYTES || scan_pkg.shape_lazy_reads_all(src, run, opts.limits) {
			st.q.key_esc_live, st.q.key_saw_escape = false, false
			s := st.base
			s.src = src
			s.pos = u64(scan_pkg.bom_len(src))
			s.alloc = context.allocator
			read, oom := scan_pkg.shape_descend_value(&s, st.q, dest)
			if e, refused := oom.?; refused {
				return unmarshal_error_of(run, scan_pkg.error_of(e))
			}
			if read {
				return nil
			}
		}
	}
	return record_walk(st, src, opts^, dest)
}

@(private)
record_bind :: #force_no_inline proc(st: ^Record_State, plan: ^core_pkg.Type_Plan, opts: ^Unmarshal_Opts) {
	shape_run_bind(&st.run, &plan.read, plan, opts^)
	st.base = scan_pkg.shape_bind(&st.run, st.q, nil, opts.limits)
	st.lazy = opts.strictness == .Lazy
	st.descends = descent_takes(&plan.read, opts^)
	st.bound_plan = plan
	(^[size_of(Unmarshal_Opts) / size_of(u64)]u64)(&st.bound_opts)^ = (^[size_of(Unmarshal_Opts) / size_of(u64)]u64)(opts)^
}

// The shape walk, for a value the descent does not take. The same dispatch as `read_planned`.
@(private)
record_walk :: #force_no_inline proc(st: ^Record_State, src: []byte, opts: Unmarshal_Opts, dest: rawptr) -> Maybe(Unmarshal_Error) {
	run := &st.run
	run.sp = 0
	run.wide_top = 0
	run.cur_live = false
	run.raw_open = false
	run.pend_live = false
	if e, refused := shape_verdict(src, run, dest, opts).?; refused {
		return unmarshal_error_of(run, e)
	}
	return nil
}

// Whether a record read refuses `opts`. `.Structural` stores what it reads, so a JSON read refuses it unless
// the dialect checks the rest; a dialect `records_read` refuses has no record walk.
@(private = "file")
record_opts_refused :: proc(opts: Unmarshal_Opts) -> bool {
	if !scan_pkg.records_read(opts.dialect) {
		return true
	}
	return opts.strictness == .Structural && scan_pkg.plain_json(opts.dialect)
}
