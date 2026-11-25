package jq

import "base:intrinsics"
import "stury:lib/query"

// The evaluator: a push model on an explicit stack. A filter sends each output on, and the answer steers it: `.Go`
// asks for more, `.Break` unwinds to the frame `Machine.brk` names, `.Fail` to the nearest `try` with the error in
// the heap, `.Halt` to the run's end. The sinks and generator resume points that native frames would hold are frames
// of the stack instead, and one loop takes one of three steps at a time (`drive`): evaluate a node into a frame, give
// an output to a frame, or resume the top frame with the signal what ran above it ended with. A node marked
// `.Native` runs to its one output in `eval_native`, whose depth its height bounds.

@(private)
Signal :: enum u8 {
	Go,
	Break,
	Fail,
	Halt,
	Taint,
}

// Where a run's outputs go, each the sink's to release: false stops the run.
Output :: #type proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool

@(private)
Machine :: struct {
	h:        ^query.Heap,
	prog:     ^Program,
	globals:  []query.Value,
	hooks:    ^Hooks,
	stack:    Stack,
	brk:      ^Frame, // the label or limit a `.Break` unwinds to, nil for the run's own end
	through:  ^Frame, // the try that an error raised downstream of its output passes
	out:      Output,
	out_data: rawptr,
	halt:     Halt_State,
	empty:    query.Value, // the program's empty array
	over:     bool, // the run ended as the step budget ran out
	budget:   int, // the evaluations a run may take, 0 for any
	steps:    int, // the evaluations left before the step budget runs out, negative for no budget
	regexes:      query.Regex_Cache, // the patterns this run compiled
	css:          Selector_Cache, // the CSS selectors this run compiled
	origin:       query.Value, // retained nearest document-origin value along active pipes (`track_origin` only)
	track_origin: bool, // enabled only when the program calls `where` or `Hooks.place != nil`
}

// How `halt` or `halt_error` ended a run.
Halt_State :: struct {
	halted: bool,
	code:   int,
	value:  query.Value, // halt_error's, held; `.Absent` for `halt`
}

@(private)
Mode_Step :: enum u8 {
	Eval,
	Emit,
	Ret,
}

// The evaluator's registers, each owning what it holds: the node to run, its input and the input's path when
// tracking, the scope, the frame outputs go to, and the output being given.
@(private)
Regs :: struct {
	n:     ^Node,
	input: query.Value,
	path:  query.Value,
	v:     query.Value,
	vpath: query.Value,
	env:   ^Env,
	k:     ^Frame,
	track: bool,
	sig:   Signal,
	mode:  Mode_Step,
}

// A frame holding a node, its scope and an input, for the kinds that run more of the program on that input.
@(private)
Input_Frame :: struct {
	using frame: Frame,
	n:           ^Node,
	env:         ^Env,
	input:       query.Value,
	path:        query.Value,
	v:           query.Value, // a value it keeps: an operand, a state, the last output
	vpath:       query.Value,
	i:           int,
	got:         bool,
	owner:       ^Frame,
}

// A comma's right side, run on the input once the left side's outputs are given.
@(private)
Comma_Frame :: struct {
	using frame: Frame,
	n:           ^Node,
	env:         ^Env,
	input:       query.Value,
	path:        query.Value,
}

@(private)
Collect_Frame :: struct {
	using frame: Frame,
	arr:         query.Value,
}

@(private)
Iter_Frame :: struct {
	using frame: Frame,
	of:          query.Value, // held
	path:        query.Value, // held, the container's
	c:           query.Cursor,
	left:        int,
	i:           i64,
}

@(private)
Range_Frame :: struct {
	using frame: Frame,
	at, to, by:  query.Value,
}

@(private)
Count_Frame :: struct {
	using frame: Frame,
	left:        i64,
}

@(private)
Origin_Frame :: struct {
	using frame: Frame,
	prev:        query.Value, // retained previous `m.origin`, restored on `.Ret`
}

@(private)
MAX_ARGS :: 4

