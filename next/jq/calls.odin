package jq

import "core:math"
import "stury:lib/query"

// Calls: of a jq function, a filter argument, and a builtin, whose value arguments run first, each combination of
// their outputs one call.

// The values of a call's value arguments, a string's parts or an object's keys and values, gathered one level per
// part: each output of a part that generates runs the parts after it, so the first part varies slowest.
@(private)
Args_Frame :: struct {
	using frame: Frame,
	n:           ^Node,
	env:         ^Env,
	input:       query.Value,
	path:        query.Value,
	vals:        query.Value, // an array of one value per part, by part
	first_slow:  bool, // parts in their order, else the last varies slowest
	mask:        u8, // a builtin's value arguments: the rest are filters
}

@(private)
eval_call :: proc(m: ^Machine, r: ^Regs) {
	n := r.n
	#partial switch n.ref.kind {
	case .Param:
		c := env_slots(env_up(r.env, n.ref.hops))[n.ref.slot].closure
		if .Native in c.node.flags && !r.track {
			out, found, s := eval_native(m, c.node, r.input, c.env)
			r.input = query.ABSENT
			if s != .Ok || !found {
				finish(m, r, fail_status(s))
				return
			}
			give(m, r, out)
			return
		}
		e := env_retain(c.env)
		env_release(m, r.env)
		r.n, r.env = c.node, e
		return
	case .Def:
		fn := n.callee
		base := env_up(r.env, n.ref.hops)
		if len(fn.params) == 0 {
			e := env_retain(base)
			env_release(m, r.env)
			r.n, r.env = fn.body, e
			return
		}
		e, s := new_env(m, base, int(fn.slots), true)
		if s != .Ok {
			finish(m, r, .Fail)
			return
		}
		slots := env_slots(e)
		for a, i in n.args {
			if a.kind == .Call && a.ref.kind == .Param {
				// A parameter passed on is its closure, so a recursion through parameters holds no chain of scopes.
				src := env_slots(env_up(r.env, a.ref.hops))[a.ref.slot].closure
				slots[i].closure = {src.node, env_retain(src.env)}
			} else {
				slots[i].closure = {a, env_retain(r.env)}
			}
		}
		env_release(m, r.env)
		r.n, r.env = fn.body, e
		return
	}
	b := n.builtin
	mask := value_args(b, len(n.args))
	if mask == 0 {
		start_builtin(m, r, n, nil)
		return
	}
	vals: [MAX_ARGS]query.Value
	all_native := true
	for a, i in n.args {
		if mask & (1 << uint(i)) != 0 && .Native not_in a.flags {
			all_native = false
		}
	}
	if all_native {
		// The same order as `start_parts`: an argument that fails or generates nothing ends the call before the ones
		// that come before it run.
		for k in 0 ..< len(n.args) {
			i := k if b.op != .None else len(n.args) - 1 - k
			a := n.args[i]
			if mask & (1 << uint(i)) == 0 {
				continue
			}
			v, found, s := eval_native(m, a, query.retain(r.input), r.env)
			if s != .Ok || !found {
				for x in vals {
					query.release(m.h, x)
				}
				finish(m, r, fail_status(s))
				return
			}
			vals[i] = v
		}
		start_builtin(m, r, n, vals[:len(n.args)])
		for x in vals {
			query.release(m.h, x)
		}
		return
	}
	start_parts(m, r, mask, b.op != .None)
}

// Which arguments of builtin `b` are values: each of a value builtin's, and those of a filter builtin jq declares
// `$name`.
@(private)
value_args :: proc(b: ^Builtin, arity: int) -> u8 {
	#partial switch b.op {
	case .None:
		return u8(1 << uint(arity)) - 1
	case .Error, .Getpath, .Halt_Error, .Limit, .Skip, .Css:
		return 1 if arity > 0 else 0
	case .Range:
		return u8(1 << uint(arity)) - 1
	}
	return 0
}

