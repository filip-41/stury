package query

import "base:runtime"

// Order, equality and hashing of values, with no recursion over their depth. How types order against each other is
// the caller's collation; within a type the order is fixed: numbers by value, strings by code point, arrays element
// by element, objects by their sorted keys and then their values in key order.

// The order of types, lowest rank first. Two types of one rank compare as equal.
Collation :: struct {
	rank: [Type]u8,
}

// JSON's values in their order of kinds: null, false, true, numbers, strings, arrays, objects, absent below all.
JSON_ORDER :: Collation {
	rank = {.Absent = 0, .Null = 1, .False = 2, .True = 3, .Number = 4, .String = 5, .Array = 6, .Object = 7},
}

// A pair of containers being compared, held, with the next child to compare and, for objects, `a`'s sorted keys.
@(private)
Compare_Frame :: struct {
	a, b: Value,
	i:    int,
	keys: [dynamic]Value,
}

// The order of `a` and `b`: -1, 0 or 1.
@(require_results)
compare :: proc(h: ^Heap, a, b: Value, coll := JSON_ORDER) -> (res: int, status: Status) {
	return compare_below(h, a, b, coll, 0)
}

// `compare` of values that lie `below` frames down in a larger comparison, which the depth budget counts.
@(private)
compare_below :: proc(h: ^Heap, a, b: Value, coll: Collation, below: int) -> (res: int, status: Status) {
	r, open := compare_head(a, b, coll)
	if !open {
		return r, .Ok
	}
	if r, open = compare_flat(a, b, coll); !open {
		return r, .Ok
	}
	stack := make([dynamic]Compare_Frame, 0, 8, h.allocator)
	defer {
		for &f in stack {
			drop_frame(h, &f)
		}
		delete(stack)
	}
	push_frame(h, &stack, retain(a), retain(b)) or_return
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		x, y: Value
		if type_of(f.a) == .Array {
			na, nb := length_of(h, f.a), length_of(h, f.b)
			if f.i >= min(na, nb) {
				if na != nb {
					return 1 if na > nb else -1, .Ok
				}
				drop_frame(h, f)
				pop(&stack)
				continue
			}
			x = element(h, f.a, f.i) or_return
			y = element(h, f.b, f.i) or_return
		} else {
			if f.i == 0 {
				if r = compare_keys(h, f) or_return; r != 0 {
					return r, .Ok
				}
			}
			if f.i >= len(f.keys) {
				drop_frame(h, f)
				pop(&stack)
				continue
			}
			k := text_of(f.keys[f.i])
			x = member(h, f.a, k) or_return
			y = member(h, f.b, k) or_return
		}
		f.i += 1
		r, open = compare_head(x, y, coll)
		if open && len(stack) + below > depth_limit(h) {
			release(h, x)
			release(h, y)
			return 0, fail(h, .Depth, .Compare)
		}
		if open {
			push_frame(h, &stack, x, y) or_return
			continue
		}
		release(h, x)
		release(h, y)
		if r != 0 {
			return r, .Ok
		}
	}
	return 0, .Ok
}

// The order of built arrays `a` and `b` when no pair of their elements is two containers, which takes no frame, and
// else whether such a pair is reached before the order is known.
@(private)
compare_flat :: proc(a, b: Value, coll: Collation) -> (int, bool) #no_bounds_check {
	if a.kind != .Array || b.kind != .Array {
		return 0, true
	}
	xs, ys := items_of(a), items_of(b)
	for i in 0 ..< min(len(xs), len(ys)) {
		r, open := compare_head(xs[i], ys[i], coll)
		if open {
			return 0, true
		}
		if r != 0 {
			return r, false
		}
	}
	return int(len(xs) > len(ys)) - int(len(xs) < len(ys)), false
}

// The order of `a` and `b` by type and, for scalars, value, and whether they are containers of one type, whose
// children decide.
@(private)
compare_head :: proc(a, b: Value, coll: Collation) -> (int, bool) {
	ta, tb := type_of(a), type_of(b)
	ra, rb := coll.rank[ta], coll.rank[tb]
	if ra != rb {
		return 1 if ra > rb else -1, false
	}
	if ta != tb {
		return 0, false
	}
	#partial switch ta {
	case .Number:
		return compare_numbers(a, b), false
	case .String:
		x, y := text_of(a), text_of(b)
		return int(x > y) - int(x < y), false
	case .Array, .Object:
		return 0, true
	}
	return 0, false
}