// Runs `root` on `input`, which it takes, in `env`, its outputs to `m.out`, with no recursion past `eval_native`'s.
@(private)
drive :: proc(m: ^Machine, root: ^Node, input: query.Value, env: ^Env) -> Signal {
	r := Regs{n = root, input = input, env = env_retain(env), mode = .Eval}
	base := m.stack.top
	steps := m.steps
	defer m.steps = steps
	for {
		switch r.mode {
		case .Eval:
			if m.h.tainted {
				taint_abort(m, &r)
				continue
			}
			if steps == 0 {
				over_budget(m, &r)
				continue
			}
			steps -= 1
			step_eval(m, &r, &steps)
		case .Emit:
			if m.h.tainted {
				taint_abort(m, &r)
				continue
			}
			if r.k == nil {
				if query.value_has_partial(r.v) {
					m.h.tainted = true
					taint_abort(m, &r)
					continue
				}
				query.release(m.h, r.vpath)
				r.vpath = query.ABSENT
				if !m.out(m.out_data, r.v, m.h) {
					m.brk = nil
					r.sig, r.mode = .Break, .Ret
				} else {
					r.sig, r.mode = .Go, .Ret
				}
				r.v = query.ABSENT
				continue
			}
			step_emit(m, &r, &steps)
		case .Ret:
			if m.h.tainted {
				r.sig = .Taint
			}
			if m.stack.top == base {
				return r.sig
			}
			step_ret(m, &r, &steps)
		}
	}
}

// Whether the heap holds an error that `try`, `?` and `?//` must not catch.
@(private)
is_fatal_error :: #force_inline proc "contextless" (h: ^query.Heap) -> bool {
	return h.tainted || h.err.kind == .Memory || h.err.kind == .Budget
}

// Ends the run as a read reached an unloaded value of a partial document: nothing catches it.
@(private, cold)
taint_abort :: proc(m: ^Machine, r: ^Regs) {
	query.release(m.h, m.halt.value)
	m.halt = {}
	query.release(m.h, r.v)
	query.release(m.h, r.vpath)
	r.v, r.vpath = query.ABSENT, query.ABSENT
	finish(m, r, .Taint)
}

// Ends the run as the step budget ran out: no `try` catches it.
@(private, cold)
over_budget :: proc(m: ^Machine, r: ^Regs) {
	query.fail(m.h, .Budget, .None)
	m.h.err.budget = .Steps
	query.release(m.h, m.halt.value)
	m.halt = {}
	m.over = true
	query.release(m.h, r.v)
	query.release(m.h, r.vpath)
	r.v, r.vpath = query.ABSENT, query.ABSENT
	finish(m, r, .Halt)
}

// Sets the step budget error for a loop inside a native builtin.
@(private, cold)
fail_budget :: proc(m: ^Machine) -> query.Status {
	query.fail(m.h, .Budget, .None)
	m.h.err.budget = .Steps
	query.release(m.h, m.halt.value)
	m.halt = {}
	m.over = true
	return .Error
}

// Ends the evaluation in hand with output `v` and its path.
@(private)
give :: #force_inline proc(m: ^Machine, r: ^Regs, v: query.Value) {
	env_release(m, r.env)
	r.env = nil
	r.vpath = r.path
	r.path = query.ABSENT
	query.release(m.h, r.input)
	r.input = query.ABSENT
	r.v, r.mode = v, .Emit
}

// Ends the evaluation in hand with no output and signal `sig`.
@(private)
finish :: #force_inline proc(m: ^Machine, r: ^Regs, sig: Signal) {
	query.release(m.h, r.input)
	query.release(m.h, r.path)
	env_release(m, r.env)
	r.input, r.path, r.env = query.ABSENT, query.ABSENT, nil
	r.sig, r.mode = sig, .Ret
}

@(private)
fail_status :: #force_inline proc(s: query.Status) -> Signal {
	return .Fail if s != .Ok else .Go
}

// Pushes a frame of type `T` whose outputs go to `r.k`, or ends the evaluation with the failure.
@(private)
push_or_fail :: #force_inline proc(m: ^Machine, r: ^Regs, $T: typeid, kind: Frame_Kind) -> ^T {
	f, s := push(m, T, kind, r.k)
	if s != .Ok {
		finish(m, r, .Fail)
		return nil
	}
	f.track = r.track
	return f
}

@(private)
LEAVES :: bit_set[Node_Kind]{.Identity, .Literal, .Var}

