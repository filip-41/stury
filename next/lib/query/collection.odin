package query


// Operations over whole arrays and objects: keys, containment, flattening, and sorting, grouping, deduplicating and
// picking the least or greatest by keys.

// The keys of object `v` in key order, or in its own order when `sorted` is false, or the indexes of array `v`.
@(require_results)
keys_of :: proc(h: ^Heap, v: Value, sorted := true) -> (res: Value, status: Status) {
	#partial switch type_of(v) {
	case .Array:
		n := length_of(h, v)
		out := make_array(h, n) or_return
		for i in 0 ..< n {
			append_owned(h, &out, int_value(i64(i))) or_return
		}
		return out, .Ok
	case .Object:
		out := make_array(h, length_of(h, v)) or_return
		c := cursor_open(h, v) or_return
		defer cursor_close(&c)
		for {
			k, x, more, s := cursor_next(h, &c)
			release(h, x)
			if s != .Ok {
				release(h, out)
				return NULL, s
			}
			if !more {
				break
			}
			append_owned(h, &out, k) or_return
		}
		if sorted {
			sort_texts(items_of(out))
		}
		return out, .Ok
	}
	return NULL, fail(h, .Types, .Keys, v)
}

// Whether `a` contains `b`: an object each of whose members has a member of `a` containing it, an array each of whose
// elements an element of `a` contains, a string `a` holds, or an equal scalar. Values of different types fail at the
// top and do not contain each other below it.
@(require_results)
contains :: proc(h: ^Heap, a, b: Value) -> (res: bool, status: Status) {
	if !same_type(type_of(a), type_of(b)) {
		return false, fail(h, .Types, .Contains, a, b)
	}
	return contained(h, a, b)
}

@(private)
same_type :: proc(a, b: Type) -> bool {
	null :: bit_set[Type]{.Null, .Absent}
	boolean :: bit_set[Type]{.False, .True}
	return a == b || a in null && b in null || a in boolean && b in boolean
}

// Whether `a` contains `b`, both of one type, with a stack of its own: an array's element is looked for in each
// element of `a` in turn, and an object's member in the member of `a` with its key.
@(private)
contained :: proc(h: ^Heap, a, b: Value) -> (res: bool, status: Status) {
	Check :: struct {
		a, b:   Value, // held: built for arrays
		i, j:   int, // the element of `b`, and of `a` it is looked for in; an object's member
		keys:   Value, // an object's members' keys, held
	}
	stack := make([dynamic]Check, 0, 8, h.allocator)
	defer {
		for c in stack {
			release(h, c.a)
			release(h, c.b)
			release(h, c.keys)
		}
		delete(stack)
	}
	open :: proc(h: ^Heap, stack: ^[dynamic]Check, a, b: Value) -> (done: bool, res: bool, status: Status) {
		if len(stack) >= depth_limit(h) {
			release(h, a)
			release(h, b)
			return true, false, fail(h, .Depth, .Contains)
		}
		ta := type_of(a)
		if !same_type(ta, type_of(b)) {
			release(h, a)
			release(h, b)
			return true, false, .Ok
		}
		#partial switch ta {
		case .Array:
			x, xs := built(h, a)
			y, ys := built(h, b)
			release(h, a)
			release(h, b)
			if xs != .Ok || ys != .Ok {
				release(h, x)
				release(h, y)
				return true, false, xs if xs != .Ok else ys
			}
			append(stack, Check{a = x, b = y})
			return false, false, .Ok
		case .Object:
			keys, s := keys_of(h, b, false)
			if s != .Ok {
				release(h, a)
				release(h, b)
				return true, false, s
			}
			append(stack, Check{a = a, b = b, keys = keys})
			return false, false, .Ok
		case .String:
			r := text_contains(text_of(a), text_of(b))
			release(h, a)
			release(h, b)
			return true, r, .Ok
		}
		r, s := equal(h, a, b)
		release(h, a)
		release(h, b)
		return true, r, s
	}
	done, r := open(h, &stack, retain(a), retain(b)) or_return
	if done {
		return r, .Ok
	}
	// `r` is the answer of the check just closed, for the one under it.
	have := false
	for len(stack) > 0 {
		c := &stack[len(stack) - 1]
		if type_of(c.b) == .Array {
			xs, ys := items_of(c.a), items_of(c.b)
			if have {
				have = false
				if r {
					c.i += 1
					c.j = 0
				} else {
					c.j += 1
				}
			}
			if c.i >= len(ys) || c.j >= len(xs) {
				r = c.i >= len(ys)
				have = true
				x := pop(&stack)
				release(h, x.a)
				release(h, x.b)
				continue
			}
			d, dr := open(h, &stack, retain(xs[c.j]), retain(ys[c.i])) or_return
			if d {
				r, have = dr, true
			}
			continue
		}
		keys := items_of(c.keys)
		if have {
			have = false
			if !r {
				c.i = len(keys) + 1
			} else {
				c.i += 1
			}
		}
		if c.i >= len(keys) {
			r = c.i == len(keys)
			have = true
			x := pop(&stack)
			release(h, x.a)
			release(h, x.b)
			release(h, x.keys)
			continue
		}
		k := text_of(keys[c.i])
		x := member(h, c.a, k) or_return
		if x.kind == .Absent {
			r, have = false, true
			c.i = len(keys)
			x := pop(&stack)
			release(h, x.a)
			release(h, x.b)
			release(h, x.keys)
			continue
		}
		y, ys := member(h, c.b, k)
		if ys != .Ok {
			release(h, x)
			return false, ys
		}
		d, dr := open(h, &stack, x, y) or_return
		if d {
			r, have = dr, true
		}
	}
	return r, .Ok
}