@(private)
push_frame :: proc(h: ^Heap, stack: ^[dynamic]Compare_Frame, a, b: Value) -> Status {
	if _, err := append(stack, Compare_Frame{a = a, b = b}); err != nil {
		release(h, a)
		release(h, b)
		return fail_memory(h)
	}
	return .Ok
}

@(private)
drop_frame :: proc(h: ^Heap, f: ^Compare_Frame) {
	release(h, f.a)
	release(h, f.b)
	for k in f.keys {
		release(h, k)
	}
	delete(f.keys)
	f^ = {}
}

// The order of the sorted key lists of the objects of `f`, keeping `a`'s in `f.keys`.
@(private)
compare_keys :: proc(h: ^Heap, f: ^Compare_Frame) -> (res: int, status: Status) {
	f.keys = sorted_keys(h, f.a) or_return
	bk := sorted_keys(h, f.b) or_return
	defer {
		for k in bk {
			release(h, k)
		}
		delete(bk)
	}
	for i in 0 ..< min(len(f.keys), len(bk)) {
		x, y := text_of(f.keys[i]), text_of(bk[i])
		if x != y {
			return 1 if x > y else -1, .Ok
		}
	}
	return int(len(f.keys) > len(bk)) - int(len(f.keys) < len(bk)), .Ok
}

// The keys of object `v`, sorted by code point, each held, in a list of the heap's allocator.
@(require_results)
sorted_keys :: proc(h: ^Heap, v: Value) -> (res: [dynamic]Value, status: Status) {
	keys := make([dynamic]Value, 0, length_of(h, v), h.allocator)
	c := cursor_open(h, v) or_return
	defer cursor_close(&c)
	for {
		k, x, more, s := cursor_next(h, &c)
		if s != .Ok {
			drop_values(h, &keys)
			return nil, s
		}
		if !more {
			break
		}
		release(h, x)
		if _, err := append(&keys, k); err != nil {
			release(h, k)
			drop_values(h, &keys)
			return nil, fail_memory(h)
		}
	}
	sort_texts(keys[:])
	return keys, .Ok
}

@(private)
drop_values :: proc(h: ^Heap, xs: ^[dynamic]Value) {
	for x in xs {
		release(h, x)
	}
	delete(xs^)
	xs^ = nil
}

// Sorts distinct strings, or entries by their keys, by code point in place, with no allocation.
sort_texts :: proc(keys: []$T) where T == Value || T == Entry {
	text :: #force_inline proc(x: T) -> string {
		when T == Entry {
			return text_of(x.key)
		} else {
			return text_of(x)
		}
	}
	n := len(keys)
	if n <= 32 {
		for i in 1 ..< n {
			k := keys[i]
			j := i
			for j > 0 && text(keys[j - 1]) > text(k) {
				keys[j] = keys[j - 1]
				j -= 1
			}
			keys[j] = k
		}
		return
	}
	sift :: proc(keys: []T, root, end: int) {
		root := root
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && text(keys[child]) < text(keys[child + 1]) {
				child += 1
			}
			if text(keys[root]) >= text(keys[child]) {
				return
			}
			keys[root], keys[child] = keys[child], keys[root]
			root = child
		}
	}
	for i := n / 2 - 1; i >= 0; i -= 1 {
		sift(keys, i, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		keys[0], keys[end] = keys[end], keys[0]
		sift(keys, 0, end)
	}
}

