package jsonpath

import "core:math"
import "core:mem"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/query"

// Zero-recursion explicit-stack RFC 9535 evaluator over `stury:lib/query`.
//
// Invariants:
// - Never accesses `doc.nodes` directly — all reads go through `stury:lib/query` so `h.tainted` fires automatically.
// - Checks `query.value_has_partial(v)` before emitting any output value so partial containers never escape.
// - Checks `h.tainted` and `budget.steps` / `budget.depth` on every loop tick and aborts immediately.
// - Zero native recursion across segments, descendant traversal (`..`), and nested filter expressions.

Run_End :: enum u8 {
	Done,     // all matching nodes emitted
	Stopped,  // emit callback returned false
	Tainted,  // partial-document read miss (uncatchable)
	Exceeded, // budget (steps, depth, or memory) ran out
	Failed,   // unexpected runtime error in heap
}

Eval_Options :: struct {
	want_paths: bool,        // compute RFC 9535 §2.7 normalized paths lazily when true
	budget:     tape.Budget, // steps (0 = unlimited), depth (0 = tape.DEFAULT_DEPTH)
}

// Output callback. Receives an owned `value` (callback MUST call `query.release(h, value)` or take ownership)
// and a borrowed `norm_path` valid only during the callback (empty when `!opts.want_paths`).
// Return `true` to continue, `false` to stop early (yielding `.Stopped`).
Emit_Proc :: #type proc(data: rawptr, value: query.Value, norm_path: string) -> bool

// Dynamic I-Regexp cache entry (used only when `match`/`search` receives a non-literal pattern).
@(private = "file")
Dyn_Regex_Entry :: struct {
	pattern:  string,
	anchored: bool,
	valid:    bool,
	re:       ^regex.Regex,
}

@(private = "file")
DYN_REGEX_CAP :: 64

@(private = "file")
Dyn_Regex_Cache :: struct {
	arena:   mem.Dynamic_Arena,
	ready:   bool,
	entries: [dynamic]Dyn_Regex_Entry,
	scratch: regex.Scratch,
}

// Reusable execution state for running a compiled `^Program` across one or more inputs.
Run :: struct {
	prog:      ^Program,
	h:         ^query.Heap,
	opts:      Eval_Options,
	frames:    [dynamic]Eval_Frame,
	path_segs: [dynamic]Path_Seg,
	path_buf:  strings.Builder,
	re_cache:  Dyn_Regex_Cache,
}

// Initializes `run` for evaluating `prog` over `h`. Caller must call `run_destroy`.
run_init :: proc(run: ^Run, prog: ^Program, h: ^query.Heap, opts := Eval_Options{}) {
	alloc := query.heap_allocator(h)
	run^ = {
		prog = prog,
		h    = h,
		opts = opts,
	}
	run.frames = make([dynamic]Eval_Frame, 0, 16, alloc)
	if opts.want_paths {
		run.path_segs = make([dynamic]Path_Seg, 0, 16, alloc)
		strings.builder_init_len_cap(&run.path_buf, 0, 64, alloc)
	}
}

run_destroy :: proc(run: ^Run) {
	if run.h != nil {
		cleanup_eval_state(run)
		delete(run.frames)
		delete(run.path_segs)
		strings.builder_destroy(&run.path_buf)
		dyn_regex_destroy(&run.re_cache)
	}
	run^ = {}
}

// Convenience one-shot evaluator. `root` is borrowed; emitted values are owned by `emit`.
eval :: proc(
	prog: ^Program,
	h: ^query.Heap,
	root: query.Value,
	emit: Emit_Proc,
	data: rawptr,
	opts := Eval_Options{},
) -> Run_End {
	run: Run
	run_init(&run, prog, h, opts)
	defer run_destroy(&run)
	return run_value(&run, root, emit, data)
}

// Evaluates `run.prog` against borrowed `root`, calling `emit` for each matching node.
run_value :: proc(run: ^Run, root: query.Value, emit: Emit_Proc, data: rawptr) -> Run_End {
	h := run.h
	if h.tainted {
		return .Tainted
	}
	defer cleanup_eval_state(run)

	raw_depth := u64(run.opts.budget.depth) if run.opts.budget.depth > 0 else u64(query.depth_limit(h))
	clamped_depth := min(raw_depth, u64(1_000_000))
	// Allow 4 internal frames per depth level without flooring small explicit `budget.depth` values.
	max_frames := max(int(clamped_depth) * 4, 4)

	m := Machine{
		run        = run,
		h          = h,
		root       = root,
		emit       = emit,
		emit_data  = data,
		want_paths = run.opts.want_paths,
		max_frames = max_frames,
		has_steps  = run.opts.budget.steps > 0,
		steps_left = run.opts.budget.steps,
	}
	defer query.release(h, m.res_val)

	// Fast guard: if the root query has 0 segments, emit root directly (with partial check).
	// Pushing the initial `.Seg_Step` frame handles 0 segments uniformly too!
	if !push_eval_frame(&m, {
		kind      = .Seg_Step,
		segs      = run.prog.root.segments,
		seg_idx   = 0,
		val       = query.retain(root),
		dest      = .Emit,
		path_mark = 0,
	}) {
		return m.end
	}

	for len(run.frames) > 0 {
		if h.tainted {
			return .Tainted
		}
		if m.has_steps {
			if m.steps_left == 0 {
				return .Exceeded
			}
			m.steps_left -= 1
		}
		f := &run.frames[len(run.frames) - 1]
		switch f.kind {
		case .Seg_Step:
			step_seg(&m, f)
		case .Descend:
			step_descend(&m, f)
		case .Expr:
			step_expr(&m, f)
		}
		if m.abort {
			return m.end
		}
	}

	if h.tainted {
		return .Tainted
	}
	return .Done
}