@(private)
text_contains :: proc(s, t: string) -> bool {
	if len(t) == 0 {
		return true
	}
	for i in 0 ..= len(s) - len(t) {
		if s[i:i + len(t)] == t {
			return true
		}
	}
	return false
}

// Array `v` with the arrays in it spliced in, `depth` levels deep, every level for a negative depth. No recursion.
@(require_results)
flatten :: proc(h: ^Heap, v: Value, depth: int) -> (res: Value, status: Status) {
	if t := type_of(v); t != .Array && t != .Object {
		return NULL, fail(h, .Types, .Iterate, v)
	}
	Level :: struct {
		c:     Cursor,
		of:    Value,
		depth: int,
	}
	out := make_array(h, length_of(h, v)) or_return
	stack := make([dynamic]Level, 0, 8, h.allocator)
	defer {
		for &l in stack {
			cursor_close(&l.c)
			release(h, l.of)
		}
		delete(stack)
	}
	c := cursor_open(h, v) or_return
	append(&stack, Level{c, retain(v), depth})
	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		key, x, more, s := cursor_next(h, &top.c)
		release(h, key)
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
		if !more {
			l := pop(&stack)
			cursor_close(&l.c)
			release(h, l.of)
			continue
		}
		if type_of(x) == .Array && top.depth != 0 {
			d := top.depth - 1 if top.depth > 0 else -1
			xc, xs := cursor_open(h, x)
			if xs != .Ok {
				release(h, x)
				release(h, out)
				return NULL, xs
			}
			append(&stack, Level{xc, x, d})
			continue
		}
		append_owned(h, &out, x) or_return
	}
	return out, .Ok
}

// The elements of array `v`, each with its sort key: the key itself when `keys` is nil.
@(private)
keyed :: proc(h: ^Heap, v, keys: Value) -> (xs, ks: Value, status: Status) {
	if type_of(v) != .Array {
		return NULL, NULL, fail(h, .Types, .Sort, v)
	}
	xs = built(h, v) or_return
	ks = retain(xs)
	if keys.kind != .Absent {
		release(h, ks)
		ks, status = built(h, keys)
		if status != .Ok {
			release(h, xs)
			return NULL, NULL, status
		}
	}
	return xs, ks, .Ok
}

// The order of the elements of `xs` by keys `ks`, stable, and when `ties` is given, which of them are equal to the one
// before.
@(private)
key_order :: proc(h: ^Heap, xs, ks: Value, coll: Collation, ties: []bool = nil) -> (order: []int, status: Status) {
	n := len(items_of(xs))
	order = make([]int, n, h.allocator)
	idx := make([]Value, 2 * n, h.allocator)
	defer delete(idx, h.allocator)
	for i in 0 ..< n {
		idx[i] = int_value(i64(i))
	}
	// The keys sort with the indexes, in a copy, as they may be the elements themselves.
	keys := idx[n:]
	copy(keys, items_of(ks))
	// One-element arrays order as their elements, so a scalar wrapped in an array sorts by the scalar alone.
	wrapped := true
	for k in keys {
		if k.kind != .Array || len(items_of(k)) != 1 || items_of(k)[0].kind >= .Array {
			wrapped = false
			break
		}
	}
	if wrapped {
		for &k in keys {
			k = items_of(k)[0]
		}
	}
	if s := sort_values(h, idx[:n], keys, coll, ties = ties); s != .Ok {
		delete(order, h.allocator)
		return nil, s
	}
	for x, i in idx[:n] {
		order[i] = int(x.i)
	}
	return order, .Ok
}

// Array `v` sorted by its elements, or by `keys`, one per element; stable.
@(require_results)
sort_by :: proc(h: ^Heap, v: Value, keys := ABSENT, coll := JSON_ORDER) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys) or_return
	defer release(h, xs)
	defer release(h, ks)
	order := key_order(h, xs, ks, coll) or_return
	defer delete(order, h.allocator)
	out := make_array(h, len(order)) or_return
	items := items_of(xs)
	for i in order {
		append_owned(h, &out, retain(items[i])) or_return
	}
	return out, .Ok
}

