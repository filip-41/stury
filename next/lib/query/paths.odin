package query

import "core:math"

// Reads and changes at paths: a path is an array of steps, each a member's key, an element's index or a slice
// `{"start": a, "end": b}`. Null reads as nothing at every path and grows into what a change at a path needs.

// `t[key]`: a member of an object by a string, an element of an array by a number rounded down, from the end when
// negative, the places of a subarray by an array, a slice by `{"start", "end"}`, and null for anything of null. Absent
// past an array's ends and for a missing member reads as null.
@(require_results)
get :: proc(h: ^Heap, t, key: Value) -> (res: Value, status: Status) {
	tt, kt := type_of(t), type_of(key)
	if kt == .Object {
		if kind, is_attr, is_fact := fact_step(h, key); is_fact {
			if is_attr {
				an := fact_step_attr(h, key) or_return
				defer release(h, an)
				return fact_read(h, t, .Attribute, text_of(an), true)
			}
			return fact_read(h, t, kind)
		}
		if unk, is_unk := unknown_fact_step(h, key); is_unk {
			defer release(h, unk)
			return NULL, fail_unknown_fact(h, text_of(unk))
		}
	}
	switch {
	case tt == .Object && kt == .String:
		v := member(h, t, text_of(key)) or_return
		return v if v.kind != .Absent else NULL, .Ok
	case tt == .Array && kt == .Number:
		i, ok := element_index(key)
		if !ok {
			return NULL, .Ok
		}
		v := element(h, t, i) or_return
		return v if v.kind != .Absent else NULL, .Ok
	case (tt == .Null || tt == .Absent) && (kt == .String || kt == .Number || kt == .Object):
		return NULL, .Ok
	case tt == .Array && kt == .Array:
		return places_of(h, t, key)
	case (tt == .Array || tt == .String) && kt == .Object:
		from, to := slice_key(h, key) or_return
		defer release(h, from)
		defer release(h, to)
		return slice(h, t, from, to)
	}
	return NULL, fail(h, .Types, .Index, t, key)
}

// The element index number `key` names, rounded down, or false past what an index can be.
@(private)
element_index :: proc(key: Value) -> (int, bool) {
	if i, ok := as_i64(key); ok {
		return int(clamp(i, -(1 << 53), 1 << 53)), true
	}
	f := as_f64(key)
	if math.is_nan(f) || f > 1e15 || f < -1e15 {
		return 0, false
	}
	return int(math.floor(f)), true
}

// Whether number `key` is an index past what an array holds, a double too large for `element_index` included.
@(private)
index_past_limit :: proc(key: Value) -> bool {
	i, ok := element_index(key)
	f := as_f64(key)
	return i > MAX_INDEX || !ok && f > 0 && !math.is_nan(f)
}

// The bounds of a slice step, each a number or null.
@(private)
slice_key :: proc(h: ^Heap, key: Value) -> (from, to: Value, status: Status) {
	from = member(h, key, "start") or_return
	to = member(h, key, "end") or_return
	for x in ([]Value{from, to}) {
		if t := type_of(x); t != .Number && t != .Null {
			release(h, from)
			release(h, to)
			return NULL, NULL, fail(h, .Types, .Slice, key, x)
		}
	}
	return from, to, .Ok
}

// The places in array `t` where array `sub`, not empty, starts.
@(private, require_results)
places_of :: proc(h: ^Heap, t, sub: Value) -> (res: Value, status: Status) {
	a := built(h, t) or_return
	defer release(h, a)
	b := built(h, sub) or_return
	defer release(h, b)
	xs, ys := items_of(a), items_of(b)
	out := make_array(h, 0) or_return
	defer if status != .Ok {
		release(h, out)
	}
	if len(ys) == 0 {
		return out, .Ok
	}
	for i in 0 ..= len(xs) - len(ys) {
		same := true
		for y, j in ys {
			eq := equal(h, xs[i + j], y) or_return
			if !eq {
				same = false
				break
			}
		}
		if same {
			append_owned(h, &out, int_value(i64(i))) or_return
		}
	}
	return out, .Ok
}

