package jq

// Paths as data: `getpath`, `setpath`, `delpaths`, and the assignment operators built on them.
//
// Values are shared, so a change copies each container on its way down. An `Owned` set names the
// containers one update already copied, which it may then change in place: `.[] |= f` copies its array
// once, not once per element, and a `reduce` whose update only writes into its state keeps one set for
// the whole reduction.

import "base:runtime"
import "core:math"
import "core:slice"

Owned :: map[rawptr]bool

owned_copy :: proc(v: Value, owned: ^Owned) -> Value {
	if p := container(v); p != nil && owned[p] {
		return v
	}
	c := own(v)
	if p := container(c); p != nil {
		owned[p] = true
	}
	return c
}

// The array or object `v` is, as an `Owned` set names it, nil for anything else.
@(private = "file")
container :: proc(v: Value) -> rawptr {
	#partial switch x in v {
	case ^Array:
		return x
	case ^Object:
		return x
	}
	return nil
}

getpath :: proc(ip: ^Interp, v: Value, path: []Value) -> (Value, Signal) {
	cur := v
	for key in path {
		next, sig := index_value(ip, cur, key)
		if sig != .Go {
			return nil, sig
		}
		cur = next
	}
	return cur, .Go
}

// The longest path jq's getpath, setpath and delpaths take.
MAX_PATH_DEPTH :: 10000

// `v` with `path` set to `nv`, as jq's jv_setpath: each step reads what is there, then sets it.
setpath :: proc(ip: ^Interp, v: Value, path: []Value, nv: Value, owned: ^Owned) -> (Value, Signal) {
	if len(path) == 0 {
		return nv, .Go
	}
	key := scalar(path[0])
	child, sig := index_value(ip, v, key)
	if sig != .Go {
		return nil, sig
	}
	if len(path) > 1 {
		if sig = set_refused(ip, v, key, owned); sig != .Go {
			return nil, sig
		}
	}
	set: Value
	if set, sig = setpath(ip, child, path[1:], nv, owned); sig != .Go {
		return nil, sig
	}
	return set_key(ip, v, key, set, owned)
}

// What jq's jv_set of null at `key` in `t` refuses, which jv_setpath tries before it descends (a slice's
// key it sets only after).
@(private = "file")
set_refused :: proc(ip: ^Interp, t: Value, key: Value, owned: ^Owned) -> Signal {
	tk := kind(t)
	#partial switch kind(key) {
	case .String:
		if tk == .Object || tk == .Null {
			return .Go
		}
	case .Number:
		if tk == .Array || tk == .Null {
			_, sig := array_set_index(ip, length_of(t), key)
			return sig
		}
	case .Object:
		return .Go
	}
	_, sig := set_key(ip, t, key, nil, owned)
	return sig
}

// The index jq's jv_set sets for number `key` in an array of `size` items.
@(private = "file")
array_set_index :: proc(ip: ^Interp, size: int, key: Value) -> (int, Signal) {
	n, _ := number_of(key)
	if math.is_nan(n.f) {
		return 0, fail(ip, "Cannot set array element at NaN index")
	}
	i := int(clamp(n.f, f64(min(i32)), f64(max(i32))))
	if i < 0 {
		i += size
		if i < 0 {
			return 0, fail(ip, "Out of bounds negative array index")
		}
	}
	if i > int(max(i32) >> 2) {
		return 0, fail(ip, "Array index too large")
	}
	return i, .Go
}

