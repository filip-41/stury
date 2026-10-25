package json

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// A typed read of many values of one type. `record_read_init` resolves the plan and the shape once.
// Each `unmarshal` of it reads one value, a record's bytes, as `unmarshal` of those bytes would, and a
// fault's offset is into those bytes. Add `Record.at` to place it in the input the record was framed from.
//
// The fields are the reader's own. It is not copied: it points into itself. `destroy` gives back a plan
// the reader made; a plan passed in is left as it was.
Record_Read :: struct {
	run:       walk.Shape_Run,
	base:      scan_pkg.Scanner,
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

// Resolve the plan and the shape for `T` under `opts`, the same refusal `unmarshal` gives before any byte
// (`.Bad_Option`, `.Plan_Mismatch`, `.Unsupported`, `.Out_Of_Memory` lowering the plan). `allocator` is the
// one each value is read with. A plan made here is freed by `destroy`.
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
	rd.opts = opts
	rd.root = T
	if plan != nil {
		if plan.root != T {
			return Unmarshal_Error{kind = .Plan_Mismatch}
		}
		rd.plan = plan
	} else {
		rd.owned = type_plan_init(T, {}, runtime.heap_allocator())
		rd.plan = &rd.owned
		rd.owns = true
	}
	shape, serr := core_pkg.read_shape_of(&rd.plan.base)
	if serr != nil {
		record_read_destroy(rd)
		return serr
	}
	rd.run = walk.Shape_Run{
		shape          = shape,
		frames         = &rd.frames,
		wide           = rd.wide[:],
		allocator      = allocator,
		borrow         = opts.borrow_strings,
		refuse_unknown = opts.unknown_fields == .Refuse,
		keep_first     = opts.duplicates == .First,
		read_over      = opts.duplicates == .All,
		enum_ints      = rd.plan.opts.enums == .Int,
		union_tag      = rd.plan.opts.union_tag,
	}
	rd.q = (^scan_pkg.Query_Ctx)(&rd.ctx_words)
	rd.base = scan_pkg.shape_bind(&rd.run, rd.q, nil, opts.limits)
	rd.ready = true
	return nil
}

@(require_results)
unmarshal_record :: #force_inline proc(rd: ^Record_Read, src: []byte, ptr: ^$T) -> (err: Maybe(Unmarshal_Error)) {
	if rd == nil || ptr == nil || !rd.ready {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if rd.root != T {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	return read_record(rd, src, ptr)
}

// Free a plan `record_read_init` made, and empty the reader.
@(private)
record_read_destroy :: proc(rd: ^Record_Read) {
	if rd.owns {
		type_plan_destroy(&rd.owned)
	}
	rd^ = {}
}

// One value. The plan, the shape and the query context stay bound. A record starts with no typed fault, no
// open key and no lazy probe carried over. A string's escape facts are reset by the string leaf.
@(private)
read_record :: #force_inline proc(rd: ^Record_Read, src: []byte, dest: rawptr) -> Maybe(Unmarshal_Error) {
	run := &rd.run
	opts := &rd.opts
	run.src = src
	run.fault = .None
	run.skip_pays = false
	lazy := opts.strictness == .Lazy
	if run.shape.descends && opts.dialect == .Json && opts.duplicates != .Refuse {
		// Under the lazy gate the probe is the same one `read_planned` runs; below it, nothing is skipped.
		small := u64(len(src)) < scan_pkg.SHAPE_LAZY_MIN_BYTES
		if !lazy || small || scan_pkg.shape_lazy_reads_all(src, run, opts.limits) {
			rd.q.key_esc_live, rd.q.key_saw_escape = false, false
			s := rd.base
			s.src = src
			s.pos = u64(scan_pkg.bom_len(src))
			s.alloc = context.allocator
			read, oom := scan_pkg.shape_descend_value(&s, rd.q, dest)
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
	run := &rd.run
	opts := rd.opts
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
