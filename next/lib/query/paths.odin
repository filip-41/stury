package query

import "core:math"

// Reads and changes at paths: steps are member keys, array indexes, or slices `{"start", "end"}`.

@(private = "file")
write_fact_step :: proc(h: ^Heap, t, key, x: Value, overlay_depth: int) -> (res: Value, handled: bool, status: Status) {
	if kind, is_attr, is_fact := fact_step(h, key); is_fact {
		if is_attr {
			an, as := fact_step_attr(h, key)
			if as != .Ok {
				release(h, t)
				release(h, x)
				return NULL, true, as
			}
			defer release(h, an)
			res, status = fact_write(h, t, .Attribute, text_of(an), true, x, overlay_depth)
			return res, true, status
		}
		res, status = fact_write(h, t, kind, "", false, x, overlay_depth)
		return res, true, status
	}
	if unk, is_unk := unknown_fact_step(h, key); is_unk {
		defer release(h, unk)
		release(h, t)
		release(h, x)
		return NULL, true, fail_unknown_fact(h, text_of(unk))
	}
	return ABSENT, false, .Ok
}

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

@(private)
index_past_limit :: proc(key: Value) -> bool {
	i, ok := element_index(key)
	f := as_f64(key)
	return i > MAX_INDEX || (!ok && f > 0 && !math.is_nan(f))
}

@(private)
slice_key :: proc(h: ^Heap, key: Value) -> (from, to: Value, status: Status) {
	from = member(h, key, "start") or_return
	to = member(h, key, "end") or_return
	for x in ([2]Value{from, to}) {
		if t := type_of(x); t != .Number && t != .Null {
			release(h, from)
			release(h, to)
			return NULL, NULL, fail(h, .Types, .Slice, key, x)
		}
	}
	return from, to, .Ok
}

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
			if !(equal(h, xs[i + j], y) or_return) {
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

@(require_results)
slice :: proc(h: ^Heap, t, from, to: Value) -> (res: Value, status: Status) {
	tt := type_of(t)
	if tt == .Null || tt == .Absent {
		return NULL, .Ok
	}
	ft, tot := type_of(from), type_of(to)
	if tt != .Array && tt != .String {
		step := make_object(h, 2) or_return
		defer release(h, step)
		object_put(h, &step, text_borrowed("start"), retain(from) if from.kind != .Absent else NULL) or_return
		object_put(h, &step, text_borrowed("end"), retain(to) if to.kind != .Absent else NULL) or_return
		return NULL, fail(h, .Types, .Index, t, step)
	}
	bad_bound :: proc(bt: Type) -> bool { return bt != .Number && bt != .Null && bt != .Absent }
	if bad_bound(ft) || bad_bound(tot) {
		return NULL, fail(h, .Types, .Slice, t, from if bad_bound(ft) else to)
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
		append_owned(h, &out, element(h, t, i) or_return) or_return
	}
	return out, .Ok
}

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
		return int(clamp(math.ceil(x) if end else math.floor(x), 0, f64(n)))
	}
	lo = bound(from, n, false) if type_of(from) == .Number else 0
	hi = bound(to, n, true) if type_of(to) == .Number else n
	return lo, max(lo, hi)
}

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
	defer if status != .Ok {
		release(h, cur)
	}
	for k in items_of(keys) {
		if t := type_of(cur); t == .Null || t == .Absent {
			release(h, cur)
			return NULL, .Ok
		}
		next := get(h, cur, k) or_return
		release(h, cur)
		cur = next
	}
	return cur, .Ok
}

@(private = "file")
overlay_item_refs :: proc "contextless" (item: Value, target_p: rawptr) -> int {
	if item.kind == .Overlay && item.p == target_p {
		return 1
	}
	if item.kind == .Array {
		count := 0
		for el in items_of(item) {
			count += int(el.kind == .Overlay && el.p == target_p)
		}
		return count
	}
	return 0
}

@(private = "file")
overlay_chain_refs :: proc "contextless" (chain: []Value, target_p: rawptr) -> int {
	if target_p == nil {
		return 0
	}
	count := 0
	for item in chain {
		count += overlay_item_refs(item, target_p)
	}
	return count
}