// `t` with `key` set to `v`, as jq's jv_set: null becomes an object under a key and an array under an
// index or a slice, and an array grows with nulls to reach an index.
@(private = "file")
set_key :: proc(ip: ^Interp, t: Value, key: Value, v: Value, owned: ^Owned) -> (Value, Signal) {
	tk := kind(t)
	#partial switch kind(key) {
	case .String:
		if tk == .Object || tk == .Null {
			k, _ := string_of(key)
			o := new_object() if tk == .Null else owned_copy(t, owned).(^Object)
			owned[o] = true
			object_put(o, k, v)
			return o, .Go
		}
	case .Number:
		if tk == .Array || tk == .Null {
			i, sig := array_set_index(ip, length_of(t), key)
			if sig != .Go {
				return nil, sig
			}
			a := new_array() if tk == .Null else owned_copy(t, owned).(^Array)
			owned[a] = true
			if cap(a.items) <= i {
				// The holes at once, where append would grow a null at a time. Resize alone grows to the exact
				// length, which a run of stores past the end would pay each time.
				reserve(&a.items, max(i + 1, 2 * cap(a.items)))
				resize(&a.items, i)
			}
			for len(a.items) <= i {
				append(&a.items, nil)
			}
			a.items[i] = v
			return a, .Go
		}
	case .Object:
		if tk == .String {
			return nil, fail(ip, "Cannot update string slices")
		}
		if tk == .Array || tk == .Null {
			n := length_of(t)
			lo, hi, sig := slice_bounds(ip, n, key)
			if sig != .Go {
				return nil, sig
			}
			if kind(v) != .Array {
				return nil, fail(ip, "A slice of an array can only be assigned another array")
			}
			// Built from `t` itself, as an owned copy of it would only be copied again into `items`.
			old := elements(t)
			items := make([dynamic]Value, 0, n - (hi - lo) + length_of(v))
			append(&items, ..old[:lo])
			it := iterate(v)
			for _, m in next_member(&it) {
				append(&items, m)
			}
			append(&items, ..old[hi:])
			a, is_array := t.(^Array)
			if !is_array || !owned[a] {
				a = new_array()
				owned[a] = true
			}
			a.items = items
			return a, .Go
		}
	}
	return nil, fail(ip, "Cannot update field at %s index of %s", type_name(key), type_name(t))
}

// `v` without `paths`, as jq's jv_delpaths: sorted, and each container's keys deleted at once, so an
// index counts in the array as it was.
delpaths :: proc(ip: ^Interp, v: Value, paths: []Value, owned: ^Owned) -> (Value, Signal) {
	sorted := slice.clone(paths)
	slice.sort_by(sorted, proc(a, b: Value) -> bool {
		return compare(a, b) < 0
	})
	steps := make([][]Value, len(sorted))
	for p, i in sorted {
		if kind(p) != .Array {
			return nil, fail(ip, "Path must be specified as array, not %s", type_name(p))
		}
		if length_of(p) > MAX_PATH_DEPTH {
			return nil, fail(ip, "Path too deep")
		}
		path := make([dynamic]Value, 0, length_of(p))
		it := iterate(p)
		for _, s in next_member(&it) {
			append(&path, scalar(s))
		}
		steps[i] = path[:]
	}
	switch {
	case len(steps) == 0:
		return v, .Go
	case len(steps[0]) == 0:
		return nil, .Go
	}
	return delpaths_sorted(ip, v, steps, 0, owned)
}

// `v` without `paths`, which share their first `start` steps and are sorted.
@(private = "file")
delpaths_sorted :: proc(ip: ^Interp, v: Value, paths: [][]Value, start: int, owned: ^Owned) -> (Value, Signal) {
	gone := make([dynamic]Value)
	cur := v
	for i := 0; i < len(paths); {
		key := paths[i][start]
		j := i + 1 // past a nan key too, which equals nothing
		for j < len(paths) && equal(key, paths[j][start]) {
			j += 1
		}
		if len(paths[i]) == start + 1 {
			append(&gone, key)
		} else {
			child, sig := index_value(ip, cur, key)
			if sig != .Go {
				return nil, sig
			}
			if child != nil {
				if child, sig = delpaths_sorted(ip, child, paths[i:j], start + 1, owned); sig != .Go {
					return nil, sig
				}
				if cur, sig = set_key(ip, cur, key, child, owned); sig != .Go {
					return nil, sig
				}
			}
		}
		i = j
	}
	return delete_keys(ip, cur, gone[:], owned)
}

