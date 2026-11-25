package jq

import "base:intrinsics"
import "stury:lib/query"

// The native evaluator: a node marked `.Native` has at most one output and calls no jq function, so it runs to that
// output with the native stack, its depth bounded by `NATIVE_HEIGHT`. It takes its input.

// What a native evaluation gave: a value, none, or the failure in the heap.
@(private)
Got :: enum u8 {
	Value,
	None,
	Failed,
}

@(private)
got_of :: #force_inline proc "contextless" (s: query.Status) -> Got {
	return .Value if s == .Ok else .Failed
}

// `n` on `input`, which it takes: the output, none (`found` false), or the failure in the heap.
@(private)
eval_native :: proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, found: bool, status: query.Status) {
	v, g := native(m, n, input, env)
	if m.h.tainted {
		if g == .Value {
			query.release(m.h, v)
		}
		return query.ABSENT, false, .Ok
	}
	return v, g == .Value, .Error if g == .Failed else .Ok
}

@(private)
native :: proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, got: Got) {
	h := m.h
	switch n.kind {
	case .Identity:
		return input, .Value
	case .Literal:
		query.release(h, input)
		return n.value, .Value
	case .Var:
		query.release(h, input)
		return var_value(m, n, env), .Value
	case .Field:
		t, tg := input, Got.Value
		if n.a.kind != .Identity {
			t, tg = native(m, n.a, input, env)
			if tg != .Value {
				return t, tg
			}
		}
		defer query.release(h, t)
		if t.kind == .Object {
			v, _ := query.member(h, t, query.text_of(n.value))
			return v if v.kind != .Absent else query.NULL, .Value
		}
		return step_got(apply_step(m, n, t, query.ABSENT, query.ABSENT, query.ABSENT))
	case .Index:
		key, kg := native(m, n.b, query.retain(input), env)
		if kg != .Value {
			query.release(h, input)
			return key, kg
		}
		defer query.release(h, key)
		t, tg := native(m, n.a, input, env)
		if tg != .Value {
			return t, tg
		}
		defer query.release(h, t)
		return step_got(apply_step(m, n, t, key, query.ABSENT, query.ABSENT))
	case .Slice:
		from, to := query.NULL, query.NULL
		defer query.release(h, from)
		defer query.release(h, to)
		for b, i in ([2]^Node{n.b, n.c}) {
			if b == nil {
				continue
			}
			x, xg := native(m, b, query.retain(input), env)
			if xg != .Value {
				query.release(h, input)
				return x, xg
			}
			if i == 0 {
				from = x
			} else {
				to = x
			}
		}
		t, tg := native(m, n.a, input, env)
		if tg != .Value {
			return t, tg
		}
		defer query.release(h, t)
		return step_got(apply_step(m, n, t, query.ABSENT, from, to))
	case .Pipe:
		x, xg := native(m, n.a, input, env)
		if xg != .Value {
			return x, xg
		}
		if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(x) {
			return native_with_origin(m, n.b, x, env)
		}
		return native(m, n.b, x, env)
	case .Binary:
		r, leaf_r := leaf_value(m, n.b, input, env)
		if !leaf_r {
			rg: Got
			r, rg = native(m, n.b, query.retain(input), env)
			if rg != .Value {
				query.release(h, input)
				return r, rg
			}
		}
		l: query.Value
		if n.a.kind == .Identity {
			l = input
		} else if lv, leaf_l := leaf_value(m, n.a, input, env); leaf_l {
			query.release(h, input)
			l = lv
		} else {
			lg: Got
			l, lg = native(m, n.a, input, env)
			if lg != .Value {
				query.release(h, r)
				return l, lg
			}
		}
		if l.kind == .Int && r.kind == .Int {
			if v, ok := int_binary(n.op, l.i, r.i); ok {
				return v, .Value
			}
		}
		v, s := binary_owned(h, n.op, l, r)
		query.release(h, r)
		return v, got_of(s)
	case .And, .Or:
		l, lg := native(m, n.a, query.retain(input), env)
		if lg != .Value || h.tainted {
			if lg == .Value {
				query.release(h, l)
			}
			query.release(h, input)
			return query.ABSENT if h.tainted else l, .None if h.tainted else lg
		}
		t := truthy(l)
		query.release(h, l)
		if n.kind == .And && !t || n.kind == .Or && t {
			query.release(h, input)
			return query.bool_value(t), .Value
		}
		r, rg := native(m, n.b, input, env)
		if rg != .Value {
			return r, rg
		}
		t = truthy(r)
		query.release(h, r)
		return query.bool_value(t), .Value
	case .Alt:
		l, lg := native(m, n.a, query.retain(input), env)
		if h.tainted {
			if lg == .Value {
				query.release(h, l)
			}
			query.release(h, input)
			return query.ABSENT, .None
		}
		if lg == .Failed || lg == .Value && truthy(l) {
			query.release(h, input)
			return l, lg
		}
		query.release(h, l)
		return native(m, n.b, input, env)
	case .If:
		c, cg := native(m, n.a, query.retain(input), env)
		if cg != .Value || h.tainted {
			if cg == .Value {
				query.release(h, c)
			}
			query.release(h, input)
			return query.ABSENT if h.tainted else c, .None if h.tainted else cg
		}
		t := truthy(c)
		query.release(h, c)
		if t {
			return native(m, n.b, input, env)
		}
		if n.c != nil {
			return native(m, n.c, input, env)
		}
		return input, .Value
	case .Try:
		v, vg := native(m, n.a, input, env)
		if vg != .Failed || is_fatal_error(h) {
			return v, vg
		}
		if n.b == nil {
			query.clear_error(h)
			return query.NULL, .None
		}
		e, s := error_value(m)
		if s != .Ok {
			return query.NULL, .Failed
		}
		return native(m, n.b, e, env)
	case .Neg:
		x, xg := native(m, n.a, input, env)
		if xg != .Value {
			return x, xg
		}
		defer query.release(h, x)
		v, s := negate(h, x)
		return v, got_of(s)
	case .Array:
		if n.a == nil {
			query.release(h, input)
			return m.empty, .Value
		}
		if t, f, is_map := map_parts(n.a); is_map {
			return native_map(m, n.a.a if n.a.kind == .Pipe else n.a, t, f, input, env)
		}
		x, xg := native(m, n.a, input, env)
		if xg == .Failed {
			return x, xg
		}
		if xg == .None {
			return m.empty, .Value
		}
		arr, s := query.make_array(h, 1)
		if s == .Ok {
			s = query.append_owned(h, &arr, x)
		} else {
			query.release(h, x)
		}
		return arr, got_of(s)
	case .Object:
		defer query.release(h, input)
		o, s := query.make_object(h, len(n.args) / 2)
		if s != .Ok {
			return query.NULL, .Failed
		}
		if .Distinct_Keys in n.flags {
			for i := 0; i < len(n.args); i += 2 {
				v, vg := native(m, n.args[i + 1], query.retain(input), env)
				if vg != .Value {
					query.release(h, o)
					return v, vg
				}
				if s = query.object_put_fresh(h, &o, n.args[i].value, v); s != .Ok {
					query.release(h, o)
					return query.NULL, .Failed
				}
			}
			return o, .Value
		}
		for i := 0; i < len(n.args); i += 2 {
			k, kg := native(m, n.args[i], query.retain(input), env)
			if kg != .Value {
				query.release(h, o)
				return k, kg
			}
			v: query.Value
			vg: Got
			if n.args[i + 1] == nil {
				vs: query.Status
				v, vs = query.get(h, input, k)
				vg = got_of(vs)
			} else {
				v, vg = native(m, n.args[i + 1], query.retain(input), env)
			}
			if vg != .Value {
				query.release(h, k)
				query.release(h, o)
				return v, vg
			}
			if s = put_entry(h, &o, k, v); s != .Ok {
				query.release(h, o)
				return query.NULL, .Failed
			}
		}
		return o, .Value
	case .String:
		defer query.release(h, input)
		acc := query.text_borrowed("")
		for part in n.args {
			if part.kind == .Literal {
				if query.text_append(h, &acc, query.text_of(part.value)) != .Ok {
					query.release(h, acc)
					return query.NULL, .Failed
				}
				continue
			}
			t, tg := native(m, part, query.retain(input), env)
			if tg == .Value && query.text_append(h, &acc, query.text_of(t)) != .Ok {
				tg = .Failed
			}
			query.release(h, t)
			if tg != .Value {
				query.release(h, acc)
				return query.NULL, tg
			}
		}
		return acc, .Value
	case .Format:
		x := input
		if n.a != nil {
			xg: Got
			x, xg = native(m, n.a, input, env)
			if xg != .Value {
				return x, xg
			}
		}
		defer query.release(h, x)
		v, s := format_value(m, n.name, x)
		return v, got_of(s)
	case .Bind:
		x, xg := native(m, n.a, query.retain(input), env)
		if xg != .Value {
			query.release(h, input)
			return x, xg
		}
		e, s := new_env(m, env, int(n.slots), false)
		matched := true
		if s == .Ok {
			matched, s = destructure_sync(m, n.patterns[0], x, e, input)
		}
		query.release(h, x)
		if s != .Ok || !matched {
			env_release(m, e)
			query.release(h, input)
			return query.NULL, .Failed if s != .Ok else .None
		}
		defer env_release(m, e)
		return native(m, n.b, input, e)
	case .Call:
		return native_call(m, n, input, env)
	case .Update:
		return native_update(m, n, input, env)
	case .Iterate, .Comma, .Reduce, .Foreach, .Def, .Label, .Break:
	}
	unreachable()
}

