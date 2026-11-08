package jq

// Indexing: `.name`, `.[e]`, `.[e:f]` and `.[]`, and the index and slice of a value.

import "core:math"

// `.name`, `.[e]`, `.[e:f]` and `.[]`: `n.a`'s outputs indexed. As in jq, `e` and `f` run first, on the input of the
// whole term, and `n.a` runs for each key they give: `(t1, t2)[0, 1]` is `t1[0], t2[0], t1[1], t2[1]`.
@(private)
eval_step :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Index_Sink{ip = ip, track = track, out = out, opt = n.opt}
	#partial switch n.kind {
	case .Field:
		s.sink.emit, s.at = index_target_emit, n.name
	case .Index:
		s.sink.emit, s.n, s.env, s.input = index_key_emit, n, env, input
		return eval(ip, n.b, input, env, false, &s)
	case .Slice:
		s.n, s.env, s.input = n, env, input
		if n.b == nil {
			return slice_to(&s, nil)
		}
		s.sink.emit = slice_from_emit
		return eval(ip, n.b, input, env, false, &s)
	case:
		s.sink.emit = iterate_emit
	}
	return eval(ip, n.a, input, env, track, &s)
}

Index_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	env:        ^Env,
	input:      Item,
	track:      bool,
	out:        ^Sink,
	at:         Value, // `.name`'s name, `.[e]`'s key, or `.[e:f]`'s `{start, end}`
	from:       Value,
	opt:        bool, // `?`: the step's own error outputs nothing
}

index_and_emit :: proc(ip: ^Interp, t: Item, key: Value, track: bool, out: ^Sink, opt := false) -> Signal {
	if track && pathless(t.path) {
		return fail(ip, "Invalid path expression near attempt to access element %s of %s", brief(ip, key), brief(ip, t.v))
	}
	if track && ends_in_fact(t.path) {
		return fact_step_not_last(ip)
	}
	v, sig := index_value(ip, t.v, key)
	if sig != .Go {
		return .Go if opt && sig == .Fail else sig
	}
	return out.emit(out, {v = v, path = extend(t.path, key) if track else nil})
}

index_key_emit :: proc(s: ^Sink, it: Item) -> Signal {
	return index_targets((^Index_Sink)(s), scalar(it.v))
}

// `n.a`'s outputs, each indexed by `at`.
index_targets :: proc(x: ^Index_Sink, at: Value) -> Signal {
	inner := x^
	inner.sink.emit = index_target_emit
	inner.at = at
	return eval(x.ip, x.n.a, x.input, x.env, x.track, &inner)
}

index_target_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Index_Sink)(s)
	return index_and_emit(x.ip, it, x.at, x.track, x.out, x.opt)
}

slice_from_emit :: proc(s: ^Sink, it: Item) -> Signal {
	return slice_to((^Index_Sink)(s), scalar(it.v))
}

slice_to :: proc(x: ^Index_Sink, from: Value) -> Signal {
	inner := x^
	inner.from = from
	if x.n.c == nil {
		return slice_finish(&inner, nil)
	}
	inner.sink.emit = slice_end_emit
	return eval(x.ip, x.n.c, x.input, x.env, false, &inner)
}

slice_end_emit :: proc(s: ^Sink, it: Item) -> Signal {
	return slice_finish((^Index_Sink)(s), scalar(it.v))
}

slice_finish :: proc(x: ^Index_Sink, to: Value) -> Signal {
	key := new_object()
	object_put(key, "start", x.from)
	object_put(key, "end", to)
	return index_targets(x, key)
}

iterate_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Index_Sink)(s)
	if x.track && pathless(it.path) {
		return fail(x.ip, "Invalid path expression near attempt to iterate through %s", brief(x.ip, it.v))
	}
	if x.track && ends_in_fact(it.path) {
		return fact_step_not_last(x.ip)
	}
	k := kind(it.v)
	if k != .Array && k != .Object {
		if x.opt {
			return .Go
		}
		return fail(x.ip, "Cannot iterate over %s (%s)", type_name(it.v), brief(x.ip, it.v))
	}
	members := iterate(it.v)
	i := 0
	for key, m in next_member(&members) {
		path: ^Path_Step
		if x.track {
			path = extend(it.path, num(f64(i)) if k == .Array else Value(key))
		}
		i += 1
		if sig := x.out.emit(x.out, {v = m, path = path}); sig != .Go {
			return sig
		}
	}
	return .Go
}