// ---- Internal Explicit-Stack VM ----

@(private = "file")
Eval_Frame_Kind :: enum u8 {
	Seg_Step,
	Descend,
	Expr,
}

@(private = "file")
Query_Dest :: enum u8 {
	Emit,   // top-level query: emit to user callback
	Exists, // test-expr: short-circuit true on first match
	Count,  // count(q): increment counter on each match
	Value,  // value(q) or singular-query: capture single value, Nothing on 0 or >=2
}

@(private = "file")
Eval_Frame :: struct {
	kind:       Eval_Frame_Kind,
	stage:      u8,
	dest:       Query_Dest,
	// Where the enclosing sub-query's `.Expr` frame sits in `run.frames` (-1 for top-level `.Emit`).
	owner_idx:  int,
	path_mark:  int,

	// `.Seg_Step` / `.Descend`:
	segs:          []Segment,
	seg_idx:       int,
	sel_idx:       int,
	val:           query.Value,  // held node being processed
	cursor:        query.Cursor,
	cursor_open:   bool,
	cursor_idx:    i64,          // array index while iterating array cursor
	slice_i:       i64,
	slice_bound:   i64,
	slice_step:    i64,
	pending_child: query.Value,  // held child awaiting filter expr result
	pending_key:   query.Value,  // held key for object child awaiting filter expr result
	pending_idx:   i64,          // array index for array child awaiting filter expr result
	pending_is_obj: bool,
	is_desc_inner: bool,         // true when `.Seg_Step` applies inner selectors of a `.Descend` segment

	// `.Expr`:
	expr:        ^Expr,
	current:     query.Value, // held `@` node for filter expression
	saved_val:   query.Value, // held LHS / arg0 value
	sub_count:   i64,         // accumulated node count for `.Count` / `.Value`
	sub_val:     query.Value, // captured single value for `.Value`
	sub_bool:    bool,        // existence flag for `.Exists`
}

@(private = "file")
Machine :: struct {
	run:        ^Run,
	h:          ^query.Heap,
	root:       query.Value,
	emit:       Emit_Proc,
	emit_data:  rawptr,
	want_paths: bool,
	max_frames: int,
	has_steps:  bool,
	steps_left: u64,
	res_bool:   bool,
	res_val:    query.Value, // held return value from popped `.Expr`
	abort:      bool,
	end:        Run_End,
}

@(private = "file")
abort_run :: proc(m: ^Machine, end: Run_End) {
	m.abort = true
	m.end = end
}

@(private = "file")
drop_frame :: proc(h: ^query.Heap, f: ^Eval_Frame) {
	if f.cursor_open {
		query.cursor_close(&f.cursor)
		f.cursor_open = false
	}
	query.release(h, f.val)
	query.release(h, f.pending_child)
	query.release(h, f.pending_key)
	query.release(h, f.current)
	query.release(h, f.saved_val)
	query.release(h, f.sub_val)
	f.val = query.ABSENT
	f.pending_child = query.ABSENT
	f.pending_key = query.ABSENT
	f.current = query.ABSENT
	f.saved_val = query.ABSENT
	f.sub_val = query.ABSENT
}

@(private = "file")
trim_paths :: proc(run: ^Run, mark: int) {
	h := run.h
	for len(run.path_segs) > mark {
		seg := pop(&run.path_segs)
		if seg.kind == .Name {
			query.release(h, seg.key_val)
		}
	}
}

@(private = "file")
cleanup_eval_state :: proc(run: ^Run) {
	h := run.h
	for len(run.frames) > 0 {
		f := &run.frames[len(run.frames) - 1]
		drop_frame(h, f)
		pop(&run.frames)
	}
	trim_paths(run, 0)
}

