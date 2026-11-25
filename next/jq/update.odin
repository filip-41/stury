package jq

import "stury:lib/query"

// Path expressions and the assignments over them: `path(f)`, and `a = b`, `a |= f`, `a op= b`, `a //= b`, which take the
// paths `a` makes on the input and set each in turn.

// An output of `path(f)`'s filter: its path, which must be one.
@(private)
emit_path :: proc(m: ^Machine, r: ^Regs, f: ^Frame) {
	h := m.h
	p := r.vpath
	query.release(h, r.v)
	r.v, r.vpath = query.ABSENT, query.ABSENT
	if !is_path(p) {
		s := raise_taken(h, path_error(m, "Invalid path expression with result ", p))
		query.release(h, p)
		r.sig, r.mode = fail_status(s), .Ret
		return
	}
	if p.kind == .Node && query.type_of(p) == .Array {
		b, s := query.built(h, p)
		query.release(h, p)
		if s != .Ok {
			r.sig, r.mode = .Fail, .Ret
			return
		}
		p = b
	} else if p.kind != .Array {
		p = m.empty
	}
	give_value(m, r, f, p)
}

// jq's message for a path expression's output that is no path, `p` its marked value, as a text value: `prefix`, the
// value cut to `size` as jq cuts it, and `suffix`.
@(private)
path_error :: proc(m: ^Machine, prefix: string, p: query.Value, size := 30, suffix := "") -> query.Value {
	v := p
	v.mark = 0
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	append(&out, prefix)
	write_brief(m.h, &out, v, size)
	append(&out, suffix)
	t, _ := query.text_value(m.h, string(out[:]))
	return t
}

// jq's message for a step by `key` on `result`, what a path expression made that is no path.
@(private)
step_path_error :: proc(m: ^Machine, result, key: query.Value) -> query.Value {
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	append(&out, "Invalid path expression near attempt to access element ")
	write_brief(m.h, &out, key)
	append(&out, " of ")
	return path_error(m, string(out[:]), result, 30)
}

@(private)
eval_parts :: proc(m: ^Machine, r: ^Regs) {
	start_parts(m, r, 0xFF, r.n.kind == .Object)
}

// `@name` on each output of a filter that generates.
@(private)
eval_format :: proc(m: ^Machine, r: ^Regs) {
	n := r.n
	if n.a == nil {
		v, s := format_value(m, n.name, r.input)
		if s != .Ok {
			finish(m, r, .Fail)
			return
		}
		value_out(m, r, v)
		return
	}
	f := push_or_fail(m, r, Input_Frame, .Format)
	if f == nil {
		return
	}
	f.n = n
	r.n, r.k = n.a, f
}

@(private)
emit_format :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	query.release(m.h, r.vpath)
	r.vpath = query.ABSENT
	v, s := format_value(m, f.n.name, r.v)
	query.release(m.h, r.v)
	r.v = query.ABSENT
	if s != .Ok {
		r.sig, r.mode = .Fail, .Ret
		return
	}
	give_value(m, r, f, v)
}

// An assignment's state: the paths its left side makes on the input, then the input changed at each in turn.
@(private)
Update_Frame :: struct {
	using frame: Frame,
	n:           ^Node,
	env:         ^Env,
	x:           query.Value, // the right side's value, but for `|=`
	state:       query.Value,
	paths:       query.Value, // an array
	dels:        query.Value, // the paths `|=`'s filter gave nothing for, deleted at the end
	out:         query.Value, // `|=`'s filter's first output
	i:           int,
	applying:    bool,
	got:         bool,
}

@(private)
eval_update :: proc(m: ^Machine, r: ^Regs) {
	n := r.n
	if n.op == .Modify {
		start_update(m, r, query.ABSENT)
		return
	}
	if .Native in n.b.flags {
		x, found, s := eval_native(m, n.b, query.retain(r.input), r.env)
		if s != .Ok || !found {
			finish(m, r, fail_status(s))
			return
		}
		start_update(m, r, x)
		return
	}
	f := push_or_fail(m, r, Input_Frame, .Update)
	if f == nil {
		return
	}
	f.n, f.env, f.input, f.path = n, env_retain(r.env), query.retain(r.input), r.path
	r.path = query.ABSENT
	r.n, r.k, r.track = n.b, f, false
}

// An assignment of `r.n` on the registers' input with right side value `x`, taken: its paths first.
@(private)
start_update :: proc(m: ^Machine, r: ^Regs, x: query.Value) {
	h := m.h
	n := r.n
	f, s := push(m, Update_Frame, .Update_Each, r.k)
	if s != .Ok {
		query.release(h, x)
		finish(m, r, .Fail)
		return
	}
	paths, ps := query.make_array(h, 4)
	if ps != .Ok {
		query.release(h, x)
		pop_frame(m)
		finish(m, r, .Fail)
		return
	}
	f.track, f.n, f.env, f.x, f.state, f.paths, f.dels = r.track, n, env_retain(r.env), x, query.retain(r.input), paths, m.empty
	query.release(h, r.path)
	r.path = query.ABSENT
	r.n, r.k, r.track = n.a, f, true
}

// An output of an assignment's right side: an assignment with it.
@(private)
emit_update :: proc(m: ^Machine, r: ^Regs, f: ^Input_Frame) {
	query.release(m.h, r.vpath)
	x := r.v
	r.v, r.vpath = query.ABSENT, query.ABSENT
	r.n, r.input, r.path, r.env, r.k, r.track, r.mode = f.n, query.retain(f.input), query.retain(f.path), env_retain(f.env), f.k, f.track, .Eval
	start_update(m, r, x)
}