// Whether `a` and `b` are equal: of one type, numbers by value (NaN equal to nothing), strings by bytes, arrays element
// by element, objects with the same keys and equal values.
@(require_results)
equal :: proc(h: ^Heap, a, b: Value) -> (res: bool, status: Status) {
	same, open := equal_head(h, a, b)
	if !open {
		return same, .Ok
	}
	stack := make([dynamic]Compare_Frame, 0, 8, h.allocator)
	defer {
		for &f in stack {
			drop_frame(h, &f)
		}
		delete(stack)
	}
	push_frame(h, &stack, retain(a), retain(b)) or_return
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		x, y: Value
		if type_of(f.a) == .Array {
			if f.i >= length_of(h, f.a) {
				drop_frame(h, f)
				pop(&stack)
				continue
			}
			x = element(h, f.a, f.i) or_return
			y = element(h, f.b, f.i) or_return
		} else if f.a.kind == .Object {
			// Keys are distinct and the counts agree, so `b` holds every key of `a` exactly when the two key sets are
			// one: `a`'s entries go in their own order, with no sorted copy.
			entries := entries_of(f.a)
			if f.i >= len(entries) {
				drop_frame(h, f)
				pop(&stack)
				continue
			}
			e := entries[f.i]
			y = member(h, f.b, text_of(e.key)) or_return
			if y.kind == .Absent {
				return false, .Ok
			}
			x = retain(e.value)
		} else {
			if f.i == 0 {
				f.keys = sorted_keys(h, f.a) or_return
			}
			if f.i >= len(f.keys) {
				drop_frame(h, f)
				pop(&stack)
				continue
			}
			k := text_of(f.keys[f.i])
			x = member(h, f.a, k) or_return
			y = member(h, f.b, k) or_return
			if y.kind == .Absent {
				release(h, x)
				return false, .Ok
			}
		}
		f.i += 1
		same, open = equal_head(h, x, y)
		if open && len(stack) > depth_limit(h) {
			release(h, x)
			release(h, y)
			return false, fail(h, .Depth, .Equal)
		}
		if open {
			push_frame(h, &stack, x, y) or_return
			continue
		}
		release(h, x)
		release(h, y)
		if !same {
			return false, .Ok
		}
	}
	return true, .Ok
}

@(private)
equal_head :: proc(h: ^Heap, a, b: Value) -> (same, open: bool) {
	ta, tb := type_of(a), type_of(b)
	if ta != tb {
		return false, false
	}
	#partial switch ta {
	case .Number:
		return numbers_equal(a, b), false
	case .String:
		return text_of(a) == text_of(b), false
	case .Array, .Object:
		if a.kind == b.kind && a.p == b.p && (a.kind != .Node || a.n == b.n) {
			return true, false
		}
		if length_of(h, a) != length_of(h, b) {
			return false, false
		}
		return true, true
	}
	return true, false
}

// A hash of `v`, alike for values `equal` holds for: an object's by its members in any order.
@(require_results)
hash :: proc(h: ^Heap, v: Value) -> (res: u64, status: Status) {
	Hash_Frame :: struct {
		v:   Value,
		c:   Cursor,
		acc: u64,
	}
	if t := type_of(v); t != .Array && t != .Object {
		return hash_scalar(v), .Ok
	}
	stack := make([dynamic]Hash_Frame, 0, 8, h.allocator)
	defer {
		for &f in stack {
			cursor_close(&f.c)
			release(h, f.v)
		}
		delete(stack)
	}
	open :: proc(h: ^Heap, stack: ^[dynamic]Hash_Frame, v: Value) -> Status {
		c, s := cursor_open(h, v)
		if s != .Ok {
			release(h, v)
			return s
		}
		seed := u64(0xA5A5) if type_of(v) == .Array else u64(0x5A5A)
		if _, err := append(stack, Hash_Frame{v = v, c = c, acc = seed}); err != nil {
			cursor_close(&c)
			release(h, v)
			return fail_memory(h)
		}
		return .Ok
	}
	open(h, &stack, retain(v)) or_return
	result: u64
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		k, x, more := cursor_next(h, &f.c) or_return
		if !more {
			done := mix64(f.acc + u64(length_of(h, f.v)))
			cursor_close(&f.c)
			release(h, f.v)
			pop(&stack)
			if len(stack) == 0 {
				result = done
			} else {
				fold_hash(&stack[len(stack) - 1].acc, done, type_of(stack[len(stack) - 1].v) == .Object)
			}
			continue
		}
		if t := type_of(x); t == .Array || t == .Object {
			if k.kind != .Absent {
				fold_hash(&f.acc, hash_text(text_of(k)), true)
			}
			release(h, k)
			open(h, &stack, x) or_return
			continue
		}
		hx := hash_scalar(x)
		if k.kind != .Absent {
			hx = mix64(hx ~ hash_text(text_of(k)))
		}
		fold_hash(&f.acc, hx, k.kind != .Absent)
		release(h, k)
		release(h, x)
	}
	return result, .Ok
}

// Folds a child's hash into its container's: added for an object's members, whose order does not count, else mixed in turn.
@(private)
fold_hash :: #force_inline proc "contextless" (acc: ^u64, x: u64, unordered: bool) {
	if unordered {
		acc^ += x
	} else {
		acc^ = mix64(acc^ ~ x)
	}
}