// Evaluates nodes while each hands on to the next, a tail turn, with no return to `drive` between them.
@(private)
step_eval :: #force_inline proc(m: ^Machine, r: ^Regs, steps: ^int) {
	for {
		if steps^ >= 0 {
			m.steps = steps^
		}
		eval_once(m, r)
		if steps^ >= 0 {
			steps^ = m.steps
		}
		if r.mode != .Eval {
			return
		}
		if m.h.tainted {
			taint_abort(m, r)
			return
		}
		if steps^ == 0 {
			over_budget(m, r)
			return
		}
		steps^ -= 1
	}
}

@(private)
eval_once :: #force_inline proc(m: ^Machine, r: ^Regs) {
	h := m.h
	n := r.n
	// A leaf gives its value below, with no call of the native evaluator.
	if .Native in n.flags && !r.track && n.kind not_in LEAVES {
		out, found, s := eval_native(m, n, r.input, r.env)
		r.input = query.ABSENT
		if s != .Ok || !found {
			finish(m, r, fail_status(s))
			return
		}
		give(m, r, out)
		return
	}
	switch n.kind {
	case .Identity:
		v := r.input
		r.input = query.ABSENT
		give(m, r, v)
	case .Literal:
		value_out(m, r, n.value)
	case .Var:
		value_out(m, r, var_value(m, n, r.env))
	case .Field, .Index, .Slice, .Iterate:
		eval_step(m, r)
	case .Pipe:
		if n.a.kind == .Array && n.a.a != nil && !r.track && counts_outputs(n.b) {
			// `[f] | length` counts the outputs of `f` with no array of them.
			f := push_or_fail(m, r, Count_Frame, .Tally)
			if f == nil {
				return
			}
			r.n, r.k = n.a.a, f
			return
		}
		if .Native in n.a.flags && !r.track {
			out, found, s := eval_native(m, n.a, r.input, r.env)
			r.input = query.ABSENT
			if s != .Ok || !found {
				finish(m, r, fail_status(s))
				return
			}
			if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(out) {
				if os := push_origin(m, out, r.k); os != .Ok {
					query.release(h, out)
					finish(m, r, .Fail)
					return
				}
			}
			r.input, r.n = out, n.b
			return
		}
		f := push_or_fail(m, r, Input_Frame, .Pipe)
		if f == nil {
			return
		}
		f.n, f.env = n.b, env_retain(r.env)
		r.n, r.k = n.a, f
	case .Comma:
		a, aenv := closure_target(n.a, r.env)
		if .Native in a.flags && !r.track {
			// The left side's one output goes on from here, the right side held in the frame it resumes.
			v, found, s := eval_native(m, a, query.retain(r.input), aenv)
			if s != .Ok {
				finish(m, r, .Fail)
				return
			}
			if !found {
				r.n = n.b
				return
			}
			f := push_or_fail(m, r, Comma_Frame, .Comma)
			if f == nil {
				query.release(h, v)
				return
			}
			f.n, f.env, f.input, f.path = n.b, r.env, r.input, r.path
			r.env, r.input, r.path = nil, query.ABSENT, query.ABSENT
			r.v, r.mode = v, .Emit
			return
		}
		f := push_or_fail(m, r, Comma_Frame, .Comma)
		if f == nil {
			return
		}
		f.n, f.env, f.input, f.path = n.b, env_retain(r.env), query.retain(r.input), query.retain(r.path)
		r.n = n.a
	case .If:
		if .Native in n.a.flags {
			cond, found, s := eval_native(m, n.a, query.retain(r.input), r.env)
			if s != .Ok || !found {
				finish(m, r, fail_status(s))
				return
			}
			t := truthy(cond)
			query.release(h, cond)
			if t {
				r.n = n.b
			} else if n.c != nil {
				r.n = n.c
			} else {
				give(m, r, query.retain(r.input))
			}
			return
		}
		f := push_or_fail(m, r, Input_Frame, .If)
		if f == nil {
			return
		}
		f.n, f.env, f.input, f.path = n, env_retain(r.env), query.retain(r.input), r.path
		r.path = query.ABSENT
		r.n, r.k, r.track = n.a, f, false
	case .Def:
		r.n = n.a
	case .Call:
		eval_call(m, r)
	case .Array:
		if n.a == nil {
			value_out(m, r, m.empty)
			return
		}
		f := push_or_fail(m, r, Collect_Frame, .Collect)
		if f == nil {
			return
		}
		arr, s := query.make_array(h, 1 if .Single in n.a.flags else 8)
		if s != .Ok {
			pop_frame(m)
			finish(m, r, .Fail)
			return
		}
		f.arr = arr
		query.release(h, r.path)
		r.path = query.ABSENT
		r.n, r.k, r.track = n.a, f, false
	case .Neg:
		f := push_or_fail(m, r, Input_Frame, .Neg)
		if f == nil {
			return
		}
		r.n, r.k = n.a, f
	case .Binary, .And, .Or:
		// The right side's outputs first, each with every output of the left: jq's order.
		f := push_or_fail(m, r, Input_Frame, .Bin_R)
		if f == nil {
			return
		}
		f.n, f.env, f.input = n, env_retain(r.env), query.retain(r.input)
		if r.track {
			f.track = true
			f.path = query.retain(r.path)
		}
		if n.kind != .Binary {
			// `a and b`, `a or b`: the left first, and the right only when it decides.
			f.kind = .Bin_L
			r.n, r.k, r.track = n.a, f, false
			return
		}
		r.n, r.k, r.track = n.b, f, false
	case .Alt:
		f := push_or_fail(m, r, Input_Frame, .Alt)
		if f == nil {
			return
		}
		f.n, f.env, f.input, f.path = n, env_retain(r.env), query.retain(r.input), query.retain(r.path)
		r.n, r.k = n.a, f
	case .Try:
		f := push_or_fail(m, r, Input_Frame, .Try)
		if f == nil {
			return
		}
		f.n, f.env = n, env_retain(r.env)
		r.n, r.k = n.a, f
	case .Label:
		f := push_or_fail(m, r, Input_Frame, .Label)
		if f == nil {
			return
		}
		e, s := new_env(m, r.env, 1, false)
		if s != .Ok {
			pop_frame(m)
			finish(m, r, .Fail)
			return
		}
		env_slots(e)[0].value = query.int_value(i64(uintptr(f)))
		env_release(m, r.env)
		r.env = e
		r.n = n.a
	case .Break:
		e := env_up(r.env, n.ref.hops)
		m.brk = (^Frame)(uintptr(env_slots(e)[n.ref.slot].value.i))
		finish(m, r, .Break)
	case .Bind:
		f := push_or_fail(m, r, Input_Frame, .Bind)
		if f == nil {
			return
		}
		f.n, f.env, f.input, f.path = n, env_retain(r.env), query.retain(r.input), query.retain(r.path)
		query.release(h, r.path)
		r.path = query.ABSENT
		r.n, r.k, r.track = n.a, f, false
	case .Reduce, .Foreach:
		f := push_or_fail(m, r, Input_Frame, .Reduce)
		if f == nil {
			return
		}
		f.n, f.env, f.input, f.path = n, env_retain(r.env), query.retain(r.input), query.retain(r.path)
		query.release(h, r.path)
		r.path = query.ABSENT
		r.n, r.k, r.track = n.b, f, false
	case .String, .Object:
		eval_parts(m, r)
	case .Format:
		eval_format(m, r)
	case .Update:
		eval_update(m, r)
	}
}

