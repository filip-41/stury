package jq

// Bindings: `a as $x | b` and its destructuring patterns, and the variables they bind.

import "base:runtime"
import "core:os"
import "core:strings"

@(private)
eval_bind :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Bind_Sink{sink = {emit = bind_emit}, ip = ip, n = n, input = input, env = env, track = track, out = out}
	if out == ip.printer && !track && !ip.scope.on {
		return eval_scoped_outputs(ip, n.a, input, env, &s)
	}
	return eval_commas(ip, n.a, input, env, false, &s)
}

// The scope `a as $x | b` runs `b` in, `a` single and its last pattern binding at most one way: on the heap, as the
// evaluator loops into `b`. Under `?//` each alternative but the last runs `b` here, the next tried when it fails.
// The last one's error stands, so nothing is left to catch it, and its `b` is a tail like any other (jq has no fork
// point left there either).
@(private)
bind_head :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: ^Item, env: ^^Env, track: bool, out: ^Sink) -> (Signal, bool) {
	v, found, sig := eval_single(ip, n.a, input^, env^, false)
	if !found {
		return sig, false
	}
	start := state_of(input^)
	st := &start if track else nil
	pats := n.patterns
	scope, keys := env^, env^
	if len(pats) > 1 {
		for p in pats {
			scope = bind_nulls(ip, p, scope)
		}
		keys = nil
		x := Bind_Sink{ip = ip, n = n, input = input^, track = track, out = out}
		for p in pats[:len(pats) - 1] {
			b := Binder{ip = ip, x = &x, body = bind_body}
			if sig = bind_each(&b, &Pending{p = p, v = v.v}, scope, st); !retries(ip, sig) {
				release_scopes(ip, scope, env^)
				return sig, false
			}
		}
	}
	x := Bind_Sink{input = input^}
	b := Binder{ip = ip, keys = keys, x = &x, keep = true, body = proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal {
		x.env, x.found = e, true
		x.input = matched(x.input, st)
		return .Go
	}}
	if keys != nil {
		b.base = scope
	}
	if sig = bind_each(&b, &Pending{p = pats[len(pats) - 1], v = v.v}, scope, st); !x.found {
		release_scopes(ip, scope, env^)
		return sig, false
	}
	env^, input^ = x.env, x.input
	return sig, true
}

Bind_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	input:         Item,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
	state:      Value,
	found:      bool,
	owned:      ^Owned,
	scratch:    ^Reduce_Scratch,
}

bind_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Bind_Sink)(s)
	if p := x.n.patterns[0]; len(x.n.patterns) == 1 && p.kind == .Var {
		e := Env{parent = x.env, kind = .Var, name = p.name, value = it.v}
		return eval(x.ip, x.n.b, x.input, &e, x.track, x.out)
	}
	if !x.track {
		return bind_alternatives(x, it.v, bind_body, nil)
	}
	st := state_of(x.input)
	return bind_alternatives(x, it.v, bind_body, &st)
}

bind_body :: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal {
	return eval(x.ip, x.n.b, matched(x.input, st), e, x.track, x.out)
}

// Bind `v` to the patterns of `x.n` and run `body` in each scope they make. With `?//` an error tries the next
// alternative, every variable of every alternative null again. The last alternative's error stands. `st` is the path
// state the match starts in, nil if not tracking.
bind_alternatives :: proc(x: ^Bind_Sink, v: Value, body: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal, st: ^Path_State) -> Signal {
	pats := x.n.patterns
	if len(pats) == 1 {
		if p := pats[0]; p.kind == .Var {
			// A scope lives only while the evaluation that made it runs (no value holds one), so the
			// commonest binding, one per reduce or `as` step, needs no allocation.
			e := Env{parent = x.env, kind = .Var, name = p.name, value = v}
			return body(x, &e, st)
		}
		b := Binder{ip = x.ip, keys = x.env, base = x.env, x = x, body = body}
		return bind_each(&b, &Pending{p = pats[0], v = v}, x.env, st)
	}
	base := x.env
	for p in pats {
		base = bind_nulls(x.ip, p, base)
	}
	sig: Signal
	for p in pats {
		b := Binder{ip = x.ip, x = x, body = body}
		sig = bind_each(&b, &Pending{p = p, v = v}, base, st)
		if !retries(x.ip, sig) {
			break
		}
	}
	release_scopes(x.ip, base, x.env)
	return sig
}