@(private = "file")
push_eval_frame :: proc(m: ^Machine, f: Eval_Frame) -> bool {
	if len(m.run.frames) >= m.max_frames {
		tmp := f
		drop_frame(m.h, &tmp)
		abort_run(m, .Exceeded)
		return false
	}
	if _, err := append(&m.run.frames, f); err != nil {
		tmp := f
		drop_frame(m.h, &tmp)
		abort_run(m, .Exceeded)
		return false
	}
	return true
}

@(private = "file")
pop_eval_frame :: proc(m: ^Machine) {
	f := &m.run.frames[len(m.run.frames) - 1]
	mark := f.path_mark
	track_path := m.want_paths && f.dest == .Emit
	drop_frame(m.h, f)
	pop(&m.run.frames)
	if track_path {
		trim_paths(m.run, mark)
	}
}

@(private = "file")
push_path_name :: proc(m: ^Machine, key_val: query.Value) -> bool {
	if _, err := append(&m.run.path_segs, Path_Seg{kind = .Name, key_val = key_val}); err != nil {
		query.release(m.h, key_val)
		abort_run(m, .Exceeded)
		return false
	}
	return true
}

@(private = "file")
push_path_index :: proc(m: ^Machine, idx: i64) -> bool {
	if _, err := append(&m.run.path_segs, Path_Seg{kind = .Index, index = idx}); err != nil {
		abort_run(m, .Exceeded)
		return false
	}
	return true
}

// Unwinds all frames belonging to the sub-query owned by `owner_idx` (leaving `owner_idx` on top).
@(private = "file")
unwind_subquery :: proc(m: ^Machine, owner_idx: int) {
	for len(m.run.frames) - 1 > owner_idx {
		pop_eval_frame(m)
	}
}

// Emits a terminal node reached at `seg_idx == len(segs)`.
@(private = "file")
deliver_node :: proc(m: ^Machine, f: ^Eval_Frame) {
	switch f.dest {
	case .Emit:
		if m.h.tainted || query.value_has_partial(f.val) {
			m.h.tainted = true
			abort_run(m, .Tainted)
			return
		}
		path_str := ""
		if m.want_paths {
			format_norm_path(&m.run.path_buf, m.run.path_segs[:])
			path_str = strings.to_string(m.run.path_buf)
		}
		// Transfer retained ownership to callback.
		out_val := query.retain(f.val)
		cont := m.emit(m.emit_data, out_val, path_str)
		if m.h.tainted {
			abort_run(m, .Tainted)
			return
		}
		if !cont {
			abort_run(m, .Stopped)
			return
		}
		pop_eval_frame(m)

	case .Exists:
		owner := &m.run.frames[f.owner_idx]
		owner.sub_bool = true
		unwind_subquery(m, f.owner_idx)

	case .Count:
		owner := &m.run.frames[f.owner_idx]
		owner.sub_count += 1
		pop_eval_frame(m)

	case .Value:
		owner := &m.run.frames[f.owner_idx]
		owner.sub_count += 1
		if owner.sub_count == 1 {
			owner.sub_val = query.retain(f.val)
			pop_eval_frame(m)
		} else {
			// >= 2 nodes -> Nothing (short-circuit immediately!).
			query.release(m.h, owner.sub_val)
			owner.sub_val = query.ABSENT
			unwind_subquery(m, f.owner_idx)
		}
	}
}

// ---- Segment & Descendant Evaluation ----

