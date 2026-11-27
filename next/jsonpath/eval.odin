package jsonpath

import "core:math"
import "core:mem"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/query"

// Zero-recursion explicit-stack RFC 9535 evaluator over `stury:lib/query`.

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

// Output callback. Receives an owned `value` and a borrowed `norm_path`. Return false to stop early.
Emit_Proc :: #type proc(data: rawptr, value: query.Value, norm_path: string) -> bool

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

run_init :: proc(run: ^Run, prog: ^Program, h: ^query.Heap, opts := Eval_Options{}) {
	alloc := query.heap_allocator(h)
	run^ = {prog = prog, h = h, opts = opts}
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

eval :: proc(prog: ^Program, h: ^query.Heap, root: query.Value, emit: Emit_Proc, data: rawptr, opts := Eval_Options{}) -> Run_End {
	run: Run
	run_init(&run, prog, h, opts)
	defer run_destroy(&run)
	return run_value(&run, root, emit, data)
}

run_value :: proc(run: ^Run, root: query.Value, emit: Emit_Proc, data: rawptr) -> Run_End {
	h := run.h
	if h.tainted {
		return .Tainted
	}
	defer cleanup_eval_state(run)

	raw_depth := u64(run.opts.budget.depth) if run.opts.budget.depth > 0 else u64(query.depth_limit(h))
	m := Machine {
		run        = run,
		h          = h,
		root       = root,
		emit       = emit,
		emit_data  = data,
		want_paths = run.opts.want_paths,
		max_frames = max(int(min(raw_depth, u64(1_000_000))) * 4, 4),
		has_steps  = run.opts.budget.steps > 0,
		steps_left = run.opts.budget.steps,
	}
	defer query.release(h, m.res_val)

	if !push_eval_frame(&m, {kind = .Seg_Step, segs = run.prog.root.segments, val = query.retain(root), dest = .Emit}) {
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
		case .Seg_Step: step_seg(&m, f)
		case .Descend:  step_descend(&m, f)
		case .Expr:     step_expr(&m, f)
		}
		if m.abort {
			return m.end
		}
	}
	return .Tainted if h.tainted else .Done
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
	Emit,
	Exists,
	Count,
	Value,
}

@(private = "file")
Eval_Frame :: struct {
	kind:           Eval_Frame_Kind,
	stage:          u8,
	dest:           Query_Dest,
	owner_idx:      int,
	path_mark:      int,
	segs:           []Segment,
	seg_idx:        int,
	sel_idx:        int,
	val:            query.Value,
	cursor:         query.Cursor,
	cursor_open:    bool,
	cursor_idx:     i64,
	slice_i:        i64,
	slice_bound:    i64,
	slice_step:     i64,
	pending_child:  query.Value,
	pending_key:    query.Value,
	pending_idx:    i64,
	pending_is_obj: bool,
	is_desc_inner:  bool,
	expr:           ^Expr,
	current:        query.Value,
	saved_val:      query.Value,
	sub_count:      i64,
	sub_val:        query.Value,
	sub_bool:       bool,
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
	res_val:    query.Value,
	abort:      bool,
	end:        Run_End,
}

@(private = "file")
abort_run :: proc(m: ^Machine, end: Run_End) {
	m.abort, m.end = true, end
}

@(private = "file")
drop_frame :: proc(h: ^query.Heap, f: ^Eval_Frame) {
	if f.cursor_open {
		query.cursor_close(&f.cursor)
		f.cursor_open = false
	}
	for v in ([6]query.Value{f.val, f.pending_child, f.pending_key, f.current, f.saved_val, f.sub_val}) {
		query.release(h, v)
	}
	f.val, f.pending_child, f.pending_key, f.current, f.saved_val, f.sub_val = query.ABSENT, query.ABSENT, query.ABSENT, query.ABSENT, query.ABSENT, query.ABSENT
}