// `t[from:to]` of an array or a string, the bounds null for its ends, the start rounded down and the end up, each from
// the end when negative. Null for null.
@(require_results)
slice :: proc(h: ^Heap, t, from, to: Value) -> (res: Value, status: Status) {
	tt := type_of(t)
	if tt == .Null || tt == .Absent {
		return NULL, .Ok
	}
	ft, tot := type_of(from), type_of(to)
	if tt != .Array && tt != .String {
		step, ms := make_object(h, 2)
		if ms != .Ok {
			return NULL, ms
		}
		defer release(h, step)
		object_put(h, &step, text_borrowed("start"), retain(from) if from.kind != .Absent else NULL) or_return
		object_put(h, &step, text_borrowed("end"), retain(to) if to.kind != .Absent else NULL) or_return
		return NULL, fail(h, .Types, .Index, t, step)
	}
	if ft != .Number && ft != .Null && ft != .Absent || tot != .Number && tot != .Null && tot != .Absent {
		return NULL, fail(h, .Types, .Slice, t, from if ft != .Number && ft != .Null && ft != .Absent else to)
	}
	n := length_of(h, t) if tt == .Array else codepoint_count(text_of(t))
	lo, hi := slice_bounds(from, to, n)
	if tt == .String {
		return text_slice(h, t, lo, hi)
	}
	if lo == 0 && hi == n && !value_has_partial(t) {
		return retain(t), .Ok
	}
	out := make_array(h, hi - lo) or_return
	defer if status != .Ok {
		release(h, out)
	}
	for i in lo ..< hi {
		x := element(h, t, i) or_return
		append_owned(h, &out, x) or_return
	}
	return out, .Ok
}

// The range a slice from `from` to `to` takes of `n` children, clamped.
@(private)
slice_bounds :: proc(from, to: Value, n: int) -> (lo, hi: int) {
	bound :: proc(v: Value, n: int, end: bool) -> int {
		x := as_f64(v)
		if math.is_nan(x) {
			x = f64(n) if end else 0
		}
		if x < 0 {
			x += f64(n)
		}
		x = math.ceil(x) if end else math.floor(x)
		return int(clamp(x, 0, f64(n)))
	}
	lo, hi = 0, n
	if type_of(from) == .Number {
		lo = bound(from, n, false)
	}
	if type_of(to) == .Number {
		hi = bound(to, n, true)
	}
	return lo, max(lo, hi)
}

// The value at `path`, an array of steps, in `v`.
@(require_results)
get_path :: proc(h: ^Heap, v, path: Value) -> (res: Value, status: Status) {
	if type_of(path) != .Array {
		return NULL, fail(h, .Types, .Get_Path, path)
	}
	keys := built(h, path) or_return
	defer release(h, keys)
	if len(items_of(keys)) > depth_limit(h) {
		return NULL, fail(h, .Depth, .Get_Path)
	}
	validate_path_facts(h, items_of(keys)) or_return
	cur := retain(v)
	for k in items_of(keys) {
		if t := type_of(cur); t == .Null || t == .Absent {
			release(h, cur)
			return NULL, .Ok
		}
		next, s := get(h, cur, k)
		release(h, cur)
		if s != .Ok {
			return NULL, s
		}
		cur = next
	}
	return cur, .Ok
}