// `t` without the members `keys` name, as jq's jv_dels.
@(private = "file")
delete_keys :: proc(ip: ^Interp, t: Value, keys: []Value, owned: ^Owned) -> (Value, Signal) {
	if kind(t) == .Null || len(keys) == 0 {
		return t, .Go
	}
	#partial switch kind(t) {
	case .Array:
		a := owned_copy(t, owned).(^Array)
		n := len(a.items)
		// The index ranges deleted, as many as the keys, not the elements: a reduce deleting one at a
		// time from a long array would otherwise take memory for each element at each step.
		gone := make([dynamic][2]int, 0, len(keys))
		for key in keys {
			#partial switch kind(key) {
			case .Number:
				k, _ := number_of(key)
				if math.is_nan(k.f) || k.f >= f64(n) || k.f < -f64(n) {
					continue
				}
				i := int(k.f)
				if k.f < 0 {
					i += n
				}
				if 0 <= i && i < n {
					append(&gone, [2]int{i, i + 1})
				}
			case .Object:
				lo, hi, sig := slice_bounds(ip, n, key)
				if sig != .Go {
					return nil, sig
				}
				append(&gone, [2]int{lo, hi})
			case:
				return nil, fail(ip, "Cannot delete %s element of array", type_name(key))
			}
		}
		slice.sort_by(gone[:], proc(x, y: [2]int) -> bool {
			return x[0] < y[0]
		})
		kept, at := 0, 0
		for m, i in a.items {
			for at < len(gone) && gone[at][1] <= i {
				at += 1
			}
			if at == len(gone) || i < gone[at][0] {
				a.items[kept] = m
				kept += 1
			}
		}
		resize(&a.items, kept)
		return a, .Go
	case .Object:
		for key in keys {
			if kind(key) != .String {
				return nil, fail(ip, "Cannot delete %s field of object", type_name(key))
			}
		}
		o := owned_copy(t, owned).(^Object)
		if len(keys) == 1 {
			k, _ := string_of(keys[0])
			object_delete(o, k)
			return o, .Go
		}
		// One pass over the object, not one per key.
		gone := make(map[string]bool, len(keys))
		for key in keys {
			k, _ := string_of(key)
			gone[k] = true
		}
		object_delete_all(o, gone)
		return o, .Go
	}
	return nil, fail(ip, "Cannot delete fields from %s", type_name(t))
}

// A reduce over the paths `lhs` reads in `v`, each updated as it comes by `step`: jq's _modify and
// _assign. An update's error reaches a `?//` in `lhs`, which tries its next alternative in the state
// jq's LOADVN leaves the reduce: null, and so too the paths `|=` deletes.
Path_Update :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	env:        ^Env,
	rhs:        Value,
	owned:      ^Owned,
	step:       proc(x: ^Path_Update, p: []Value) -> Signal,
	cur:        Value,
	gone:       [dynamic]Value, // the paths `|=` deletes
	gone_null:  bool,           // which are null
	failed:     bool,
	// Under a path expression, the update's input there: jq's _modify runs `f` path-tracked, on a value
	// no path leads to unless it is that very input.
	top:        ^Item,
}

update_paths :: proc(ip: ^Interp, n: ^Node, v: Value, env: ^Env, rhs: Value, owned: ^Owned, step: proc(x: ^Path_Update, p: []Value) -> Signal, top: ^Item = nil) -> (Value, Signal) {
	x := Path_Update{sink = {emit = path_update_emit}, ip = ip, n = n, env = env, rhs = rhs, owned = owned, step = step, cur = v, top = top}
	if sig := eval(ip, n.a, {v = v}, env, true, &x); sig != .Go {
		return nil, sig
	}
	if top != nil && n.op != .Assign {
		// Under a path expression, jq's _modify fails reading its value out of its state `[v, gone]`.
		gone: Value
		if !x.gone_null {
			a := new_array(len(x.gone))
			append(&a.items, ..x.gone[:])
			gone = a
		}
		state := new_array(2)
		append(&state.items, x.cur, gone)
		return nil, fail(ip, "Invalid path expression near attempt to access element 0 of %s", brief(state))
	}
	if x.gone_null {
		return nil, fail(ip, "Paths must be specified as an array")
	}
	if len(x.gone) > 0 {
		return delpaths(ip, x.cur, x.gone[:], owned)
	}
	return x.cur, .Go
}