@(private = "file")
trim_paths :: proc(run: ^Run, mark: int) {
	for len(run.path_segs) > mark {
		if seg := pop(&run.path_segs); seg.kind == .Name {
			query.release(run.h, seg.key_val)
		}
	}
}

@(private = "file")
cleanup_eval_state :: proc(run: ^Run) {
	for len(run.frames) > 0 {
		drop_frame(run.h, &run.frames[len(run.frames) - 1])
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
	mark, track_path := f.path_mark, m.want_paths && f.dest == .Emit
	drop_frame(m.h, f)
	pop(&m.run.frames)
	if track_path {
		trim_paths(m.run, mark)
	}
}

// Records optional path step (taking `key` if `is_obj`) and pushes the next `.Seg_Step` or `.Descend` frame (taking `child`).
@(private = "file")
push_child_frame :: proc(m: ^Machine, f: ^Eval_Frame, kind: Eval_Frame_Kind, next_seg: int, child, key: query.Value, idx: i64, is_obj: bool) {
	k := key
	mark := len(m.run.path_segs)
	if m.want_paths && f.dest == .Emit {
		seg := Path_Seg{kind = .Name, key_val = k} if is_obj else Path_Seg{kind = .Index, index = idx}
		if _, err := append(&m.run.path_segs, seg); err != nil {
			query.release(m.h, k)
			query.release(m.h, child)
			abort_run(m, .Exceeded)
			return
		}
		if is_obj {
			k = query.ABSENT
		}
	}
	query.release(m.h, k)
	push_eval_frame(m, {kind = kind, segs = f.segs, seg_idx = next_seg, val = child, dest = f.dest, owner_idx = f.owner_idx, path_mark = mark})
}

@(private = "file")
open_frame_cursor :: proc(m: ^Machine, f: ^Eval_Frame, next_stage: u8) -> bool {
	cur, st := query.cursor_open(m.h, f.val)
	if m.h.tainted || st != .Ok {
		query.cursor_close(&cur)
		abort_run(m, .Tainted if m.h.tainted else status_to_end(m.h))
		return false
	}
	f.cursor, f.cursor_open, f.cursor_idx, f.stage = cur, true, 0, next_stage
	return true
}

@(private = "file")
next_cursor_item :: proc(m: ^Machine, f: ^Eval_Frame) -> (key, child: query.Value, idx: i64, more, ok: bool) {
	st: query.Status
	key, child, more, st = query.cursor_next(m.h, &f.cursor)
	if m.h.tainted || st != .Ok {
		query.release(m.h, key)
		query.release(m.h, child)
		abort_run(m, .Tainted if m.h.tainted else status_to_end(m.h))
		return query.ABSENT, query.ABSENT, 0, false, false
	}
	if more {
		idx = f.cursor_idx
		f.cursor_idx += 1
	}
	return key, child, idx, more, true
}

@(private = "file")
check_child_status :: proc(m: ^Machine, child: query.Value, st: query.Status) -> bool {
	if m.h.tainted || st != .Ok {
		query.release(m.h, child)
		abort_run(m, .Tainted if m.h.tainted else status_to_end(m.h))
		return false
	}
	return child.kind != .Absent
}

@(private = "file")
unwind_subquery :: proc(m: ^Machine, owner_idx: int) {
	for len(m.run.frames) - 1 > owner_idx {
		pop_eval_frame(m)
	}
}

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
		cont := m.emit(m.emit_data, query.retain(f.val), path_str)
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
		m.run.frames[f.owner_idx].sub_bool = true
		unwind_subquery(m, f.owner_idx)
	case .Count:
		m.run.frames[f.owner_idx].sub_count += 1
		pop_eval_frame(m)
	case .Value:
		owner := &m.run.frames[f.owner_idx]
		owner.sub_count += 1
		if owner.sub_count == 1 {
			owner.sub_val = query.retain(f.val)
			pop_eval_frame(m)
		} else {
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
	if seg.kind == .Descendant && !f.is_desc_inner {
		f.kind, f.stage = .Descend, 0
		return
	}
	if f.stage == 3 {
		child, key, idx, is_obj := f.pending_child, f.pending_key, f.pending_idx, f.pending_is_obj
		f.pending_child, f.pending_key, f.stage = query.ABSENT, query.ABSENT, 1
		if m.res_bool {
			push_child_frame(m, f, .Seg_Step, f.seg_idx + 1, child, key, idx, is_obj)
		} else {
			query.release(m.h, child)
			query.release(m.h, key)
		}
		return
	}
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
		if check_child_status(m, child, st) {
			push_child_frame(m, f, .Seg_Step, f.seg_idx + 1, child, query.text_borrowed(sel.name), 0, true)
		}
	case .Index:
		f.sel_idx += 1
		if vtype != .Array {
			return
		}
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
			return
		}
		child, st := query.element(m.h, f.val, int(norm_idx))
		if check_child_status(m, child, st) {
			push_child_frame(m, f, .Seg_Step, f.seg_idx + 1, child, query.ABSENT, norm_idx, false)
		}
	case .Wildcard, .Filter:
		if f.stage == 0 {
			if vtype != .Array && vtype != .Object {
				f.sel_idx += 1
				return
			}
			if !open_frame_cursor(m, f, 1) {
				return
			}
		}
		key, child, idx, more, ok := next_cursor_item(m, f)
		if !ok {
			return
		}
		if !more {
			query.cursor_close(&f.cursor)
			f.cursor_open, f.stage = false, 0
			f.sel_idx += 1
			return
		}
		if sel.kind == .Wildcard {
			push_child_frame(m, f, .Seg_Step, f.seg_idx + 1, child, key, idx, vtype == .Object)
			return
		}
		f.pending_child, f.pending_key, f.pending_idx, f.pending_is_obj, f.stage = child, key, idx, vtype == .Object, 3
		push_eval_frame(m, {kind = .Expr, expr = sel.filter, current = query.retain(child), dest = .Exists, owner_idx = -1, path_mark = len(m.run.path_segs)})
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
			raw_start := sel.start if sel.has_start else (i64(0) if step_v >= 0 else n - 1)
			raw_end := sel.end if sel.has_end else (n if step_v >= 0 else -n - 1)
			n_start := raw_start if raw_start >= 0 else n + raw_start
			n_end := raw_end if raw_end >= 0 else n + raw_end
			lo_lim := i64(0) if step_v > 0 else i64(-1)
			hi_lim := n if step_v > 0 else n - 1
			f.slice_i, f.slice_bound, f.slice_step, f.stage = clamp(n_start, lo_lim, hi_lim), clamp(n_end, lo_lim, hi_lim), step_v, 1
		}
		if (f.slice_i >= f.slice_bound) if f.slice_step > 0 else (f.slice_i <= f.slice_bound) {
			f.stage = 0
			f.sel_idx += 1
			return
		}
		idx := f.slice_i
		f.slice_i += f.slice_step
		child, st := query.element(m.h, f.val, int(idx))
		if check_child_status(m, child, st) {
			push_child_frame(m, f, .Seg_Step, f.seg_idx + 1, child, query.ABSENT, idx, false)
		}
	}
}

