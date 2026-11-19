#+private
package jq

// Indexing: `.name`, `.[e]`, `.[e:f]` and `.[]`, and the index and slice of a value.

import "base:runtime"
import "core:math"
import "core:strings"
import core_pkg "../core"

// `.name`, `.[e]`, `.[e:f]` and `.[]`: `n.a`'s outputs indexed. As in jq, `e` and `f` run first, on the input of the
// whole term, and `n.a` runs for each key they give: `(t1, t2)[0, 1]` is `t1[0], t2[0], t1[1], t2[1]`.
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
	at:         core_pkg.Value, // `.name`'s name, `.[e]`'s key, or `.[e:f]`'s `{start, end}`
	from:       core_pkg.Value,
	opt:        bool, // `?`: the step's own error outputs nothing
}

index_and_emit :: proc(ip: ^Interp, t: Item, key: core_pkg.Value, track: bool, out: ^Sink, opt := false) -> Signal {
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
index_targets :: proc(x: ^Index_Sink, at: core_pkg.Value) -> Signal {
	if a := x.n.a; !x.track && a != nil && a.kind == .Var {
		if v, read := index_var(a.name, x.env, at); read {
			return x.out.emit(x.out, {v = v})
		}
	}
	inner := x^
	inner.sink.emit = index_target_emit
	inner.at = at
	return eval(x.ip, x.n.a, x.input, x.env, x.track, &inner)
}

// The names of a wide object of a document that a variable holds, counted at each read by name and hashed at the
// READS_HASHED_AFTER th, each to the value of its last member as `core.member` reads it. It lives in the memory the
// variable's scope was made in, which outlives every read of the variable, and so does its hash.
Member_Keys :: struct {
	reads:     int,
	hashed:    bool,
	allocator: runtime.Allocator,
	slots:     map[string]core_pkg.Node_Index,
}

// An object narrower than this is scanned at each read, which costs about what a hash lookup does.
@(private = "file")
MEMBERS_HASHED_FROM :: 64

@(private = "file")
READS_HASHED_AFTER :: 16

// What a scope binding `v` keeps of its names: nil but for a wide object of a document.
member_keys :: proc(v: core_pkg.Value) -> ^Member_Keys {
	r, is_ref := core_pkg.plain(v).(core_pkg.Node_Ref)
	if !is_ref || core_pkg.kind(r.doc, r.node) != .Object || core_pkg.length(r.doc, r.node) < MEMBERS_HASHED_FROM ||
	   core_pkg.header_of(r.doc) != 0 || core_pkg.is_markup(r.doc) {
		return nil
	}
	return new_clone(Member_Keys{allocator = context.allocator})
}

// `$name[key]` read from the hash of the names of the object `$name` holds, and whether the hash answered: false for a
// key that is not a string and a variable with no `Member_Keys`, and until the hash is made.
@(private = "file")
index_var :: proc(name: string, env: ^Env, key: core_pkg.Value) -> (core_pkg.Value, bool) {
	k, is_str := key.(string)
	if !is_str {
		return nil, false
	}
	e := env
	for e != nil && (e.kind != .Var || e.name != name) {
		e = e.parent
	}
	if e == nil || e.keys == nil {
		return nil, false
	}
	m := e.keys
	r := core_pkg.plain(e.value).(core_pkg.Node_Ref)
	if !m.hashed {
		m.reads += 1
		if m.reads != READS_HASHED_AFTER || !hash_members(m, r) {
			return nil, false
		}
		m.hashed = true
	}
	node, has := m.slots[k]
	return core_pkg.Node_Ref{r.doc, node} if has else nil, true
}

// Fills `m.slots` from object `r`, its names borrowed from the source. False for a name that needs decoding, which the
// format's `key_equals` compares.
@(private = "file")
hash_members :: proc(m: ^Member_Keys, r: core_pkg.Node_Ref) -> bool {
	doc := r.doc
	m.slots = make(map[string]core_pkg.Node_Index, core_pkg.length(doc, r.node), m.allocator)
	end := r.node + core_pkg.Node_Index(doc.nodes[r.node].n)
	for j := r.node + 1; j < end; {
		key := doc.nodes[j]
		if key.role != .Key || key.spelling & core_pkg.SPELLING_DECODE != 0 {
			return false
		}
		m.slots[string(doc.src[key.lo:key.lo + u64(key.n)])] = j + 1
		j += 1 + core_pkg.Node_Index(core_pkg.subtree_size(doc, j + 1))
	}
	return true
}

index_target_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Index_Sink)(s)
	return index_and_emit(x.ip, it, x.at, x.track, x.out, x.opt)
}

slice_from_emit :: proc(s: ^Sink, it: Item) -> Signal {
	return slice_to((^Index_Sink)(s), scalar(it.v))
}