@(private = "file")
step_seg :: proc(m: ^Machine, f: ^Eval_Frame) {
	if f.seg_idx >= len(f.segs) {
		deliver_node(m, f)
		return
	}

	seg := f.segs[f.seg_idx]

	// If this is a descendant segment (not yet inside its inner selectors), replace frame with `.Descend`.
	if seg.kind == .Descendant && !f.is_desc_inner {
		f.kind = .Descend
		f.stage = 0
		return
	}

	// Resume from a filter expression evaluation (`stage == 3`).
	if f.stage == 3 {
		matched := m.res_bool
		child := f.pending_child
		key := f.pending_key
		idx := f.pending_idx
		is_obj := f.pending_is_obj
		f.pending_child = query.ABSENT
		f.pending_key = query.ABSENT
		f.stage = 1 // continue filter cursor
		if matched {
			mark := len(m.run.path_segs)
			if m.want_paths && f.dest == .Emit {
				if is_obj {
					if !push_path_name(m, key) {
						query.release(m.h, child)
						return
					}
					key = query.ABSENT
				} else {
					if !push_path_index(m, idx) {
						query.release(m.h, child)
						query.release(m.h, key)
						return
					}
				}
			}
			query.release(m.h, key)
			push_eval_frame(m, {
				kind      = .Seg_Step,
				segs      = f.segs,
				seg_idx   = f.seg_idx + 1,
				val       = child,
				dest      = f.dest,
				owner_idx = f.owner_idx,
				path_mark = mark,
			})
			return
		}
		query.release(m.h, child)
		query.release(m.h, key)
		return
	}

	// Done with all selectors in this segment?
	if f.sel_idx >= len(seg.selectors) {
		pop_eval_frame(m)
		return
	}

	sel := seg.selectors[f.sel_idx]
	vtype := query.type_of(f.val)
	if m.h.tainted {
		abort_run(m, .Tainted)
		return
	}

	switch sel.kind {
	case .Name:
		f.sel_idx += 1
		if vtype != .Object {
			return
		}
		child, st := query.member(m.h, f.val, sel.name)
		if m.h.tainted {
			query.release(m.h, child)
			abort_run(m, .Tainted)
			return
		}
		if st != .Ok {
			query.release(m.h, child)
			abort_run(m, status_to_end(m.h))
			return
		}
		if child.kind == .Absent {
			return
		}
		mark := len(m.run.path_segs)
		if m.want_paths && f.dest == .Emit {
			if !push_path_name(m, query.text_borrowed(sel.name)) {
				query.release(m.h, child)
				return
			}
		}
		push_eval_frame(m, {
			kind      = .Seg_Step,
			segs      = f.segs,
			seg_idx   = f.seg_idx + 1,
			val       = child,
			dest      = f.dest,
			owner_idx = f.owner_idx,
			path_mark = mark,
		})

	case .Index:
		f.sel_idx += 1
		if vtype != .Array {
			return
		}
		// Compute normalized index and bounds.
		norm_idx := sel.index
		if sel.index < 0 {
			arr_len := i64(query.length_of(m.h, f.val))
			if m.h.tainted {
				abort_run(m, .Tainted)
				return
			}
			norm_idx = arr_len + sel.index
			if norm_idx < 0 || norm_idx >= arr_len {
				return
			}
		} else if sel.index > i64(max(int)) {
			// Exceeds addressable array size -> out of bounds.
			return
		}
		child, st := query.element(m.h, f.val, int(norm_idx))
		if m.h.tainted {
			query.release(m.h, child)
			abort_run(m, .Tainted)
			return
		}
		if st != .Ok {
			query.release(m.h, child)
			abort_run(m, status_to_end(m.h))
			return
		}
		if child.kind == .Absent {
			return
		}
		mark := len(m.run.path_segs)
		if m.want_paths && f.dest == .Emit {
			if !push_path_index(m, norm_idx) {
				query.release(m.h, child)
				return
			}
		}
		push_eval_frame(m, {
			kind      = .Seg_Step,
			segs      = f.segs,
			seg_idx   = f.seg_idx + 1,
			val       = child,
			dest      = f.dest,
			owner_idx = f.owner_idx,
			path_mark = mark,
		})

	case .Wildcard:
		if f.stage == 0 {
			if vtype != .Array && vtype != .Object {
				f.sel_idx += 1
				return
			}
			cur, st := query.cursor_open(m.h, f.val)
			if m.h.tainted {
				query.cursor_close(&cur)
				abort_run(m, .Tainted)
				return
			}
			if st != .Ok {
				query.cursor_close(&cur)
				abort_run(m, status_to_end(m.h))
				return
			}
			f.cursor = cur
			f.cursor_open = true
			f.cursor_idx = 0
			f.stage = 1
		}
		key, child, more, st := query.cursor_next(m.h, &f.cursor)
		if m.h.tainted {
			query.release(m.h, key)
			query.release(m.h, child)
			abort_run(m, .Tainted)
			return
		}
		if st != .Ok {
			query.release(m.h, key)
			query.release(m.h, child)
			abort_run(m, status_to_end(m.h))
			return
		}
		if !more {
			query.cursor_close(&f.cursor)
			f.cursor_open = false
			f.stage = 0
			f.sel_idx += 1
			return
		}
		idx := f.cursor_idx
		f.cursor_idx += 1
		mark := len(m.run.path_segs)
		if m.want_paths && f.dest == .Emit {
			if vtype == .Object {
				if !push_path_name(m, key) {
					query.release(m.h, child)
					return
				}
				key = query.ABSENT
			} else {
				if !push_path_index(m, idx) {
					query.release(m.h, key)
					query.release(m.h, child)
					return
				}
			}
		}
		query.release(m.h, key)
		push_eval_frame(m, {
			kind      = .Seg_Step,
			segs      = f.segs,
			seg_idx   = f.seg_idx + 1,
			val       = child,
			dest      = f.dest,
			owner_idx = f.owner_idx,
			path_mark = mark,
		})

	case .Slice:
		if f.stage == 0 {
			step_v := sel.step if sel.has_step else i64(1)
			if step_v == 0 || vtype != .Array {
				f.sel_idx += 1
				return
			}
			n := i64(query.length_of(m.h, f.val))
			if m.h.tainted {
				abort_run(m, .Tainted)
				return
			}
			// RFC 9535 §2.3.4.2.2 exact slice bounds.
			def_start := i64(0) if step_v >= 0 else n - 1
			def_end := n if step_v >= 0 else -n - 1
			raw_start := sel.start if sel.has_start else def_start
			raw_end := sel.end if sel.has_end else def_end
			n_start := raw_start if raw_start >= 0 else n + raw_start
			n_end := raw_end if raw_end >= 0 else n + raw_end
			if step_v > 0 {
				lower := min(max(n_start, i64(0)), n)
				upper := min(max(n_end, i64(0)), n)
				f.slice_i = lower
				f.slice_bound = upper
				f.slice_step = step_v
			} else {
				upper := min(max(n_start, i64(-1)), n - 1)
				lower := min(max(n_end, i64(-1)), n - 1)
				f.slice_i = upper
				f.slice_bound = lower
				f.slice_step = step_v
			}
			f.stage = 1
		}
		done := (f.slice_i >= f.slice_bound) if f.slice_step > 0 else (f.slice_i <= f.slice_bound)
		if done {
			f.stage = 0
			f.sel_idx += 1
			return
		}
		idx := f.slice_i
		f.slice_i += f.slice_step
		child, st := query.element(m.h, f.val, int(idx))
		if m.h.tainted {
			query.release(m.h, child)
			abort_run(m, .Tainted)
			return
		}
		if st != .Ok {
			query.release(m.h, child)
			abort_run(m, status_to_end(m.h))
			return
		}
		if child.kind == .Absent {
			return
		}
		mark := len(m.run.path_segs)
		if m.want_paths && f.dest == .Emit {
			if !push_path_index(m, idx) {
				query.release(m.h, child)
				return
			}
		}
		push_eval_frame(m, {
			kind      = .Seg_Step,
			segs      = f.segs,
			seg_idx   = f.seg_idx + 1,
			val       = child,
			dest      = f.dest,
			owner_idx = f.owner_idx,
			path_mark = mark,
		})

	case .Filter:
		if f.stage == 0 {
			if vtype != .Array && vtype != .Object {
				f.sel_idx += 1
				return
			}
			cur, st := query.cursor_open(m.h, f.val)
			if m.h.tainted {
				query.cursor_close(&cur)
				abort_run(m, .Tainted)
				return
			}
			if st != .Ok {
				query.cursor_close(&cur)
				abort_run(m, status_to_end(m.h))
				return
			}
			f.cursor = cur
			f.cursor_open = true
			f.cursor_idx = 0
			f.stage = 1
		}
		key, child, more, st := query.cursor_next(m.h, &f.cursor)
		if m.h.tainted {
			query.release(m.h, key)
			query.release(m.h, child)
			abort_run(m, .Tainted)
			return
		}
		if st != .Ok {
			query.release(m.h, key)
			query.release(m.h, child)
			abort_run(m, status_to_end(m.h))
			return
		}
		if !more {
			query.cursor_close(&f.cursor)
			f.cursor_open = false
			f.stage = 0
			f.sel_idx += 1
			return
		}
		idx := f.cursor_idx
		f.cursor_idx += 1
		f.pending_child = child
		f.pending_key = key
		f.pending_idx = idx
		f.pending_is_obj = vtype == .Object
		f.stage = 3
		push_eval_frame(m, {
			kind      = .Expr,
			expr      = sel.filter,
			current   = query.retain(child),
			dest      = .Exists,
			owner_idx = -1,
			path_mark = len(m.run.path_segs),
		})
	}
}

