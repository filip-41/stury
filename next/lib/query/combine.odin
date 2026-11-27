package query

// Operations that make a container out of others: concatenation, merging, removal, and freezing a constant.

// The elements of array `a` followed by those of array `b`.
@(require_results)
array_concat :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	nb := length_of(h, b)
	if nb == 0 {
		return retain(a), .Ok
	}
	if length_of(h, a) == 0 {
		return retain(b), .Ok
	}
	out := built(h, a) or_return
	defer if status != .Ok {
		release(h, out)
	}
	own_array(h, &out, nb) or_return
	if b.kind == .Array {
		dst, src := (^Array_Block)(out.p), (^Array_Block)(b.p)
		items := array_items(src)
		raw_dst := ([^]Value)(uintptr(dst) + size_of(Array_Block))
		n := dst.len
		for x, i in items {
			raw_dst[n + u32(i)] = retain(x)
		}
		dst.len = n + u32(len(items))
		dst.flags |= src.flags
		return out, .Ok
	}
	c := cursor_open(h, b) or_return
	defer cursor_close(&c)
	for {
		_, x, more := cursor_next(h, &c) or_return
		if !more {
			return out, .Ok
		}
		append_owned(h, &out, x) or_return
	}
}

// The members of object `a` with those of `b` set over them: with `deep`, a member that is an object in both is merged
// in turn, with no recursion.
@(require_results)
object_merge :: proc(h: ^Heap, a, b: Value, deep: bool) -> (res: Value, status: Status) {
	if length_of(h, b) == 0 {
		return retain(a), .Ok
	}
	if !deep && length_of(h, a) == 0 {
		return retain(b), .Ok
	}
	Merge :: struct {
		into, over, key: Value,
		c:               Cursor,
	}
	stack := make([dynamic]Merge, 0, 4, h.allocator)
	defer {
		for &m in stack {
			cursor_close(&m.c)
			release(h, m.into)
			release(h, m.over)
			release(h, m.key)
		}
		delete(stack)
	}
	push :: proc(h: ^Heap, stack: ^[dynamic]Merge, a, b, key: Value) -> Status {
		into, s := built(h, a)
		c: Cursor
		if s == .Ok {
			c, s = cursor_open(h, b)
		}
		if s == .Ok {
			if _, err := append(stack, Merge{into = into, over = b, key = key, c = c}); err != nil {
				cursor_close(&c)
				s = fail_memory(h)
			}
		}
		if s != .Ok {
			release(h, into)
			release(h, b)
			release(h, key)
		}
		return s
	}
	push(h, &stack, a, retain(b), ABSENT) or_return
	for {
		m := &stack[len(stack) - 1]
		k, x, more := cursor_next(h, &m.c) or_return
		if !more {
			done, key := m.into, m.key
			cursor_close(&m.c)
			release(h, m.over)
			pop(&stack)
			if len(stack) == 0 {
				return done, .Ok
			}
			object_put(h, &stack[len(stack) - 1].into, key, done) or_return
			continue
		}
		if deep && type_of(x) == .Object {
			mine := member(h, m.into, text_of(k)) or_return
			if type_of(mine) == .Object {
				if len(stack) > depth_limit(h) {
					release(h, mine)
					release(h, x)
					release(h, k)
					return NULL, fail(h, .Depth, .Merge)
				}
				s := push(h, &stack, mine, x, k)
				release(h, mine)
				s or_return
				continue
			}
			release(h, mine)
		}
		object_put(h, &m.into, k, x) or_return
	}
}

// Sets the members of object `b` over the object `acc^` owns, in place when it holds its block alone.
@(require_results)
object_merge_into :: proc(h: ^Heap, acc: ^Value, b: Value) -> Status {
	if length_of(h, b) == 0 {
		return .Ok
	}
	c := cursor_open(h, b) or_return
	defer cursor_close(&c)
	for {
		k, x, more := cursor_next(h, &c) or_return
		if !more {
			return .Ok
		}
		object_put(h, acc, k, x) or_return
	}
}