@(require_results)
set_path :: proc(h: ^Heap, v, path, x: Value) -> (res: Value, status: Status) {
	fail_vx :: proc(h: ^Heap, v, x: Value, s: Status) -> (Value, Status) {
		release(h, v)
		release(h, x)
		return NULL, s
	}
	if type_of(path) != .Array {
		return fail_vx(h, v, x, fail(h, .Types, .Set_Path, path))
	}
	keys_v, ks := built(h, path)
	if ks != .Ok {
		return fail_vx(h, v, x, ks)
	}
	defer release(h, keys_v)
	keys := items_of(keys_v)
	if len(keys) > depth_limit(h) {
		return fail_vx(h, v, x, fail(h, .Depth, .Set_Path))
	}
	if fs := validate_path_facts(h, keys); fs != .Ok {
		return fail_vx(h, v, x, fs)
	}
	if len(keys) == 0 {
		release(h, v)
		return x, .Ok
	}
	cur_root := v
	if cur_root.kind == .Overlay {
		cs: Status
		cur_root, cs = ensure_unique_overlay(h, cur_root, int(x.kind == .Overlay && x.p == cur_root.p))
		if cs != .Ok {
			release(h, x)
			return NULL, cs
		}
	}
	if len(keys) == 1 {
		return set(h, cur_root, keys[0], x)
	}
	chain_buf: [16]Value
	chain_n := 0
	chain_dyn: [dynamic]Value
	defer delete(chain_dyn)
	cur, s := cur_root, Status.Ok
	_, _, last_is_fact := fact_step(h, keys[len(keys) - 1])
	for k in keys[:len(keys) - 1] {
		child: Value
		if type_of(k) == .Number && (type_of(cur) == .Array || type_of(cur) == .Null || type_of(cur) == .Absent) && index_past_limit(k) {
			s = fail(h, .Range, .Set_Path, cur, k, "Array index too large")
			break
		}
		if cur.kind == .Overlay {
			chain_so_far := chain_dyn[:] if len(chain_dyn) > 0 else chain_buf[:chain_n]
			cur, s = ensure_unique_overlay(h, cur, overlay_chain_refs(chain_so_far, cur.p))
			if s != .Ok {
				break
			}
		}
		child, s = get(h, cur, k)
		if s == .Ok && (!last_is_fact || child.kind == .Overlay) && cur.kind != .Overlay && type_of(k) != .Object && type_of(cur) != .Null && type_of(cur) != .Absent {
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
	if s == .Ok && last_is_fact && cur.kind != .Overlay && len(chain) > 0 && chain[len(chain) - 1].kind == .Overlay {
		cur, s = overlay_promote_fact_target(h, chain[len(chain) - 1], keys[len(keys) - 2], cur)
	}
	if s == .Ok {
		cur, s = set(h, cur, keys[len(keys) - 1], x, overlay_chain_refs(chain, cur.p) if cur.kind == .Overlay else 0)
	} else {
		release(h, cur)
		release(h, x)
	}
	#reverse for parent, i in chain {
		if s != .Ok {
			release(h, parent)
			continue
		}
		cur, s = set(h, parent, keys[i], cur, overlay_chain_refs(chain[:i], parent.p) if parent.kind == .Overlay else 0)
	}
	if s != .Ok {
		return NULL, s
	}
	return cur, .Ok
}

@(require_results)
set_one :: proc(h: ^Heap, t, key, x: Value) -> (Value, Status) {
	return set_one_key_owned(h, t, retain(key), x)
}

@(require_results)
set_one_key_owned :: proc(h: ^Heap, t, key, x: Value) -> (res: Value, status: Status) {
	if t.kind == .Object && key.kind == .String {
		out := t
		if ps := object_put(h, &out, key, x); ps != .Ok {
			release(h, out)
			return NULL, ps
		}
		return out, .Ok
	}
	defer release(h, key)
	return set(h, t, key, x, 0)
}

@(require_results)
del_one :: proc(h: ^Heap, t, key: Value) -> (Value, Status) {
	ks := [1]Value{key}
	return del_keys(h, t, ks[:], 0)
}

@(private = "file", require_results)
set_overlay_unique :: proc(h: ^Heap, t: Value, key: string, idx: int, is_member: bool, x: Value, overlay_depth: int) -> (Value, Status) {
	out_ov, cs := ensure_unique_overlay(h, t, overlay_depth + int(x.kind == .Overlay && x.p == t.p))
	if cs != .Ok {
		release(h, x)
		return NULL, cs
	}
	return overlay_set_at(h, out_ov, key, idx, is_member, x)
}

@(private, require_results)
set :: proc(h: ^Heap, t, key, x: Value, overlay_depth := 0) -> (res: Value, status: Status) {
	tt, kt := type_of(t), type_of(key)
	out, s := t, Status.Ok
	switch {
	case (tt == .Object || tt == .Null || tt == .Absent) && kt == .String:
		if t.kind == .Overlay && tt == .Object {
			return set_overlay_unique(h, t, text_of(key), 0, true, x, overlay_depth)
		}
		if tt != .Object {
			release(h, t)
			out, s = make_object(h, 1)
		} else {
			out, s = ensure_built(h, t)
		}
		if s == .Ok {
			if ps := object_put(h, &out, retain(key), x); ps != .Ok {
				release(h, out)
				return NULL, ps
			}
			return out, .Ok
		}
	case (tt == .Array || tt == .Null || tt == .Absent) && kt == .Number:
		i, _ := element_index(key)
		if math.is_nan(as_f64(key)) {
			s = fail(h, .Range, .Set_Path, out, key, "Cannot set array element at NaN index")
		} else if i < 0 {
			i += length_of(h, out)
			if i < 0 {
				s = fail(h, .Range, .Set_Path, out, key, "Out of bounds negative array index")
			}
		}
		if s == .Ok && index_past_limit(key) {
			s = fail(h, .Range, .Set_Path, out, key, "Array index too large")
		}
		if s == .Ok && t.kind == .Overlay && tt == .Array {
			return set_overlay_unique(h, t, "", i, false, x, overlay_depth)
		}
		if s == .Ok {
			if tt != .Array {
				release(h, t)
				out, s = make_array(h, 1)
			} else {
				out, s = ensure_built(h, t)
			}
		}
		if s == .Ok {
			if ps := array_put(h, &out, i, x); ps != .Ok {
				release(h, out)
				return NULL, ps
			}
			return out, .Ok
		}
	case kt == .Object:
		if f_res, handled, fs := write_fact_step(h, out, key, x, overlay_depth); handled {
			return f_res, fs
		}
		if tt == .Array || tt == .Null || tt == .Absent {
			return set_slice(h, t, key, x)
		}
		if tt == .String {
			if from, to, ks := slice_key(h, key); ks == .Ok {
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
	defer if status != .Ok {
		release(h, out)
	}
	add :: proc(h: ^Heap, out: ^Value, from: Value, lo, hi: int) -> Status {
		for i in lo ..< hi {
			append_owned(h, out, element(h, from, i) or_return) or_return
		}
		return .Ok
	}
	add(h, &out, t, 0, lo) or_return
	add(h, &out, x, 0, length_of(h, x)) or_return
	add(h, &out, t, hi, n) or_return
	return out, .Ok
}

@(require_results)
del_paths :: proc(h: ^Heap, v, paths: Value) -> (res: Value, status: Status) {
	if type_of(paths) != .Array {
		release(h, v)
		return NULL, fail(h, .Types, .Delete_Paths, paths)
	}
	ps, s := built(h, paths)
	if s == .Ok { s = own_array(h, &ps, 0) }
	if s == .Ok { s = sort_values(h, items_of(ps)) }
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

@(private)
del_sorted :: proc(h: ^Heap, v: Value, paths: []Value) -> (res: Value, status: Status) {
	Del_Frame :: struct {
		out, key:    Value,
		paths:       []Value,
		depth, i, j: int,
		keys:        [dynamic]Value,
	}
	del_stack_ov_refs :: proc(frames: []Del_Frame, target_p: rawptr) -> int {
		if target_p == nil { return 0 }
		count := 0
		for fr in frames {
			count += overlay_item_refs(fr.out, target_p)
		}
		return count
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
	root_v := v
	if root_v.kind == .Overlay {
		root_v = ensure_unique_overlay(h, root_v) or_return
	}
	if _, err := append(&stack, Del_Frame{out = root_v, paths = paths, keys = make([dynamic]Value, alloc)}); err != nil {
		release(h, root_v)
		return NULL, fail_memory(h)
	}
	for {
		f := &stack[len(stack) - 1]
		if f.i >= len(f.paths) {
			ov_refs := del_stack_ov_refs(stack[:len(stack) - 1], f.out.p) if f.out.kind == .Overlay else 0
			done, s := del_keys(h, f.out, f.keys[:], ov_refs)
			delete(f.keys)
			pop(&stack)
			if s != .Ok {
				return NULL, s
			}
			if len(stack) == 0 {
				return done, .Ok
			}
			up := &stack[len(stack) - 1]
			up_refs := del_stack_ov_refs(stack[:len(stack) - 1], up.out.p) if up.out.kind == .Overlay else 0
			up.out, s = set(h, up.out, up.key, done, up_refs)
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
		for j < len(f.paths) && (equal(h, key, items_of(f.paths[j])[f.depth]) or_return) {
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
		if sub.kind != .Overlay && f.out.kind == .Overlay && len(items_of(f.paths[f.i])) == f.depth + 2 {
			if _, _, is_fact := fact_step(h, items_of(f.paths[f.i])[f.depth + 1]); is_fact {
				sub = overlay_promote_fact_target(h, f.out, key, sub) or_return
			}
		} else if sub.kind == .Overlay {
			sub = ensure_unique_overlay(h, sub, del_stack_ov_refs(stack[:], sub.p)) or_return
		}
		f.key, f.j = key, j
		if _, err := append(&stack, Del_Frame{out = sub, paths = f.paths[f.i:j], depth = f.depth + 1, keys = make([dynamic]Value, alloc)}); err != nil {
			release(h, sub)
			return NULL, fail_memory(h)
		}
	}
}

@(private)
del_keys :: proc(h: ^Heap, t: Value, keys: []Value, overlay_depth := 0) -> (res: Value, status: Status) {
	if len(keys) == 0 {
		return t, .Ok
	}
	has_fact := false
	for k in keys {
		if _, _, is_fact := fact_step(h, k); is_fact {
			has_fact = true
			break
		}
	}
	if has_fact {
		alloc := heap_allocator(h)
		rest := make([dynamic]Value, 0, len(keys), alloc)
		facts := make([dynamic]Value, 0, len(keys), alloc)
		defer { delete(rest); delete(facts) }
		for k in keys {
			_, _, is_fact := fact_step(h, k)
			if _, err := append(&facts if is_fact else &rest, k); err != nil {
				release(h, t)
				return NULL, fail_memory(h)
			}
		}
		cur := t
		if len(rest) > 0 {
			cur = del_keys(h, cur, rest[:], overlay_depth) or_return
		}
		for fk in facts {
			cur, _ = write_fact_step(h, cur, fk, NULL, overlay_depth) or_return
		}
		return cur, .Ok
	}
	#partial switch type_of(t) {
	case .Null, .Absent:
		return t, .Ok
	case .Object:
		if t.kind == .Overlay {
			return overlay_del_members(h, ensure_unique_overlay(h, t, overlay_depth) or_return, keys)
		}
		out := ensure_built(h, t) or_return
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
		n, alloc := length_of(h, t), heap_allocator(h)
		gone := make([]bool, n, alloc)
		if gone == nil && n > 0 {
			release(h, t)
			return NULL, fail_memory(h)
		}
		defer delete(gone, alloc)
		for k in keys {
			#partial switch type_of(k) {
			case .Number:
				if i, ok := element_index(k); ok {
					idx := i + n if i < 0 else i
					if idx >= 0 && idx < n {
						gone[idx] = true
					}
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
		if t.kind == .Overlay {
			return overlay_del_elements(h, ensure_unique_overlay(h, t, overlay_depth) or_return, gone)
		}
		defer release(h, t)
		out := make_array(h, n) or_return
		defer if status != .Ok {
			release(h, out)
		}
		for i in 0 ..< n {
			if !gone[i] {
				append_owned(h, &out, element(h, t, i) or_return) or_return
			}
		}
		return out, .Ok
	}
	s := fail(h, .Types, .Delete_Paths, t, keys[0], "fields from")
	release(h, t)
	return NULL, s
}

@(private)
MAX_INDEX :: 1 << 29