// `t[key]`: a member, an element, a slice (`key` a `{start, end}` object), or the indices of a subarray. Null indexes
// to null by a string, a number or a slice.
index_value :: proc(ip: ^Interp, t: Value, key: Value) -> (Value, Signal) {
	tk := kind(t)
	switch k in key {
	case string:
		if tk == .Object {
			v, _ := object_get(t, k)
			return v, .Go
		}
		if tk == .Null {
			return nil, .Go
		}
		return nil, fail(ip, "Cannot index %s with string (%s)", type_name(t), brief(ip, k))
	case Number:
		if tk == .Array {
			if math.is_nan(k.f) {
				return nil, .Go
			}
			i := int(k.f)
			if i < 0 {
				i += length_of(t)
			}
			return array_at(t, i), .Go
		}
		if tk == .Null {
			return nil, .Go
		}
		return nil, fail(ip, "Cannot index %s with number (%s)", type_name(t), brief(ip, key))
	case ^Object, ^Array, Ref, Path, ^Commented:
		switch kind(key) {
		case .Object:
			if role, is_fact := fact_step(key); is_fact {
				return comments_value(t, role), .Go
			}
			if tk == .Null {
				return nil, .Go
			}
			return slice_value(ip, t, key)
		case .Array:
			if tk == .Array {
				too_deep = false
				found := indices_of(t, key)
				return found, compare_failed(ip, true)
			}
		case .Number, .String: // read from the input, as getpath's keys are
			return index_value(ip, t, scalar(key))
		case .Null, .False, .True:
		}
	case nil, bool:
	}
	return nil, fail(ip, "Cannot index %s with %s (%s)", type_name(t), type_name(key), brief(ip, key))
}

// Bounds of the slice `key` ({"start", "end"}) of length `n`: negative counts from the end, the start
// truncates and the end rounds up, both clamp, and an end before the start is the start.
slice_bounds :: proc(ip: ^Interp, n: int, key: Value) -> (lo, hi: int, sig: Signal) {
	from, fok := object_get(key, "start")
	to, tok := object_get(key, "end")
	f, t := 0.0, f64(n)
	if from != nil {
		x: Number
		x, fok = number_of(from)
		f = x.f
	}
	if to != nil {
		x: Number
		x, tok = number_of(to)
		t = x.f
	}
	if !fok || !tok {
		return 0, 0, fail(ip, "Array/string slice indices must be integers")
	}
	// jq's parse_slice: nan is the whole, the start rounds down and the end up.
	if math.is_nan(f) {
		f = 0
	}
	if f < 0 {
		f += f64(n)
	}
	lo = int(clamp(f, 0, f64(n)))
	if math.is_nan(t) {
		t = f64(n)
	}
	if t < 0 {
		t += f64(n)
	}
	switch {
	case t < 0:
		hi = lo
	case t >= f64(n):
		hi = n
	case:
		hi = int(t)
		if f64(hi) < t {
			hi += 1
		}
	}
	return lo, max(hi, lo), .Go
}

slice_value :: proc(ip: ^Interp, t: Value, key: Value) -> (v: Value, sig: Signal) {
	switch kind(t) {
	case .Array:
		lo, hi := slice_bounds(ip, length_of(t), key) or_return
		return array_slice(t, lo, hi), .Go
	case .String:
		s, _ := string_of(t)
		runes := codepoints(s)
		lo, hi := slice_bounds(ip, runes, key) or_return
		if runes == len(s) { // all ASCII: character indices are byte offsets
			return s[lo:hi], .Go
		}
		w := Char_Walk{}
		if lo > runes / 2 { // walk from the nearer end
			w = {len(s), runes}
		}
		return char_slice(&w, s, lo, hi), .Go
	case .Null, .False, .True, .Number, .Object:
	}
	return nil, fail(ip, "Cannot index %s with object (%s)", type_name(t), brief(ip, key))
}

indices_of :: proc(t: Value, sub: Value) -> Value {
	out := new_array()
	n, m := length_of(t), length_of(sub)
	if m == 0 {
		return out
	}
	if n * m >= 256 {
		if scalar_indices(t, sub, out) {
			return out
		}
	}
	outer: for i in 0 ..= n - m {
		for j in 0 ..< m {
			if !equal(array_at(t, i + j), array_at(sub, j)) {
				continue outer
			}
		}
		append(&out.items, num(f64(i)))
	}
	return out
}

// `indices_of` when `sub` holds only scalars: every element is read into its atom once, and a window is
// compared by atoms, not by equal() on rows. The all-matching window (zeros in zeros) stays n * m, a ceiling.
// The result is false when `sub` holds an array or object, which `indices_of` compares.
@(private = "file")
scalar_indices :: proc(t, sub: Value, out: ^Array) -> (fast: bool) {
	ss := make([]Sort_Atom, length_of(sub))
	for x, j in elements(sub) {
		ss[j] = sort_atom(x)
		if ss[j].kind == .Array || ss[j].kind == .Object {
			return false
		}
	}
	ts := make([]Sort_Atom, length_of(t))
	for x, i in elements(t) {
		ts[i] = sort_atom(x)
	}
	outer: for i in 0 ..= len(ts) - len(ss) {
		for a, j in ss {
			if compare_atoms(ts[i + j], a) != 0 {
				continue outer
			}
		}
		append(&out.items, num(f64(i)))
	}
	return true
}
