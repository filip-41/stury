package json

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// A typed read of many JSON records of one type: `unmarshal` of it pulls the next record of a `Records` and reads
// its bytes as `unmarshal` of those bytes would. The contract is `core.Record_Read`'s. `record_read_at` gives the
// record's offset in the input, as `Record.at` does.
//
// The `Records` must outlive the reader and not move: the reader's state points at it. A fault that framed no
// record is `.Syntax`.
Record_Read :: core_pkg.Record_Read(Unmarshal_Opts)

// What a `Record_Read`'s source holds. The run, `base` and `q` are bound to `bound_plan` and `bound_opts`, so no
// pointer into the handle is kept.
@(private)
Record_State :: struct {
	run:        walk.Shape_Run,
	q:          ^scan_pkg.Query_Ctx,
	it:         ^Records,
	at:         u64,
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
record_state_new :: proc() -> ^Record_State {
	return new(Record_State, runtime.heap_allocator())
}

@(private)
record_state_free :: proc(state: rawptr) {
	free((^Record_State)(state), runtime.heap_allocator())
}

// `allocator` is the one each record is read with; the state and a plan the reader makes are the heap's.
@(require_results)
record_read_init :: proc(
	rd: ^Record_Read,
	$T: typeid,
	it: ^Records,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> Maybe(Unmarshal_Error) {
	if rd == nil || it == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	record_read_destroy(rd)
	if record_opts_refused(opts) {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	state := record_state_new()
	if state == nil {
		return Unmarshal_Error{kind = .Out_Of_Memory}
	}
	state.it = it
	source := core_pkg.Record_Source(Unmarshal_Opts){
		state = state,
		read = record_source_read,
		destroy = record_state_free,
		format = json_plan_format(),
	}
	base: ^core_pkg.Type_Plan
	if plan != nil {
		base = &plan.base
	}
	if err := core_pkg.record_read_init(rd, T, source, opts, base, runtime.heap_allocator()); err != nil {
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
@(require_results)
record_read_at :: proc(rd: ^Record_Read) -> u64 {
	if rd == nil {
		return 0
	}
	state := (^Record_State)(rd.source.state)
	return state == nil ? 0 : state.at
}

@(private)
record_source_read :: #force_inline proc(state: rawptr, opts: ^Unmarshal_Opts, plan: ^core_pkg.Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error) {
	st := (^Record_State)(state)
	rec, ok := next_record(st.it)
	if !ok {
		// No record is read: the frame is the input's.
		st.at = 0
		if e, faulted := st.it.err.?; faulted {
			return record_framing_error(e)
		}
		return Unmarshal_Error{kind = .Bad_Option}
	}
	st.at = rec.at
	return read_record(st, rec.bytes, opts, plan, dest)
}

// The iterator's framing fault, which no record holds.
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
				return unmarshal_error_of(run, e)
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
	run := &st.run
	run.shape = &plan.read
	run.enum_ints = plan.opts.enums == .Int
	run.union_tag = plan.opts.union_tag
	run.borrow = opts.borrow_strings
	run.refuse_unknown = opts.unknown_fields == .Refuse
	run.keep_first = opts.duplicates == .First
	run.read_over = opts.duplicates == .All
	st.base = scan_pkg.shape_bind(run, st.q, nil, opts.limits)
	st.lazy = opts.strictness == .Lazy
	st.descends = run.shape.descends && opts.dialect == .Json && opts.duplicates != .Refuse
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

// `core_pkg.record_read_destroy`, for `destroy`'s overload set, which names this package's procedures.
@(private)
record_read_destroy :: proc(rd: ^Record_Read) {
	core_pkg.record_read_destroy(rd)
}

// Whether a record read refuses `opts`. `.Structural` stores what it reads, so a JSON read refuses it unless
// the dialect checks the rest (JSONC); `.Json5` has no record walk.
@(private = "file")
record_opts_refused :: proc(opts: Unmarshal_Opts) -> bool {
	switch opts.dialect {
	case .Json:
		return opts.strictness == .Structural
	case .Jsonc:
		return false
	case .Json5:
		return true
	}
	return true
}
