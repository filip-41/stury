package query

// Operations over whole arrays and objects: keys, containment, flattening, sorting, grouping, deduplicating, extremes, sets.

@(require_results)
keys_of :: proc(h: ^Heap, v: Value, sorted := true) -> (res: Value, status: Status) {
	t := type_of(v)
	if t != .Array && t != .Object {
		return NULL, fail(h, .Types, .Keys, v)
	}
	n := length_of(h, v)
	out := make_array(h, n) or_return
	defer if status != .Ok {
		release(h, out)
	}
	if t == .Array {
		for i in 0 ..< n {
			append_owned(h, &out, int_value(i64(i))) or_return
		}
		return out, .Ok
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
	return a == b || (a in null && b in null) || (a in boolean && b in boolean)
}

@(private)
contained :: proc(h: ^Heap, a, b: Value) -> (res: bool, status: Status) {
	Check :: struct {
		a, b, keys: Value,
		i, j:       int,
	}
	pop_check :: proc(h: ^Heap, stack: ^[dynamic]Check) {
		x := pop(stack)
		release(h, x.a)
		release(h, x.b)
		release(h, x.keys)
	}
	stack := make([dynamic]Check, 0, 8, h.allocator)
	defer {
		for len(stack) > 0 {
			pop_check(h, &stack)
		}
		delete(stack)
	}
	open :: proc(h: ^Heap, stack: ^[dynamic]Check, a, b: Value) -> (done, res: bool, status: Status) {
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
	have := false
	for len(stack) > 0 {
		c := &stack[len(stack) - 1]
		if type_of(c.b) == .Array {
			xs, ys := items_of(c.a), items_of(c.b)
			if have {
				have = false
				if r { c.i, c.j = c.i + 1, 0 } else { c.j += 1 }
			}
			if c.i >= len(ys) || c.j >= len(xs) {
				r, have = c.i >= len(ys), true
				pop_check(h, &stack)
				continue
			}
			if d, dr := open(h, &stack, retain(xs[c.j]), retain(ys[c.i])) or_return; d {
				r, have = dr, true
			}
			continue
		}
		keys := items_of(c.keys)
		if have {
			have = false
			c.i = (c.i + 1) if r else (len(keys) + 1)
		}
		if c.i >= len(keys) {
			r, have = c.i == len(keys), true
			pop_check(h, &stack)
			continue
		}
		k := text_of(keys[c.i])
		x := member(h, c.a, k) or_return
		if x.kind == .Absent {
			r, have = false, true
			pop_check(h, &stack)
			continue
		}
		y, ys := member(h, c.b, k)
		if ys != .Ok {
			release(h, x)
			return false, ys
		}
		if d, dr := open(h, &stack, x, y) or_return; d {
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

@(require_results)
flatten :: proc(h: ^Heap, v: Value, depth: int) -> (res: Value, status: Status) {
	if t := type_of(v); t != .Array && t != .Object {
		return NULL, fail(h, .Types, .Iterate, v)
	}
	Level :: struct { c: Cursor, of: Value, depth: int }
	push_level :: proc(h: ^Heap, stack: ^[dynamic]Level, x: Value, d: int) -> Status {
		c, s := cursor_open(h, x)
		if s != .Ok {
			release(h, x)
			return s
		}
		if _, err := append(stack, Level{c, x, d}); err != nil {
			cursor_close(&c)
			release(h, x)
			return fail_memory(h)
		}
		return .Ok
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
	push_level(h, &stack, retain(v), depth) or_return
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
			push_level(h, &stack, x, top.depth - 1 if top.depth > 0 else -1) or_return
			continue
		}
		append_owned(h, &out, x) or_return
	}
	return out, .Ok
}

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
		return xs, retain(xs), .Ok
	}
	ks, status = built(h, keys)
	if status != .Ok {
		release(h, xs)
		return NULL, NULL, status
	}
	return xs, ks, .Ok
}

@(private)
key_order :: proc(h: ^Heap, xs, ks: Value, coll: Collation, ties: []bool = nil) -> (order: []int, status: Status) {
	alloc, n := heap_allocator(h), len(items_of(xs))
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
	dst, src_blk := (^Array_Block)(out.p), (^Array_Block)(xs.p)
	raw_dst := ([^]Value)(uintptr(dst) + size_of(Array_Block))
	can_move := unique(xs)
	for i, k in order {
		raw_dst[k] = items[i] if can_move else retain(items[i])
	}
	dst.len, dst.flags = u32(len(order)), src_blk.flags
	if can_move {
		src_blk.len, src_blk.flags = 0, 0
	}
	return out, .Ok
}

Run_Pick :: enum u8 { Group, First, Last }

@(require_results)
runs_by :: proc(h: ^Heap, v: Value, keys: Value, pick: Run_Pick, coll := JSON_ORDER, move := false) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys, move) or_return
	defer release(h, xs)
	alloc, items := heap_allocator(h), items_of(xs)
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
		groups += int(!ties[k])
	}
	out := make_array(h, groups) or_return
	defer if status != .Ok {
		release(h, out)
	}
	can_move, src_blk := unique(xs), (^Array_Block)(xs.p)
	if pick == .Group {
		for at := 0; at < len(order); {
			end := at + 1
			for end < len(order) && ties[end] {
				end += 1
			}
			g_len := end - at
			run := make_array(h, g_len) or_return
			rblk := (^Array_Block)(run.p)
			rdst := ([^]Value)(uintptr(rblk) + size_of(Array_Block))
			for k in 0 ..< g_len {
				rdst[k] = items[order[at + k]] if can_move else retain(items[order[at + k]])
			}
			rblk.len, rblk.flags = u32(g_len), src_blk.flags
			append_owned(h, &out, run) or_return
			at = end
		}
		if can_move {
			src_blk.len, src_blk.flags = 0, 0
		}
	} else {
		for i, at in order {
			if pick == .First ? !ties[at] : (at + 1 == len(order) || !ties[at + 1]) {
				x := items[i]
				if can_move { items[i] = NULL } else { x = retain(x) }
				append_owned(h, &out, x) or_return
			}
		}
	}
	return out, .Ok
}