// Gathers the parts of `r.n`, a call, a string or an object, in an `Args` frame.
@(private)
start_parts :: proc(m: ^Machine, r: ^Regs, mask: u8, first_slow: bool) {
	h := m.h
	n := r.n
	f := push_or_fail(m, r, Args_Frame, .Args)
	if f == nil {
		return
	}
	vals, s := query.make_array(h, len(n.args))
	for _ in n.args {
		if s == .Ok {
			s = query.append_owned(h, &vals, query.NULL)
		}
	}
	if s != .Ok {
		query.release(h, vals)
		pop_frame(m)
		finish(m, r, .Fail)
		return
	}
	f.n, f.env, f.input, f.path, f.vals, f.first_slow, f.mask = n, r.env, r.input, r.path, vals, first_slow, mask
	r.env, r.input, r.path = nil, query.ABSENT, query.ABSENT
	r.sig, r.mode = .Go, .Ret
	advance_parts(m, r, f, 0)
}

// The part level `level` of `f` stands for.
@(private)
part_at :: #force_inline proc(f: ^Args_Frame, level: int) -> int {
	return level if f.first_slow else len(f.n.args) - 1 - level
}

// Runs the parts of `f` from `level` on: those that need no frame at once, and the next one that does into an `Arg`
// frame. With every part valued, gives the call's, string's or object's value.
@(private)
advance_parts :: proc(m: ^Machine, r: ^Regs, f: ^Args_Frame, from: int) {
	h := m.h
	n := f.n
	for level := from; level < len(n.args); level += 1 {
		i := part_at(f, level)
		if n.kind == .Call && f.mask & (1 << uint(i)) == 0 {
			continue
		}
		part := n.args[i]
		if part == nil {
			continue
		}
		if part.kind == .Literal || .Native in part.flags {
			v, found, s := eval_native(m, part, query.retain(f.input), f.env)
			if s != .Ok || !found {
				r.sig, r.mode = fail_status(s), .Ret
				return
			}
			if s = query.array_put(h, &f.vals, i, v); s != .Ok {
				r.sig, r.mode = .Fail, .Ret
				return
			}
			continue
		}
		g, s := push(m, Input_Frame, .Arg, nil)
		if s != .Ok {
			r.sig, r.mode = .Fail, .Ret
			return
		}
		g.owner, g.i = f, level
		node := part
		if n.kind == .String && part.kind == .Format {
			node = part.a
		}
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = node, query.retain(f.input), query.ABSENT, env_retain(f.env), g, false, .Eval
		return
	}
	parts_done(m, r, f)
}

// An output of a part that generates: its value, then the parts after it.
@(private)
emit_arg :: proc(m: ^Machine, r: ^Regs, g: ^Input_Frame) {
	h := m.h
	f := (^Args_Frame)(g.owner)
	query.release(h, r.vpath)
	r.vpath = query.ABSENT
	v := r.v
	r.v = query.ABSENT
	i := part_at(f, g.i)
	part := f.n.args[i]
	if f.n.kind == .String && part.kind == .Format {
		t, s := format_value(m, part.name, v)
		query.release(h, v)
		if s != .Ok {
			r.sig, r.mode = .Fail, .Ret
			return
		}
		v = t
	}
	if s := query.array_put(h, &f.vals, i, v); s != .Ok {
		r.sig, r.mode = .Fail, .Ret
		return
	}
	advance_parts(m, r, f, g.i + 1)
}

// Every part of `f` has a value: the string, the object, or the call with them.
@(private)
parts_done :: proc(m: ^Machine, r: ^Regs, f: ^Args_Frame) {
	h := m.h
	n := f.n
	vals := query.items_of(f.vals)
	v: query.Value
	s := query.Status.Ok
	#partial switch n.kind {
	case .String:
		v = query.text_borrowed("")
		for x in vals {
			if s = query.text_append(h, &v, query.text_of(x)); s != .Ok {
				break
			}
		}
	case .Object:
		v, s = query.make_object(h, len(vals) / 2)
		for i := 0; s == .Ok && i < len(vals); i += 2 {
			val: query.Value
			if n.args[i + 1] == nil {
				val, s = query.get(h, f.input, vals[i])
			} else {
				val = query.retain(vals[i + 1])
			}
			if s == .Ok {
				s = put_entry(h, &v, query.retain(vals[i]), val)
			}
		}
	case .Call:
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = n, query.retain(f.input), query.retain(f.path), env_retain(f.env), f.k, f.track, .Eval
		start_builtin(m, r, n, vals)
		return
	}
	if s != .Ok {
		query.release(h, v)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	give_value(m, r, f, v)
}