@(private)
hash_scalar :: proc(v: Value) -> u64 {
	t := type_of(v)
	#partial switch t {
	case .Number:
		return hash_number(v)
	case .String:
		return hash_text(text_of(v))
	}
	return mix64(u64(t) + 1)
}

// Sorts `xs` in place by `compare`, greatest first when `descending`, stably, the equal ones in their order. `keys`,
// when given, is sorted alike and decides: `xs[i]` sorts by `keys[i]`. `ties`, when given, one entry per value, is set
// for each value that is equal to the one before it in the sorted order.
@(require_results)
sort_values :: proc(
	h: ^Heap,
	xs: []Value,
	keys: []Value = nil,
	coll := JSON_ORDER,
	descending := false,
	ties: []bool = nil,
) -> Status {
	n := len(xs)
	if n < 2 {
		return .Ok
	}
	by := keys if keys != nil else xs
	order := make([]int, 2 * n, h.allocator)
	if order == nil {
		return fail_memory(h)
	}
	defer delete(order, h.allocator)
	src, tmp := order[:n], order[n:]
	for i in 0 ..< n {
		src[i] = i
	}
	ints := true
	for v in by {
		if v.kind != .Int {
			ints = false
			break
		}
	}
	if ints {
		src = int_order(h, by, src, descending) or_return
		for k in 1 ..< len(ties) {
			ties[k] = by[src[k]].i == by[src[k - 1]].i
		}
	} else {
		o := ordering_init(h, by, coll) or_return
		defer ordering_destroy(&o)
		// A bottom-up merge sort of indexes: no recursion, and stable.
		for width := 1; width < n; width *= 2 {
			for lo := 0; lo < n; lo += 2 * width {
				mid, hi := min(lo + width, n), min(lo + 2 * width, n)
				i, j, k := lo, mid, lo
				for i < mid && j < hi {
					r := ordering_compare(&o, src[j], src[i]) or_return
					if descending ? r > 0 : r < 0 {
						tmp[k] = src[j]
						j += 1
					} else {
						tmp[k] = src[i]
						i += 1
					}
					k += 1
				}
				for ; i < mid; i += 1 {
					tmp[k] = src[i]
					k += 1
				}
				for ; j < hi; j += 1 {
					tmp[k] = src[j]
					k += 1
				}
			}
			src, tmp = tmp, src
		}
		for k in 1 ..< len(ties) {
			r := ordering_compare(&o, src[k], src[k - 1]) or_return
			ties[k] = r == 0
		}
	}
	permute(h, xs, src) or_return
	if keys != nil {
		permute(h, keys, src) or_return
	}
	return .Ok
}

// The stable order of integer keys `by`, written to `src`, by a merge sort of (key, index) pairs, which it reads in
// order instead of through the indexes.
@(private)
int_order :: proc(h: ^Heap, by: []Value, src: []int, descending: bool) -> (res: []int, status: Status) #no_bounds_check {
	Pair :: struct {
		k: i64,
		i: int,
	}
	n := len(by)
	buf := make([]Pair, 2 * n, h.allocator)
	if buf == nil {
		return nil, fail_memory(h)
	}
	defer delete(buf, h.allocator)
	from, to := buf[:n], buf[n:]
	for v, i in by {
		from[i] = {v.i, i}
	}
	for width := 1; width < n; width *= 2 {
		for lo := 0; lo < n; lo += 2 * width {
			mid, hi := min(lo + width, n), min(lo + 2 * width, n)
			i, j, k := lo, mid, lo
			for i < mid && j < hi {
				right := from[j].k > from[i].k if descending else from[j].k < from[i].k
				if right {
					to[k] = from[j]
					j += 1
				} else {
					to[k] = from[i]
					i += 1
				}
				k += 1
			}
			copy(to[k:], from[i:mid])
			k += mid - i
			copy(to[k:], from[j:hi])
		}
		from, to = to, from
	}
	for p, i in from {
		src[i] = p.i
	}
	return src, .Ok
}

// Puts `xs[order[i]]` at `xs[i]`.
@(private)
permute :: proc(h: ^Heap, xs: []Value, order: []int) -> Status {
	moved := make([]Value, len(xs), h.allocator)
	if moved == nil {
		return fail_memory(h)
	}
	defer delete(moved, h.allocator)
	for k, i in order {
		moved[i] = xs[k]
	}
	runtime.mem_copy_non_overlapping(raw_data(xs), raw_data(moved), len(xs) * size_of(Value))
	return .Ok
}
