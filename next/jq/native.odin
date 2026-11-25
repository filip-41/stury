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
		l, leaf_l := leaf_value(m, n.a, input, env)
		if leaf_l {
			query.release(h, input)
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
		if lg != .Value {
			query.release(h, input)
			return l, lg
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
		if lg == .Failed || lg == .Value && truthy(l) {
			query.release(h, input)
			return l, lg
		}
		query.release(h, l)
		return native(m, n.b, input, env)
	case .If:
		c, cg := native(m, n.a, query.retain(input), env)
		if cg != .Value {
			query.release(h, input)
			return c, cg
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
		v, vg := native(m, n.a, query.retain(input), env)
		query.release(h, input)
		if vg != .Failed {
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
		for i := 0; i < len(n.args); i += 2 {
			k, kg := native(m, n.args[i], query.retain(input), env)
			if kg != .Value {
				query.release(h, o)
				return k, kg
			}
			v, vg := native(m, n.args[i + 1], query.retain(input), env)
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
		if s == .Ok {
			s = destructure(m, n.patterns[0], x, e, input)
		}
		query.release(h, x)
		if s != .Ok {
			env_release(m, e)
			query.release(h, input)
			return query.NULL, .Failed
		}
		defer env_release(m, e)
		return native(m, n.b, input, e)
	case .Call:
		return native_call(m, n, input, env)
	case .Iterate, .Comma, .Reduce, .Foreach, .Def, .Label, .Break, .Update:
	}
	unreachable()
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
			y, yg := query.retain(x), Got.Value
			if f != nil {
				y, yg = native(m, f, y, env)
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
			y, yg = native(m, f, x, env)
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
	defer query.release(h, input)
	v, s := b.fn(m, b, input, args[:len(n.args)])
	return v, got_of(s)
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
				return acc, s
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