// Whether a `?//` tries its next alternative after `sig`: an error, and a break, which jq raises as one
// (`first` and `limit` break after their generator's output, downstream of a `?//` in it). Not `halt`.
retries :: proc(ip: ^Interp, sig: Signal) -> bool {
	return sig == .Fail || sig == .Break && ip.brk >= 0
}

// The scopes from `env` up to `upto`, which a binding made for the evaluation it ran, given back.
release_scopes :: proc(ip: ^Interp, env: ^Env, upto: ^Env) {
	for e := env; e != upto; {
		next := e.parent
		e.parent, ip.free_envs = ip.free_envs, e
		e = next
	}
}

bind_nulls :: proc(ip: ^Interp, p: ^Pattern, env: ^Env) -> ^Env {
	e := env
	switch p.kind {
	case .Var:
		e = bind_var(ip, e, p.name, nil)
	case .Array:
		for sub in p.elems {
			e = bind_nulls(ip, sub, e)
		}
	case .Object:
		for m in p.members {
			if m.var != "" {
				e = bind_var(ip, e, m.var, nil)
			}
			if m.pattern != nil {
				e = bind_nulls(ip, m.pattern, e)
			}
		}
	}
	return e
}

bind_var :: proc(ip: ^Interp, env: ^Env, name: string, v: Value) -> ^Env {
	e := new_env(ip)
	e^ = {parent = env, kind = .Var, name = name, value = v}
	return e
}

// A destructuring: `body` runs once for each way the pattern binds, as an object pattern's key may
// yield several names. A key reads the value in `keys` if not nil (the scope outside the pattern), else
// in the variables bound so far.
Binder :: struct {
	ip:   ^Interp,
	keys: ^Env,
	// The scope outside a pattern with no `?//`: its body sees the first of the pattern's variables of one name, as
	// jq binds the body to its first store. With `?//` all stores of a name write one variable, and the last stands.
	// It is nil with `?//`.
	base: ^Env,
	x:    ^Bind_Sink,
	body: proc(x: ^Bind_Sink, e: ^Env, st: ^Path_State) -> Signal,
	// The scope outlives the binding (a tail bind's, which the evaluator loops into): its variables go
	// on the heap, not in the binding's frames.
	keep: bool,
}

// The patterns still to bind, innermost first, each to its value: an array pattern's elements from the
// last back (jq indexes the last first), `from` of them bound, an object pattern's members from `from`
// on. They live in the frames of the binding, which run the body.
Pending :: struct {
	p:    ^Pattern,
	v:    Value,
	from: int,
	next: ^Pending,
}

// `st` is the path state, nil if not tracking: each index a pattern takes steps from the value at the
// path, or fails as jq's does on another (`path(. as [$a, $b] | $a)`).
bind_each :: proc(b: ^Binder, todo: ^Pending, env: ^Env, st: ^Path_State) -> Signal {
	if todo == nil {
		return b.body(b.x, env, st)
	}
	p, v := todo.p, todo.v
	switch p.kind {
	case .Var:
		if b.base != nil && bound_since(env, b.base, p.name) {
			return bind_each(b, todo.next, env, st)
		}
		if b.keep {
			return bind_each(b, todo.next, bind_var(b.ip, env, p.name, v), st)
		}
		e := Env{parent = env, kind = .Var, name = p.name, value = v}
		return bind_each(b, todo.next, &e, st)
	case .Array:
		if todo.from == len(p.elems) {
			return bind_each(b, todo.next, env, st)
		}
		i := len(p.elems) - 1 - todo.from
		at: Path_State
		elem, next, sig := pattern_index(b.ip, v, num(f64(i)), st, &at)
		if sig != .Go {
			return sig
		}
		rest := Pending{p = p, v = v, from = todo.from + 1, next = todo.next}
		sub := Pending{p = p.elems[i], v = elem, next = &rest}
		return bind_each(b, &sub, env, next)
	case .Object:
		if todo.from == len(p.members) {
			return bind_each(b, todo.next, env, st)
		}
		s := Key_Sink{sink = {emit = key_emit}, b = b, todo = todo, env = env, st = st}
		return eval(b.ip, p.members[todo.from].key, {v = v}, b.keys if b.keys != nil else env, false, &s)
	}
	return .Go
}

