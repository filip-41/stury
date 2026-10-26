package json

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// A typed read of many JSON records of one type. `record_read_init` resolves the plan and the read shape once,
// and each `unmarshal` of it pulls the next record of a `Records` and reads that record's bytes as `unmarshal`
// of those bytes would. A fault's offset is into those bytes; `record_read_at` gives the record's offset in the
// input, so a caller places it as `Record.at` was.
//
// The `Records` is the caller's: it must outlive the reader and not move, since the reader's state points at it.
// The end of the records is `.Bad_Option`; a fault that framed no record is `.Syntax`, with an offset in the
// input and `record_read_at` 0.
//
// It is a value: `record_read_init` allocates the pull's state on the heap, and `destroy` frees it with the plan
// the reader made. A copy shares both, so destroy a reader once. `opts` is read again at every record, so an
// option changed between records takes effect on the next one.
Record_Read :: core_pkg.Record_Read(Unmarshal_Opts)

// What a `Record_Read`'s source holds: the records it pulls, the walk's frames and query context, and the last
// record's offset. The run is bound to the plan a read arrives with, and bound again when it differs, so no
// pointer into the handle is kept; the options are applied at each read. Its fields are the reader's own.
@(private)
Record_State :: struct {
	run:        walk.Shape_Run,
	q:          ^scan_pkg.Query_Ctx,
	it:         ^Records,
	at:         u64,
	bound_plan: ^core_pkg.Type_Plan, // nil until the first read
	base:       scan_pkg.Scanner,
	ctx_words:  [size_of(scan_pkg.Query_Ctx) / 8]u64,
	frames:     [MAX_DEPTH]walk.Shape_Frame,
	wide:       [walk.SHAPE_WIDE_WORDS]u64,
}

// The state's own heap. Its lifetime is the reader's, not a read's: a caller reads records into an arena and
// frees that whole, while the state outlives it. `new` zeroes it, and it is freed with the same allocator.
@(private)
record_state_new :: proc() -> ^Record_State {
	return new(Record_State, runtime.heap_allocator())
}

@(private)
record_state_free :: proc(state: rawptr) {
	free((^Record_State)(state), runtime.heap_allocator())
}

// Resolve the plan and the shape for `T` under `opts`, the same refusal `unmarshal` gives before any byte
// (`.Bad_Option`, `.Plan_Mismatch`, `.Unsupported`, `.Bad_Tag`, or `.Out_Of_Memory` for the state or lowering the plan).
// `allocator` is the one each record is read with; the state and the plan the reader makes are the heap's. A
// plan made here is freed by `destroy`.
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
	if opts.strictness == .Structural && opts.dialect != .Jsonc {
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

// The offset of the record the last read pulled, from the input's first byte: the `Record.at` of that record.
// A reader that has pulled none is at 0. A fault's offset is into the record's bytes, so it says where the
// fault is in the input.
@(require_results)
record_read_at :: proc(rd: ^Record_Read) -> u64 {
	if rd == nil {
		return 0
	}
	state := (^Record_State)(rd.source.state)
	return state == nil ? 0 : state.at
}

// Pull the next record and read it. A fault that framed no record is `.Syntax` at its offset in the input; the
// end of the input is `.Bad_Option`.
@(private)
record_source_read :: proc(state: rawptr, opts: ^Unmarshal_Opts, plan: ^core_pkg.Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error) {
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

// One record. The options are applied here, so an option changed after `record_read_init` takes effect on the
// next record. A record starts with no typed fault, no open key and no lazy probe carried over. A string's
// escape facts are reset by the string leaf.
@(private)
read_record :: #force_inline proc(st: ^Record_State, src: []byte, opts: ^Unmarshal_Opts, plan: ^core_pkg.Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error) {
	run := &st.run
	// `.Structural` stores what it reads, so a JSON read refuses it unless the dialect checks the rest (JSONC).
	if opts.strictness == .Structural && opts.dialect != .Jsonc {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if plan != st.bound_plan {
		record_bind(st, plan)
	}
	run.src = src
	run.fault = .None
	run.skip_pays = false
	run.borrow = opts.borrow_strings
	run.refuse_unknown = opts.unknown_fields == .Refuse
	run.keep_first = opts.duplicates == .First
	run.read_over = opts.duplicates == .All
	lazy := opts.strictness == .Lazy
	if run.shape.descends && opts.dialect == .Json && opts.duplicates != .Refuse {
		// Under the lazy gate the probe is the same one `read_planned` runs; below it, nothing is skipped.
		small := u64(len(src)) < scan_pkg.SHAPE_LAZY_MIN_BYTES
		if !lazy || small || scan_pkg.shape_lazy_reads_all(src, run, opts.limits) {
			st.q.key_esc_live, st.q.key_saw_escape = false, false
			s := st.base
			s.src = src
			s.pos = u64(scan_pkg.bom_len(src))
			s.alloc = context.allocator
			s.limits = scan_pkg.resolve_under(opts.limits, scan_pkg.MAX_DEPTH)
			st.q.max_depth = s.limits.max_depth
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

// Bind the run, the query context and the base scanner to `plan`.
@(private)
record_bind :: #force_no_inline proc(st: ^Record_State, plan: ^core_pkg.Type_Plan) {
	run := &st.run
	run.shape = &plan.read
	run.enum_ints = plan.opts.enums == .Int
	run.union_tag = plan.opts.union_tag
	st.base = scan_pkg.shape_bind(run, st.q, nil, {})
	st.bound_plan = plan
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
	lazy := opts.strictness == .Lazy
	refuse := opts.duplicates == .Refuse
	verdict: Maybe(Error)
	if opts.dialect == .Jsonc {
		verdict = scan_pkg.scan_shape(src, run, dest, lazy, opts.limits, .Jsonc, false) if !refuse else scan_pkg.scan_shape(src, run, dest, lazy, opts.limits, .Jsonc, true)
	} else if lazy {
		verdict = scan_pkg.scan_shape_lazy(src, run, dest, opts.limits, false) if !refuse else scan_pkg.scan_shape_lazy(src, run, dest, opts.limits, true)
	} else {
		verdict = scan_pkg.scan_shape(src, run, dest, false, opts.limits, .Json, false) if !refuse else scan_pkg.scan_shape(src, run, dest, false, opts.limits, .Json, true)
	}
	if e, refused := verdict.?; refused {
		return unmarshal_error_of(run, e)
	}
	return nil
}

// `core_pkg.record_read_destroy`, for `destroy`'s overload set, which names this package's procedures.
@(private)
record_read_destroy :: proc(rd: ^Record_Read) {
	core_pkg.record_read_destroy(rd)
}