// What to keep of each run of elements with equal keys, in key order.
Run_Pick :: enum u8 {
	Group, // the run, as an array
	First, // its first element
	Last, // its last element
}

// Array `v` in runs of equal keys, by `keys` or by its elements, in key order: each run, its first or its last element.
@(require_results)
runs_by :: proc(h: ^Heap, v: Value, keys: Value, pick: Run_Pick, coll := JSON_ORDER) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys) or_return
	defer release(h, xs)
	defer release(h, ks)
	items := items_of(xs)
	ties := make([]bool, len(items), h.allocator)
	defer delete(ties, h.allocator)
	if len(ties) != len(items) {
		return NULL, fail_memory(h)
	}
	order := key_order(h, xs, ks, coll, ties) or_return
	defer delete(order, h.allocator)
	out := make_array(h, 0) or_return
	run := NULL
	defer if status != .Ok {
		release(h, out)
		release(h, run)
	}
	for i, at in order {
		same := ties[at]
		switch pick {
		case .Group:
			if !same {
				if at > 0 {
					move_run(h, &out, &run) or_return
				}
				run = make_array(h, 1) or_return
			}
			append_owned(h, &run, retain(items[i])) or_return
		case .First:
			if !same {
				append_owned(h, &out, retain(items[i])) or_return
			}
		case .Last:
			if same {
				release(h, run)
			} else if at > 0 {
				move_run(h, &out, &run) or_return
			}
			run = retain(items[i])
		}
	}
	if pick != .First && len(order) > 0 {
		move_run(h, &out, &run) or_return
	}
	return out, .Ok
}

// Appends `run^` to `out^`, leaving `run^` null whether it fails or not.
@(private)
move_run :: proc(h: ^Heap, out, run: ^Value) -> Status {
	x := run^
	run^ = NULL
	return append_owned(h, out, x)
}

// The least element of array `v` by `keys` or by itself, the first of equals; the greatest, the last of equals. Null
// for an empty array.
@(require_results)
extreme_by :: proc(h: ^Heap, v: Value, keys: Value, greatest: bool, coll := JSON_ORDER) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys) or_return
	defer release(h, xs)
	defer release(h, ks)
	items, kitems := items_of(xs), items_of(ks)
	if len(items) == 0 {
		return NULL, .Ok
	}
	o := ordering_init(h, kitems, coll) or_return
	defer ordering_destroy(&o)
	best := 0
	for i in 1 ..< len(items) {
		c := ordering_compare(&o, i, best) or_return
		if greatest && c >= 0 || !greatest && c < 0 {
			best = i
		}
	}
	return retain(items[best]), .Ok
}

// The group of each of `keys`, numbered from 0 in the order each first occurs, equal keys in one, by `hash` and
// `equal`: in time linear in the keys, where `runs_by` sorts them.
@(require_results)
group_ids :: proc(h: ^Heap, keys: []Value) -> (ids: []int, groups: int, status: Status) {
	n := len(keys)
	size := 2
	for size < 2 * n {
		size *= 2
	}
	ids = make([]int, n, h.allocator)
	// A slot holds the index plus one of the first key of a group, 0 for none.
	slots := make([]int, size, h.allocator)
	defer delete(slots, h.allocator)
	hashes := make([]u64, n, h.allocator)
	defer delete(hashes, h.allocator)
	for k, i in keys {
		s: Status
		hashes[i], s = hash(h, k)
		at := int(hashes[i]) & (size - 1)
		for s == .Ok {
			j := slots[at] - 1
			if j < 0 {
				slots[at] = i + 1
				ids[i] = groups
				groups += 1
				break
			}
			same := false
			if hashes[j] == hashes[i] {
				same, s = equal(h, keys[j], k)
			}
			if same {
				ids[i] = ids[j]
				break
			}
			at = (at + 1) & (size - 1)
		}
		if s != .Ok {
			delete(ids, h.allocator)
			return nil, 0, s
		}
	}
	return ids, groups, .Ok
}

// What a set operation keeps of two arrays.
Set_Op :: enum u8 {
	Union, // the elements of either
	Intersect, // those of both
	Except, // those of the first only
}

// The elements of arrays `a` and `b` that `op` keeps, sorted by `coll` and with no two equal.
@(require_results)
set_of :: proc(h: ^Heap, a, b: Value, op: Set_Op, coll := JSON_ORDER) -> (res: Value, status: Status) {
	if type_of(a) != .Array || type_of(b) != .Array {
		return NULL, fail(h, .Types, .Set, a, b)
	}
	if op == .Union {
		both := array_concat(h, a, b) or_return
		defer release(h, both)
		return runs_by(h, both, ABSENT, .First, coll)
	}
	ua := runs_by(h, a, ABSENT, .First, coll) or_return
	defer release(h, ua)
	if op == .Except {
		return array_without(h, ua, b)
	}
	only_a := array_without(h, ua, b) or_return
	defer release(h, only_a)
	return array_without(h, ua, only_a)
}