@(private)
drop_args :: proc(m: ^Machine, f: ^Args_Frame) {
	env_release(m, f.env)
	query.release(m.h, f.input)
	query.release(m.h, f.path)
	query.release(m.h, f.vals)
}

// Runs builtin call `n` on the registers' input, with its value arguments `vals` (by argument, the filters' slots
// unused), its filter arguments in the registers' scope.
@(private)
start_builtin :: proc(m: ^Machine, r: ^Regs, n: ^Node, vals: []query.Value) {
	h := m.h
	b := n.builtin
	switch b.op {
	case .None:
		inp := r.input
		if b.takes_input {
			r.input = query.ABSENT
		}
		v, s := b.fn(m, b, inp, vals)
		if s != .Ok {
			finish(m, r, .Fail)
			return
		}
		value_out(m, r, v)
	case .Empty:
		finish(m, r, .Go)
	case .Select:
		f := push_or_fail(m, r, Input_Frame, .Select)
		if f == nil {
			return
		}
		f.input, f.path = r.input, r.path
		r.input, r.path = query.retain(f.input), query.ABSENT
		r.n, r.k, r.track = n.args[0], f, false
	case .Kind_Filter:
		if query.type_of(r.input) in b.types {
			give(m, r, query.retain(r.input))
		} else {
			finish(m, r, .Go)
		}
	case .Error:
		x := vals[0] if len(vals) > 0 else r.input
		raise(h, x)
		finish(m, r, .Fail)
	case .Path:
		f := push_or_fail(m, r, Input_Frame, .Path)
		if f == nil {
			return
		}
		query.release(h, r.path)
		r.path = query.ABSENT
		r.n, r.k, r.track = n.args[0], f, true
	case .Getpath:
		v, s := query.get_path(h, r.input, vals[0])
		if s == .Ok && r.track {
			if !is_path(r.path) {
				s = raise_taken(h, path_error(m, "Invalid path expression with result ", r.path))
			} else {
				p: query.Value
				if r.path.kind == .Array {
					p, s = query.array_concat(h, r.path, vals[0])
				} else {
					p, s = query.built(h, vals[0])
				}
				query.release(h, r.path)
				r.path = p
			}
		}
		if s != .Ok {
			query.release(h, v)
			finish(m, r, .Fail)
			return
		}
		give(m, r, v)
	case .Limit, .Skip, .First:
		count := 1.0
		if b.op != .First {
			// In jq's order a count below the numbers (null, a boolean, NaN) is negative, one above them is no count.
			t := query.type_of(vals[0])
			if t == .String || t == .Array || t == .Object {
				raise_text(m, "Invalid limit: not a number")
				finish(m, r, .Fail)
				return
			}
			count = query.as_f64(vals[0]) if t == .Number else -1
			if !(count >= 0) {
				raise_text(m, "limit doesn't support negative count" if b.op == .Limit else "skip doesn't support negative count")
				finish(m, r, .Fail)
				return
			}
		}
		if count <= 0 && b.op == .Limit {
			finish(m, r, .Go)
			return
		}
		body := n.args[len(n.args) - 1]
		// A limit takes one value more for a fractional count, and a skip drops only the whole values of it.
		whole := math.floor(count) if b.op == .Skip else math.ceil(count)
		if whole <= 0 {
			r.n = body
			return
		}
		f := push_or_fail(m, r, Count_Frame, .Skip if b.op == .Skip else .Limit)
		if f == nil {
			return
		}
		f.left = i64(min(whole, 1e18))
		r.n, r.k = body, f
	case .Last:
		f := push_or_fail(m, r, Input_Frame, .Last)
		if f == nil {
			return
		}
		r.n, r.k = n.args[0], f
	case .Isempty:
		f := push_or_fail(m, r, Input_Frame, .Isempty)
		if f == nil {
			return
		}
		query.release(h, r.path)
		r.path = query.ABSENT
		r.n, r.k, r.track = n.args[0], f, false
	case .Range:
		start_range(m, r, vals)
	case .Input:
		v, ok, s := next_input(m)
		if s == .Ok && !ok {
			s = raise_text(m, "No more inputs")
		}
		if s != .Ok {
			finish(m, r, .Fail)
			return
		}
		value_out(m, r, v)
	case .Inputs:
		f := push_or_fail(m, r, Frame, .Gen)
		if f == nil {
			return
		}
		finish(m, r, .Go)
		resume_gen(m, r, f)
	case .Debug, .Stderr:
		if m.hooks != nil {
			hook := m.hooks.debug if b.op == .Debug else m.hooks.stderr
			if hook != nil {
				hook(m.hooks.data, r.input, h)
			}
		}
		give(m, r, query.retain(r.input))
	case .Halt:
		query.release(h, m.halt.value)
		m.halt = {halted = true}
		finish(m, r, .Halt)
	case .Halt_Error:
		if query.type_of(vals[0]) != .Number {
			raise_text(m, "halt_error/1: number required")
			finish(m, r, .Fail)
			return
		}
		query.release(h, m.halt.value)
		m.halt = {halted = true, code = int(query.trunc_i64(vals[0])), value = query.retain(r.input)}
		finish(m, r, .Halt)
	case .Css:
		start_css(m, r, vals[0])
	}
}