// `v`, taken, with the value at `path` set to `x`, taken: containers along the path that are not there are made, and
// a container the caller alone holds changes in place.
@(require_results)
set_path :: proc(h: ^Heap, v, path, x: Value) -> (res: Value, status: Status) {
	if type_of(path) != .Array {
		release(h, v)
		release(h, x)
		return NULL, fail(h, .Types, .Set_Path, path)
	}
	keys_v, ks := built(h, path)
	if ks != .Ok {
		release(h, v)
		release(h, x)
		return NULL, ks
	}
	defer release(h, keys_v)
	keys := items_of(keys_v)
	if len(keys) > depth_limit(h) {
		release(h, v)
		release(h, x)
		return NULL, fail(h, .Depth, .Set_Path)
	}
	if fs := validate_path_facts(h, keys); fs != .Ok {
		release(h, v)
		release(h, x)
		return NULL, fs
	}
	if len(keys) == 0 {
		release(h, v)
		return x, .Ok
	}
	if len(keys) == 1 {
		return set(h, v, keys[0], x)
	}
	// Each container on the way down has its child taken out, so the child is held once and changes in place.
	chain_buf: [16]Value
	chain_n := 0
	chain_dyn: [dynamic]Value
	defer delete(chain_dyn)
	cur := v
	s := Status.Ok
	_, _, last_is_fact := fact_step(h, keys[len(keys) - 1])
	for k in keys[:len(keys) - 1] {
		child: Value
		if type_of(k) == .Number && (type_of(cur) == .Array || type_of(cur) == .Null || type_of(cur) == .Absent) {
			// An index past the limit is refused before a key further down is looked at.
			if index_past_limit(k) {
				s = fail(h, .Range, .Set_Path, cur, k, "Array index too large")
				break
			}
		}
		child, s = get(h, cur, k)
		if s == .Ok && !last_is_fact && cur.kind != .Overlay && type_of(k) != .Object && type_of(cur) != .Null && type_of(cur) != .Absent {
			cur, s = set(h, cur, k, NULL)
		}
		if s != .Ok {
			release(h, child)
			break
		}
		if chain_n < len(chain_buf) && len(chain_dyn) == 0 {
			chain_buf[chain_n] = cur
			chain_n += 1
		} else {
			if chain_dyn.allocator.procedure == nil {
				chain_dyn = make([dynamic]Value, 0, len(keys), h.allocator)
				if _, err := append(&chain_dyn, ..chain_buf[:chain_n]); err != nil {
					release(h, cur)
					release(h, child)
					s = fail_memory(h)
					break
				}
				chain_n = 0
			}
			if _, err := append(&chain_dyn, cur); err != nil {
				release(h, cur)
				release(h, child)
				s = fail_memory(h)
				break
			}
		}
		cur = child
	}
	chain := chain_dyn[:] if len(chain_dyn) > 0 else chain_buf[:chain_n]
	if s == .Ok {
		cur, s = set(h, cur, keys[len(keys) - 1], x, len(chain))
	} else {
		release(h, cur)
		release(h, x)
	}
	#reverse for parent, i in chain {
		if s != .Ok {
			release(h, parent)
			continue
		}
		cur, s = set(h, parent, keys[i], cur, i)
	}
	if s != .Ok {
		return NULL, s
	}
	return cur, .Ok
}

// `t`, taken, with `t[key]` set to `x`, taken (single-step `set_path` without allocating a path array).
@(require_results)
set_one :: proc(h: ^Heap, t, key, x: Value) -> (res: Value, status: Status) {
	return set(h, t, key, x, 0)
}

// `t`, taken, without `t[key]` (single-step `del_paths` without allocating a path array).
@(require_results)
del_one :: proc(h: ^Heap, t, key: Value) -> (res: Value, status: Status) {
	ks := [1]Value{key}
	return del_keys(h, t, ks[:], 0)
}