// Pre-order iterative descendant walk (`..[selectors]`):
// stage 0: apply inner selectors of `segs[seg_idx]` to `f.val` (visiting self first).
// stage 1: open cursor on `f.val` (if container) and descend into each child in document order.
@(private = "file")
step_descend :: proc(m: ^Machine, f: ^Eval_Frame) {
	if f.stage == 0 {
		f.stage = 1
		// Push inner `.Seg_Step` to apply this descendant segment's selectors to `f.val` itself.
		push_eval_frame(m, {
			kind          = .Seg_Step,
			segs          = f.segs,
			seg_idx       = f.seg_idx,
			val           = query.retain(f.val),
			dest          = f.dest,
			owner_idx     = f.owner_idx,
			path_mark     = len(m.run.path_segs),
			is_desc_inner = true,
		})
		return
	}

	vtype := query.type_of(f.val)
	if m.h.tainted {
		abort_run(m, .Tainted)
		return
	}
	if f.stage == 1 {
		if vtype != .Array && vtype != .Object {
			pop_eval_frame(m)
			return
		}
		cur, st := query.cursor_open(m.h, f.val)
		if m.h.tainted {
			query.cursor_close(&cur)
			abort_run(m, .Tainted)
			return
		}
		if st != .Ok {
			query.cursor_close(&cur)
			abort_run(m, status_to_end(m.h))
			return
		}
		f.cursor = cur
		f.cursor_open = true
		f.cursor_idx = 0
		f.stage = 2
	}

	key, child, more, st := query.cursor_next(m.h, &f.cursor)
	if m.h.tainted {
		query.release(m.h, key)
		query.release(m.h, child)
		abort_run(m, .Tainted)
		return
	}
	if st != .Ok {
		query.release(m.h, key)
		query.release(m.h, child)
		abort_run(m, status_to_end(m.h))
		return
	}
	if !more {
		pop_eval_frame(m)
		return
	}
	idx := f.cursor_idx
	f.cursor_idx += 1
	mark := len(m.run.path_segs)
	if m.want_paths && f.dest == .Emit {
		if vtype == .Object {
			if !push_path_name(m, key) {
				query.release(m.h, child)
				return
			}
			key = query.ABSENT
		} else {
			if !push_path_index(m, idx) {
				query.release(m.h, key)
				query.release(m.h, child)
				return
			}
		}
	}
	query.release(m.h, key)
	// Push child `.Descend` frame; LIFO stack gives exact pre-order traversal!
	push_eval_frame(m, {
		kind      = .Descend,
		segs      = f.segs,
		seg_idx   = f.seg_idx,
		val       = child,
		dest      = f.dest,
		owner_idx = f.owner_idx,
		path_mark = mark,
	})
}