@(require_results)
extreme_by :: proc(h: ^Heap, v: Value, keys: Value, greatest: bool, coll := JSON_ORDER) -> (res: Value, status: Status) {
	xs, ks := keyed(h, v, keys) or_return
	defer release(h, xs)
	defer release(h, ks)
	items := items_of(xs)
	if len(items) == 0 {
		return NULL, .Ok
	}
	o := ordering_init(h, items_of(ks), coll) or_return
	defer ordering_destroy(&o)
	best := 0
	for i in 1 ..< len(items) {
		c := ordering_compare(&o, i, best) or_return
		if (greatest && c >= 0) || (!greatest && c < 0) {
			best = i
		}
	}
	return retain(items[best]), .Ok
}

@(require_results)
group_ids :: proc(h: ^Heap, keys: []Value) -> (ids: []int, groups: int, status: Status) {
	n, size := len(keys), 2
	for size < 2 * n {
		size *= 2
	}
	alloc := heap_allocator(h)
	ids = make([]int, n, h.allocator)
	if ids == nil && n > 0 {
		return nil, 0, fail_memory(h)
	}
	defer if status != .Ok {
		delete(ids, h.allocator)
	}
	slots := make([]int, size, alloc)
	defer delete(slots, alloc)
	hashes := make([]u64, n, alloc)
	defer delete(hashes, alloc)
	if slots == nil || (hashes == nil && n > 0) {
		return nil, 0, fail_memory(h)
	}
	for k, i in keys {
		hashes[i] = hash(h, k) or_return
		for at := int(hashes[i]) & (size - 1); ; at = (at + 1) & (size - 1) {
			j := slots[at] - 1
			if j < 0 {
				slots[at], ids[i], groups = i + 1, groups, groups + 1
				break
			}
			if hashes[j] == hashes[i] && (equal(h, keys[j], k) or_return) {
				ids[i] = ids[j]
				break
			}
		}
	}
	return ids, groups, .Ok
}

Set_Op :: enum u8 { Union, Intersect, Except }

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