// `t`, taken, with `t[key]` set to `x`, taken.
@(private, require_results)
set :: proc(h: ^Heap, t, key, x: Value, overlay_depth := 0) -> (res: Value, status: Status) {
	tt, kt := type_of(t), type_of(key)
	out := t
	s := Status.Ok
	switch {
	case (tt == .Object || tt == .Null || tt == .Absent) && kt == .String:
		if t.kind == .Overlay && tt == .Object {
			same_ov := 1 if (x.kind == .Overlay && x.p == t.p) else 0
			if overlay_is_unique(t, overlay_depth + same_ov) {
				return overlay_set_member(h, t, text_of(key), x)
			}
			// Shared/aliased `.Overlay`: COW-materialize before mutating so aliases stay untouched!
			out, s = overlay_built(h, t)
			release(h, t)
		} else if tt != .Object {
			release(h, t)
			out, s = make_object(h, 1)
		} else if t.kind == .Node {
			out, s = built(h, t)
			release(h, t)
		}
		if s == .Ok {
			ps := object_put(h, &out, retain(key), x)
			if ps != .Ok {
				release(h, out)
				return NULL, ps
			}
			return out, .Ok
		}
	case (tt == .Array || tt == .Null || tt == .Absent) && kt == .Number:
		i, _ := element_index(key)
		if math.is_nan(as_f64(key)) {
			s = fail(h, .Range, .Set_Path, out, key, "Cannot set array element at NaN index")
		}
		if s == .Ok && i < 0 {
			i += length_of(h, out)
			if i < 0 {
				s = fail(h, .Range, .Set_Path, out, key, "Out of bounds negative array index")
			}
		}
		if s == .Ok && index_past_limit(key) {
			s = fail(h, .Range, .Set_Path, out, key, "Array index too large")
		}
		if s == .Ok && t.kind == .Overlay && tt == .Array {
			same_ov := 1 if (x.kind == .Overlay && x.p == t.p) else 0
			if overlay_is_unique(t, overlay_depth + same_ov) {
				return overlay_set_element(h, t, i, x)
			}
			out, s = overlay_built(h, t)
			release(h, t)
		} else if s == .Ok {
			if tt != .Array {
				release(h, t)
				out, s = make_array(h, 1)
			} else if t.kind == .Node {
				out, s = built(h, t)
				release(h, t)
			}
		}
		if s == .Ok {
			ps := array_put(h, &out, i, x)
			if ps != .Ok {
				release(h, out)
				return NULL, ps
			}
			return out, .Ok
		}
	case kt == .Object:
		if kind, is_attr, is_fact := fact_step(h, key); is_fact {
			if is_attr {
				an, as := fact_step_attr(h, key)
				if as != .Ok {
					release(h, out)
					release(h, x)
					return NULL, as
				}
				defer release(h, an)
				return fact_write(h, out, .Attribute, text_of(an), true, x)
			}
			return fact_write(h, out, kind, "", false, x)
		}
		if unk, is_unk := unknown_fact_step(h, key); is_unk {
			defer release(h, unk)
			release(h, out)
			release(h, x)
			return NULL, fail_unknown_fact(h, text_of(unk))
		}
		if tt == .Array || tt == .Null || tt == .Absent {
			return set_slice(h, t, key, x)
		}
		if tt == .String {
			from, to, ks := slice_key(h, key)
			if ks == .Ok {
				release(h, from)
				release(h, to)
				s = fail(h, .Types, .Set_Path, t, key, "Cannot update string slices")
			} else {
				s = ks
			}
		} else {
			s = fail(h, .Types, .Index, t, key)
		}
	case tt == .Array && kt == .Array:
		s = fail(h, .Types, .Set_Path, t, key, "Cannot update field at array index of array")
	case:
		s = fail(h, .Types, .Index, t, key)
	}
	release(h, out)
	release(h, x)
	return NULL, s
}

// Array `t`, taken, with the slice step `key` names replaced by array `x`, taken.
@(private)
set_slice :: proc(h: ^Heap, t, key, x: Value) -> (res: Value, status: Status) {
	defer release(h, t)
	defer release(h, x)
	from, to := slice_key(h, key) or_return
	defer release(h, from)
	defer release(h, to)
	if type_of(x) != .Array {
		return NULL, fail(h, .Types, .Set_Path, t, x, "A slice of an array can only be assigned another array")
	}
	n := length_of(h, t) if type_of(t) == .Array else 0
	lo, hi := slice_bounds(from, to, n)
	out := make_array(h, n - (hi - lo) + length_of(h, x)) or_return
	add :: proc(h: ^Heap, out: ^Value, from: Value, lo, hi: int) -> Status {
		for i in lo ..< hi {
			v := element(h, from, i) or_return
			append_owned(h, out, v) or_return
		}
		return .Ok
	}
	s := add(h, &out, t, 0, lo)
	if s == .Ok {
		s = add(h, &out, x, 0, length_of(h, x))
	}
	if s == .Ok {
		s = add(h, &out, t, hi, n)
	}
	if s != .Ok {
		release(h, out)
		return NULL, s
	}
	return out, .Ok
}

