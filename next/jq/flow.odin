package jq

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "stury:lib/query"

// The machine's handling of steps, iteration, ranges, try, bindings, folds and operators.

// A path step's target and its key or bounds, which run on the step's input before the target.
@(private)
Step_Frame :: struct {
	using frame: Frame,
	n:           ^Node,
	key:         query.Value,
	from, to:    query.Value,
}

@(private)
eval_step :: proc(m: ^Machine, r: ^Regs) {
	h := m.h
	n := r.n
	// A key or a bound that is not native runs first, into a `Key` frame for each: the first of them varies slowest.
	if n.kind == .Index && .Native not_in n.b.flags || n.kind == .Slice && !native_bound(n.b) {
		key_frame(m, r, n, n.b, 0, query.ABSENT)
		return
	}
	key, from, to: query.Value
	s := query.Status.Ok
	found := true
	#partial switch n.kind {
	case .Index:
		key, found, s = eval_native(m, n.b, query.retain(r.input), r.env)
	case .Slice:
		from, found, s = bound_value(m, n.b, r.input, r.env)
		if s == .Ok && found && !native_bound(n.c) {
			key_frame(m, r, n, n.c, 1, from)
			return
		}
		if s == .Ok && found {
			to, found, s = bound_value(m, n.c, r.input, r.env)
		}
	}
	if s != .Ok || !found {
		query.release(h, key)
		query.release(h, from)
		finish(m, r, fail_status(s))
		return
	}
	step_on_target(m, r, n, key, from, to)
}

@(private)
native_bound :: #force_inline proc(b: ^Node) -> bool {
	return b == nil || .Native in b.flags
}

// A slice bound's value, null for none written.
@(private)
bound_value :: proc(m: ^Machine, b: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, found: bool, status: query.Status) {
	if b == nil {
		return query.NULL, true, .Ok
	}
	return eval_native(m, b, query.retain(input), env)
}

// Runs `b`, key `stage` of step `n` (0 an index or a slice's start, 1 its end), into a `Key` frame holding `before`, the
// start a slice's end follows.
@(private)
key_frame :: proc(m: ^Machine, r: ^Regs, n, b: ^Node, stage: int, before: query.Value) {
	f := push_or_fail(m, r, Input_Frame, .Key)
	if f == nil {
		query.release(m.h, before)
		return
	}
	f.n, f.env, f.input, f.path, f.i, f.v = n, env_retain(r.env), query.retain(r.input), query.retain(r.path), stage, before
	query.release(m.h, r.path)
	r.n, r.k, r.track, r.path = b, f, false, query.ABSENT
}

// An output of a step's key or bound: the next bound, or the step on its target.
@(private)
emit_key :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	h := m.h
	query.release(h, r.vpath)
	x := r.v
	r.v, r.vpath = query.ABSENT, query.ABSENT
	n := f.n
	r.input, r.path, r.env, r.k, r.track, r.mode = query.retain(f.input), query.retain(f.path), env_retain(f.env), f.k, f.track, .Eval
	if n.kind == .Index {
		step_on_target(m, r, n, x, query.ABSENT, query.ABSENT)
		return
	}
	if f.i == 1 {
		step_on_target(m, r, n, query.ABSENT, query.retain(f.v), x)
		return
	}
	if !native_bound(n.c) {
		key_frame(m, r, n, n.c, 1, x)
		return
	}
	to, found, s := bound_value(m, n.c, r.input, r.env)
	if s != .Ok || !found {
		query.release(h, x)
		finish(m, r, fail_status(s))
		return
	}
	step_on_target(m, r, n, query.ABSENT, x, to)
}

// Runs step `n` with its key and bounds, which it takes, on its target: the input itself, or each output of `n.a`.
@(private)
step_on_target :: proc(m: ^Machine, r: ^Regs, n: ^Node, key, from, to: query.Value) {
	if n.a.kind == .Identity {
		step_apply(m, r, n, r.input, r.path, key, from, to)
		r.input, r.path = query.ABSENT, query.ABSENT
		query.release(m.h, key)
		query.release(m.h, from)
		query.release(m.h, to)
		return
	}
	f, s := push(m, Step_Frame, .Step, r.k)
	if s != .Ok {
		query.release(m.h, key)
		query.release(m.h, from)
		query.release(m.h, to)
		finish(m, r, .Fail)
		return
	}
	f.track, f.n, f.key, f.from, f.to = r.track, n, key, from, to
	r.n, r.k = n.a, f
	r.mode = .Eval
}

