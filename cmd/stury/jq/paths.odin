package jq

// Path tracking: the path an output was read at, kept beside it while a path expression runs.

extend :: proc(p: ^Path_Step, key: Value) -> ^Path_Step {
	s := new(Path_Step)
	s.parent, s.key = p, key
	return s
}

path_array :: proc(p: ^Path_Step) -> ^Array {
	n := 0
	for s := p; s != nil; s = s.parent {
		n += 1
	}
	a := new_array(n)
	resize(&a.items, n)
	for s := p; s != nil; s = s.parent {
		n -= 1
		a.items[n] = s.key
	}
	return a
}

// The path of a value no path leads to, made by an expression that is not a path: a path expression
// fails where it next steps into the value, or outputs it.
@(rodata)
no_path: Path_Step

// A value made by an expression that is not a path.
emit_value :: proc(ip: ^Interp, out: ^Sink, v: Value, track: bool) -> Signal {
	return out.emit(out, {v = v, path = &no_path if track else nil})
}

// jq's path tracking where a path expression makes a value: the path it last stepped along
// (`&no_path` if not known) and the value it found there. jq takes a value for that path's only if it
// is that very value (jv_identical), so `path(. as $x | $x)` is `[]` and `path(.[0] | null)` on `[null]`
// is `[0]`, while a destructuring steps along its pattern's indices and leaves its body's input pathless.
Path_State :: struct {
	path: ^Path_Step,
	at:   Value,
}

// The path of an item no path leads to that keeps the state it was made in, for a value made from it
// later, which may be the value there (`path(. as [$a] | $a)`).
Detached :: struct {
	using step: Path_Step, // `parent` is &no_path, `key` the value at `path`
	path:       ^Path_Step,
}

// Whether no path leads to an item.
pathless :: proc(p: ^Path_Step) -> bool {
	return p == &no_path || p != nil && p.parent == &no_path
}

state_of :: proc(it: Item) -> Path_State {
	if it.path != nil && it.path.parent == &no_path {
		return {(^Detached)(it.path).path, it.path.key}
	}
	return {it.path, it.v}
}

// The path of `v` made in state `st`.
placed :: proc(st: Path_State, v: Value) -> ^Path_Step {
	if st.path == &no_path || identical(v, st.at) {
		return st.path
	}
	d := new(Detached)
	d.parent, d.key, d.path = &no_path, st.at, st.path
	return d
}

// The path of `v` made from `it` without a step: a literal's, a variable's.
path_from :: proc(it: Item, v: Value) -> ^Path_Step {
	if it.path != nil && it.path.parent == &no_path && !identical(v, it.path.key) {
		return it.path
	}
	return placed(state_of(it), v)
}

// jq's jv_identical: the same value, not an equal one. There is one null, true and false. A number written in the
// input or the program is the place it is written, a computed one its bits.
identical :: proc(a, b: Value) -> bool {
	k := kind(a)
	if k != kind(b) {
		return false
	}
	if k == .Null || k == .True || k == .False {
		return true
	}
	switch x in a {
	case Ref:
		y, is_ref := b.(Ref)
		return is_ref && x == y
	case Number:
		y, is_num := b.(Number)
		if !is_num {
			return false
		}
		if x.lit != "" || y.lit != "" {
			return raw_data(x.lit) == raw_data(y.lit)
		}
		return transmute(u64)x.f == transmute(u64)y.f
	case string:
		y, is_str := b.(string)
		return is_str && raw_data(x) == raw_data(y) && len(x) == len(y)
	case ^Array:
		y, is_arr := b.(^Array)
		return is_arr && x == y
	case ^Object:
		y, is_obj := b.(^Object)
		return is_obj && x == y
	case bool:
	}
	return true
}

// `v`, made from `input` without a step.
emit_made :: proc(out: ^Sink, input: Item, v: Value, track: bool) -> Signal {
	return out.emit(out, {v = v, path = path_from(input, v) if track else nil})
}

// The path a path expression output `it` by, or jq's error for a value no path leads to.
path_of :: proc(ip: ^Interp, it: Item) -> (^Array, Signal) {
	if pathless(it.path) {
		return nil, fail(ip, "Invalid path expression with result %s", brief(it.v))
	}
	return path_array(it.path), .Go
}

// `it` after a pattern's match left the path state `st` (nil if not tracking): pathless, unless no index
// stepped from its own.
matched :: proc(it: Item, st: ^Path_State) -> Item {
	if st == nil || st.path == state_of(it).path {
		return it
	}
	return {v = it.v, path = placed(st^, it.v)}
}

// A reduce's or foreach's state `v` as its update's input, in the path state `st` its source output and
// pattern left (nil if not tracking).
in_state :: proc(v: Value, st: ^Path_State) -> Item {
	return {v = v, path = placed(st^, v) if st != nil else nil}
}