// `v`, taken, without the values at each of `paths`, an array of paths. The paths are sorted, and those that share a
// first step delete under it together, so the indexes of one array all count from the array before any deletion.
@(require_results)
del_paths :: proc(h: ^Heap, v, paths: Value) -> (res: Value, status: Status) {
	if type_of(paths) != .Array {
		release(h, v)
		return NULL, fail(h, .Types, .Delete_Paths, paths)
	}
	ps, s := built(h, paths)
	if s == .Ok {
		s = own_array(h, &ps, 0)
	}
	if s == .Ok {
		s = sort_values(h, items_of(ps))
	}
	defer release(h, ps)
	if s != .Ok {
		release(h, v)
		return NULL, s
	}
	lists := make([dynamic]Value, 0, len(items_of(ps)), heap_allocator(h))
	defer {
		for l in lists {
			release(h, l)
		}
		delete(lists)
	}
	for p in items_of(ps) {
		if type_of(p) != .Array {
			release(h, v)
			return NULL, fail(h, .Types, .Delete_Paths, p, detail = "path")
		}
		l, ls := built(h, p)
		if ls != .Ok {
			release(h, v)
			return NULL, ls
		}
		if len(items_of(l)) == 0 {
			release(h, l)
			release(h, v)
			return NULL, .Ok
		}
		if len(items_of(l)) > depth_limit(h) {
			release(h, l)
			release(h, v)
			return NULL, fail(h, .Depth, .Delete_Paths)
		}
		if fs := validate_path_facts(h, items_of(l)); fs != .Ok {
			release(h, l)
			release(h, v)
			return NULL, fs
		}
		if _, err := append(&lists, l); err != nil {
			release(h, l)
			release(h, v)
			return NULL, fail_memory(h)
		}
	}
	return del_sorted(h, v, lists[:])
}

// `v`, taken, without the values at `paths`, sorted and none empty, with no recursion: a frame for each container on
// the way down deletes its children at the paths that end there and changes the others' in turn.
@(private)
del_sorted :: proc(h: ^Heap, v: Value, paths: []Value) -> (res: Value, status: Status) {
	Del_Frame :: struct {
		out:   Value, // owned, the container being changed
		paths: []Value, // the paths below it, alike in their steps down to it
		depth: int, // its level: each path's step `depth` names one of its children
		i:     int, // the first path not done
		j:     int, // past the paths of the child being changed below it
		key:   Value, // that child's step
		keys:  [dynamic]Value, // the children to delete, at the paths that end at them
	}
	alloc := heap_allocator(h)
	stack := make([dynamic]Del_Frame, 0, 8, alloc)
	defer {
		for &f in stack {
			release(h, f.out)
			delete(f.keys)
		}
		delete(stack)
	}
	if _, err := append(&stack, Del_Frame{out = v, paths = paths, keys = make([dynamic]Value, alloc)}); err != nil {
		release(h, v)
		return NULL, fail_memory(h)
	}
	for {
		f := &stack[len(stack) - 1]
		if f.i >= len(f.paths) {
			done, s := del_keys(h, f.out, f.keys[:], len(stack) - 1)
			delete(f.keys)
			pop(&stack)
			if s != .Ok {
				return NULL, s
			}
			if len(stack) == 0 {
				return done, .Ok
			}
			up := &stack[len(stack) - 1]
			up.out, s = set(h, up.out, up.key, done, len(stack) - 1)
			if s != .Ok {
				up.out = NULL
				return NULL, s
			}
			up.i = up.j
			continue
		}
		key := items_of(f.paths[f.i])[f.depth]
		whole := len(items_of(f.paths[f.i])) == f.depth + 1
		j := f.i + 1
		for j < len(f.paths) {
			same := equal(h, key, items_of(f.paths[j])[f.depth]) or_return
			if !same {
				break
			}
			j += 1
		}
		if whole {
			if _, err := append(&f.keys, key); err != nil {
				return NULL, fail_memory(h)
			}
			f.i = j
			continue
		}
		sub := get(h, f.out, key) or_return
		if t := type_of(sub); t == .Null || t == .Absent {
			release(h, sub)
			f.i = j
			continue
		}
		f.key, f.j = key, j
		below := Del_Frame{out = sub, paths = f.paths[f.i:j], depth = f.depth + 1, keys = make([dynamic]Value, alloc)}
		if _, err := append(&stack, below); err != nil {
			release(h, sub)
			return NULL, fail_memory(h)
		}
	}
}

