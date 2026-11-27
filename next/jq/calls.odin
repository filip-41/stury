package jq

import "core:math"
import "stury:lib/query"

// Calls: of a jq function, a filter argument, and a builtin, whose value arguments run first, each combination of
// their outputs one call.

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
		if fn.prelude && !r.track && (len(n.args) == 2 || len(n.args) == 3) && (fn.name == "gsub" || fn.name == "sub") {
			if eval_sub_fast(m, r, fn, n) {
				return
			}
		}
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
	if b.fn == v_by && len(n.args) == 1 && !r.track && query.type_of(r.input) == .Array {
		if key_expr, key_env, ok := unwrap_by_key_env(n.args[0], r.env); ok {
			keys, kg, fell_back := eval_by_keys(m, r.input, key_expr, key_env)
			if !fell_back {
				if kg != .Value {
					finish(m, r, fail_status(.Error if kg == .Failed else .Ok))
					return
				}
				inp := r.input
				if b.takes_input {
					r.input = query.ABSENT
				}
				v, s := b.fn(m, b, inp, {keys})
				query.release(m.h, keys)
				if s != .Ok {
					finish(m, r, .Fail)
					return
				}
				value_out(m, r, v)
				return
			}
		}
	}
	mask := value_args(b, len(n.args))
	if mask == 0 {
		start_builtin(m, r, n, nil)
		return
	}
	all_native := true
	for a, i in n.args {
		if mask & (1 << uint(i)) != 0 && .Native not_in a.flags {
			all_native = false
			break
		}
	}
	if all_native {
		vals: [MAX_ARGS]query.Value
		defer for x in vals {
			query.release(m.h, x)
		}
		for k in 0 ..< len(n.args) {
			i := k if b.op != .None else len(n.args) - 1 - k
			if mask & (1 << uint(i)) == 0 {
				continue
			}
			v, found, s := eval_native(m, n.args[i], query.retain(r.input), r.env)
			if s != .Ok || !found {
				finish(m, r, fail_status(s))
				return
			}
			vals[i] = v
		}
		start_builtin(m, r, n, vals[:len(n.args)])
		return
	}
	start_parts(m, r, mask, b.op != .None)
}

@(private)
value_args :: proc(b: ^Builtin, arity: int) -> u8 {
	#partial switch b.op {
	case .None, .Range:
		return u8(1 << uint(arity)) - 1
	case .Error, .Getpath, .Halt_Error, .Limit, .Skip, .Css:
		return 1 if arity > 0 else 0
	}
	return 0
}

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

@(private)
part_at :: #force_inline proc(f: ^Args_Frame, level: int) -> int {
	return level if f.first_slow else len(f.n.args) - 1 - level
}