bound_since :: proc(env, base: ^Env, name: string) -> bool {
	for e := env; e != base; e = e.parent {
		if e.name == name {
			return true
		}
	}
	return false
}

// A pattern's `v[key]`, and the path state after it in `at` (nil if not tracking).
pattern_index :: proc(ip: ^Interp, v: Value, key: Value, st: ^Path_State, at: ^Path_State) -> (Value, ^Path_State, Signal) {
	if st != nil && (st.path == &no_path || !identical(v, st.at)) {
		return nil, nil, fail(ip, "Invalid path expression near attempt to access element %s of %s", brief(key), brief(v))
	}
	m, sig := index_value(ip, v, key)
	if sig != .Go || st == nil {
		return m, nil, sig
	}
	at^ = {extend(st.path, key), m}
	return m, at, .Go
}

Key_Sink :: struct {
	using sink: Sink,
	b:          ^Binder,
	todo:       ^Pending,
	env:        ^Env,
	st:         ^Path_State,
}

// A name an object pattern's key yields: its member bound, and the rest of the pattern after it.
key_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Key_Sink)(s)
	p, v, from := x.todo.p, x.todo.v, x.todo.from
	m := p.members[from]
	at: Path_State
	member, st, sig := pattern_index(x.b.ip, v, scalar(it.v), x.st, &at)
	if sig != .Go {
		return sig
	}
	e := x.env
	local: Env
	if m.var != "" && (x.b.base == nil || !bound_since(e, x.b.base, m.var)) {
		if x.b.keep {
			e = bind_var(x.b.ip, e, m.var, member)
		} else {
			local = {parent = e, kind = .Var, name = m.var, value = member}
			e = &local
		}
	}
	rest := Pending{p = p, v = v, from = from + 1, next = x.todo.next}
	if m.pattern == nil {
		return bind_each(x.b, &rest, e, st)
	}
	sub := Pending{p = m.pattern, v = member, next = &rest}
	return bind_each(x.b, &sub, e, st)
}

// $ENV, made on first use, as most filters never read it. It outlives every input's memory, so it is made on the
// heap.
env_value :: proc(ip: ^Interp) -> (Value, Signal) {
	if ip.env_obj == nil {
		context.allocator = runtime.heap_allocator()
		env := new_object()
		environ, err := os.environ(context.allocator)
		if err != nil {
			return nil, fail(ip, "cannot read the environment: %v", err)
		}
		for kv in environ {
			if eq := strings.index_byte(kv, '='); eq > 0 {
				object_put(env, valid_utf8(kv[:eq]), valid_utf8(kv[eq + 1:])) // as jq's jv_string makes them
			}
		}
		ip.env_obj = env
	}
	return ip.env_obj, .Go
}

lookup_var :: proc(ip: ^Interp, name: string, env: ^Env) -> (Value, Signal) {
	for e := env; e != nil; e = e.parent {
		if e.kind == .Var && e.name == name {
			return e.value, .Go
		}
	}
	switch name {
	case "ENV":
		return env_value(ip)
	}
	return nil, fail(ip, "$%s is not defined", name)
}