// `t`, taken, without its children at `keys`: indexes and slices of an array, all counted from `t` as it is, or keys
// of an object.
@(private)
del_keys :: proc(h: ^Heap, t: Value, keys: []Value, overlay_depth := 0) -> (res: Value, status: Status) {
	if len(keys) == 0 {
		return t, .Ok
	}
	// Handle fact-step deletions (`del(.a.@comment)`, `del(.r.&k)`) separately from container member/element deletions.
	has_fact := false
	for k in keys {
		if _, _, is_fact := fact_step(h, k); is_fact {
			has_fact = true
			break
		}
	}
	if has_fact {
		rest := make([dynamic]Value, 0, len(keys), heap_allocator(h))
		facts := make([dynamic]Value, 0, len(keys), heap_allocator(h))
		defer delete(rest)
		defer delete(facts)
		for k in keys {
			if _, _, is_fact := fact_step(h, k); is_fact {
				if _, err := append(&facts, k); err != nil {
					release(h, t)
					return NULL, fail_memory(h)
				}
			} else {
				if _, err := append(&rest, k); err != nil {
					release(h, t)
					return NULL, fail_memory(h)
				}
			}
		}
		cur := t
		if len(rest) > 0 {
			cur = del_keys(h, cur, rest[:], overlay_depth) or_return
		}
		for fk in facts {
			kind, is_attr, _ := fact_step(h, fk)
			if is_attr {
				an, as := fact_step_attr(h, fk)
				if as != .Ok {
					release(h, cur)
					return NULL, as
				}
				defer release(h, an)
				cur = fact_write(h, cur, .Attribute, text_of(an), true, NULL) or_return
			} else {
				cur = fact_write(h, cur, kind, "", false, NULL) or_return
			}
		}
		return cur, .Ok
	}
	#partial switch type_of(t) {
	case .Null, .Absent:
		return t, .Ok
	case .Object:
		if t.kind == .Overlay && overlay_is_unique(t, overlay_depth) {
			return overlay_del_members(h, t, keys)
		}
		out := t
		if t.kind == .Node || t.kind == .Overlay {
			bs: Status
			out, bs = built(h, t)
			release(h, t)
			if bs != .Ok {
				return NULL, bs
			}
		}
		defer if status != .Ok {
			release(h, out)
		}
		for k in keys {
			if type_of(k) != .String {
				return NULL, fail(h, .Types, .Delete_Paths, out, k, "field of object")
			}
		}
		object_delete_many(h, &out, keys) or_return
		return out, .Ok
	case .Array:
		n := length_of(h, t)
		alloc := heap_allocator(h)
		gone := make([]bool, n, alloc)
		if gone == nil && n > 0 {
			release(h, t)
			return NULL, fail_memory(h)
		}
		defer delete(gone, alloc)
		for k in keys {
			#partial switch type_of(k) {
			case .Number:
				i, ok := element_index(k)
				if ok && i < 0 {
					i += n
				}
				if ok && i >= 0 && i < n {
					gone[i] = true
				}
			case .Object:
				from, to, s := slice_key(h, k)
				if s != .Ok {
					release(h, t)
					return NULL, s
				}
				lo, hi := slice_bounds(from, to, n)
				release(h, from)
				release(h, to)
				for i in lo ..< hi {
					gone[i] = true
				}
			case:
				s := fail(h, .Types, .Delete_Paths, t, k, "element of array")
				release(h, t)
				return NULL, s
			}
		}
		if t.kind == .Overlay && overlay_is_unique(t, overlay_depth) {
			return overlay_del_elements(h, t, gone)
		}
		out, s := make_array(h, n)
		for i in 0 ..< n {
			if s != .Ok {
				break
			}
			if !gone[i] {
				x: Value
				x, s = element(h, t, i)
				if s == .Ok {
					s = append_owned(h, &out, x)
				}
			}
		}
		release(h, t)
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
		return out, .Ok
	}
	s := fail(h, .Types, .Delete_Paths, t, keys[0], "fields from")
	release(h, t)
	return NULL, s
}

// The greatest index a change at a path may make an array reach.
@(private)
MAX_INDEX :: 1 << 29 - 1