// A value the node made, not read at a path: in a path expression it keeps the input's path only when it is the input
// itself, as jq's jv_identical tells.
@(private)
value_out :: #force_inline proc(m: ^Machine, r: ^Regs, v: query.Value) {
	if r.track {
		if !identical(v, r.input) {
			query.release(m.h, r.path)
			r.path = not_path_marker(m, v)
		}
	}
	give(m, r, v)
}

// Whether `a` and `b` are the same value as jq's jv_identical has it: one block, one node, or equal null or booleans.
@(private)
identical :: proc(a, b: query.Value) -> bool {
	if a.kind != b.kind {
		ta, tb := query.type_of(a), query.type_of(b)
		return ta == tb && (ta == .Null || ta == .True || ta == .False)
	}
	#partial switch a.kind {
	case .Absent, .Null, .False, .True:
		return true
	case .Int, .Double:
		// A number the input and the program wrote is a literal of its own in jq, never the one a function made.
		return false
	case .String:
		return a.s == b.s && a.n == b.n
	case .Node:
		return a.p == b.p && a.n == b.n && query.type_of(a) != .Number
	}
	return a.p == b.p
}


// A frame's handling of output `r.v`.
@(private)
step_emit :: #force_inline proc(m: ^Machine, r: ^Regs, steps: ^int) {
	h := m.h
	f := r.k
	switch f.kind {
	case .Pipe:
		p := (^Input_Frame)(f)
		if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(r.v) {
			if os := push_origin(m, r.v, p.k); os != .Ok {
				query.release(h, r.v)
				query.release(h, r.vpath)
				r.v, r.vpath = query.ABSENT, query.ABSENT
				r.sig, r.mode = .Fail, .Ret
				return
			}
		}
		r.n, r.input, r.path, r.env, r.k, r.track = p.n, r.v, r.vpath, env_retain(p.env), p.k, p.track
		r.v, r.vpath, r.mode = query.ABSENT, query.ABSENT, .Eval
	case .Collect:
		c := (^Collect_Frame)(f)
		query.release(h, r.vpath)
		r.vpath = query.ABSENT
		s := query.append_owned(h, &c.arr, r.v)
		r.v = query.ABSENT
		r.sig, r.mode = fail_status(s), .Ret
	case .Tally:
		query.release(h, r.v)
		query.release(h, r.vpath)
		r.v, r.vpath = query.ABSENT, query.ABSENT
		(^Count_Frame)(f).left += 1
		r.sig, r.mode = .Go, .Ret
	case .If:
		p := (^Input_Frame)(f)
		t := truthy(r.v)
		query.release(h, r.v)
		query.release(h, r.vpath)
		r.v, r.vpath = query.ABSENT, query.ABSENT
		n := p.n.b if t else p.n.c
		if n == nil {
			r.v, r.vpath, r.k = query.retain(p.input), query.retain(p.path), p.k
			return
		}
		r.n, r.input, r.path, r.env, r.k, r.track = n, query.retain(p.input), query.retain(p.path), env_retain(p.env), p.k, p.track
		r.mode = .Eval
	case .Neg:
		query.release(h, r.vpath)
		r.vpath = query.ABSENT
		y, s := negate(h, r.v)
		query.release(h, r.v)
		r.v = query.ABSENT
		if s != .Ok {
			r.sig, r.mode = .Fail, .Ret
			return
		}
		give_value(m, r, f, y)
	case .Format:
		emit_format(m, r, (^Input_Frame)(f))
	case .Bin_R:
		p := (^Input_Frame)(f)
		query.release(h, r.vpath)
		r.vpath = query.ABSENT
		g, s := push(m, Input_Frame, .Bin_L, p.k)
		if s != .Ok {
			query.release(h, r.v)
			r.v = query.ABSENT
			r.sig, r.mode = .Fail, .Ret
			return
		}
		g.n, g.v, g.track = p.n, r.v, p.track
		g.path = query.retain(p.path)
		r.v = query.ABSENT
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = p.n.a, query.retain(p.input), query.ABSENT, env_retain(p.env), g, false, .Eval
	case .Bin_L:
		emit_binary(m, r, (^Input_Frame)(f))
	case .Truth:
		query.release(h, r.vpath)
		r.vpath = query.ABSENT
		t := truthy(r.v)
		query.release(h, r.v)
		r.v = query.ABSENT
		give_value(m, r, f, query.bool_value(t))
	case .Step:
		p := (^Step_Frame)(f)
		t, tp := r.v, r.vpath
		r.v, r.vpath = query.ABSENT, query.ABSENT
		r.k, r.track = p.k, p.track
		step_apply(m, r, p.n, t, tp, p.key, p.from, p.to)
	case .Key:
		emit_key(m, r, (^Input_Frame)(f))
	case .Alt:
		p := (^Input_Frame)(f)
		if !truthy(r.v) {
			query.release(h, r.v)
			query.release(h, r.vpath)
			r.v, r.vpath = query.ABSENT, query.ABSENT
			r.sig, r.mode = .Go, .Ret
			return
		}
		p.got = true
		r.k = f.k
	case .Try, .Alternative:
		pass_through(m, r, f)
	case .Bind:
		emit_bind(m, r, (^Input_Frame)(f))
	case .Destruct:
		emit_destruct(m, r, (^Destruct_Frame)(f))
	case .Reduce:
		emit_fold_start(m, r, (^Input_Frame)(f))
	case .Reduce_Update:
		p := (^Input_Frame)(f)
		query.release(h, p.v)
		query.release(h, r.vpath)
		p.v, p.got, r.v, r.vpath = r.v, true, query.ABSENT, query.ABSENT
		r.sig, r.mode = .Go, .Ret
	case .Foreach:
		if steps^ == 0 {
			over_budget(m, r)
			return
		}
		steps^ -= 1
		if steps^ >= 0 {
			m.steps = steps^
		}
		emit_foreach_item(m, r, (^Input_Frame)(f))
		if steps^ >= 0 {
			steps^ = m.steps
		}
	case .Foreach_Update:
		p := (^Input_Frame)(f)
		run := (^Input_Frame)(p.owner)
		query.release(h, r.vpath)
		r.vpath = query.ABSENT
		query.release(h, run.v)
		run.v = query.retain(r.v)
		if run.n.d == nil {
			if run.track {
				r.vpath = not_path_marker(m, r.v)
			}
			r.k = run.k
			return
		}
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = run.n.d, r.v, not_path_marker(m, r.v) if run.track else query.ABSENT, env_retain(p.env), run.k, run.track, .Eval
		r.v = query.ABSENT
	case .Label, .Out, .Comma, .Iter, .Range, .Cut, .Gen, .Css, .Args, .Origin:
		// These frames give their outputs straight to `k`: none is a `k` itself.
		r.k = f.k
	case .Limit:
		emit_limit(m, r, (^Count_Frame)(f))
	case .Skip:
		c := (^Count_Frame)(f)
		if c.left > 0 {
			c.left -= 1
			query.release(h, r.v)
			query.release(h, r.vpath)
			r.v, r.vpath = query.ABSENT, query.ABSENT
			r.sig, r.mode = .Go, .Ret
			return
		}
		r.k = f.k
	case .Isempty:
		query.release(h, r.v)
		query.release(h, r.vpath)
		r.v, r.vpath = query.ABSENT, query.ABSENT
		m.brk = f
		r.sig, r.mode = .Break, .Ret
	case .Last:
		p := (^Input_Frame)(f)
		query.release(h, p.v)
		query.release(h, p.vpath)
		p.v, p.vpath, p.got = r.v, r.vpath, true
		r.v, r.vpath = query.ABSENT, query.ABSENT
		r.sig, r.mode = .Go, .Ret
	case .Select:
		p := (^Input_Frame)(f)
		t := truthy(r.v)
		query.release(h, r.v)
		query.release(h, r.vpath)
		r.v, r.vpath = query.ABSENT, query.ABSENT
		if !t {
			r.sig, r.mode = .Go, .Ret
			return
		}
		r.v, r.vpath, r.k = query.retain(p.input), query.retain(p.path), p.k
	case .Path:
		emit_path(m, r, f)
	case .Arg:
		emit_arg(m, r, (^Input_Frame)(f))
	case .Update:
		emit_update(m, r, (^Input_Frame)(f))
	case .Update_Each:
		emit_update_each(m, r, (^Update_Frame)(f))
	}
}