// An output to an assignment's frame: a path of its left side, or the first output of `|=`'s filter.
@(private)
emit_update_each :: proc(m: ^Machine, r: ^Regs, f: ^Update_Frame) {
	h := m.h
	if f.applying {
		query.release(h, r.vpath)
		f.out, f.got = r.v, true
		r.v, r.vpath = query.ABSENT, query.ABSENT
		m.brk = f
		r.sig, r.mode = .Break, .Ret
		return
	}
	p := r.vpath
	query.release(h, r.v)
	r.v, r.vpath = query.ABSENT, query.ABSENT
	s := query.Status.Ok
	if !is_path(p) {
		s = raise_taken(h, path_error(m, "Invalid path expression with result ", p))
		query.release(h, p)
	} else if p.kind == .Node && query.type_of(p) == .Array {
		b: query.Value
		b, s = query.built(h, p)
		query.release(h, p)
		if s == .Ok {
			s = query.append_owned(h, &f.paths, b)
		}
	} else {
		s = query.append_owned(h, &f.paths, p if p.kind == .Array else m.empty)
	}
	r.sig, r.mode = fail_status(s), .Ret
}

@(private)
resume_update_each :: proc(m: ^Machine, r: ^Regs, f: ^Update_Frame) {
	h := m.h
	sig := r.sig
	if sig == .Break && m.brk == f {
		sig = .Go
	}
	if sig != .Go {
		drop_update(m, f)
		pop_frame(m)
		r.sig = sig
		return
	}
	if f.applying {
		p := query.items_of(f.paths)[f.i]
		s := query.Status.Ok
		if f.got {
			f.state, s = query.set_path(h, f.state, p, f.out)
			f.out, f.got = query.ABSENT, false
		} else {
			s = query.append_owned(h, &f.dels, query.retain(p))
		}
		if s != .Ok {
			drop_update(m, f)
			pop_frame(m)
			r.sig = .Fail
			return
		}
		f.i += 1
	}
	f.applying = true
	update_next(m, r, f)
}

// Sets the paths of `f` from its `i`th, running `|=`'s filter in the machine when it is not native.
@(private)
update_next :: proc(m: ^Machine, r: ^Regs, f: ^Update_Frame) {
	h := m.h
	n := f.n
	paths := query.items_of(f.paths)
	for ; f.i < len(paths); f.i += 1 {
		p := paths[f.i]
		s := query.Status.Ok
		#partial switch n.op {
		case .Assign:
			f.state, s = query.set_path(h, f.state, p, query.retain(f.x))
		case .Modify:
			cur: query.Value
			cur, s = query.get_path(h, f.state, p)
			if s != .Ok {
				break
			}
			if f.i + 1 == len(paths) {
				if s = take_container(h, f, p, cur); s != .Ok {
					break
				}
			}
			if .Native not_in n.b.flags {
				f.got = false
				r.n, r.input, r.path, r.env, r.k, r.track, r.mode = n.b, cur, query.ABSENT, env_retain(f.env), f, false, .Eval
				return
			}
			v, found, vs := eval_native(m, n.b, cur, f.env)
			s = vs
			if s == .Ok && found {
				f.state, s = query.set_path(h, f.state, p, v)
			} else if s == .Ok {
				s = query.append_owned(h, &f.dels, query.retain(p))
			}
		case:
			cur: query.Value
			cur, s = query.get_path(h, f.state, p)
			if s != .Ok {
				break
			}
			if n.op == .Add && f.i + 1 == len(paths) {
				if s = take_container(h, f, p, cur); s != .Ok {
					break
				}
			}
			v: query.Value
			if n.op == .Alt {
				v = cur if truthy(cur) else query.retain(f.x)
				if !truthy(cur) {
					query.release(h, cur)
				}
			} else {
				v, s = binary_owned(h, n.op, cur, f.x)
			}
			if s == .Ok {
				f.state, s = query.set_path(h, f.state, p, v)
			}
		}
		if s != .Ok {
			drop_update(m, f)
			pop_frame(m)
			r.sig, r.mode = .Fail, .Ret
			return
		}
	}
	v := f.state
	s := query.Status.Ok
	if len(query.items_of(f.dels)) > 0 {
		v, s = query.del_paths(h, v, f.dels)
	}
	f.state = query.ABSENT
	k, track := f.k, f.track
	drop_update(m, f)
	pop_frame(m)
	if s != .Ok {
		r.sig, r.mode = .Fail, .Ret
		return
	}
	r.v, r.vpath, r.k, r.mode = v, query.ABSENT, k, .Emit
	if track {
		r.vpath = not_path_marker(m, v)
	}
}

// Lets the state's slot at path `p` go of `cur`, the value read there, so the operation on `cur` runs in place. On
// failure `cur` is released. A path with a slice is left alone: a slice takes only an array.
@(private)
take_container :: proc(h: ^query.Heap, f: ^Update_Frame, p, cur: query.Value) -> query.Status {
	if cur.kind != .Array && cur.kind != .Object && cur.kind != .String {
		return .Ok
	}
	for step in query.items_of(p) {
		if query.type_of(step) == .Object {
			return .Ok
		}
	}
	s: query.Status
	f.state, s = query.set_path(h, f.state, p, query.NULL)
	if s != .Ok {
		query.release(h, cur)
	}
	return s
}

@(private)
drop_update :: proc(m: ^Machine, f: ^Update_Frame) {
	h := m.h
	env_release(m, f.env)
	query.release(h, f.x)
	query.release(h, f.state)
	query.release(h, f.paths)
	query.release(h, f.dels)
	query.release(h, f.out)
}