@(private)
start_range :: proc(m: ^Machine, r: ^Regs, vals: []query.Value) {
	from, to, by := query.int_value(0), query.int_value(0), query.int_value(1)
	switch len(vals) {
	case 1:
		to = vals[0]
	case 2:
		from, to = vals[0], vals[1]
	case 3:
		from, to, by = vals[0], vals[1], vals[2]
	}
	if len(vals) < 3 {
		if query.type_of(from) != .Number || query.type_of(to) != .Number {
			raise_text(m, "Range bounds must be numeric")
			finish(m, r, .Fail)
			return
		}
		if from.kind != .Int || to.kind != .Int {
			by = query.ABSENT
		}
	}
	track := r.track
	k := r.k
	finish(m, r, .Go)
	go, gs := range_goes_on(m, from, to, by)
	if gs != .Ok {
		r.sig = .Fail
		return
	}
	if !go {
		return
	}
	f, s := push(m, Range_Frame, .Range, k)
	if s != .Ok {
		r.sig = .Fail
		return
	}
	f.track, f.at, f.to, f.by = track, query.retain(from), query.retain(to), query.retain(by)
	resume_range(m, r, f)
}

// The next input the hooks give, `ok` false at the end. With no hook it raises jq's library error, "break".
@(private)
next_input :: proc(m: ^Machine) -> (v: query.Value, ok: bool, status: query.Status) {
	if m.hooks == nil || m.hooks.input == nil {
		return query.NULL, false, raise_text(m, "break")
	}
	return m.hooks.input(m.hooks.data, m.h)
}

@(private)
resume_gen :: proc(m: ^Machine, r: ^Regs, f: ^Frame) {
	if r.sig != .Go || m.hooks == nil || m.hooks.input == nil {
		pop_frame(m)
		return
	}
	v, ok, s := next_input(m)
	if s != .Ok || !ok {
		pop_frame(m)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	give_value(m, r, f, v)
}

// Raises the message `text`, borrowed from the program's rodata, as jq raises an error of its own.
@(private)
raise_text :: proc(m: ^Machine, text: string) -> query.Status {
	return query.fail(m.h, .Raised, .None, query.text_borrowed(text))
}