path_update_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Path_Update)(s)
	p, sig := path_of(x.ip, it)
	if sig != .Go {
		return sig
	}
	if x.failed {
		x.cur, x.failed = nil, false
		clear(&x.gone)
		x.gone_null = x.n.op != .Assign
	}
	if sig = x.step(x, path_array(p).items[:]); sig != .Go {
		x.failed = true
	}
	return sig
}

eval_update :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if n.op == .Modify {
		owned: Owned
		top := input
		v, sig := modify(ip, n, input.v, env, &owned, &top if track else nil)
		if sig != .Go {
			return sig
		}
		return emit_value(ip, out, v, track)
	}
	s := Node_Sink{sink = {emit = update_rhs_emit}, ip = ip, n = n, input = input, env = env, track = track, out = out}
	// jq binds `=`'s right side as a `$value` argument, out of the path expression, but runs `op=`'s inline
	// before its _modify, so under path() that one is path-tracked (`path(.a += ([1] | .[0]))` fails).
	return eval(ip, n.b, input, env, track && n.op != .Assign, &s)
}

update_rhs_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Node_Sink)(s)
	owned: Owned
	v, sig := assign(x.ip, x.n, x.input.v, it.v, x.env, &owned, &x.input if x.track else nil)
	if sig != .Go {
		return sig
	}
	// jq's _assign is a reduce from `.`: with no path to set, its output is the very input, path and all.
	return emit_made(x.out, x.input, v, x.track)
}

// `lhs op= rhs` with one value of `rhs`: `=` sets every path to it, `op=` combines it with what each
// path holds, `//=` keeps what is truthy.
assign :: proc(ip: ^Interp, n: ^Node, v: Value, rhs: Value, env: ^Env, owned: ^Owned, top: ^Item = nil) -> (Value, Signal) {
	return update_paths(ip, n, v, env, rhs, owned, assign_step, top)
}

assign_step :: proc(x: ^Path_Update, p: []Value) -> Signal {
	nv := x.rhs
	sig: Signal
	if x.n.op != .Assign {
		fresh_label(x.ip) // `a op= b` is jq's _modify, which runs each path in a label
		old: Value
		if old, sig = getpath(x.ip, x.cur, p); sig != .Go {
			return sig
		}
		switch {
		case x.n.op == .Alt:
			nv = old if truthy(old) else x.rhs
		case:
			if nv, sig = binary_op(x.ip, x.n.op, old, x.rhs, x.owned); sig != .Go {
				return sig
			}
		}
	}
	x.cur, sig = setpath(x.ip, x.cur, p, nv, x.owned)
	return sig
}

// `lhs |= f`: each path takes the first output of `f` on what it holds, or is deleted when `f` has none.
// jq's _modify keeps the value and the paths to delete as its reduce state `[v, gone]`, and reads it
// with `$$$$dot`, which empties the variable: an output of `f` after the first (a `?//` in `f` retrying
// on the break) sets its path in null, and leaves null for the paths to delete, which delpaths refuses.
modify :: proc(ip: ^Interp, n: ^Node, v: Value, env: ^Env, owned: ^Owned, top: ^Item = nil) -> (Value, Signal) {
	return update_paths(ip, n, v, env, nil, owned, modify_step, top)
}

modify_step :: proc(x: ^Path_Update, p: []Value) -> Signal {
	label := fresh_label(x.ip) // jq's _modify runs each path in a label
	old, sig := getpath(x.ip, x.cur, p)
	if sig != .Go {
		return sig
	}
	at := Item{v = old}
	if x.top != nil {
		same := identical(x.cur, x.top.v) && (identical(old, x.cur) || whole_slice(p, old, x.cur))
		at.path = x.top.path if same else &no_path
	}
	got, outputs, fsig := first_of(x.ip, label, x.n.b, at, x.env, x.top != nil)
	switch {
	case fsig != .Go:
		return fsig
	case outputs == 0:
		a := new_array(len(p))
		append(&a.items, ..p)
		append(&x.gone, a)
		x.gone_null = false
	case outputs == 1:
		x.cur, sig = setpath(x.ip, x.cur, p, got.v, x.owned)
	case:
		x.cur, sig = setpath(x.ip, nil, p, got.v, x.owned)
		clear(&x.gone)
		x.gone_null = true
	}
	return sig
}