// Fast native path for simple non-optional updates (`. op= rhs`, `.k op= rhs`, `.[expr] op= rhs`, `.a.b = rhs`).
@(private)
native_update :: proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, got: Got) {
	h := m.h
	rhs := query.ABSENT
	if n.op != .Modify {
		rg: Got
		rhs, rg = native(m, n.b, query.retain(input), env)
		if rg != .Value {
			query.release(h, input)
			return rhs, rg
		}
	}
	defer query.release(h, rhs)
	// Collect path steps from outermost to innermost (at most 8).
	steps: [8]^Node
	depth := 0
	for cur := n.a; cur.kind != .Identity; cur = cur.a {
		steps[depth] = cur
		depth += 1
	}
	if depth == 0 {
		#partial switch n.op {
		case .Assign:
			query.release(h, input)
			r := rhs
			rhs = query.ABSENT
			return r, .Value
		case .Modify:
			v, vg := native(m, n.b, input, env)
			if vg == .None {
				return query.NULL, .Value
			}
			return v, vg
		case .Alt:
			if truthy(input) {
				return input, .Value
			}
			query.release(h, input)
			r := rhs
			rhs = query.ABSENT
			return r, .Value
		case:
			v, s := binary_owned(h, n.op, input, rhs)
			return v, got_of(s)
		}
	}
	keys: [8]query.Value
	defer for k in keys[:depth] {
		query.release(h, k)
	}
	for i in 0 ..< depth {
		step := steps[depth - 1 - i]
		if step.kind == .Field {
			keys[i] = step.value
		} else {
			k, kg := native(m, step.b, query.retain(input), env)
			if kg != .Value {
				if kg == .None {
					return input, .Value
				}
				query.release(h, input)
				return k, kg
			}
			keys[i] = k
		}
	}
	if depth == 1 {
		k := keys[0]
		#partial switch n.op {
		case .Assign:
			r := rhs
			rhs = query.ABSENT
			v, s := query.set_one(h, input, k, r)
			return v, got_of(s)
		case .Modify:
			cur, s := query.get(h, input, k)
			if s != .Ok || h.tainted {
				query.release(h, cur)
				query.release(h, input)
				return query.ABSENT if h.tainted else query.NULL, .None if h.tainted else .Failed
			}
			state := input
			if (cur.kind == .Array || cur.kind == .Object || cur.kind == .String) && query.type_of(k) != .Object {
				state, s = query.set_one(h, state, k, query.NULL)
				if s != .Ok || h.tainted {
					query.release(h, cur)
					if h.tainted {
						query.release(h, state)
						return query.ABSENT, .None
					}
					return query.NULL, .Failed
				}
			}
			v, vg := native_maybe_origin(m, n.b, cur, env)
			if vg == .Failed || h.tainted {
				if vg == .Value {
					query.release(h, v)
				}
				query.release(h, state)
				return query.ABSENT if h.tainted else query.NULL, .None if h.tainted else .Failed
			}
			if vg == .None {
				out, ds := query.del_one(h, state, k)
				return out, got_of(ds)
			}
			out, ss := query.set_one(h, state, k, v)
			return out, got_of(ss)
		case:
			cur, s := query.get(h, input, k)
			if s != .Ok || h.tainted {
				query.release(h, cur)
				query.release(h, input)
				return query.ABSENT if h.tainted else query.NULL, .None if h.tainted else .Failed
			}
			state := input
			if n.op == .Add && (cur.kind == .Array || cur.kind == .Object || cur.kind == .String) && query.type_of(k) != .Object {
				state, s = query.set_one(h, state, k, query.NULL)
				if s != .Ok {
					query.release(h, cur)
					return query.NULL, .Failed
				}
			}
			v: query.Value
			if n.op == .Alt {
				if truthy(cur) {
					v = cur
				} else {
					query.release(h, cur)
					v = query.retain(rhs)
				}
			} else {
				v, s = binary_owned(h, n.op, cur, rhs)
				if s != .Ok {
					query.release(h, state)
					return query.NULL, .Failed
				}
			}
			out, ss := query.set_one(h, state, k, v)
			return out, got_of(ss)
		}
	}
	path_arr, ps := query.make_array(h, depth)
	if ps != .Ok {
		query.release(h, input)
		return query.NULL, .Failed
	}
	defer query.release(h, path_arr)
	has_slice := false
	for k in keys[:depth] {
		if query.type_of(k) == .Object {
			has_slice = true
		}
		if query.append_owned(h, &path_arr, query.retain(k)) != .Ok {
			query.release(h, input)
			return query.NULL, .Failed
		}
	}
	#partial switch n.op {
	case .Assign:
		r := rhs
		rhs = query.ABSENT
		v, s := query.set_path(h, input, path_arr, r)
		return v, got_of(s)
	case .Modify:
		cur, s := query.get_path(h, input, path_arr)
		if s != .Ok {
			query.release(h, input)
			return query.NULL, .Failed
		}
		state := input
		if !has_slice && (cur.kind == .Array || cur.kind == .Object || cur.kind == .String) {
			state, s = query.set_path(h, state, path_arr, query.NULL)
			if s != .Ok {
				query.release(h, cur)
				return query.NULL, .Failed
			}
		}
		v, vg := native_maybe_origin(m, n.b, cur, env)
		if vg == .Failed || h.tainted {
			if vg == .Value {
				query.release(h, v)
			}
			query.release(h, state)
			return query.ABSENT if h.tainted else query.NULL, .None if h.tainted else .Failed
		}
		if vg == .None {
			dels, ds := query.make_array(h, 1)
			if ds != .Ok {
				query.release(h, state)
				return query.NULL, .Failed
			}
			defer query.release(h, dels)
			if query.append_owned(h, &dels, query.retain(path_arr)) != .Ok {
				query.release(h, state)
				return query.NULL, .Failed
			}
			out, dss := query.del_paths(h, state, dels)
			return out, got_of(dss)
		}
		out, ss := query.set_path(h, state, path_arr, v)
		return out, got_of(ss)
	case:
		cur, s := query.get_path(h, input, path_arr)
		if s != .Ok {
			query.release(h, input)
			return query.NULL, .Failed
		}
		state := input
		if n.op == .Add && !has_slice && (cur.kind == .Array || cur.kind == .Object || cur.kind == .String) {
			state, s = query.set_path(h, state, path_arr, query.NULL)
			if s != .Ok {
				query.release(h, cur)
				return query.NULL, .Failed
			}
		}
		v: query.Value
		if n.op == .Alt {
			if truthy(cur) {
				v = cur
			} else {
				query.release(h, cur)
				v = query.retain(rhs)
			}
		} else {
			v, s = binary_owned(h, n.op, cur, rhs)
			if s != .Ok {
				query.release(h, state)
				return query.NULL, .Failed
			}
		}
		out, ss := query.set_path(h, state, path_arr, v)
		return out, got_of(ss)
	}
}