// The elements of array `a` that equal no element of array `b`, in order.
@(require_results)
array_without :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	na, nb := length_of(h, a), length_of(h, b)
	if nb == 0 || na == 0 {
		return built(h, a)
	}
	out := make_array(h, na) or_return
	defer if status != .Ok {
		release(h, out)
	}
	bv := built(h, b) or_return
	defer release(h, bv)
	bs := items_of(bv)

	slots: []int
	hashes: []u64
	alloc := heap_allocator(h)
	defer delete(slots, alloc)
	defer delete(hashes, alloc)
	mask := 0
	if nb > 16 {
		size := 32
		for size < 2 * len(bs) {
			size <<= 1
		}
		slots = make([]int, size, alloc)
		hashes = make([]u64, len(bs), alloc)
		if slots == nil || hashes == nil {
			return NULL, fail_memory(h)
		}
		mask = size - 1
		for y, i in bs {
			hy := hash(h, y) or_return
			hashes[i] = hy
			for at := int(hy) & mask; ; at = (at + 1) & mask {
				j := slots[at] - 1
				if j < 0 {
					slots[at] = i + 1
					break
				}
				if hashes[j] == hy && (equal(h, bs[j], y) or_return) {
					break
				}
			}
		}
	}

	c := cursor_open(h, a) or_return
	defer cursor_close(&c)
	for {
		_, x, more := cursor_next(h, &c) or_return
		if !more {
			return out, .Ok
		}
		found := false
		s := Status.Ok
		if slots != nil {
			hx: u64
			hx, s = hash(h, x)
			for at := int(hx) & mask; s == .Ok; at = (at + 1) & mask {
				j := slots[at] - 1
				if j < 0 {
					break
				}
				if hashes[j] == hx {
					found, s = equal(h, x, bs[j])
					if found {
						break
					}
				}
			}
		} else {
			for y in bs {
				found, s = equal(h, x, y)
				if s != .Ok || found {
					break
				}
			}
		}
		if s == .Ok && !found {
			append_owned(h, &out, x) or_return
		} else {
			release(h, x)
			s or_return
		}
	}
}

// `v` as a constant: it and every block inside it held by no count, so no run frees or changes them.
freeze :: proc(v: Value) -> Value {
	if !v.held {
		return v
	}
	out := v
	out.held = false
	if v.kind != .Array && v.kind != .Object {
		return out
	}
	stack_buf: [32]Value
	sp := 1
	stack_buf[0] = v
	dyn: [dynamic]Value
	defer delete(dyn)
	block_of(v).rc = FROZEN_RC
	freeze_child :: proc(slot: ^Value, buf: ^[32]Value, sp: ^int, dyn: ^[dynamic]Value) {
		if !slot.held {
			return
		}
		child := slot^
		b := block_of(child)
		slot.held = false
		if b.rc != FROZEN_RC {
			b.rc = FROZEN_RC
			if child.kind == .Array || child.kind == .Object {
				if len(dyn^) == 0 && sp^ < len(buf) {
					buf[sp^] = child
					sp^ += 1
				} else {
					append(dyn, child)
				}
			}
		}
	}
	for sp > 0 || len(dyn) > 0 {
		cur: Value
		if len(dyn) > 0 {
			cur = pop(&dyn)
		} else {
			sp -= 1
			cur = stack_buf[sp]
		}
		if cur.kind == .Object {
			for &e in object_entries((^Object_Block)(cur.p)) {
				if e.key.held {
					block_of(e.key).rc = FROZEN_RC
					e.key.held = false
				}
				freeze_child(&e.value, &stack_buf, &sp, &dyn)
			}
		} else {
			for &x in array_items((^Array_Block)(cur.p)) {
				freeze_child(&x, &stack_buf, &sp, &dyn)
			}
		}
	}
	return out
}

// The count of a frozen block, which a block reached twice is known by.
@(private)
FROZEN_RC :: max(u32)