// Whether `old` at path `p` in `v` is a slice of all of `v`, which jq's slice leaves the very array.
@(private = "file")
whole_slice :: proc(p: []Value, old, v: Value) -> bool {
	return len(p) == 1 && kind(p[0]) == .Object && kind(old) == .Array && kind(v) == .Array && length_of(old) > 0 && length_of(old) == length_of(v)
}

// Whether a reduce's update only writes into its state, so the state may change in place: an
// assignment to one path whose right side does not read `.`, `|=` on one path, `. + x` with `x` not
// reading `.` and chains of these (`. + x + y`), `setpath`, `delpaths` or `del`, a value that does not read
// `.`, and pipes and `if`s of these. A right side is single: with more outputs, jq stores the state each
// makes, so the last one's before an error is the state, and the first to fail is the error (`. + (1, "a", 2)`
// on 0). (A path expression with more outputs reads the state between updates.)
in_place_update :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .Update:
		return n.a.single && (n.op == .Modify || n.b.single && !reads_input(n.b))
	case .Binary:
		if n.op != .Add && n.op != .Mul || !n.b.single || reads_input(n.b) {
			return false
		}
		// Built one operand at a time, a chain's intermediate is the state's only holder, as jq's
		// reference counts find it, and grows in place too.
		return n.a.kind == .Identity || n.a.kind == .Binary && in_place_update(n.a)
	case .Identity, .Var, .Literal:
		return true
	case .Pipe:
		return n.a.single && in_place_update(n.a) && in_place_update(n.b)
	case .If:
		// The condition reads the state only to choose a branch.
		return n.a.single && in_place_update(n.b) && (n.c == nil || in_place_update(n.c))
	case .Call:
		// The paths are all made before anything is set or deleted, and only the value set is kept.
		switch path_call(n) {
		case "setpath":
			return n.args[0].single && n.args[1].single && !reads_input(n.args[1])
		case "delpaths":
			return n.args[0].single
		case "del":
			return true
		}
	}
	return false
}

// Whether each output of a reduce's update `n` is the state plus a value that does not read `.`: `. + (x, y)`
// or `. + x, . + y`. Only the last output reaches the state, so only it is made, in place (`add_last`).
adds_to_state :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .Binary:
		return n.op == .Add && n.a.kind == .Identity && !reads_input(n.b)
	case .Comma:
		return adds_to_state(n.a) && adds_to_state(n.b)
	}
	return false
}

// `adds_to_state`'s update: the state plus the last value added, each value before it only checked to add,
// in turn, as jq makes and drops each output. After an error the state is the last output before it.
add_last :: proc(ip: ^Interp, n: ^Node, state: Value, env: ^Env, owned: ^Owned) -> (v: Value, found: bool, sig: Signal) {
	last := Addend_Sink{sink = {emit = addend_emit}, ip = ip, state = state}
	sig = run_addends(ip, n, env, &last)
	if !last.found {
		return nil, false, sig
	}
	v, _ = add(ip, state, last.v, owned)
	return v, true, sig
}

@(private = "file")
run_addends :: proc(ip: ^Interp, n: ^Node, env: ^Env, s: ^Addend_Sink) -> Signal {
	if n.kind == .Comma {
		if sig := run_addends(ip, n.a, env, s); sig != .Go {
			return sig
		}
		return run_addends(ip, n.b, env, s)
	}
	return eval(ip, n.b, {v = s.state}, env, false, s)
}

@(private = "file")
Addend_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	state:      Value,
	v:          Value,
	found:      bool,
}

@(private = "file")
addend_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Addend_Sink)(s)
	if !addable(x.state, it.v) {
		_, sig := add(x.ip, x.state, it.v)
		return sig
	}
	x.v, x.found = it.v, true
	return .Go
}

// "setpath", "delpaths" or "del" for a call to that builtin, else "".
@(private = "file")
path_call :: proc(n: ^Node) -> string {
	if b, bound := n.native.?; bound && (b.fn == fn_setpath || b.fn == fn_delpaths) {
		return n.name
	}
	if n.name == "del" && len(n.args) == 1 && n.def != nil && n.def.in_prelude {
		return "del"
	}
	return ""
}

