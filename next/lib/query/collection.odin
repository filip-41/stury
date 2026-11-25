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
		defer if status != .Ok {
			release(h, out)
		}
		for i in 0 ..< n {
			append_owned(h, &out, int_value(i64(i))) or_return
		}
		return out, .Ok
	case .Object:
		out := make_array(h, length_of(h, v)) or_return
		defer if status != .Ok {
			release(h, out)
		}
		c := cursor_open(h, v) or_return
		defer cursor_close(&c)
		for {
			k, x, more, s := cursor_next(h, &c)
			release(h, x)
			if s != .Ok {
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
	defer if status != .Ok {
		release(h, out)
	}
	stack := make([dynamic]Level, 0, 8, heap_allocator(h))
	defer {
		for &l in stack {
			cursor_close(&l.c)
			release(h, l.of)
		}
		delete(stack)
	}
	c := cursor_open(h, v) or_return
	if _, err := append(&stack, Level{c, retain(v), depth}); err != nil {
		cursor_close(&c)
		release(h, v)
		return NULL, fail_memory(h)
	}
	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		key, x, more, s := cursor_next(h, &top.c)
		release(h, key)
		if s != .Ok {
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
				return NULL, xs
			}
			if _, err := append(&stack, Level{xc, x, d}); err != nil {
				cursor_close(&xc)
				release(h, x)
				return NULL, fail_memory(h)
			}
			continue
		}
		append_owned(h, &out, x) or_return
	}
	return out, .Ok
}

// The elements of array `v`, each with its sort key: the key itself when `keys` is nil.
// When `move` is true, takes ownership of `v` (releasing it on error), preserving `rc == 1` for in-place element moves.
@(private)
keyed :: proc(h: ^Heap, v, keys: Value, move := false) -> (xs, ks: Value, status: Status) {
	if type_of(v) != .Array {
		if move {
			release(h, v)
		}
		return NULL, NULL, fail(h, .Types, .Sort, v)
	}
	if move && v.kind == .Array {
		xs = v
	} else {
		xs, status = built(h, v)
		if move {
			release(h, v)
		}
		if status != .Ok {
			return NULL, NULL, status
		}
	}
	if keys.kind == .Absent {
		ks = retain(xs)
	} else {
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
	alloc := heap_allocator(h)
	n := len(items_of(xs))
	order = make([]int, n, alloc)
	if order == nil && n > 0 {
		return nil, fail_memory(h)
	}
	if n < 2 {
		if n == 1 {
			order[0] = 0
		}
		return order, .Ok
	}
	raw_keys := items_of(ks)
	// One-element arrays order as their elements, so a scalar wrapped in an array sorts by the scalar alone.
	wrapped := true
	for k in raw_keys {
		if k.kind != .Array || len(items_of(k)) != 1 || items_of(k)[0].kind >= .Array {
			wrapped = false
			break
		}
	}
	by := raw_keys
	unwrapped: []Value
	if wrapped {
		unwrapped = make([]Value, n, alloc)
		if unwrapped == nil {
			delete(order, alloc)
			return nil, fail_memory(h)
		}
		for k, i in raw_keys {
			unwrapped[i] = items_of(k)[0]
		}
		by = unwrapped
	}
	defer delete(unwrapped, alloc)
	if s := order_values(h, by, order, coll, ties = ties); s != .Ok {
		delete(order, alloc)
		return nil, s
	}
	return order, .Ok
}

// Array `v` sorted by its elements, or by `keys`, one per element; stable.
@(require_results)
sort_by :: proc(h: ^Heap, v: Value, keys := ABSENT, coll := JSON_ORDER, move := false) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys, move) or_return
	defer release(h, xs)
	order, os := key_order(h, xs, ks, coll)
	release(h, ks)
	if os != .Ok {
		return NULL, os
	}
	defer delete(order, heap_allocator(h))
	out := make_array(h, len(order)) or_return
	defer if status != .Ok {
		release(h, out)
	}
	items := items_of(xs)
	dst := (^Array_Block)(out.p)
	raw_dst := ([^]Value)(uintptr(dst) + size_of(Array_Block))
	if unique(xs) {
		for i, k in order {
			raw_dst[k] = items[i]
		}
		dst.len = u32(len(order))
		src_blk := (^Array_Block)(xs.p)
		dst.flags = src_blk.flags
		src_blk.len = 0
		src_blk.flags = 0
	} else {
		for i, k in order {
			raw_dst[k] = retain(items[i])
		}
		dst.len = u32(len(order))
		dst.flags = (^Array_Block)(xs.p).flags
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
runs_by :: proc(h: ^Heap, v: Value, keys: Value, pick: Run_Pick, coll := JSON_ORDER, move := false) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys, move) or_return
	defer release(h, xs)
	alloc := heap_allocator(h)
	items := items_of(xs)
	ties := make([]bool, len(items), alloc)
	defer delete(ties, alloc)
	if len(ties) != len(items) {
		release(h, ks)
		return NULL, fail_memory(h)
	}
	order, os := key_order(h, xs, ks, coll, ties)
	release(h, ks)
	if os != .Ok {
		return NULL, os
	}
	defer delete(order, alloc)
	if len(order) == 0 {
		return make_array(h, 0)
	}
	groups := 1
	for k in 1 ..< len(ties) {
		if !ties[k] {
			groups += 1
		}
	}
	out := make_array(h, groups) or_return
	defer if status != .Ok {
		release(h, out)
	}
	can_move := unique(xs)
	src_blk := (^Array_Block)(xs.p)
	switch pick {
	case .Group:
		at := 0
		for at < len(order) {
			end := at + 1
			for end < len(order) && ties[end] {
				end += 1
			}
			g_len := end - at
			run := make_array(h, g_len) or_return
			rblk := (^Array_Block)(run.p)
			rdst := ([^]Value)(uintptr(rblk) + size_of(Array_Block))
			if can_move {
				for k in 0 ..< g_len {
					rdst[k] = items[order[at + k]]
				}
			} else {
				for k in 0 ..< g_len {
					rdst[k] = retain(items[order[at + k]])
				}
			}
			rblk.len = u32(g_len)
			rblk.flags = src_blk.flags
			append_owned(h, &out, run) or_return
			at = end
		}
		if can_move {
			src_blk.len = 0
			src_blk.flags = 0
		}
	case .First:
		for i, at in order {
			if !ties[at] {
				if can_move {
					x := items[i]
					items[i] = NULL
					append_owned(h, &out, x) or_return
				} else {
					append_owned(h, &out, retain(items[i])) or_return
				}
			}
		}
	case .Last:
		for i, at in order {
			if at + 1 == len(order) || !ties[at + 1] {
				if can_move {
					x := items[i]
					items[i] = NULL
					append_owned(h, &out, x) or_return
				} else {
					append_owned(h, &out, retain(items[i])) or_return
				}
			}
		}
	}
	return out, .Ok
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
	alloc := heap_allocator(h)
	ids = make([]int, n, h.allocator)
	if ids == nil && n > 0 {
		return nil, 0, fail_memory(h)
	}
	// A slot holds the index plus one of the first key of a group, 0 for none.
	slots := make([]int, size, alloc)
	defer delete(slots, alloc)
	hashes := make([]u64, n, alloc)
	defer delete(hashes, alloc)
	if slots == nil || (hashes == nil && n > 0) {
		delete(ids, h.allocator)
		return nil, 0, fail_memory(h)
	}
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
