package jq

// Construction: arrays, objects, string interpolation and formats from the outputs of their parts.

import json "../../../json"

@(private)
eval_format :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, track: bool, out: ^Sink) -> Signal {
	if track && n.name == "text" && kind(input.v) == .String {
		return out.emit(out, input) // jq's tostring gives a string back as it is
	}
	s, sig := format(ip, n.name, input.v)
	if sig != .Go {
		return sig
	}
	return emit_made(out, input, s, track)
}

@(private)
eval_array :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	a := new_array(1 if n.a != nil && n.a.single else iterated_length(n.a, input.v))
	// Under a path expression jq collects with the paths tracked, so a step into a value no path leads to fails.
	if n.a != nil && (track || !column_into(n.a, input.v, &a.items)) {
		if sig := collect_into(ip, n.a, input, env, &a.items, track); sig != .Go {
			return sig
		}
	}
	return emit_made(out, input, a, track)
}

// `[f] | length`: how many outputs `f` has, without the array of them.
@(private)
eval_count :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, out: ^Sink) -> Signal {
	Count_Sink :: struct {
		using sink: Sink,
		n:          int,
	}
	s := Count_Sink{sink = {emit = proc(s: ^Sink, it: Item) -> Signal {
				(^Count_Sink)(s).n += 1
				return .Go
			}}}
	if n.a != nil {
		if sig := eval(ip, n.a, input, env, false, &s); sig != .Go {
			return sig
		}
	}
	return emit_value(ip, out, num(f64(s.n)), false)
}

// Whether `n` calls the builtin `length`, not a definition of that name.
@(private)
is_length :: proc(n: ^Node) -> bool {
	b, native := n.native.?
	return n.kind == .Call && native && b.fn == fn_length
}

// The outputs `[.[] | f]` (map's body), `[.[]]` or `[.a.b[].c]` likely has, the iterated value's length, to
// size the array once.
@(private = "file")
iterated_length :: proc(n: ^Node, v: Value) -> int {
	it := n
	if it != nil && it.kind == .Pipe {
		it = it.a
	}
	for it != nil && it.kind == .Field {
		it = it.a // one output for each of its input's
	}
	if it == nil || it.kind != .Iterate {
		return 0
	}
	x, found := fields_of(it.a, v)
	if k := kind(x); !found || k != .Array && k != .Object {
		return 0
	}
	return length_of(x)
}

// `.a.b[].c` of `v` into `into`, read from each element straight, where every element is an object or null: what its
// sinks would collect. It returns false, with `into` as it was, when it is no such path, or some element is neither,
// or `.a.b` reads no array, for the filter to run as usual and fail as jq does.
@(private = "file")
column_into :: proc(n: ^Node, v: Value, into: ^[dynamic]Value) -> bool {
	if n.kind != .Field || n.opt || n.a.kind != .Iterate {
		return false
	}
	x, found := fields_of(n.a.a, v)
	if !found {
		return false
	}
	start := len(into)
	switch c in x {
	case ^Array:
		for e in c.items {
			if !append_field(into, e, n.name) {
				resize(into, start)
				return false
			}
		}
		return true
	case Ref:
		if kd, _ := json.kind(c.doc, c.node); kd != .Array {
			return false
		}
		it := json.children(c.doc, c.node)
		for row in json.children(&it) {
			if !append_field(into, Ref{c.doc, row}, n.name) {
				resize(into, start)
				return false
			}
		}
		return true
	case nil, bool, Number, string, ^Object, Path:
	}
	return false
}

// `e.name` onto `into`, where `e` is an object or null.
@(private = "file")
append_field :: #force_inline proc(into: ^[dynamic]Value, e: Value, name: string) -> bool {
	switch y in e {
	case Ref:
		#partial switch kd, _ := json.kind(y.doc, y.node); kd {
		case .Object:
			r := json.child(y.doc, y.node, name)
			append(into, Value(Ref{y.doc, r}) if r != json.NO_NODE else nil)
			return true
		case .Null:
			append(into, nil)
			return true
		}
	case ^Object:
		f, _ := object_get(y, name)
		append(into, f)
		return true
	case nil:
		append(into, nil)
		return true
	case bool, Number, string, ^Array, Path:
	}
	return false
}

// What `n`, `.` or a chain of fields of it, reads from `v`, where it reads anything.
@(private = "file")
fields_of :: proc(n: ^Node, v: Value) -> (x: Value, found: bool) {
	switch {
	case n.kind == .Identity:
		return v, true
	case n.kind != .Field:
		return
	}
	x = fields_of(n.a, v) or_return
	if kind(x) != .Object {
		return nil, false
	}
	return object_get(x, n.name)
}

eval_object :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if o, sig, direct := object_direct(ip, n, input.v, env); direct {
		if sig != .Go {
			return sig
		}
		return emit_made(out, input, o, track)
	}
	return eval_args(ip, n, nil, input, env, track, out)
}