// `[t[] | f]`, `it` the iteration, `f` nil for `[t[]]`.
@(private)
native_map :: proc(m: ^Machine, it, t, f: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, got: Got) {
	h := m.h
	of, og := native(m, t, input, env)
	if og == .Failed {
		return of, og
	}
	if og == .None {
		return m.empty, .Value
	}
	defer query.release(h, of)
	if tt := query.type_of(of); tt != .Array && tt != .Object {
		if .Opt in it.flags {
			return m.empty, .Value
		}
		return query.NULL, got_of(query.fail(h, .Types, .Iterate, of))
	}
	count := query.length_of(h, of)
	if count == 0 {
		return m.empty, .Value
	}
	arr, as := query.make_array(h, count)
	if as != .Ok {
		return query.NULL, .Failed
	}
	if of.kind == .Array {
		for x in query.items_of(of) {
			if m.steps >= 0 {
				if m.steps == 0 {
					query.release(h, arr)
					_ = fail_budget(m)
					return query.NULL, .Failed
				}
				m.steps -= 1
			}
			y, yg := query.retain(x), Got.Value
			if f != nil {
				if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(y) {
					y, yg = native_with_origin(m, f, y, env)
				} else {
					y, yg = native(m, f, y, env)
				}
			}
			if yg == .None {
				continue
			}
			if yg == .Failed || query.append_owned(h, &arr, y) != .Ok {
				query.release(h, arr)
				return query.NULL, .Failed
			}
		}
		return arr, .Value
	}
	c, cs := query.cursor_open(h, of)
	if cs != .Ok {
		query.release(h, arr)
		return query.NULL, .Failed
	}
	defer query.cursor_close(&c)
	for {
		if m.steps >= 0 {
			if m.steps == 0 {
				query.release(h, arr)
				_ = fail_budget(m)
				return query.NULL, .Failed
			}
			m.steps -= 1
		}
		key, x, more, s := query.cursor_next(h, &c)
		query.release(h, key)
		if s != .Ok || !more {
			if s != .Ok {
				query.release(h, arr)
				return query.NULL, .Failed
			}
			return arr, .Value
		}
		y, yg := x, Got.Value
		if f != nil {
			if intrinsics.expect(m.track_origin, false) && query.has_doc_origin(x) {
				y, yg = native_with_origin(m, f, x, env)
			} else {
				y, yg = native(m, f, x, env)
			}
		}
		if yg == .None {
			continue
		}
		if yg == .Failed || query.append_owned(h, &arr, y) != .Ok {
			query.release(h, arr)
			return query.NULL, .Failed
		}
	}
}

