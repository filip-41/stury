package jq

import "base:runtime"
import "core:math"
import "core:slice"

// Path tracking: the path an output was read at, kept beside it while a path expression runs.

extend :: proc(p: ^Path_Step, key: Value) -> ^Path_Step {
	s := new(Path_Step)
	s.parent, s.key, s.depth = p, key, 1 + p.depth if p != nil else 1
	return s
}

path_array :: proc(p: ^Path_Step) -> ^Array {
	n := p.depth if p != nil else 0
	a := new_array(n)
	resize(&a.items, n)
	for s := p; s != nil; s = s.parent {
		n -= 1
		a.items[n] = s.key
	}
	return a
}

PATH_KEYS_ON_STACK :: 32

// `compare` of two arrays one of which is a path, whose keys are read into the stack or a heap block that
// is freed on return, as a sort compares paths often and an arena frees no block.
@(cold)
compare_path_members :: proc(a, b: Value, depth: int, eq: bool) -> int {
	bufs: [2][PATH_KEYS_ON_STACK]Value
	xs: [2][]Value
	for v, i in ([2]Value{a, b}) {
		if p, is_path := v.(Path); is_path {
			s := (^Path_Step)(p)
			xs[i] = bufs[i][:s.depth] if s.depth <= PATH_KEYS_ON_STACK else make([]Value, s.depth, runtime.heap_allocator())
			for n := s.depth; s != nil; s = s.parent {
				n -= 1
				xs[i][n] = s.key
			}
		} else {
			xs[i] = elements(v)
		}
	}
	defer for v, i in ([2]Value{a, b}) {
		if _, is_path := v.(Path); is_path && len(xs[i]) > PATH_KEYS_ON_STACK {
			delete(xs[i], runtime.heap_allocator())
		}
	}
	return compare_items(xs[0], xs[1], depth, eq)
}

// The path as a value that reads as its array of keys without making it.
path_value :: proc(p: ^Path_Step) -> Value {
	return Path(p) if p != nil else path_array(nil)
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

pathless :: proc(p: ^Path_Step) -> bool {
	return p == &no_path || p != nil && p.parent == &no_path
}

state_of :: proc(it: Item) -> Path_State {
	if it.path != nil && it.path.parent == &no_path {
		return {(^Detached)(it.path).path, it.path.key}
	}
	return {it.path, it.v}
}

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
	case Path:
		y, is_path := b.(Path)
		return is_path && x == y
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
path_of :: proc(ip: ^Interp, it: Item) -> (^Path_Step, Signal) {
	if pathless(it.path) {
		return nil, fail(ip, "Invalid path expression with result %s", brief(it.v))
	}
	return it.path, .Go
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

// Paths as data: getpath, setpath and delpaths. Values are shared, so a change copies each container on
// its way down; an `Owned` set names the containers one update already copied, which it may then change
// in place: `.[] |= f` copies its array once, not once per element, and a reduce whose update only
// writes into its state keeps one set for the whole reduction.
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
@(private)
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
	if len(path) == 1 && indexes_without_error(v, key) {
		return set_key(ip, v, key, nv, owned)
	}
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

// Whether `index_value` of `t` at `key` cannot fail: a string key in an object, a number in an array.
@(private = "file")
indexes_without_error :: proc(t: Value, key: Value) -> bool {
	tk, kk := kind(t), kind(key)
	return tk == .Object && kk == .String || tk == .Array && kk == .Number
}

// What jq's jv_set of null at `key` in `t` refuses, which jv_setpath tries before it descends (a slice's
// key it sets only after).
@(private = "file")
set_refused :: proc(ip: ^Interp, t: Value, key: Value, owned: ^Owned) -> Signal {
	tk := kind(t)
	switch kind(key) {
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
	case .Null, .False, .True, .Array:
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
	switch kind(key) {
	case .String:
		if tk == .Object || tk == .Null {
			k, _ := string_of(key)
			o: ^Object
			if tk == .Null {
				o = new_object()
				owned[o] = true
			} else {
				o = owned_copy(t, owned).(^Object)
			}
			object_put(o, k, v)
			return o, .Go
		}
	case .Number:
		if tk == .Array || tk == .Null {
			i, sig := array_set_index(ip, length_of(t), key)
			if sig != .Go {
				return nil, sig
			}
			a: ^Array
			if tk == .Null {
				a = new_array()
				owned[a] = true
			} else {
				a = owned_copy(t, owned).(^Array)
			}
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
	case .Null, .False, .True, .Array:
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
	switch kind(t) {
	case .Array:
		a := owned_copy(t, owned).(^Array)
		n := len(a.items)
		// The index ranges deleted, as many as the keys, not the elements: a reduce deleting one at a
		// time from a long array would otherwise take memory for each element at each step.
		gone := make([dynamic][2]int, 0, len(keys))
		for key in keys {
			switch kind(key) {
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
			case .Null, .False, .True, .String, .Array:
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
	case .Null, .False, .True, .Number, .String:
	}
	return nil, fail(ip, "Cannot delete fields from %s", type_name(t))
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