// An output of a try's body, given on through an `Out` marker, so an error raised by what takes it is known to come from
// downstream.
@(private)
pass_through :: proc(m: ^Machine, r: ^Regs, owner: ^Frame) {
	o, s := push(m, Input_Frame, .Out, owner.k)
	if s != .Ok {
		query.release(m.h, r.v)
		query.release(m.h, r.vpath)
		r.v, r.vpath = query.ABSENT, query.ABSENT
		r.sig, r.mode = .Fail, .Ret
		return
	}
	o.owner = owner
	r.k = owner.k
}

// What the top frame does with signal `r.sig` from what ran above it.
@(private)
step_ret :: #force_inline proc(m: ^Machine, r: ^Regs, steps: ^int) {
	h := m.h
	f := m.stack.top
	sig := r.sig
	switch f.kind {
	case .Pipe, .If, .Bin_R, .Bin_L, .Neg, .Truth, .Select, .Path, .Update, .Key, .Format, .Reduce, .Foreach_Update:
		drop_frame(m, f)
		pop_frame(m)
	case .Comma:
		p := (^Comma_Frame)(f)
		if sig != .Go {
			env_release(m, p.env)
			query.release(h, p.input)
			query.release(h, p.path)
			pop_frame(m)
			return
		}
		r.n, r.input, r.path, r.env, r.k, r.track = p.n, p.input, p.path, p.env, p.k, p.track
		pop_frame(m)
		r.mode = .Eval
	case .Collect:
		c := (^Collect_Frame)(f)
		arr, k, track := c.arr, c.k, c.track
		pop_frame(m)
		if sig != .Go {
			query.release(h, arr)
			return
		}
		r.v, r.vpath, r.k, r.mode = arr, not_path_marker(m, arr) if track else query.ABSENT, k, .Emit
	case .Tally:
		count, k := (^Count_Frame)(f).left, f.k
		pop_frame(m)
		if sig == .Go {
			r.v, r.k, r.mode = query.int_value(count), k, .Emit
		}
	case .Iter:
		if sig == .Go {
			if steps^ == 0 {
				over_budget(m, r)
				return
			}
			steps^ -= 1
		}
		resume_iter(m, r, (^Iter_Frame)(f))
	case .Range:
		if sig == .Go {
			if steps^ == 0 {
				over_budget(m, r)
				return
			}
			steps^ -= 1
		}
		resume_range(m, r, (^Range_Frame)(f))
	case .Step:
		p := (^Step_Frame)(f)
		query.release(h, p.key)
		query.release(h, p.from)
		query.release(h, p.to)
		pop_frame(m)
	case .Alt:
		p := (^Input_Frame)(f)
		if sig != .Go || p.got {
			drop_frame(m, f)
			pop_frame(m)
			return
		}
		r.n, r.input, r.path, r.env, r.k, r.track = p.n.b, p.input, p.path, p.env, p.k, p.track
		pop_frame(m)
		r.mode = .Eval
	case .Try:
		resume_try(m, r, (^Input_Frame)(f))
	case .Out:
		o := (^Input_Frame)(f)
		if sig == .Fail && m.through == nil {
			m.through = o.owner
		}
		pop_frame(m)
	case .Label, .Limit:
		pop_frame(m)
		if sig == .Break && m.brk == f {
			r.sig = .Go
		}
	case .Skip, .Arg:
		pop_frame(m)
	case .Origin:
		of := (^Origin_Frame)(f)
		query.release(h, m.origin)
		m.origin = of.prev
		pop_frame(m)
	case .Gen:
		if sig == .Go {
			if steps^ == 0 {
				over_budget(m, r)
				return
			}
			steps^ -= 1
		}
		resume_gen(m, r, f)
	case .Css:
		if sig == .Go {
			if steps^ == 0 {
				over_budget(m, r)
				return
			}
			steps^ -= 1
		}
		resume_css(m, r, (^Css_Frame)(f))
	case .Cut:
		c := (^Input_Frame)(f)
		target := c.owner
		pop_frame(m)
		if sig == .Go {
			m.brk = target
			r.sig = .Break
		}
	case .Isempty:
		k, track := f.k, f.track
		pop_frame(m)
		if sig == .Go || sig == .Break && m.brk == f {
			v := query.bool_value(sig == .Go)
			r.v, r.vpath, r.k, r.mode = v, not_path_marker(m, v) if track else query.ABSENT, k, .Emit
		}
	case .Bind:
		resume_bind(m, r, (^Input_Frame)(f))
	case .Alternative:
		resume_alternative(m, r, (^Input_Frame)(f))
	case .Destruct:
		drop_destruct(m, (^Destruct_Frame)(f))
		pop_frame(m)
	case .Reduce_Update:
		p := (^Input_Frame)(f)
		run := (^Input_Frame)(p.owner)
		if sig == .Go {
			run.v = p.v if p.got else query.NULL
		} else {
			query.release(h, p.v)
		}
		pop_frame(m)
	case .Foreach:
		resume_fold(m, r, (^Input_Frame)(f))
	case .Args:
		drop_args(m, (^Args_Frame)(f))
		pop_frame(m)
	case .Update_Each:
		resume_update_each(m, r, (^Update_Frame)(f))
	case .Last:
		p := (^Input_Frame)(f)
		v, vp, got, k := p.v, p.vpath, p.got, p.k
		pop_frame(m)
		if sig == .Go && got {
			r.v, r.vpath, r.k, r.mode = v, vp, k, .Emit
		} else {
			query.release(h, v)
			query.release(h, vp)
		}
	}
}