// Evaluates `n` on `input` (which has a document origin) while setting `m.origin` to `input` and restoring on return.
@(private, cold)
native_with_origin :: #force_no_inline proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, got: Got) {
	prev := m.origin
	m.origin = query.retain(input)
	defer {
		query.release(m.h, m.origin)
		m.origin = prev
	}
	return native(m, n, input, env)
}

// The value of a node that reads no more than its input or scope, held, or false for any other node.
@(private)
leaf_value :: #force_inline proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (query.Value, bool) {
	#partial switch n.kind {
	case .Literal:
		return n.value, true
	case .Identity:
		return query.retain(input), true
	case .Var:
		return var_value(m, n, env), true
	}
	return {}, false
}

// `a op b` on two integers when it stays an `i64` and cannot fail, else false for the general operation.
@(private)
int_binary :: #force_inline proc "contextless" (op: Op, a, b: i64) -> (query.Value, bool) {
	#partial switch op {
	case .Add:
		r, overflow := intrinsics.overflow_add(a, b)
		return query.int_value(r), !overflow
	case .Sub:
		r, overflow := intrinsics.overflow_sub(a, b)
		return query.int_value(r), !overflow
	case .Mul:
		r, overflow := intrinsics.overflow_mul(a, b)
		return query.int_value(r), !overflow
	case .Mod:
		if b == 0 {
			return {}, false
		}
		return query.int_value(0 if b == -1 else a % b), true
	case .Eq:
		return query.bool_value(a == b), true
	case .Ne:
		return query.bool_value(a != b), true
	case .Lt:
		return query.bool_value(a < b), true
	case .Le:
		return query.bool_value(a <= b), true
	case .Gt:
		return query.bool_value(a > b), true
	case .Ge:
		return query.bool_value(a >= b), true
	}
	return {}, false
}