// Step `n` applied to target `t` at path `tpath`, both taken: an output, an iteration, or none.
@(private)
step_apply :: proc(m: ^Machine, r: ^Regs, n: ^Node, t, tpath: query.Value, key, from, to: query.Value) {
	h := m.h
	env_release(m, r.env)
	r.env = nil
	if r.track && !is_path(tpath) {
		s := invalid_step(m, n, t, tpath, key)
		query.release(h, t)
		query.release(h, tpath)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	if r.track && path_ends_in_fact(h, tpath) {
		s := query.fail_fact_msg(h, "A comment step must be the last step of a path")
		query.release(h, t)
		query.release(h, tpath)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	if n.kind == .Iterate {
		iterate(m, r, n, t, tpath)
		return
	}
	v, found, s := apply_step(m, n, t, key, from, to)
	if s != .Ok || !found {
		query.release(h, t)
		query.release(h, tpath)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	if r.track {
		step_key := key
		if n.kind == .Field {
			step_key = n.value
		}
		if n.kind == .Slice {
			ks: query.Status
			step_key, ks = slice_key(m, from, to)
			if ks != .Ok {
				query.release(h, t)
				query.release(h, tpath)
				query.release(h, v)
				r.sig, r.mode = .Fail, .Ret
				return
			}
		}
		p, ps := path_append(m, tpath, step_key)
		if n.kind == .Slice {
			query.release(h, step_key)
		}
		query.release(h, tpath)
		if ps != .Ok {
			query.release(h, t)
			query.release(h, v)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		r.vpath = p
	}
	query.release(h, t)
	r.v, r.mode = v, .Emit
}

// The key a slice's path holds: `{"start": from, "end": to}`.
@(private)
slice_key :: proc(m: ^Machine, from, to: query.Value) -> (res: query.Value, status: query.Status) {
	o := query.make_object(m.h, 2) or_return
	defer if status != .Ok {
		query.release(m.h, o)
	}
	query.object_put_fresh(m.h, &o, query.text_borrowed("start"), query.retain(from) if from.kind != .Absent else query.NULL) or_return
	query.object_put_fresh(m.h, &o, query.text_borrowed("end"), query.retain(to) if to.kind != .Absent else query.NULL) or_return
	return o, .Ok
}

// jq's error for a step on what a path expression made that is no path.
@(private)
invalid_step :: proc(m: ^Machine, n: ^Node, t, tpath, key: query.Value) -> query.Status {
	result := tpath
	result.mark = 0
	k := n.value if n.kind == .Field else key
	if n.kind == .Iterate {
		return raise_taken(m.h, path_error(m, "Invalid path expression near attempt to iterate through ", result, 30))
	}
	return raise_taken(m.h, step_path_error(m, result, k))
}

// `.[]` of `t`, taken: its first child given now, the rest from an `Iter` frame.
@(private)
iterate :: proc(m: ^Machine, r: ^Regs, n: ^Node, t, tpath: query.Value) {
	h := m.h
	tt := query.type_of(t)
	if tt != .Array && tt != .Object {
		s := query.Status.Ok
		if .Opt not_in n.flags {
			s = query.fail(h, .Types, .Iterate, t)
		}
		query.release(h, t)
		query.release(h, tpath)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	count := -1
	if t.kind != .Node || (^query.Doc_Block)(t.p).doc.partial == nil {
		count = query.length_of(h, t)
		if count == 0 {
			query.release(h, t)
			query.release(h, tpath)
			r.sig, r.mode = .Go, .Ret
			return
		}
	}
	f, s := push(m, Iter_Frame, .Iter, r.k)
	if s != .Ok {
		query.release(h, t)
		query.release(h, tpath)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	f.track, f.of, f.path, f.left = r.track, t, tpath, count
	c, cs := query.cursor_open(h, t)
	if cs != .Ok {
		drop_iter(m, f)
		pop_frame(m)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	f.c = c
	next_child(m, r, f)
}

// The next child of iteration `f`, given to its `k`, the frame popped before its last.
@(private)
next_child :: proc(m: ^Machine, r: ^Regs, f: ^Iter_Frame) {
	h := m.h
	key, v, more, s := query.cursor_next(h, &f.c)
	if s != .Ok || !more {
		drop_iter(m, f)
		pop_frame(m)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	k := f.k
	r.vpath = query.ABSENT
	if f.track {
		step := key if key.kind != .Absent else query.int_value(f.i)
		p, ps := path_append(m, f.path, step)
		if ps != .Ok {
			query.release(h, key)
			query.release(h, v)
			drop_iter(m, f)
			pop_frame(m)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		r.vpath = p
	}
	query.release(h, key)
	f.i += 1
	if f.left > 0 {
		f.left -= 1
		if f.left == 0 {
			drop_iter(m, f)
			pop_frame(m)
		}
	}
	r.v, r.k, r.mode = v, k, .Emit
}

@(private)
drop_iter :: proc(m: ^Machine, f: ^Iter_Frame) {
	query.cursor_close(&f.c)
	query.release(m.h, f.of)
	query.release(m.h, f.path)
	f.of, f.path = query.ABSENT, query.ABSENT
}

@(private)
resume_iter :: proc(m: ^Machine, r: ^Regs, f: ^Iter_Frame) {
	if r.sig != .Go {
		drop_iter(m, f)
		pop_frame(m)
		return
	}
	next_child(m, r, f)
}

@(private)
resume_range :: proc(m: ^Machine, r: ^Regs, f: ^Range_Frame) {
	h := m.h
	if r.sig != .Go {
		drop_range(m, f)
		return
	}
	x := f.at
	track := f.track
	if x.kind == .Int && f.to.kind == .Int && (f.by.kind == .Absent || f.by.kind == .Int) {
		by := f.by.i if f.by.kind == .Int else 1
		if next, overflow := intrinsics.overflow_add(x.i, by); !overflow {
			f.at = query.int_value(next)
			k := f.k
			if !(by > 0 && next < f.to.i || by < 0 && next > f.to.i) {
				pop_frame(m)
			}
			r.v, r.vpath, r.k, r.mode = x, not_path_marker(m, x) if track else query.ABSENT, k, .Emit
			return
		}
	}
	step := f.by if f.by.kind != .Absent else query.int_value(1)
	if f.to.kind == .Absent {
		// The last output had no successor: the failed addition is raised now, after that output went out.
		next, s := add_values(h, x, step)
		query.release(h, next)
		drop_range(m, f)
		r.sig = .Fail if s != .Ok else .Go
		return
	}
	next, s := add_values(h, x, step)
	if s != .Ok && h.err.kind != .Types {
		drop_range(m, f)
		r.sig = .Fail
		return
	}
	k := f.k
	if s != .Ok {
		query.clear_error(h)
		query.release(h, f.to)
		f.to = query.ABSENT
		x = query.retain(x)
	} else {
		f.at = next
		go, gs := range_goes_on(m, f.at, f.to, f.by)
		if gs != .Ok {
			query.release(h, x)
			drop_range(m, f)
			r.sig = .Fail
			return
		}
		if !go {
			drop_range(m, f)
		}
	}
	r.v, r.vpath, r.k, r.mode = x, not_path_marker(m, x) if track else query.ABSENT, k, .Emit
}

@(private)
is_nan_number :: proc(v: query.Value) -> bool {
	return query.type_of(v) == .Number && math.is_nan(query.as_f64(v))
}

@(private)
drop_range :: proc(m: ^Machine, f: ^Range_Frame) {
	query.release(m.h, f.at)
	query.release(m.h, f.to)
	query.release(m.h, f.by)
	pop_frame(m)
}

// Whether a range at `at` toward `to` by `by` has an output left. An absent `by` is range/1 and range/2: step one,
// stop once `at` reaches `to`, which a NaN never does. range/3 is jq's `while` over its own comparisons, so the bounds
// and the step are any values: a step above zero in jq's order runs while `at < to`, one below while `at > to`, and
// NaN is below every value, itself included.
@(private)
range_goes_on :: proc(m: ^Machine, at, to, by: query.Value) -> (go: bool, status: query.Status) {
	if at.kind == .Int && to.kind == .Int {
		if by.kind == .Int {
			return by.i > 0 && at.i < to.i || by.i < 0 && at.i > to.i, .Ok
		}
		if by.kind == .Absent {
			return at.i < to.i, .Ok
		}
	}
	if by.kind == .Absent {
		return is_nan_number(at) || is_nan_number(to) || query.compare_numbers(at, to) < 0, .Ok
	}
	up := query.compare(m.h, by, query.int_value(0)) or_return
	if up == 0 {
		return false, .Ok
	}
	c := query.compare(m.h, at, to) or_return
	if up > 0 {
		return c < 0 || is_nan_number(at), .Ok
	}
	return c > 0, .Ok
}

@(private)
resume_try :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	h := m.h
	sig := r.sig
	if sig != .Fail || m.through != nil || is_fatal_error(h) {
		if m.through == f {
			m.through = nil
		}
		drop_frame(m, f)
		pop_frame(m)
		return
	}
	n := f.n
	if n.b == nil {
		query.clear_error(h)
		drop_frame(m, f)
		pop_frame(m)
		r.sig = .Go
		return
	}
	caught, s := error_value(m)
	r.n, r.input, r.path, r.env, r.k, r.track = n.b, caught, query.ABSENT, f.env, f.k, false
	f.env = nil
	drop_frame(m, f)
	pop_frame(m)
	if s != .Ok {
		finish(m, r, .Fail)
		return
	}
	r.mode = .Eval
}

// `a op b` of the left output `r.v` and the right one the frame keeps, or `a and b`, `a or b` once the left decides.
@(private)
emit_binary :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	h := m.h
	n := f.n
	l := r.v
	r.v = query.ABSENT
	query.release(h, r.vpath)
	r.vpath = query.ABSENT
	if n.kind == .And || n.kind == .Or {
		t := truthy(l)
		query.release(h, l)
		if n.kind == .And && !t || n.kind == .Or && t {
			give_value(m, r, f, query.bool_value(t))
			return
		}
		g, s := push(m, Input_Frame, .Truth, f.k)
		if s != .Ok {
			r.sig, r.mode = .Fail, .Ret
			return
		}
		g.track = f.track
		g.path = query.retain(f.path)
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = n.b, query.retain(f.input), query.ABSENT, env_retain(f.env), g, false, .Eval
		return
	}
	v, s := binary_owned(h, n.op, l, f.v)
	if s != .Ok {
		r.sig, r.mode = .Fail, .Ret
		return
	}
	give_value(m, r, f, v)
}

// Gives `v`, a value an operator made, to frame `f`'s `k`: in a path expression it is no path.
@(private)
give_value :: proc(m: ^Machine, r: ^Regs, f: ^Frame, v: query.Value) {
	r.vpath = query.ABSENT
	if f.track {
		r.vpath = not_path_marker(m, v)
	}
	r.v, r.k, r.mode = v, f.k, .Emit
}

// ---- Bindings and folds

@(private)
Destruct_Work :: struct {
	p:    ^Pattern,
	v:    query.Value, // held
	next: int, // an object pattern's next member
}

@(private)
Destruct_Mode :: enum u8 {
	Bind,
	Reduce,
	Foreach,
}

@(private)
Destruct_Frame :: struct {
	using frame: Frame,
	n:           ^Node,
	env:         ^Env,
	input:       query.Value,
	path:        query.Value,
	owner:       ^Input_Frame,
	cur_p:       ^Pattern,
	cur_v:       query.Value,
	cur_i:       int,
	rest:        []Destruct_Work,
	mode:        Destruct_Mode,
}

@(private)
clone_env :: proc(m: ^Machine, src: ^Env) -> (e: ^Env, status: query.Status) {
	e = new_env(m, src.parent, int(src.count), src.closures) or_return
	dst_slots := env_slots(e)
	src_slots := env_slots(src)
	for i in 0 ..< int(src.count) {
		dst_slots[i].value = query.retain(src_slots[i].value)
	}
	return e, .Ok
}

// Binds output `r.v` of a binding's source by its patterns and runs the body in the scope they make.
@(private)
emit_bind :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	h := m.h
	n := f.n
	query.release(h, r.vpath)
	r.vpath = query.ABSENT
	x := r.v
	r.v = query.ABSENT
	if len(n.patterns) > 1 {
		alternatives(m, r, f, x)
		return
	}
	e, s := new_env(m, f.env, int(n.slots), false)
	if s != .Ok {
		query.release(h, x)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	if n.patterns[0].kind == .Var {
		env_set(m, e, n.patterns[0].slot, x)
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = n.b, query.retain(f.input), query.retain(f.path), e, f.k, f.track, .Eval
		return
	}
	init := [1]Destruct_Work{{p = n.patterns[0], v = x}}
	destructure_run(m, r, n, e, f.input, f.path, f.k, f.track, nil, .Bind, init[:])
}

@(private)
resume_bind :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	drop_frame(m, f)
	pop_frame(m)
}

// `as p1 ?// p2 ...`: each pattern in turn, the next tried when destructuring or the body fails, every variable of
// every pattern bound, null where its pattern does not bind it.
@(private)
alternatives :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame, x: query.Value) {
	g, s := push(m, Input_Frame, .Alternative, f.k)
	if s != .Ok {
		query.release(m.h, x)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	g.track, g.n, g.env, g.input, g.path, g.v, g.i = f.track, f.n, env_retain(f.env), query.retain(f.input), query.retain(f.path), x, 0
	try_alternative(m, r, g)
}

@(private)
try_alternative :: proc(m: ^Machine, r: ^Regs, g: ^Input_Frame) {
	h := m.h
	n := g.n
	is_fold := g.owner != nil
	mode := Destruct_Mode.Bind
	if is_fold {
		mode = .Reduce if n.kind == .Reduce else .Foreach
	}
	for {
		e, s := new_env(m, g.env, int(n.slots), false)
		if s != .Ok {
			drop_frame(m, g)
			pop_frame(m)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		for k in 0 ..< int(n.slots) {
			env_slots(e)[k].value = query.NULL
		}
		init := [1]Destruct_Work{{p = n.patterns[g.i], v = query.retain(g.v)}}
		destructure_run(m, r, n, e, g.input, g.path, g, g.track, g, mode, init[:])
		if r.mode != .Ret || r.sig != .Fail || (is_fold && g.got) {
			return
		}
		if g.i + 1 >= len(n.patterns) || is_fatal_error(h) {
			drop_frame(m, g)
			pop_frame(m)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		query.clear_error(h)
		g.i += 1
	}
}

@(private)
resume_alternative :: proc(m: ^Machine, r: ^Regs, g: ^Input_Frame) {
	if r.sig == .Fail && g.i + 1 < len(g.n.patterns) && m.through == nil && !is_fatal_error(m.h) && (g.owner == nil || !g.got) {
		query.clear_error(m.h)
		g.i += 1
		try_alternative(m, r, g)
		return
	}
	if m.through == g {
		m.through = nil
	}
	drop_frame(m, g)
	pop_frame(m)
}

// Binds `x` by pattern `p` into the slots of `e` synchronously (all key expressions must be `.Native`).
// Returns `matched = false` with `.Ok` if a key expression yields empty.
@(private)
destructure_sync :: proc(m: ^Machine, p: ^Pattern, x: query.Value, e: ^Env, input: query.Value) -> (matched: bool, status: query.Status) {
	h := m.h
	if p.kind == .Var {
		env_set(m, e, p.slot, query.retain(x))
		return true, .Ok
	}
	inline_buf: [8]Destruct_Work
	sp := 0
	dyn: [dynamic]Destruct_Work
	defer {
		for i in 0 ..< sp {
			query.release(h, inline_buf[i].v)
		}
		for w in dyn {
			query.release(h, w.v)
		}
		delete(dyn)
	}
	push_w :: proc(h: ^query.Heap, inline_buf: ^[8]Destruct_Work, sp: ^int, dyn: ^[dynamic]Destruct_Work, w: Destruct_Work) -> query.Status {
		if len(dyn^) == 0 && sp^ < len(inline_buf) {
			inline_buf[sp^] = w
			sp^ += 1
			return .Ok
		}
		if dyn.allocator.procedure == nil {
			dyn^ = make([dynamic]Destruct_Work, 0, 16, h.allocator)
		}
		if _, err := append(dyn, w); err != nil {
			query.release(h, w.v)
			return query.fail(h, .Memory, .None)
		}
		return .Ok
	}
	inline_buf[0] = Work_init(p, query.retain(x))
	sp = 1
	for sp > 0 || len(dyn) > 0 {
		w: Destruct_Work
		if len(dyn) > 0 {
			w = pop(&dyn)
		} else {
			sp -= 1
			w = inline_buf[sp]
		}
		defer query.release(h, w.v)
		switch w.p.kind {
		case .Var:
			env_set(m, e, w.p.slot, query.retain(w.v))
		case .Array:
			t := query.type_of(w.v)
			if t != .Array && t != .Null && t != .Absent {
				return false, query.fail(h, .Types, .Index, w.v, query.int_value(i64(len(w.p.elems) - 1)))
			}
			#reverse for sub, i in w.p.elems {
				v := query.get(h, w.v, query.int_value(i64(i))) or_return
				push_w(h, &inline_buf, &sp, &dyn, Destruct_Work{p = sub, v = v}) or_return
			}
		case .Object:
			for i in w.next ..< len(w.p.members) {
				mem := w.p.members[i]
				key, found, s := eval_native(m, mem.key, query.retain(input), e.parent)
				if s != .Ok {
					return false, s
				}
				if !found {
					return false, .Ok
				}
				defer query.release(h, key)
				if query.type_of(key) != .String {
					return false, query.fail(h, .Types, .Index, w.v, key)
				}
				t := query.type_of(w.v)
				if t != .Object && t != .Null && t != .Absent {
					return false, query.fail(h, .Types, .Index, w.v, key)
				}
				v := query.get(h, w.v, key) or_return
				if mem.var != "" {
					env_set(m, e, mem.slot, query.retain(v))
				}
				if mem.pattern == nil {
					query.release(h, v)
					continue
				}
				if i + 1 < len(w.p.members) {
					push_w(h, &inline_buf, &sp, &dyn, Destruct_Work{p = w.p, v = query.retain(w.v), next = i + 1}) or_return
				}
				push_w(h, &inline_buf, &sp, &dyn, Destruct_Work{p = mem.pattern, v = v}) or_return
				break
			}
		}
	}
	return true, .Ok
}

@(private = "file")
Work_init :: #force_inline proc "contextless" (p: ^Pattern, v: query.Value) -> Destruct_Work {
	return {p = p, v = v}
}

// Runs destructuring work `init` (takes ownership of `e` and all `.v` in `init`), pausing onto a `Destruct_Frame`
// whenever a pattern key expression is not `.Native`, then dispatching to `mode` once all work items complete.
@(private)
destructure_run :: proc(m: ^Machine, r: ^Regs, n: ^Node, e: ^Env, input, path: query.Value, k: ^Frame, track: bool, owner: ^Input_Frame, mode: Destruct_Mode, init: []Destruct_Work) {
	h := m.h
	stack := make([dynamic]Destruct_Work, 0, max(len(init), 4), h.allocator)
	for w in init {
		if _, err := append(&stack, w); err != nil {
			query.release(h, w.v)
			for rem in stack {
				query.release(h, rem.v)
			}
			delete(stack)
			env_release(m, e)
			_ = query.fail(h, .Memory, .None)
			r.sig, r.mode = .Fail, .Ret
			return
		}
	}
	release_all :: proc(m: ^Machine, stack: ^[dynamic]Destruct_Work, e: ^Env) {
		for w in stack^ {
			query.release(m.h, w.v)
		}
		delete(stack^)
		env_release(m, e)
	}
	for len(stack) > 0 {
		w := pop(&stack)
		switch w.p.kind {
		case .Var:
			env_set(m, e, w.p.slot, w.v)
		case .Array:
			t := query.type_of(w.v)
			if t != .Array && t != .Null && t != .Absent {
				_ = query.fail(h, .Types, .Index, w.v, query.int_value(i64(len(w.p.elems) - 1)))
				query.release(h, w.v)
				release_all(m, &stack, e)
				r.sig, r.mode = .Fail, .Ret
				return
			}
			ok := true
			#reverse for sub, i in w.p.elems {
				v, vs := query.get(h, w.v, query.int_value(i64(i)))
				if vs != .Ok {
					ok = false
					break
				}
				if _, err := append(&stack, Destruct_Work{p = sub, v = v}); err != nil {
					query.release(h, v)
					_ = query.fail(h, .Memory, .None)
					ok = false
					break
				}
			}
			query.release(h, w.v)
			if !ok {
				release_all(m, &stack, e)
				r.sig, r.mode = .Fail, .Ret
				return
			}
		case .Object:
			paused := false
			for i in w.next ..< len(w.p.members) {
				mem := w.p.members[i]
				if .Native not_in mem.key.flags {
					df, ps := push(m, Destruct_Frame, .Destruct, k)
					if ps != .Ok {
						query.release(h, w.v)
						release_all(m, &stack, e)
						r.sig, r.mode = .Fail, .Ret
						return
					}
					rest: []Destruct_Work
					if len(stack) > 0 {
						err: runtime.Allocator_Error
						rest, err = make([]Destruct_Work, len(stack), h.allocator)
						if err != nil {
							pop_frame(m)
							query.release(h, w.v)
							release_all(m, &stack, e)
							_ = query.fail(h, .Memory, .None)
							r.sig, r.mode = .Fail, .Ret
							return
						}
						copy(rest, stack[:])
					}
					delete(stack)
					df.track = track
					df.n, df.env, df.input, df.path, df.owner, df.mode = n, e, query.retain(input), query.retain(path), owner, mode
					df.cur_p, df.cur_v, df.cur_i, df.rest = w.p, w.v, i, rest
					key_env := e if len(n.patterns) > 1 else e.parent
					r.n, r.input, r.path, r.env, r.k, r.track, r.mode = mem.key, query.retain(input), query.ABSENT, env_retain(key_env), df, false, .Eval
					paused = true
					break
				}
				key_env := e if len(n.patterns) > 1 else e.parent
				key, found, s := eval_native(m, mem.key, query.retain(input), key_env)
				if s != .Ok {
					query.release(h, w.v)
					release_all(m, &stack, e)
					r.sig, r.mode = .Fail, .Ret
					return
				}
				if !found {
					query.release(h, w.v)
					release_all(m, &stack, e)
					r.sig, r.mode = .Go, .Ret
					return
				}
				if query.type_of(key) != .String {
					_ = query.fail(h, .Types, .Index, w.v, key)
					query.release(h, key)
					query.release(h, w.v)
					release_all(m, &stack, e)
					r.sig, r.mode = .Fail, .Ret
					return
				}
				t := query.type_of(w.v)
				if t != .Object && t != .Null && t != .Absent {
					_ = query.fail(h, .Types, .Index, w.v, key)
					query.release(h, key)
					query.release(h, w.v)
					release_all(m, &stack, e)
					r.sig, r.mode = .Fail, .Ret
					return
				}
				v, vs := query.get(h, w.v, key)
				query.release(h, key)
				if vs != .Ok {
					query.release(h, w.v)
					release_all(m, &stack, e)
					r.sig, r.mode = .Fail, .Ret
					return
				}
				if mem.var != "" {
					env_set(m, e, mem.slot, query.retain(v))
				}
				if mem.pattern == nil {
					query.release(h, v)
					continue
				}
				if i + 1 < len(w.p.members) {
					if _, err := append(&stack, Destruct_Work{p = w.p, v = query.retain(w.v), next = i + 1}); err != nil {
						query.release(h, v)
						query.release(h, w.v)
						release_all(m, &stack, e)
						_ = query.fail(h, .Memory, .None)
						r.sig, r.mode = .Fail, .Ret
						return
					}
				}
				if _, err := append(&stack, Destruct_Work{p = mem.pattern, v = v}); err != nil {
					query.release(h, v)
					query.release(h, w.v)
					release_all(m, &stack, e)
					_ = query.fail(h, .Memory, .None)
					r.sig, r.mode = .Fail, .Ret
					return
				}
				break
			}
			if paused {
				return
			}
			query.release(h, w.v)
		}
	}
	delete(stack)
	switch mode {
	case .Bind:
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = n.b, query.retain(input), query.retain(path), e, k, track, .Eval
	case .Reduce, .Foreach:
		run := owner
		if owner != nil && owner.kind == .Alternative {
			owner.got = true
			run = (^Input_Frame)(owner.owner)
		}
		run_fold_update(m, r, run, e)
	}
}

@(private)
emit_destruct :: proc(m: ^Machine, r: ^Regs, df: ^Destruct_Frame) {
	h := m.h
	query.release(h, r.vpath)
	r.vpath = query.ABSENT
	key := r.v
	r.v = query.ABSENT
	defer query.release(h, key)
	if query.type_of(key) != .String {
		_ = query.fail(h, .Types, .Index, df.cur_v, key)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	t := query.type_of(df.cur_v)
	if t != .Object && t != .Null && t != .Absent {
		_ = query.fail(h, .Types, .Index, df.cur_v, key)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	v, vs := query.get(h, df.cur_v, key)
	if vs != .Ok {
		r.sig, r.mode = .Fail, .Ret
		return
	}
	e, es := clone_env(m, df.env)
	if es != .Ok {
		query.release(h, v)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	mem := df.cur_p.members[df.cur_i]
	if mem.var != "" {
		env_set(m, e, mem.slot, query.retain(v))
	}
	extra := 0
	if df.cur_i + 1 < len(df.cur_p.members) {
		extra += 1
	}
	if mem.pattern != nil {
		extra += 1
	}
	work, err := make([]Destruct_Work, len(df.rest) + extra, h.allocator)
	if err != nil {
		query.release(h, v)
		env_release(m, e)
		_ = query.fail(h, .Memory, .None)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	defer delete(work, h.allocator)
	idx := 0
	for w in df.rest {
		work[idx] = {p = w.p, v = query.retain(w.v), next = w.next}
		idx += 1
	}
	if df.cur_i + 1 < len(df.cur_p.members) {
		work[idx] = {p = df.cur_p, v = query.retain(df.cur_v), next = df.cur_i + 1}
		idx += 1
	}
	if mem.pattern != nil {
		work[idx] = {p = mem.pattern, v = v}
		idx += 1
	} else {
		query.release(h, v)
	}
	destructure_run(m, r, df.n, e, df.input, df.path, df.k, df.track, df.owner, df.mode, work[:idx])
}

@(private)
drop_destruct :: proc(m: ^Machine, df: ^Destruct_Frame) {
	h := m.h
	env_release(m, df.env)
	query.release(h, df.input)
	query.release(h, df.path)
	query.release(h, df.cur_v)
	for w in df.rest {
		query.release(h, w.v)
	}
	delete(df.rest, h.allocator)
}

// A start of a reduce or foreach: a fold over its source from state `r.v`.
@(private)
emit_fold_start :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	h := m.h
	query.release(h, r.vpath)
	r.vpath = query.ABSENT
	run, s := push(m, Input_Frame, .Foreach, f.k)
	if s != .Ok {
		query.release(h, r.v)
		r.v = query.ABSENT
		r.sig, r.mode = .Fail, .Ret
		return
	}
	n := f.n
	run.n, run.v, run.input, run.track = n, r.v, query.retain(f.input), f.track
	r.v = query.ABSENT
	e, es := new_env(m, f.env, int(n.slots), false)
	if es != .Ok {
		drop_frame(m, run)
		pop_frame(m)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	run.env = e
	r.n, r.input, r.path, r.env, r.k, r.track, r.mode = n.a, query.retain(f.input), query.ABSENT, env_retain(f.env), run, false, .Eval
}

// Runs one fold update step for `run` with bound scope `e` (takes ownership of `e`).
@(private)
run_fold_update :: proc(m: ^Machine, r: ^Regs, run: ^Input_Frame, e: ^Env) {
	h := m.h
	n := run.n
	upd := n.c
	if n.kind == .Reduce {
		state := run.v
		run.v = query.ABSENT
		if .Native in upd.flags {
			out, found, us := eval_native_maybe_origin(m, upd, state, e)
			env_release(m, e)
			if us != .Ok {
				r.sig, r.mode = .Fail, .Ret
				return
			}
			run.v = out if found else query.NULL
			r.sig, r.mode = .Go, .Ret
			return
		}
		u, ps := push(m, Input_Frame, .Reduce_Update, nil)
		if ps != .Ok {
			env_release(m, e)
			query.release(h, state)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		u.owner = run
		if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(state) {
			if os := push_origin(m, state, u); os != .Ok {
				env_release(m, e)
				query.release(h, state)
				r.sig, r.mode = .Fail, .Ret
				return
			}
		}
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = upd, state, query.ABSENT, e, u, false, .Eval
		return
	}
	u, ps := push(m, Input_Frame, .Foreach_Update, nil)
	if ps != .Ok {
		env_release(m, e)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	u.owner, u.env = run, env_retain(e)
	// The state moves into the update: one that gives nothing leaves null, as jq's does.
	state := run.v
	run.v = query.NULL
	if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(state) {
		if os := push_origin(m, state, u); os != .Ok {
			env_release(m, e)
			query.release(h, state)
			r.sig, r.mode = .Fail, .Ret
			return
		}
	}
	r.n, r.input, r.path, r.env, r.k, r.track, r.mode = upd, state, query.ABSENT, e, u, false, .Eval
}

// An item of a fold's source: bound, then the update run on the state.
@(private)
emit_foreach_item :: proc(m: ^Machine, r: ^Regs, run: ^Input_Frame) {
	h := m.h
	query.release(h, r.vpath)
	r.vpath = query.ABSENT
	n := run.n
	x := r.v
	r.v = query.ABSENT
	if len(n.patterns) == 1 && n.patterns[0].kind == .Var {
		if run.env.rc > 1 {
			e, s := new_env(m, run.env.parent, int(n.slots), false)
			if s != .Ok {
				query.release(h, x)
				r.sig, r.mode = .Fail, .Ret
				return
			}
			env_release(m, run.env)
			run.env = e
		}
		env_set(m, run.env, n.patterns[0].slot, x)
		if n.kind == .Reduce && .Native in n.c.flags {
			state := run.v
			run.v = query.ABSENT
			out, found, us := eval_native_maybe_origin(m, n.c, state, run.env)
			if us != .Ok {
				r.sig, r.mode = .Fail, .Ret
				return
			}
			run.v = out if found else query.NULL
			r.sig, r.mode = .Go, .Ret
			return
		}
		run_fold_update(m, r, run, env_retain(run.env))
		return
	}
	if len(n.patterns) > 1 {
		g, ps := push(m, Input_Frame, .Alternative, run.k)
		if ps != .Ok {
			query.release(h, x)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		g.track, g.n, g.env, g.input, g.v, g.owner, g.i = run.track, n, env_retain(run.env.parent), query.retain(run.input), x, run, 0
		try_alternative(m, r, g)
		return
	}
	all_native := true
	for key in n.keys {
		if .Native not_in key.flags {
			all_native = false
			break
		}
	}
	if !all_native {
		e, s := new_env(m, run.env.parent, int(n.slots), false)
		if s != .Ok {
			query.release(h, x)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		init := [1]Destruct_Work{{p = n.patterns[0], v = x}}
		destructure_run(m, r, n, e, run.input, query.ABSENT, run.k, run.track, run, .Reduce if n.kind == .Reduce else .Foreach, init[:])
		return
	}
	if run.env.rc > 1 {
		// A closure of the last update still holds the scope: bind in a new one.
		e, s := new_env(m, run.env.parent, int(n.slots), false)
		if s != .Ok {
			query.release(h, x)
			r.sig, r.mode = .Fail, .Ret
			return
		}
		env_release(m, run.env)
		run.env = e
	}
	matched, s := destructure_sync(m, n.patterns[0], x, run.env, run.input)
	query.release(h, x)
	if s != .Ok || !matched {
		r.sig, r.mode = .Fail if s != .Ok else .Go, .Ret
		return
	}
	run_fold_update(m, r, run, env_retain(run.env))
}

// The end of a fold's source: a reduce gives its state.
@(private)
resume_fold :: proc(m: ^Machine, r: ^Regs, run: ^Input_Frame) {
	if r.sig == .Go && run.n.kind == .Reduce {
		v, k, track := run.v, run.k, run.track
		run.v = query.ABSENT
		drop_frame(m, run)
		pop_frame(m)
		r.v, r.vpath, r.k, r.mode = v, not_path_marker(m, v) if track else query.ABSENT, k, .Emit
		return
	}
	drop_frame(m, run)
	pop_frame(m)
}

// An output of `limit`'s filter: the last one it lets through takes a cut, which breaks it once taken.
@(private)
emit_limit :: proc(m: ^Machine, r: ^Regs, f: ^Count_Frame) {
	f.left -= 1
	if f.left > 0 {
		r.k = f.k
		return
	}
	c, s := push(m, Input_Frame, .Cut, nil)
	if s != .Ok {
		query.release(m.h, r.v)
		query.release(m.h, r.vpath)
		r.v, r.vpath = query.ABSENT, query.ABSENT
		r.sig, r.mode = .Fail, .Ret
		return
	}
	c.owner = f
	r.k = f.k
}