// Gives up what frame `f` owns, as it is popped with nothing taken out of it.
@(private)
drop_frame :: proc(m: ^Machine, f: ^Frame) {
	h := m.h
	#partial switch f.kind {
	case .Comma:
		p := (^Comma_Frame)(f)
		env_release(m, p.env)
		query.release(h, p.input)
		query.release(h, p.path)
	case .Pipe, .If, .Bin_R, .Bin_L, .Truth, .Neg, .Format, .Key, .Alt, .Try, .Bind, .Alternative, .Reduce, .Foreach,
	     .Foreach_Update, .Reduce_Update, .Path, .Last, .Select, .Update:
		p := (^Input_Frame)(f)
		env_release(m, p.env)
		query.release(h, p.input)
		query.release(h, p.path)
		query.release(h, p.v)
		query.release(h, p.vpath)
	case .Collect:
		query.release(h, (^Collect_Frame)(f).arr)
	case .Destruct:
		drop_destruct(m, (^Destruct_Frame)(f))
	case .Css:
		drop_css(m, (^Css_Frame)(f))
	case .Origin:
		of := (^Origin_Frame)(f)
		query.release(h, of.prev)
	}
}

// The node a call of a filter argument runs, through arguments passed on, and its scope: `n` in `env` for any other.
@(private)
closure_target :: #force_inline proc "contextless" (n: ^Node, env: ^Env) -> (^Node, ^Env) {
	n, env := n, env
	for n.kind == .Call && n.ref.kind == .Param {
		c := env_slots(env_up(env, n.ref.hops))[n.ref.slot].closure
		n, env = c.node, c.env
	}
	return n, env
}