@(private)
step_got :: #force_inline proc(v: query.Value, found: bool, s: query.Status) -> (query.Value, Got) {
	if s != .Ok {
		return v, .Failed
	}
	return v, .Value if found else .None
}

// A call of a builtin the native evaluator runs.
@(private)
native_call :: proc(m: ^Machine, n: ^Node, input: query.Value, env: ^Env) -> (res: query.Value, got: Got) {
	h := m.h
	b := n.builtin
	#partial switch b.op {
	case .Empty:
		query.release(h, input)
		return query.NULL, .None
	case .Select:
		c, cg := native(m, n.args[0], query.retain(input), env)
		if cg != .Value || !truthy(c) {
			query.release(h, c)
			query.release(h, input)
			return query.NULL, .None if cg != .Failed else .Failed
		}
		query.release(h, c)
		return input, .Value
	case .Kind_Filter:
		if query.type_of(input) in b.types {
			return input, .Value
		}
		query.release(h, input)
		return query.NULL, .None
	case .Error:
		x := input
		if len(n.args) == 1 {
			xg: Got
			x, xg = native(m, n.args[0], input, env)
			if xg != .Value {
				return x, xg
			}
		}
		raise(h, x)
		query.release(h, x)
		return query.NULL, .Failed
	}
	args: [MAX_ARGS]query.Value
	defer for a in args[:len(n.args)] {
		query.release(h, a)
	}
	// Fast path for `sort_by`/`group_by`/`unique_by`/`min_by`/`max_by`: unwrap `map([f])` when `f` is native,
	// avoiding per-element 1-element wrapper array allocations.
	unwrapped_keys := false
	if b.fn == v_by && len(n.args) == 1 && query.type_of(input) == .Array {
		if key_expr, ok := unwrap_by_key(n.args[0]); ok {
			keys, kg, fell_back := eval_by_keys(m, input, key_expr, env)
			if !fell_back {
				if kg != .Value {
					query.release(h, input)
					return keys, kg
				}
				args[0] = keys
				unwrapped_keys = true
			}
		}
	}
	if !unwrapped_keys {
		// The last argument first, as the call evaluates them when they generate.
		for k in 0 ..< len(n.args) {
			i := k if b.op != .None else len(n.args) - 1 - k
			x, xg := native(m, n.args[i], query.retain(input), env)
			if xg != .Value {
				query.release(h, input)
				return x, xg
			}
			args[i] = x
		}
	}
	v, s := b.fn(m, b, input, args[:len(n.args)])
	if !b.takes_input {
		query.release(h, input)
	}
	return v, got_of(s)
}