@(private = "file")
step_descend :: proc(m: ^Machine, f: ^Eval_Frame) {
	if f.stage == 0 {
		f.stage = 1
		push_eval_frame(m, {kind = .Seg_Step, segs = f.segs, seg_idx = f.seg_idx, val = query.retain(f.val), dest = f.dest, owner_idx = f.owner_idx, path_mark = len(m.run.path_segs), is_desc_inner = true})
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
		if !open_frame_cursor(m, f, 2) {
			return
		}
	}
	key, child, idx, more, ok := next_cursor_item(m, f)
	if !ok {
		return
	}
	if !more {
		pop_eval_frame(m)
		return
	}
	push_child_frame(m, f, .Descend, f.seg_idx, child, key, idx, vtype == .Object)
}

// ---- Filter Expression Evaluation (Explicit Stack) ----

@(private = "file")
push_expr :: #force_inline proc(m: ^Machine, expr: ^Expr, cur: query.Value, dest: Query_Dest) {
	push_eval_frame(m, {kind = .Expr, expr = expr, current = query.retain(cur), dest = dest})
}

@(private = "file")
step_expr :: proc(m: ^Machine, f: ^Eval_Frame) {
	e := f.expr
	switch e.kind {
	case .Literal:
		query.release(m.h, m.res_val)
		m.res_val = e.literal
		pop_eval_frame(m)
	case .Paren, .Not:
		if f.stage == 0 {
			f.stage = 1
			push_expr(m, e.a, f.current, .Exists)
			return
		}
		if e.kind == .Not {
			m.res_bool = !m.res_bool
		}
		pop_eval_frame(m)
	case .Or, .And:
		if f.stage == 0 {
			f.stage = 1
			push_expr(m, e.a, f.current, .Exists)
			return
		}
		if f.stage == 1 {
			if m.res_bool == (e.kind == .Or) {
				pop_eval_frame(m)
				return
			}
			f.stage = 2
			push_expr(m, e.b, f.current, .Exists)
			return
		}
		pop_eval_frame(m)
	case .Query:
		if f.stage == 0 {
			f.stage, f.sub_bool, f.sub_count, f.sub_val = 1, false, 0, query.ABSENT
			start_val := m.root if e.query.kind == .Root else f.current
			push_eval_frame(m, {kind = .Seg_Step, segs = e.query.segments, val = query.retain(start_val), dest = f.dest, owner_idx = len(m.run.frames) - 1})
			return
		}
		#partial switch f.dest {
		case .Exists:
			m.res_bool = f.sub_bool
		case .Count:
			query.release(m.h, m.res_val)
			m.res_val = query.int_value(f.sub_count)
		case .Value:
			query.release(m.h, m.res_val)
			m.res_val, f.sub_val = f.sub_val, query.ABSENT
		}
		pop_eval_frame(m)
	case .Compare:
		if f.stage == 0 {
			f.stage = 1
			push_expr(m, e.a, f.current, .Value)
			return
		}
		if f.stage == 1 {
			f.saved_val, m.res_val, f.stage = m.res_val, query.ABSENT, 2
			push_expr(m, e.b, f.current, .Value)
			return
		}
		lhs, rhs := f.saved_val, m.res_val
		f.saved_val, m.res_val = query.ABSENT, query.ABSENT
		res, ok := eval_compare(m, lhs, rhs, e.op)
		query.release(m.h, lhs)
		query.release(m.h, rhs)
		if ok {
			m.res_bool = res
			pop_eval_frame(m)
		}
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
			push_expr(m, e.args[0], f.current, .Value)
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
	case .Count, .Value:
		if f.stage == 0 {
			f.stage = 1
			push_expr(m, e.args[0], f.current, .Count if e.func == .Count else .Value)
			return
		}
		pop_eval_frame(m)
	case .Match, .Search:
		if f.stage == 0 {
			f.stage = 1
			push_expr(m, e.args[0], f.current, .Value)
			return
		}
		if f.stage == 1 {
			if e.pat_state != .Dynamic {
				str_val := m.res_val
				m.res_val = query.ABSENT
				defer query.release(m.h, str_val)
				hit, ok := false, true
				if e.pat_state == .Valid {
					hit, ok = run_regex(m, e.compiled_re, str_val)
				}
				if ok {
					m.res_bool = hit
					pop_eval_frame(m)
				}
				return
			}
			f.saved_val, m.res_val, f.stage = m.res_val, query.ABSENT, 2
			push_expr(m, e.args[1], f.current, .Value)
			return
		}
		str_val, pat_val := f.saved_val, m.res_val
		f.saved_val, m.res_val = query.ABSENT, query.ABSENT
		hit, ok := run_dynamic_regex(m, str_val, pat_val, anchored = e.func == .Match)
		query.release(m.h, str_val)
		query.release(m.h, pat_val)
		if ok {
			m.res_bool = hit
			pop_eval_frame(m)
		}
	}
}