// Whether `n` is jq's own `length` with no argument.
@(private)
counts_outputs :: proc(n: ^Node) -> bool {
	return n.kind == .Call && n.ref.kind == .None && n.builtin != nil && n.builtin.fn == v_length
}

// The value of variable node `n`, held.
@(private)
var_value :: #force_inline proc(m: ^Machine, n: ^Node, env: ^Env) -> query.Value {
	if n.ref.kind == .Global {
		return query.retain(m.globals[n.ref.slot])
	}
	e := env_up(env, n.ref.hops)
	return query.retain(env_slots(e)[n.ref.slot].value)
}

// Updates `m.origin` for a continuation targeting `k`, coalescing into an existing top `Origin_Frame`
// targeting the same `k` so tail recursion under `where` stays O(1) in stack space.
@(private, cold)
push_origin :: #force_no_inline proc(m: ^Machine, v: query.Value, k: ^Frame) -> query.Status {
	if m.stack.top != nil && m.stack.top.kind == .Origin && m.stack.top.k == k {
		query.release(m.h, m.origin)
		m.origin = query.retain(v)
		return .Ok
	}
	of, os := push(m, Origin_Frame, .Origin, k)
	if os != .Ok {
		return os
	}
	of.prev = m.origin
	m.origin = query.retain(v)
	return .Ok
}

// Evaluates native node `n` on `input` while setting `m.origin` to `input` for its duration.
@(private, cold)
eval_native_origin :: #force_no_inline proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (query.Value, bool, query.Status) {
	prev := m.origin
	m.origin = query.retain(input)
	v, found, s := eval_native(m, n, input, env)
	query.release(m.h, m.origin)
	m.origin = prev
	return v, found, s
}

@(private)
eval_native_maybe_origin :: #force_inline proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (query.Value, bool, query.Status) {
	if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(input) {
		return eval_native_origin(m, n, input, env)
	}
	return eval_native(m, n, input, env)
}

@(private)
native_maybe_origin :: #force_inline proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (query.Value, Got) {
	if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(input) {
		return native_with_origin(m, n, input, env)
	}
	return native(m, n, input, env)
}

// jq's truth: anything but null and false.
@(private)
truthy :: #force_inline proc "contextless" (v: query.Value) -> bool {
	#partial switch v.kind {
	case .Absent, .Null, .False:
		return false
	case .Node:
		t := query.type_of(v)
		return t != .Null && t != .False
	}
	return true
}