// Checks whether `arg` has the shape `[.[] | [f]]` (from `map([f])` in `group_by`/`sort_by`/...) with native `f`.
@(private)
unwrap_by_key :: proc(arg: ^Node) -> (key_expr: ^Node, ok: bool) {
	if arg == nil || arg.kind != .Array || arg.a == nil {
		return nil, false
	}
	t, f, is_map := map_parts(arg.a)
	if !is_map || t.kind != .Identity || f == nil || f.kind != .Array || f.a == nil {
		return nil, false
	}
	if .Native not_in f.a.flags {
		return nil, false
	}
	if _, _, inner_map := map_parts(f.a); inner_map {
		return nil, false
	}
	return f.a, true
}

// Evaluates `key_expr` once per element of array `input` directly into a flat keys array.
// Falls back (`fell_back = true`) if any element yields `empty` (since `[empty]` is `[]`, which sorts differently from scalars).
@(private)
eval_by_keys :: proc(m: ^Machine, input: query.Value, key_expr: ^Node, env: ^Env) -> (res: query.Value, got: Got, fell_back: bool) {
	h := m.h
	n := query.length_of(h, input)
	if n == 0 {
		return m.empty, .Value, false
	}
	keys, s := query.make_array(h, n)
	if s != .Ok {
		return query.NULL, .Failed, false
	}
	if input.kind == .Array {
		for x in query.items_of(input) {
			if m.steps >= 0 {
				if m.steps == 0 {
					query.release(h, keys)
					_ = fail_budget(m)
					return query.NULL, .Failed, false
				}
				m.steps -= 1
			}
			y, yg := native_maybe_origin(m, key_expr, query.retain(x), env)
			if yg == .None {
				query.release(h, keys)
				return query.NULL, .None, true
			}
			if yg == .Failed || query.append_owned(h, &keys, y) != .Ok {
				query.release(h, keys)
				return query.NULL, .Failed, false
			}
		}
		return keys, .Value, false
	}
	c, cs := query.cursor_open(h, input)
	if cs != .Ok {
		query.release(h, keys)
		return query.NULL, .Failed, false
	}
	defer query.cursor_close(&c)
	for {
		if m.steps >= 0 {
			if m.steps == 0 {
				query.release(h, keys)
				_ = fail_budget(m)
				return query.NULL, .Failed, false
			}
			m.steps -= 1
		}
		_, x, more, ns := query.cursor_next(h, &c)
		if ns != .Ok {
			query.release(h, keys)
			return query.NULL, .Failed, false
		}
		if !more {
			return keys, .Value, false
		}
		y, yg := native_maybe_origin(m, key_expr, x, env)
		if yg == .None {
			query.release(h, keys)
			return query.NULL, .None, true
		}
		if yg == .Failed || query.append_owned(h, &keys, y) != .Ok {
			query.release(h, keys)
			return query.NULL, .Failed, false
		}
	}
}