// ---- RFC 9535 §2.3.5.2.2 Comparison Semantics ----

@(private = "file")
eval_compare :: proc(m: ^Machine, a, b: query.Value, op: Compare_Op) -> (res: bool, ok: bool) {
	switch op {
	case .Eq: return rfc_equal(m, a, b)
	case .Ne: return !(rfc_equal(m, a, b) or_return), true
	case .Lt: return rfc_less(m, a, b)
	case .Gt: return rfc_less(m, b, a)
	case .Le:
		if rfc_less(m, a, b) or_return {
			return true, true
		}
		return rfc_equal(m, a, b)
	case .Ge:
		if rfc_less(m, b, a) or_return {
			return true, true
		}
		return rfc_equal(m, a, b)
	}
	return false, true
}

@(private = "file")
rfc_equal :: proc(m: ^Machine, a, b: query.Value) -> (bool, bool) {
	ta, tb := query.type_of(a), query.type_of(b)
	if m.h.tainted {
		abort_run(m, .Tainted)
		return false, false
	}
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
		if m.h.tainted || st != .Ok {
			abort_run(m, .Tainted if m.h.tainted else status_to_end(m.h))
			return false, false
		}
		return eq, true
	}
	return false, true
}

@(private = "file")
number_is_nan :: #force_inline proc(v: query.Value) -> bool {
	return v.kind != .Int && v.kind != .Big && math.is_nan(v.f if v.kind == .Double else query.as_f64(v))
}