// ---- Filter Expression Evaluation (Explicit Stack) ----

@(private = "file")
step_expr :: proc(m: ^Machine, f: ^Eval_Frame) {
	e := f.expr
	switch e.kind {
	case .Literal:
		// Literals are frozen constants in the program arena/heap (unheld).
		query.release(m.h, m.res_val)
		m.res_val = e.literal
		pop_eval_frame(m)

	case .Paren:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.a, current = query.retain(f.current), dest = .Exists})
			return
		}
		pop_eval_frame(m)

	case .Not:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.a, current = query.retain(f.current), dest = .Exists})
			return
		}
		m.res_bool = !m.res_bool
		pop_eval_frame(m)

	case .Or:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.a, current = query.retain(f.current), dest = .Exists})
			return
		}
		if f.stage == 1 {
			if m.res_bool {
				// Short-circuit LogicalTrue.
				pop_eval_frame(m)
				return
			}
			f.stage = 2
			push_eval_frame(m, {kind = .Expr, expr = e.b, current = query.retain(f.current), dest = .Exists})
			return
		}
		pop_eval_frame(m)

	case .And:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.a, current = query.retain(f.current), dest = .Exists})
			return
		}
		if f.stage == 1 {
			if !m.res_bool {
				// Short-circuit LogicalFalse.
				pop_eval_frame(m)
				return
			}
			f.stage = 2
			push_eval_frame(m, {kind = .Expr, expr = e.b, current = query.retain(f.current), dest = .Exists})
			return
		}
		pop_eval_frame(m)

	case .Query:
		if f.stage == 0 {
			f.stage = 1
			f.sub_bool = false
			f.sub_count = 0
			f.sub_val = query.ABSENT
			owner_idx := len(m.run.frames) - 1
			start_val := m.root if e.query.kind == .Root else f.current
			push_eval_frame(m, {
				kind      = .Seg_Step,
				segs      = e.query.segments,
				seg_idx   = 0,
				val       = query.retain(start_val),
				dest      = f.dest,
				owner_idx = owner_idx,
			})
			return
		}
		// Sub-query completed; publish result based on `f.dest`.
		switch f.dest {
		case .Exists:
			m.res_bool = f.sub_bool
		case .Count:
			query.release(m.h, m.res_val)
			m.res_val = query.int_value(f.sub_count)
		case .Value:
			query.release(m.h, m.res_val)
			m.res_val = f.sub_val
			f.sub_val = query.ABSENT
		case .Emit:
		}
		pop_eval_frame(m)

	case .Compare:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.a, current = query.retain(f.current), dest = .Value})
			return
		}
		if f.stage == 1 {
			f.saved_val = m.res_val
			m.res_val = query.ABSENT
			f.stage = 2
			push_eval_frame(m, {kind = .Expr, expr = e.b, current = query.retain(f.current), dest = .Value})
			return
		}
		lhs := f.saved_val
		rhs := m.res_val
		f.saved_val = query.ABSENT
		m.res_val = query.ABSENT
		res, ok := eval_compare(m, lhs, rhs, e.op)
		query.release(m.h, lhs)
		query.release(m.h, rhs)
		if !ok {
			return
		}
		m.res_bool = res
		pop_eval_frame(m)

	case .Func:
		step_func_expr(m, f, e)
	}
}