// A call `path_call` names, on `state` with the paths' containers it owns changed in place. The arguments run first,
// in order, as a builtin's do. `del(f)` is the prelude's `delpaths([path(f)])`.
@(private = "file")
update_by_call :: proc(ip: ^Interp, n: ^Node, state: Value, env: ^Env, owned: ^Owned) -> (v: Value, found: bool, sig: Signal) {
	input := Item{v = state}
	if path_call(n) == "del" {
		paths := new_array()
		s := Collect_Sink{sink = {emit = collect_emit}, into = &paths.items}
		if sig = native_path(ip, n, input, env, false, &s); sig != .Go {
			return nil, false, sig
		}
		v, sig = delpaths_value(ip, state, paths, owned)
		return v, true, sig
	}
	args: [2]Value
	for a, i in n.args {
		it: Item
		if it, found, sig = eval_single(ip, a, input, env, false); sig != .Go || !found {
			return nil, false, sig
		}
		args[i] = it.v
	}
	if n.name == "setpath" {
		v, sig = setpath_value(ip, state, args[0], args[1], owned)
	} else {
		v, sig = delpaths_value(ip, state, args[0], owned)
	}
	return v, true, sig
}

// jq's setpath/2 and delpaths/1 of a path or paths given as a value.
setpath_value :: proc(ip: ^Interp, v: Value, path: Value, nv: Value, owned: ^Owned) -> (Value, Signal) {
	if kind(path) != .Array {
		return nil, fail(ip, "Path must be specified as an array")
	}
	if length_of(path) > MAX_PATH_DEPTH {
		return nil, fail(ip, "Path too deep")
	}
	return setpath(ip, v, elements(path), nv, owned)
}

delpaths_value :: proc(ip: ^Interp, v: Value, paths: Value, owned: ^Owned) -> (Value, Signal) {
	if kind(paths) != .Array {
		return nil, fail(ip, "Paths must be specified as an array")
	}
	return delpaths(ip, v, elements(paths), owned)
}

// Whether `n`'s outputs can depend on its input `.`, conservative.
reads_input :: proc(n: ^Node) -> bool {
	if n == nil {
		return false
	}
	#partial switch n.kind {
	case .Literal, .Var:
		return false
	case .Field, .Iterate:
		return reads_input(n.a)
	case .Index, .Slice:
		return reads_input(n.a) || reads_input(n.b) || reads_input(n.c)
	case .Pipe:
		return reads_input(n.a)
	case .Comma, .Binary, .And, .Or, .Alt:
		return reads_input(n.a) || reads_input(n.b)
	case .Neg:
		return reads_input(n.a)
	case .Array:
		return reads_input(n.a)
	case .String, .Object:
		for p in n.args {
			if p == nil || reads_input(p) { // an object's `{"key"}` reads the input's member
				return true
			}
		}
		return false
	case .Format:
		return n.a == nil || reads_input(n.a)
	}
	return true
}

// One step of an in-place reduce or foreach (`in_place_update`): the new state, the update's last output,
// and whether it had one.
update_value :: proc(ip: ^Interp, n: ^Node, state: Value, env: ^Env, owned: ^Owned) -> (v: Value, found: bool, sig: Signal) {
	if n.kind == .Update && n.op == .Modify {
		v, sig = modify(ip, n, state, env, owned)
		return v, true, sig
	}
	#partial switch n.kind {
	case .Call:
		return update_by_call(ip, n, state, env, owned)
	case .Identity:
		return state, true, .Go
	case .Var, .Literal:
		it: Item
		it, found, sig = eval_single(ip, n, {v = state}, env, false)
		return it.v, found, sig
	case .Pipe:
		if v, found, sig = update_value(ip, n.a, state, env, owned); sig != .Go || !found {
			return
		}
		return update_value(ip, n.b, v, env, owned)
	case .If:
		cond: Item
		if cond, found, sig = eval_single(ip, n.a, {v = state}, env, false); sig != .Go || !found {
			return nil, false, sig
		}
		branch := n.b if truthy(cond.v) else n.c
		if branch == nil {
			return state, true, .Go
		}
		return update_value(ip, branch, state, env, owned)
	}
	// Only the last output of the right side counts, so none is kept but it.
	rhs := Last_Sink{sink = {emit = last_emit}}
	if sig = eval(ip, n.b, {v = state}, env, false, &rhs); sig != .Go || !rhs.found {
		return nil, false, sig
	}
	switch {
	case n.kind == .Update:
		v, sig = assign(ip, n, state, rhs.it.v, env, owned)
	case n.a.kind == .Binary:
		// The right operand runs first, as jq's arithmetic runs it outermost.
		if v, found, sig = update_value(ip, n.a, state, env, owned); sig != .Go || !found {
			return
		}
		v, sig = binary_op(ip, n.op, v, rhs.it.v, owned)
	case:
		v, sig = binary_op(ip, n.op, state, rhs.it.v, owned) // `. + x` or `. * x`
	}
	return v, true, sig
}