slice_to :: proc(x: ^Index_Sink, from: core_pkg.Value) -> Signal {
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

slice_finish :: proc(x: ^Index_Sink, to: core_pkg.Value) -> Signal {
	key := core_pkg.new_object()
	core_pkg.object_put(key, "start", x.from)
	core_pkg.object_put(key, "end", to)
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
		path: ^core_pkg.Trail_Step
		if x.track {
			path = extend(it.path, num(f64(i)) if k == .Array else core_pkg.Value(key))
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
index_value :: proc(ip: ^Interp, t: core_pkg.Value, key: core_pkg.Value) -> (core_pkg.Value, Signal) {
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
	case f64, core_pkg.Number_View:
		if tk == .Array {
			// A literal zero keeps its digits (`literal`), and `.[0]` is common.
			f, is_f64 := key.(f64)
			if !is_f64 {
				n, _ := number_of(key)
				f = n.f
			}
			if math.is_nan(f) {
				return nil, .Go
			}
			i := int(f)
			if i < 0 {
				i += length_of(t)
			}
			return array_at(t, i), .Go
		}
		if tk == .Null {
			return nil, .Go
		}
		return nil, fail(ip, "Cannot index %s with number (%s)", type_name(t), brief(ip, key))
	case ^core_pkg.Object, ^core_pkg.Array, core_pkg.Node_Ref, core_pkg.Trail, ^core_pkg.Commented:
		switch kind(key) {
		case .Object:
			if fact, is_fact := fact_step(key); is_fact {
				if is_attribute_step(key) {
					return core_pkg.attributes_value(t, attribute_step_name(key), true), .Go
				}
				return fact_value(t, fact), .Go
			}
			if name, unknown := unknown_fact_step(key); unknown {
				return nil, unknown_fact(ip, name)
			}
			if tk == .Null {
				return nil, .Go
			}
			return slice_value(ip, t, key)
		case .Array:
			if tk == .Array {
				ip.too_deep = false
				found := indices_of(&ip.too_deep, t, key)
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
slice_bounds :: proc(ip: ^Interp, n: int, key: core_pkg.Value) -> (lo, hi: int, sig: Signal) {
	from, fok := object_get(key, "start")
	to, tok := object_get(key, "end")
	f, t := 0.0, f64(n)
	if from != nil {
		x: Num
		x, fok = number_of(from)
		f = x.f
	}
	if to != nil {
		x: Num
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

// The text of string `t`, and whether it lies in `scratch^`, the buffer slices share (valid until the next slice).
// The piece a slice keeps is copied out, so a loop over slices of one long string holds the pieces, not a decode of
// the whole string for each.
@(private = "file")
slice_source :: proc(scratch: ^[dynamic]byte, t: core_pkg.Value) -> (s: string, decoded: bool) {
	if r, is_ref := core_pkg.plain(t).(core_pkg.Node_Ref); is_ref {
		if room := core_pkg.text_room(r.doc, r.node); room > 0 && r.doc.nodes[r.node].kind != .Bytes {
			if scratch.allocator.procedure == nil {
				scratch^ = make([dynamic]byte, runtime.heap_allocator())
			}
			resize(scratch, room)
			if text, ok := core_pkg.text(r.doc, r.node, scratch[:]); ok {
				return text, true
			}
		}
	}
	s, _ = string_of(t)
	return s, false
}

slice_value :: proc(ip: ^Interp, t: core_pkg.Value, key: core_pkg.Value) -> (v: core_pkg.Value, sig: Signal) {
	switch kind(t) {
	case .Array:
		lo, hi := slice_bounds(ip, length_of(t), key) or_return
		return array_slice(t, lo, hi), .Go
	case .String:
		s, decoded := slice_source(&ip.slice_scratch, t)
		runes := codepoints(s)
		lo, hi := slice_bounds(ip, runes, key) or_return
		piece: string
		if runes == len(s) { // all ASCII: character indices are byte offsets
			piece = s[lo:hi]
		} else {
			w := Char_Walk{}
			if lo > runes / 2 { // walk from the nearer end
				w = {len(s), runes}
			}
			piece = char_slice(&w, s, lo, hi)
		}
		return strings.clone(piece) if decoded else piece, .Go
	case .Null, .False, .True, .Number, .Object:
	}
	return nil, fail(ip, "Cannot index %s with object (%s)", type_name(t), brief(ip, key))
}

indices_of :: proc(too_deep: ^bool, t: core_pkg.Value, sub: core_pkg.Value) -> core_pkg.Value {
	out := core_pkg.new_array()
	n, m := length_of(t), length_of(sub)
	if m == 0 {
		return out
	}
	if n * m >= 256 && scalar_indices(too_deep, t, sub, out) {
		return out
	}
	outer: for i in 0 ..= n - m {
		for j in 0 ..< m {
			if !equal(too_deep, array_at(t, i + j), array_at(sub, j)) {
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
scalar_indices :: proc(too_deep: ^bool, t, sub: core_pkg.Value, out: ^core_pkg.Array) -> (fast: bool) {
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
	s := Sort_Run{too_deep = too_deep}
	outer: for i in 0 ..= len(ts) - len(ss) {
		for a, j in ss {
			if compare_atoms(&s, ts[i + j], a) != 0 {
				continue outer
			}
		}
		append(&out.items, num(f64(i)))
	}
	return true
}