// Raises `x` as a jq error value.
@(private)
raise :: proc(h: ^query.Heap, x: query.Value) -> query.Status {
	return query.fail(h, .Raised, .None, x)
}

// Raises `x`, which it takes.
@(private)
raise_taken :: proc(h: ^query.Heap, x: query.Value) -> query.Status {
	s := raise(h, x)
	query.release(h, x)
	return s
}

// `-x`.
@(private)
negate :: proc(h: ^query.Heap, x: query.Value) -> (res: query.Value, status: query.Status) {
	if query.type_of(x) != .Number {
		return query.NULL, query.fail(h, .Types, .Negate, x)
	}
	return query.num_neg(h, x)
}

// Puts key `k` and value `v`, both taken, into object `o`: jq refuses a key that is no string.
@(private)
put_entry :: proc(h: ^query.Heap, o: ^query.Value, k, v: query.Value) -> query.Status {
	if query.type_of(k) != .String {
		s := query.fail(h, .Types, .Index, o^, k, "object key")
		query.release(h, k)
		query.release(h, v)
		return s
	}
	return query.object_put(h, o, k, v)
}

// `a op b`, `a` taken, and changed in place for `+` when nothing else holds it.
@(private)
binary_owned :: proc(h: ^query.Heap, op: Op, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	if op == .Add && query.unique(a) {
		#partial switch a.kind {
		case .String:
			if query.is_text(b) {
				acc := a
				s := query.text_append(h, &acc, query.text_of(b))
				if s != .Ok {
					query.release(h, acc)
					return query.NULL, s
				}
				return acc, .Ok
			}
		case .Array:
			if query.type_of(b) == .Array {
				return append_all(h, a, b)
			}
		case .Object:
			if query.type_of(b) == .Object {
				acc := a
				s := query.object_merge_into(h, &acc, b)
				if s != .Ok {
					query.release(h, acc)
					return query.NULL, s
				}
				return acc, .Ok
			}
		}
	}
	defer query.release(h, a)
	return binary_value(h, op, a, b)
}

// Array `a`, taken and held once, with the elements of array `b` after its own.
@(private)
append_all :: proc(h: ^query.Heap, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	acc := a
	s := query.own_array(h, &acc, query.length_of(h, b))
	if s == .Ok && b.kind == .Array {
		for x in query.items_of(b) {
			if s = query.append_owned(h, &acc, query.retain(x)); s != .Ok {
				break
			}
		}
		if s != .Ok {
			query.release(h, acc)
			return query.NULL, s
		}
		return acc, .Ok
	}
	c: query.Cursor
	if s == .Ok {
		c, s = query.cursor_open(h, b)
	}
	for s == .Ok {
		_, x, more, cs := query.cursor_next(h, &c)
		if cs != .Ok || !more {
			s = cs
			break
		}
		s = query.append_owned(h, &acc, x)
	}
	query.cursor_close(&c)
	if s != .Ok {
		query.release(h, acc)
		return query.NULL, s
	}
	return acc, .Ok
}
