package json

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// A typed read of many values of one type. `record_read_init` resolves the plan and the shape once.
// Each `unmarshal` of it reads one value, a record's bytes, as `unmarshal` of those bytes would, and a
// fault's offset is into those bytes. Add `Record.at` to place it in the input the record was framed from.
//
// The handle is one pointer: `record_read_init` allocates the reader's state on the heap, and `destroy`
// frees it. The state is not inside the handle, so a handle can be returned from a procedure or copied. A
// copy shares its state, and a state is destroyed once.
//
// `state.opts` is applied at the start of every read, so an option changed between records takes effect on
// the next one. A plan passed in is borrowed; a plan the reader made is freed by `destroy`.
Record_Read :: struct {
	state: ^Record_State,
}

// What a `Record_Read` points at: the resolved plan and shape, the walk's frames, and the options. Its fields
// are the reader's own except `opts`, which every read applies: read none of the others.
@(private)
Record_State :: struct {
	run:       walk.Shape_Run,
	q:         ^scan_pkg.Query_Ctx,
	plan:      ^Type_Plan,
	root:      typeid,
	opts:      Unmarshal_Opts,
	ready:     bool,
	owns:      bool,
	owned:     Type_Plan,
	ctx_words: [size_of(scan_pkg.Query_Ctx) / 8]u64,
	frames:    [MAX_DEPTH]walk.Shape_Frame,
	wide:      [walk.SHAPE_WIDE_WORDS]u64,
}

// The state's own heap. Its lifetime is the reader's, not a read's: a caller reads records into an arena and
// frees that whole, while the state outlives it. `new` zeroes it, and it is freed with the same allocator.
@(private)
record_state_new :: proc() -> ^Record_State {
	return new(Record_State, runtime.heap_allocator())
}

@(private)
record_state_free :: proc(state: ^Record_State) {
	free(state, runtime.heap_allocator())
}

// These two keep the imports of `record_read_init` out of its body: that procedure is polymorphic in `T`, and
// `-vet` reads a name used only inside a polymorphic procedure as unused.
@(private)
record_owned_plan_init :: proc(plan: ^Type_Plan, T: typeid) {
	plan^ = type_plan_init(T, {}, runtime.heap_allocator())
}

@(private)
record_shape_of :: proc(plan: ^Type_Plan) -> (shape: ^walk.Read_Shape, err: Maybe(Unmarshal_Error)) {
	return core_pkg.read_shape_of(&plan.base)
}

// Resolve the plan and the shape for `T` under `opts`, the same refusal `unmarshal` gives before any byte
// (`.Bad_Option`, `.Plan_Mismatch`, `.Unsupported`, or `.Out_Of_Memory` for the state or lowering the plan).
// `allocator` is the one each value is read with. A plan made here is freed by `destroy`.
@(require_results)
record_read_init :: proc(
	rd: ^Record_Read,
	$T: typeid,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> Maybe(Unmarshal_Error) {
	if rd == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	record_read_destroy(rd)
	if opts.strictness == .Structural && opts.dialect != .Jsonc {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if plan != nil && plan.root != T {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	state := record_state_new()
	if state == nil {
		return Unmarshal_Error{kind = .Out_Of_Memory}
	}
	rd.state = state
	state.opts = opts
	state.root = T
	if plan != nil {
		state.plan = plan
	} else {
		record_owned_plan_init(&state.owned, T)
		state.plan = &state.owned
		state.owns = true
	}
	shape, serr := record_shape_of(state.plan)
	if serr != nil {
		record_read_destroy(rd)
		return serr
	}
	state.run = walk.Shape_Run{
		shape     = shape,
		frames    = &state.frames,
		wide      = state.wide[:],
		allocator = allocator,
	}
	state.q = (^scan_pkg.Query_Ctx)(&state.ctx_words)
	state.ready = true
	return nil
}

@(require_results)
unmarshal_record :: #force_inline proc(rd: ^Record_Read, src: []byte, ptr: ^$T) -> (err: Maybe(Unmarshal_Error)) {
	if rd == nil || rd.state == nil || ptr == nil || !rd.state.ready {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if rd.state.opts.strictness == .Structural && rd.state.opts.dialect != .Jsonc {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if rd.state.root != T {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	return read_record(rd, src, ptr)
}

// Free the plan `record_read_init` made and the state, and clear the handle. A copy of the handle shares the
// state, so destroy a handle once; destroying this one twice finds no state the second time.
@(private)
record_read_destroy :: proc(rd: ^Record_Read) {
	if rd == nil || rd.state == nil {
		return
	}
	if rd.state.owns {
		type_plan_destroy(&rd.state.owned)
	}
	record_state_free(rd.state)
	rd.state = nil
}

// One value. `state.opts` is applied here, and the shape is bound to the read's limits again, so an option
// changed after `record_read_init` takes effect on the next read. A record starts with no typed fault, no
// open key and no lazy probe carried over. A string's escape facts are reset by the string leaf.
@(private)
read_record :: #force_inline proc(rd: ^Record_Read, src: []byte, dest: rawptr) -> Maybe(Unmarshal_Error) {
	state := rd.state
	run := &state.run
	opts := state.opts
	run.src = src
	run.fault = .None
	run.skip_pays = false
	run.borrow = opts.borrow_strings
	run.refuse_unknown = opts.unknown_fields == .Refuse
	run.keep_first = opts.duplicates == .First
	run.read_over = opts.duplicates == .All
	run.enum_ints = state.plan.opts.enums == .Int
	run.union_tag = state.plan.opts.union_tag
	s := scan_pkg.shape_bind(run, state.q, src, opts.limits)
	lazy := opts.strictness == .Lazy
	if run.shape.descends && opts.dialect == .Json && opts.duplicates != .Refuse {
		// Under the lazy gate the probe is the same one `read_planned` runs; below it, nothing is skipped.
		small := u64(len(src)) < scan_pkg.SHAPE_LAZY_MIN_BYTES
		if !lazy || small || scan_pkg.shape_lazy_reads_all(src, run, opts.limits) {
			state.q.key_esc_live, state.q.key_saw_escape = false, false
			read, oom := scan_pkg.shape_descend_value(&s, state.q, dest)
			if e, refused := oom.?; refused {
				return unmarshal_error_of(run, e)
			}
			if read {
				return nil
			}
		}
	}
	return record_walk(rd, src, dest)
}

// The shape walk, for a value the descent does not take. The same dispatch as `read_planned`.
@(private)
record_walk :: #force_no_inline proc(rd: ^Record_Read, src: []byte, dest: rawptr) -> Maybe(Unmarshal_Error) {
	state := rd.state
	run := &state.run
	opts := state.opts
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