@(private = "file")
step_func_expr :: proc(m: ^Machine, f: ^Eval_Frame, e: ^Expr) {
	switch e.func {
	case .Length:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.args[0], current = query.retain(f.current), dest = .Value})
			return
		}
		arg := m.res_val
		m.res_val = query.ABSENT
		out := query.ABSENT
		#partial switch query.type_of(arg) {
		case .String:
			out = query.int_value(i64(query.codepoint_count(query.text_of(arg))))
		case .Array, .Object:
			n := query.length_of(m.h, arg)
			if m.h.tainted {
				query.release(m.h, arg)
				abort_run(m, .Tainted)
				return
			}
			out = query.int_value(i64(n))
		}
		query.release(m.h, arg)
		m.res_val = out
		pop_eval_frame(m)

	case .Count:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.args[0], current = query.retain(f.current), dest = .Count})
			return
		}
		// `m.res_val` already holds `int_value(count)`.
		pop_eval_frame(m)

	case .Value:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.args[0], current = query.retain(f.current), dest = .Value})
			return
		}
		// `m.res_val` already holds the single node's value or `ABSENT`.
		pop_eval_frame(m)

	case .Match, .Search:
		if f.stage == 0 {
			f.stage = 1
			push_eval_frame(m, {kind = .Expr, expr = e.args[0], current = query.retain(f.current), dest = .Value})
			return
		}
		if f.stage == 1 {
			if e.pat_state == .Invalid {
				query.release(m.h, m.res_val)
				m.res_val = query.ABSENT
				m.res_bool = false
				pop_eval_frame(m)
				return
			}
			if e.pat_state == .Valid {
				str_val := m.res_val
				m.res_val = query.ABSENT
				hit, ok := run_regex(m, e.compiled_re, str_val)
				query.release(m.h, str_val)
				if !ok {
					return
				}
				m.res_bool = hit
				pop_eval_frame(m)
				return
			}
			// Dynamic pattern: save arg0, evaluate arg1.
			f.saved_val = m.res_val
			m.res_val = query.ABSENT
			f.stage = 2
			push_eval_frame(m, {kind = .Expr, expr = e.args[1], current = query.retain(f.current), dest = .Value})
			return
		}
		str_val := f.saved_val
		pat_val := m.res_val
		f.saved_val = query.ABSENT
		m.res_val = query.ABSENT
		hit, ok := run_dynamic_regex(m, str_val, pat_val, anchored = e.func == .Match)
		query.release(m.h, str_val)
		query.release(m.h, pat_val)
		if !ok {
			return
		}
		m.res_bool = hit
		pop_eval_frame(m)
	}
}

// ---- RFC 9535 §2.3.5.2.2 Comparison Semantics ----

@(private = "file")
eval_compare :: proc(m: ^Machine, a, b: query.Value, op: Compare_Op) -> (res: bool, ok: bool) {
	switch op {
	case .Eq:
		return rfc_equal(m, a, b)
	case .Ne:
		eq := rfc_equal(m, a, b) or_return
		return !eq, true
	case .Lt:
		return rfc_less(m, a, b)
	case .Le:
		lt := rfc_less(m, a, b) or_return
		if lt {
			return true, true
		}
		return rfc_equal(m, a, b)
	case .Gt:
		return rfc_less(m, b, a)
	case .Ge:
		gt := rfc_less(m, b, a) or_return
		if gt {
			return true, true
		}
		return rfc_equal(m, a, b)
	}
	return false, true
}

@(private = "file")
rfc_equal :: proc(m: ^Machine, a, b: query.Value) -> (res: bool, ok: bool) {
	ta, tb := query.type_of(a), query.type_of(b)
	if m.h.tainted {
		abort_run(m, .Tainted)
		return false, false
	}
	// RFC 9535 §2.3.5.2.2: Nothing == Nothing is TRUE; Nothing == any JSON value is FALSE.
	if ta == .Absent && tb == .Absent {
		return true, true
	}
	if ta != tb {
		return false, true
	}
	#partial switch ta {
	case .Null, .False, .True:
		return true, true
	case .Number:
		eq := query.numbers_equal(a, b, query.heap_allocator(m.h))
		if m.h.tainted || m.h.err.kind != .None {
			abort_run(m, status_to_end(m.h))
			return false, false
		}
		return eq, true
	case .String:
		return query.text_of(a) == query.text_of(b), true
	case .Array, .Object:
		if query.value_has_partial(a) || query.value_has_partial(b) {
			m.h.tainted = true
			abort_run(m, .Tainted)
			return false, false
		}
		eq, st := query.equal(m.h, a, b)
		if m.h.tainted {
			abort_run(m, .Tainted)
			return false, false
		}
		if st != .Ok {
			abort_run(m, status_to_end(m.h))
			return false, false
		}
		return eq, true
	}
	return false, true
}

@(private = "file")
number_is_nan :: #force_inline proc(v: query.Value) -> bool {
	if v.kind == .Int || v.kind == .Big {
		return false
	}
	if v.kind == .Double {
		return math.is_nan(v.f)
	}
	return math.is_nan(query.as_f64(v))
}