// The state of an in-place foreach as its extract sees it, and whether what the extract outputs must be
// checked for containers the update goes on to change (`holds_owned`). Under `. + x` an array state only
// grows, so the extract sees a copy of its header: the elements it has now, which no later append moves
// or changes, as the interpreter's values live in an arena, which frees no block a growing array leaves.
// A string state grows the same way (`append_owned`), and owns no container.
foreach_view :: proc(n: ^Node, state: Value) -> (Value, bool) {
	if n.kind != .Binary {
		return state, true
	}
	#partial switch x in state {
	case ^Array:
		view := new(Array)
		view.items = x.items
		// At its capacity, the view moves before anything appends to it, so it writes nothing into the state.
		(^runtime.Raw_Dynamic_Array)(&view.items).cap = len(x.items)
		return view, false
	case string:
		return state, false
	}
	return state, true
}

// Whether `v` is or holds a container in `owned`, or is too big to tell within `budget` members.
holds_owned :: proc(v: Value, owned: ^Owned, budget: ^int) -> bool {
	if p := container(v); p != nil && owned[p] {
		return true
	}
	members: []Value
	#partial switch x in v {
	case ^Array:
		members = x.items[:]
	case ^Object:
		members = x.vals[:]
	}
	for m in members {
		budget^ -= 1
		if budget^ < 0 || holds_owned(m, owned, budget) {
			return true
		}
	}
	return false
}

// The code points of the first `counted` bytes of an owned buffer, left by `length` so that a state that
// grows by `+` is counted from where it was last, not from its start. The bytes below a string's length never
// change, and a buffer made anew clears it, for the old one's address may be handed out again.
Text_Count :: struct {
	p:       rawptr,
	counted: int,
	points:  int,
}

// `codepoints(s)`, counting only what `ip.text` has not, if `s` is a buffer of the update running.
owned_codepoints :: proc(ip: ^Interp, s: string) -> int {
	p := raw_data(s)
	if len(s) == 0 || ip.owned == nil || !ip.owned[p] {
		return codepoints(s)
	}
	t := &ip.text
	if t.p != p || t.counted > len(s) {
		t^ = {p = p}
	}
	t.points += codepoints(s[t.counted:])
	t.counted = len(s)
	return t.points
}

// `s + t` written into `s`'s buffer when this `owned` set made it, so a run of adds copies each byte
// a constant number of times rather than once per add. A buffer made here holds `owned_size(len)`
// bytes, which the string's own length tells again after any append into it: the length only grows,
// and never past the size. Writing past the end of `s` changes no string an earlier add returned,
// since each still ends where it did.
append_owned :: proc(ip: ^Interp, s, t: string, owned: ^Owned) -> string {
	if len(t) == 0 {
		return s
	}
	n := len(s) + len(t)
	if p := raw_data(s); p != nil && owned[p] && n <= owned_size(len(s)) {
		buf := ([^]u8)(p)
		copy(buf[len(s):n], t)
		return string(buf[:n])
	}
	ip.text = {}
	buf := make([]u8, owned_size(n))
	copy(buf, s)
	copy(buf[len(s):], t)
	delete_key(owned, raw_data(s))
	owned[raw_data(buf)] = true
	return string(buf[:n])
}

@(private = "file")
owned_size :: proc(n: int) -> int {
	return max(16, math.next_power_of_two(n))
}
