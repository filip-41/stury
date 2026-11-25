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
	if s := own_array(h, &out, nb); s != .Ok {
		release(h, out)
		return NULL, s
	}
	c := cursor_open(h, b) or_return
	defer cursor_close(&c)
	for {
		_, x, more, s := cursor_next(h, &c)
		if s == .Ok && more {
			s = append_owned(h, &out, x)
		}
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
		if !more {
			return out, .Ok
		}
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
		into:   Value, // owned, the merge being made
		over:   Value, // held, the object set over it
		key:    Value, // held, where `into` goes in the merge below, `.Absent` for the outermost
		c:      Cursor,
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
		if s != .Ok {
			release(h, b)
			release(h, key)
			return s
		}
		c: Cursor
		c, s = cursor_open(h, b)
		if s == .Ok {
			if _, err := append(stack, Merge{into = into, over = b, key = key, c = c}); err != nil {
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
			done := m.into
			key := m.key
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
			if type_of(mine) == .Object && len(stack) > depth_limit(h) {
				release(h, mine)
				release(h, x)
				release(h, k)
				return NULL, fail(h, .Depth, .Merge)
			}
			if type_of(mine) == .Object {
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
	out := make_array(h, length_of(h, a)) or_return
	c := cursor_open(h, a) or_return
	defer cursor_close(&c)
	for {
		_, x, more, s := cursor_next(h, &c)
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
		if !more {
			return out, .Ok
		}
		found := false
		d: Cursor
		if d, s = cursor_open(h, b); s == .Ok {
			for !found {
				_, y, has, e := cursor_next(h, &d)
				if e != .Ok || !has {
					s = e
					break
				}
				found, s = equal(h, x, y)
				release(h, y)
				if s != .Ok {
					break
				}
			}
			cursor_close(&d)
		}
		if s == .Ok && !found {
			s = append_owned(h, &out, x)
		} else {
			release(h, x)
		}
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
	}
}

// `v` as a constant: it and every block inside it held by no count, so no run frees or changes them. Its blocks stay in
// the heap that made them, which outlives every run that reads it.
freeze :: proc(v: Value) -> Value {
	if !v.held {
		return v
	}
	out := v
	out.held = false
	if v.kind != .Array && v.kind != .Object {
		return out
	}
	// The containers still to freeze are threaded through their own `next` field.
	pending := block_of(v)
	pending.rc = FROZEN_RC
	set_next(v.kind, pending, nil)
	for pending != nil {
		b := pending
		pending = next_of(b)
		if (^Array_Block)(b).class == FROZEN_OBJECT {
			for &e in object_entries((^Object_Block)(b)) {
				thaw_child(&e.key, &pending)
				thaw_child(&e.value, &pending)
			}
		} else {
			for &x in array_items((^Array_Block)(b)) {
				thaw_child(&x, &pending)
			}
		}
	}
	return out
}

// Marks child `x` held by no count, putting a container on the list to freeze.
@(private)
thaw_child :: proc(x: ^Value, pending: ^^Block) {
	if !x.held {
		return
	}
	b := block_of(x^)
	x.held = false
	if b.rc == FROZEN_RC {
		return
	}
	b.rc = FROZEN_RC
	if x.kind == .Array || x.kind == .Object {
		set_next(x.kind, b, pending^)
		pending^ = b
	}
}

// The count of a frozen block, which a block reached twice is known by.
@(private)
FROZEN_RC :: max(u32)

// A frozen container's class marks an object, as its count is no longer read.
@(private)
FROZEN_OBJECT :: u8(0xFC)

@(private)
set_next :: proc(kind: Kind, b: ^Block, next: ^Block) {
	if kind == .Object {
		(^Object_Block)(b).next = next
		b.class = FROZEN_OBJECT
	} else {
		(^Array_Block)(b).next = next
	}
}

@(private)
next_of :: proc(b: ^Block) -> ^Block {
	if b.class == FROZEN_OBJECT {
		return (^Object_Block)(b).next
	}
	return (^Array_Block)(b).next
}