@(private)
advance_parts :: proc(m: ^Machine, r: ^Regs, f: ^Args_Frame, from: int) {
	h := m.h
	n := f.n
	for level := from; level < len(n.args); level += 1 {
		i := part_at(f, level)
		if (n.kind == .Call && f.mask & (1 << uint(i)) == 0) || n.args[i] == nil {
			continue
		}
		part := n.args[i]
		if part.kind == .Literal || .Native in part.flags {
			v, found, s := eval_native(m, part, query.retain(f.input), f.env)
			if s != .Ok || !found {
				r.sig, r.mode = fail_status(s), .Ret
				return
			}
			if query.array_put(h, &f.vals, i, v) != .Ok {
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
		node := part.a if n.kind == .String && part.kind == .Format else part
		r.n, r.input, r.path, r.env, r.k, r.track, r.mode = node, query.retain(f.input), query.ABSENT, env_retain(f.env), g, false, .Eval
		return
	}
	parts_done(m, r, f)
}

@(private)
emit_arg :: proc(m: ^Machine, r: ^Regs, g: ^Input_Frame) {
	h := m.h
	f := (^Args_Frame)(g.owner)
	query.release(h, r.vpath)
	v := r.v
	r.v, r.vpath = query.ABSENT, query.ABSENT
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
	if query.array_put(h, &f.vals, i, v) != .Ok {
		r.sig, r.mode = .Fail, .Ret
		return
	}
	advance_parts(m, r, f, g.i + 1)
}

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
			val := query.retain(vals[i + 1])
			if n.args[i + 1] == nil {
				val, s = query.get(h, f.input, vals[i])
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
		if f := push_or_fail(m, r, Input_Frame, .Select); f != nil {
			f.input, f.path = r.input, r.path
			r.input, r.path, r.n, r.k, r.track = query.retain(f.input), query.ABSENT, n.args[0], f, false
		}
	case .Kind_Filter:
		if query.type_of(r.input) in b.types {
			give(m, r, query.retain(r.input))
		} else {
			finish(m, r, .Go)
		}
	case .Error:
		raise(h, vals[0] if len(vals) > 0 else r.input)
		finish(m, r, .Fail)
	case .Path, .Isempty:
		if f := push_or_fail(m, r, Input_Frame, .Path if b.op == .Path else .Isempty); f != nil {
			query.release(h, r.path)
			r.path, r.n, r.k, r.track = query.ABSENT, n.args[0], f, b.op == .Path
		}
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
			t := query.type_of(vals[0])
			if t == .String || t == .Bytes || t == .Array || t == .Object {
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
		whole := math.floor(count) if b.op == .Skip else math.ceil(count)
		if whole <= 0 {
			r.n = body
			return
		}
		if f := push_or_fail(m, r, Count_Frame, .Skip if b.op == .Skip else .Limit); f != nil {
			f.left = i64(min(whole, 1e18))
			r.n, r.k = body, f
		}
	case .Last:
		if f := push_or_fail(m, r, Input_Frame, .Last); f != nil {
			r.n, r.k = n.args[0], f
		}
	case .Range:
		start_range(m, r, vals)
	case .Input, .Inputs:
		if h.tainted {
			finish(m, r, .Taint)
			return
		}
		if b.op == .Inputs {
			if f := push_or_fail(m, r, Frame, .Gen); f != nil {
				finish(m, r, .Go)
				resume_gen(m, r, f)
			}
			return
		}
		v, ok, s := next_input(m)
		if s == .Ok && !ok {
			s = raise_text(m, "No more inputs")
		}
		if s != .Ok {
			finish(m, r, .Fail)
			return
		}
		value_out(m, r, v)
	case .Debug, .Stderr:
		if h.tainted || query.value_has_partial(r.input) {
			h.tainted = true
			finish(m, r, .Taint)
			return
		}
		if m.hooks != nil {
			if hook := m.hooks.debug if b.op == .Debug else m.hooks.stderr; hook != nil {
				hook(m.hooks.data, r.input, h)
			}
		}
		give(m, r, query.retain(r.input))
	case .Halt, .Halt_Error:
		if h.tainted || (b.op == .Halt_Error && query.value_has_partial(r.input)) {
			h.tainted = true
			finish(m, r, .Taint)
			return
		}
		if b.op == .Halt_Error && query.type_of(vals[0]) != .Number {
			raise_text(m, "halt_error/1: number required")
			finish(m, r, .Fail)
			return
		}
		query.release(h, m.halt.value)
		m.halt = {halted = true}
		if b.op == .Halt_Error {
			m.halt.code, m.halt.value = int(query.trunc_i64(vals[0])), query.retain(r.input)
		}
		finish(m, r, .Halt)
	case .Css:
		start_css(m, r, vals[0])
	}
}

@(private)
start_range :: proc(m: ^Machine, r: ^Regs, vals: []query.Value) {
	from, to, by := query.int_value(0), vals[0], query.int_value(1)
	if len(vals) >= 2 {
		from, to = vals[0], vals[1]
	}
	if len(vals) == 3 {
		by = vals[2]
	} else {
		if query.type_of(from) != .Number || query.type_of(to) != .Number {
			raise_text(m, "Range bounds must be numeric")
			finish(m, r, .Fail)
			return
		}
		if from.kind != .Int || to.kind != .Int {
			by = query.ABSENT
		}
	}
	track, k := r.track, r.k
	finish(m, r, .Go)
	go, gs := range_goes_on(m, from, to, by)
	if gs != .Ok || !go {
		r.sig = fail_status(gs)
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

@(private)
next_input :: proc(m: ^Machine) -> (query.Value, bool, query.Status) {
	if m.hooks == nil || m.hooks.input == nil {
		return query.NULL, false, raise_text(m, "break")
	}
	return m.hooks.input(m.hooks.data, m.h)
}

@(private)
resume_gen :: proc(m: ^Machine, r: ^Regs, f: ^Frame) {
	if r.sig != .Go || m.h.tainted || m.hooks == nil || m.hooks.input == nil {
		pop_frame(m)
		if m.h.tainted {
			r.sig = .Taint
		}
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

@(private)
raise_text :: proc(m: ^Machine, text: string) -> query.Status {
	return query.fail(m.h, .Raised, .None, query.text_borrowed(text))
}