// RFC 9535 §2.3.5.2.2: `a < b` is true ONLY for two numbers (mathematical order) or two strings (Unicode scalar order).
@(private = "file")
rfc_less :: proc(m: ^Machine, a, b: query.Value) -> (res: bool, ok: bool) {
	ta, tb := query.type_of(a), query.type_of(b)
	if m.h.tainted {
		abort_run(m, .Tainted)
		return false, false
	}
	if ta != tb {
		return false, true
	}
	#partial switch ta {
	case .Number:
		if a.kind == .Int && b.kind == .Int {
			return a.i < b.i, true
		}
		if number_is_nan(a) || number_is_nan(b) {
			return false, true
		}
		cmp := query.compare_numbers(a, b, query.heap_allocator(m.h))
		if m.h.tainted || m.h.err.kind != .None {
			abort_run(m, status_to_end(m.h))
			return false, false
		}
		return cmp < 0, true
	case .String:
		// UTF-8 preserves Unicode scalar value lexicographical order.
		return query.text_of(a) < query.text_of(b), true
	}
	return false, true
}

// ---- I-Regexp Execution & Dynamic Cache ----

@(private = "file")
ensure_regex_scratch :: proc(m: ^Machine) -> bool {
	c := &m.run.re_cache
	if c.scratch.held.gate != nil {
		return true
	}
	sc, err := regex.scratch_make(query.heap_allocator(m.h))
	if err.kind != .None {
		abort_run(m, .Exceeded)
		return false
	}
	c.scratch = sc
	return true
}

@(private = "file")
run_regex :: proc(m: ^Machine, re: ^regex.Regex, str_val: query.Value) -> (hit: bool, ok: bool) {
	if query.type_of(str_val) != .String {
		return false, true
	}
	if !ensure_regex_scratch(m) {
		return false, false
	}
	steps := m.steps_left if m.has_steps else u64(0)
	if m.has_steps && steps == 0 {
		abort_run(m, .Exceeded)
		return false, false
	}
	found, err := regex.search(re, query.text_of(str_val), 0, nil, &m.run.re_cache.scratch, steps)
	if m.has_steps {
		spent := m.run.re_cache.scratch.spent
		if spent >= m.steps_left {
			m.steps_left = 0
		} else {
			m.steps_left -= spent
		}
	}
	if err.kind != .None {
		if err.kind == .Steps || err.kind == .Memory {
			abort_run(m, .Exceeded)
		} else {
			abort_run(m, .Failed)
		}
		return false, false
	}
	return found, true
}

@(private = "file")
run_dynamic_regex :: proc(m: ^Machine, str_val, pat_val: query.Value, anchored: bool) -> (hit: bool, ok: bool) {
	if query.type_of(str_val) != .String || query.type_of(pat_val) != .String {
		return false, true
	}
	pat := query.text_of(pat_val)
	c := &m.run.re_cache
	for &e in c.entries {
		if e.anchored == anchored && e.pattern == pat {
			if !e.valid {
				return false, true
			}
			return run_regex(m, e.re, str_val)
		}
	}
	counted := query.heap_allocator(m.h)
	if !c.ready {
		mem.dynamic_arena_init(&c.arena, counted, counted, block_size = 8 << 10, out_band_size = 2 << 10)
		c.entries = make([dynamic]Dyn_Regex_Entry, 0, 8, counted)
		c.ready = true
	} else if len(c.entries) >= DYN_REGEX_CAP {
		clear(&c.entries)
		mem.dynamic_arena_reset(&c.arena)
	}
	arena_alloc := mem.dynamic_arena_allocator(&c.arena)
	re, state, oom := compile_iregexp(pat, anchored, arena_alloc, counted)
	if oom {
		abort_run(m, .Exceeded)
		return false, false
	}
	pat_copy, serr := strings.clone(pat, arena_alloc)
	if serr != nil {
		abort_run(m, .Exceeded)
		return false, false
	}
	if _, aerr := append(&c.entries, Dyn_Regex_Entry{
		pattern  = pat_copy,
		anchored = anchored,
		valid    = state == .Valid,
		re       = re,
	}); aerr != nil {
		abort_run(m, .Exceeded)
		return false, false
	}
	if state != .Valid {
		return false, true
	}
	return run_regex(m, re, str_val)
}

@(private = "file")
dyn_regex_destroy :: proc(c: ^Dyn_Regex_Cache) {
	if c.ready {
		delete(c.entries)
		mem.dynamic_arena_destroy(&c.arena)
	}
	regex.scratch_destroy(&c.scratch)
	c^ = {}
}

@(private = "file")
status_to_end :: proc "contextless" (h: ^query.Heap) -> Run_End {
	if h.tainted {
		return .Tainted
	}
	if h.err.kind == .Memory || h.err.kind == .Budget || h.err.kind == .Depth {
		return .Exceeded
	}
	return .Failed
}