// The object when every entry has one value and no generator: a constant string key, and `{name}`, a
// constant, `.name` or `$name` for the value. Built in entry order, as `eval_args` would, without its sinks.
// An object's args come in pairs, which the parser makes.
@(private = "file")
object_direct :: proc(ip: ^Interp, n: ^Node, v: Value, env: ^Env) -> (o: ^Object, sig: Signal, direct: bool) #no_bounds_check {
	for i := 0; i < len(n.args); i += 2 {
		key, value := n.args[i], n.args[i + 1]
		if key.kind != .Literal || kind(key.value) != .String {
			return
		}
		if value == nil {
			continue
		}
		#partial switch value.kind {
		case .Literal, .Var:
		case .Field:
			if value.opt || value.a.kind != .Identity {
				return
			}
		case:
			return
		}
	}
	o = new_object()
	o.keys = make([dynamic]string, 0, len(n.args) / 2)
	o.vals = make([dynamic]Value, 0, len(n.args) / 2)
	for i := 0; i < len(n.args); i += 2 {
		k, value := n.args[i].value.(string), n.args[i + 1]
		val: Value
		switch {
		case value == nil:
			val, sig = index_value(ip, v, k)
		case value.kind == .Literal:
			val = value.value
		case value.kind == .Var:
			val, sig = lookup_var(ip, value.name, env)
		case:
			val, sig = index_value(ip, v, value.name)
		}
		if sig != .Go {
			return nil, sig, true
		}
		object_put(o, k, val)
	}
	return o, .Go, true
}

Args_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	b:          ^Builtin, // nil for an interpolation or an object
	n:          ^Node,
	i:          int, // the argument this sink takes the values of
	step:       int, // how many arguments run before it
	vals:       []Value,
	last_outer: bool,
	input:      Item,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
}

// Every combination of the values of `n.args`, each made into an output: the builtin `b` on them, an
// interpolation's string of its parts, or an object of its keys and values.
eval_args :: #force_no_inline proc(ip: ^Interp, n: ^Node, b: ^Builtin, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// jq's C builtins and an interpolation run their last argument outermost. An object its first entry, and range
	// and split/2, which jq defines with `$name` parameters, their first.
	last_outer := n.kind == .String || n.kind == .Call && !(b.gen == gen_range || b.fn == fn_split_regex)
	// The values so far, on this frame when they fit: it outlives every output made of them.
	buf: [8]Value = ---
	vals := buf[:len(n.args)] if len(n.args) <= len(buf) else make([]Value, len(n.args))
	s := Args_Sink{sink = {emit = args_emit}, ip = ip, b = b, n = n, vals = vals, last_outer = last_outer, input = input, env = env, track = track, out = out}
	return args_from(&s, 0)
}

// The arguments from the `step`th one run on, each value of each in turn, then `n`'s output of them. A
// literal is its value (an object's key when a string), an object's missing value (`{"key"}`) the input's
// member, and an interpolation's part `@name` of an expression runs the expression. Inlined into the sink
// of the argument before, as a sink of its own would run the next: a call per argument less.
@(private = "file")
args_from :: #force_inline proc(x: ^Args_Sink, step: int) -> Signal {
	for step := step; step < len(x.vals); step += 1 {
		i := len(x.vals) - 1 - step if x.last_outer else step
		a := x.n.args[i]
		switch {
		case a == nil:
			v, sig := index_value(x.ip, x.input.v, x.vals[i - 1].(string))
			if sig != .Go {
				return sig
			}
			x.vals[i] = v
			continue
		case a.kind == .Literal && (x.n.kind != .Object || i % 2 == 1 || kind(a.value) == .String):
			x.vals[i] = a.value
			continue
		}
		inner := x^
		inner.i, inner.step = i, step
		#partial switch x.n.kind {
		case .String:
			inner.emit, a = part_emit, a.a
		case .Object:
			inner.emit = object_key_emit if i % 2 == 0 else args_emit
		}
		return eval(x.ip, a, x.input, x.env, false, &inner)
	}
	return args_done(x)
}

// `n`'s output of one combination of its arguments' values.
@(private = "file")
args_done :: #force_no_inline proc(x: ^Args_Sink) -> Signal {
	#partial switch x.n.kind {
	case .String:
		size := 0
		for p in x.vals {
			size += len(p.(string))
		}
		s := make([]byte, size)
		at := 0
		for p in x.vals {
			at += copy(s[at:], p.(string))
		}
		return emit_made(x.out, x.input, string(s), x.track)
	case .Object:
		o := new_object()
		o.keys = make([dynamic]string, 0, len(x.vals) / 2)
		o.vals = make([dynamic]Value, 0, len(x.vals) / 2)
		for i := 0; i < len(x.vals); i += 2 {
			object_put(o, x.vals[i].(string), x.vals[i + 1])
		}
		return emit_made(x.out, x.input, o, x.track)
	}
	return apply_builtin(x)
}

@(private = "file")
args_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Args_Sink)(s)
	x.vals[x.i] = it.v
	return args_from(x, x.step + 1)
}

// An interpolation's part: its expression's output, formatted.
@(private = "file")
part_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Args_Sink)(s)
	v, sig := format(x.ip, x.n.args[x.i].name, it.v)
	if sig != .Go {
		return sig
	}
	return args_emit(s, {v = v})
}

@(private = "file")
object_key_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Args_Sink)(s)
	k, ok := string_of(it.v)
	if !ok {
		return fail(x.ip, "Cannot use %s (%s) as object key", type_name(it.v), brief(it.v))
	}
	return args_emit(s, {v = k})
}