@(private = "file")
rfc_less :: proc(m: ^Machine, a, b: query.Value) -> (bool, bool) {
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
		return query.text_of(a) < query.text_of(b), true
	}
	return false, true
}

// ---- I-Regexp Execution & Dynamic Cache ----

@(private = "file")
run_regex :: proc(m: ^Machine, re: ^regex.Regex, str_val: query.Value) -> (bool, bool) {
	if query.type_of(str_val) != .String {
		return false, true
	}
	c := &m.run.re_cache
	if c.scratch.held.gate == nil {
		sc, err := regex.scratch_make(query.heap_allocator(m.h))
		if err.kind != .None {
			abort_run(m, .Exceeded)
			return false, false
		}
		c.scratch = sc
	}
	steps := m.steps_left if m.has_steps else u64(0)
	if m.has_steps && steps == 0 {
		abort_run(m, .Exceeded)
		return false, false
	}
	found, err := regex.search(re, query.text_of(str_val), 0, nil, &c.scratch, steps)
	if m.has_steps {
		m.steps_left = 0 if c.scratch.spent >= m.steps_left else m.steps_left - c.scratch.spent
	}
	if err.kind != .None {
		abort_run(m, .Exceeded if err.kind == .Steps || err.kind == .Memory else .Failed)
		return false, false
	}
	return found, true
}

@(private = "file")
run_dynamic_regex :: proc(m: ^Machine, str_val, pat_val: query.Value, anchored: bool) -> (bool, bool) {
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
	pat_copy, serr := strings.clone(pat, arena_alloc)
	if oom || serr != nil {
		abort_run(m, .Exceeded)
		return false, false
	}
	if _, aerr := append(&c.entries, Dyn_Regex_Entry{pattern = pat_copy, anchored = anchored, valid = state == .Valid, re = re}); aerr != nil {
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
	return .Exceeded if h.err.kind == .Memory || h.err.kind == .Budget || h.err.kind == .Depth else .Failed
}
