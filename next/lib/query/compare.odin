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
	r, open := compare_head(h, a, b, coll)
	if !open {
		return r, .Ok
	}
	if r, open = compare_flat(h, a, b, coll); !open {
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
		r, open = compare_head(h, x, y, coll)
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
compare_flat :: proc(h: ^Heap, a, b: Value, coll: Collation) -> (int, bool) #no_bounds_check {
	if a.kind != .Array || b.kind != .Array {
		return 0, true
	}
	xs, ys := items_of(a), items_of(b)
	for i in 0 ..< min(len(xs), len(ys)) {
		r, open := compare_head(h, xs[i], ys[i], coll)
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
compare_head :: proc(h: ^Heap, a, b: Value, coll: Collation) -> (int, bool) {
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
		return compare_numbers(a, b, heap_allocator(h)), false
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
@(private, require_results)
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
@(private)
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
equal :: proc(h: ^Heap, a, b: Value) -> (res: bool, status: Status) #no_bounds_check {
	same, open := equal_head(h, a, b)
	if !open {
		return same, .Ok
	}
	// Fast path for flat built arrays and objects (no nested containers): zero allocations, zero retain/release.
	if a.kind == .Array && b.kind == .Array {
		ba, bb := (^Array_Block)(a.p), (^Array_Block)(b.p)
		if (ba.flags | bb.flags) & BLOCK_HAS_CONTAINER == 0 {
			xs, ys := array_items(ba), array_items(bb)
			for i in 0 ..< len(xs) {
				eq, _ := equal_head(h, xs[i], ys[i])
				if !eq {
					return false, .Ok
				}
			}
			return true, .Ok
		}
	} else if a.kind == .Object && b.kind == .Object {
		ba, bb := (^Object_Block)(a.p), (^Object_Block)(b.p)
		if (ba.flags | bb.flags) & BLOCK_HAS_CONTAINER == 0 {
			entries_a, entries_b := object_entries(ba), object_entries(bb)
			for e in entries_a {
				j := find_key(bb, text_of(e.key))
				if j < 0 {
					return false, .Ok
				}
				eq, _ := equal_head(h, e.value, entries_b[j].value)
				if !eq {
					return false, .Ok
				}
			}
			return true, .Ok
		}
	}
	Eq_Frame :: struct {
		a, b:       Value,
		c:          Cursor,
		i, n:       int,
		has_cursor: bool,
	}
	drop_eq :: proc(h: ^Heap, f: ^Eq_Frame) {
		if f.has_cursor {
			cursor_close(&f.c)
		}
		release(h, f.a)
		release(h, f.b)
		f^ = {}
	}
	open_eq :: proc(h: ^Heap, a, b: Value) -> (f: Eq_Frame, status: Status) {
		f = {a = a, b = b, n = length_of(h, a)}
		if (a.kind == .Node || a.kind == .Overlay) && type_of(a) == .Object {
			c, s := cursor_open(h, a)
			if s != .Ok {
				release(h, a)
				release(h, b)
				return {}, s
			}
			f.c, f.has_cursor = c, true
		}
		return f, .Ok
	}
	inline_buf: [8]Eq_Frame
	sp := 0
	dyn: [dynamic]Eq_Frame
	defer {
		for k in 0 ..< sp {
			drop_eq(h, &inline_buf[k])
		}
		for &f in dyn {
			drop_eq(h, &f)
		}
		delete(dyn)
	}
	push_eq :: proc(h: ^Heap, inline_buf: ^[8]Eq_Frame, sp: ^int, dyn: ^[dynamic]Eq_Frame, a, b: Value) -> Status {
		f := open_eq(h, a, b) or_return
		if len(dyn^) == 0 && sp^ < len(inline_buf) {
			inline_buf[sp^] = f
			sp^ += 1
			return .Ok
		}
		if dyn.allocator.procedure == nil {
			dyn^ = make([dynamic]Eq_Frame, 0, 16, h.allocator)
		}
		if _, err := append(dyn, f); err != nil {
			drop_eq(h, &f)
			return fail_memory(h)
		}
		return .Ok
	}
	push_eq(h, &inline_buf, &sp, &dyn, retain(a), retain(b)) or_return
	for sp > 0 || len(dyn) > 0 {
		f := &dyn[len(dyn) - 1] if len(dyn) > 0 else &inline_buf[sp - 1]
		x, y: Value
		if type_of(f.a) == .Array {
			if f.i >= f.n {
				drop_eq(h, f)
				if len(dyn) > 0 {
					pop(&dyn)
				} else {
					sp -= 1
				}
				continue
			}
			if f.a.kind == .Array {
				x = retain(items_of(f.a)[f.i])
			} else {
				x = element(h, f.a, f.i) or_return
			}
			if f.b.kind == .Array {
				y = retain(items_of(f.b)[f.i])
			} else {
				y = element(h, f.b, f.i) or_return
			}
			f.i += 1
		} else if f.a.kind == .Object {
			entries := entries_of(f.a)
			if f.i >= f.n {
				drop_eq(h, f)
				if len(dyn) > 0 {
					pop(&dyn)
				} else {
					sp -= 1
				}
				continue
			}
			e := entries[f.i]
			f.i += 1
			y = member(h, f.b, text_of(e.key)) or_return
			if y.kind == .Absent {
				return false, .Ok
			}
			x = retain(e.value)
		} else {
			k, vx, more := cursor_next(h, &f.c) or_return
			if !more {
				drop_eq(h, f)
				if len(dyn) > 0 {
					pop(&dyn)
				} else {
					sp -= 1
				}
				continue
			}
			y = member(h, f.b, text_of(k)) or_return
			release(h, k)
			if y.kind == .Absent {
				release(h, vx)
				return false, .Ok
			}
			x = vx
		}
		same, open = equal_head(h, x, y)
		depth := sp + len(dyn)
		if open && depth > depth_limit(h) {
			release(h, x)
			release(h, y)
			return false, fail(h, .Depth, .Equal)
		}
		if open {
			push_eq(h, &inline_buf, &sp, &dyn, x, y) or_return
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
		return numbers_equal(a, b, heap_allocator(h)), false
	case .String:
		return text_of(a) == text_of(b), false
	case .Array, .Object:
		if a.kind == b.kind && a.p == b.p && (a.kind != .Node || (a.n == b.n && (^Doc_Block)(a.p).doc.partial == nil)) && (a.kind != .Overlay || a.n == b.n) {
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
	inline_buf: [8]Hash_Frame
	sp := 0
	dyn: [dynamic]Hash_Frame
	defer {
		for k in 0 ..< sp {
			cursor_close(&inline_buf[k].c)
			release(h, inline_buf[k].v)
		}
		for &f in dyn {
			cursor_close(&f.c)
			release(h, f.v)
		}
		delete(dyn)
	}
	open :: proc(h: ^Heap, inline_buf: ^[8]Hash_Frame, sp: ^int, dyn: ^[dynamic]Hash_Frame, v: Value) -> Status {
		c, s := cursor_open(h, v)
		if s != .Ok {
			release(h, v)
			return s
		}
		seed := u64(0xA5A5) if type_of(v) == .Array else u64(0x5A5A)
		hf := Hash_Frame{v = v, c = c, acc = seed}
		if len(dyn^) == 0 && sp^ < len(inline_buf) {
			inline_buf[sp^] = hf
			sp^ += 1
			return .Ok
		}
		if dyn.allocator.procedure == nil {
			dyn^ = make([dynamic]Hash_Frame, 0, 16, h.allocator)
		}
		if _, err := append(dyn, hf); err != nil {
			cursor_close(&c)
			release(h, v)
			return fail_memory(h)
		}
		return .Ok
	}
	open(h, &inline_buf, &sp, &dyn, retain(v)) or_return
	result: u64
	for sp > 0 || len(dyn) > 0 {
		f := &dyn[len(dyn) - 1] if len(dyn) > 0 else &inline_buf[sp - 1]
		k, x, more := cursor_next(h, &f.c) or_return
		if !more {
			done := mix64(f.acc + u64(length_of(h, f.v)))
			cursor_close(&f.c)
			release(h, f.v)
			if len(dyn) > 0 {
				pop(&dyn)
			} else {
				sp -= 1
			}
			if sp == 0 && len(dyn) == 0 {
				result = done
			} else {
				parent := &dyn[len(dyn) - 1] if len(dyn) > 0 else &inline_buf[sp - 1]
				fold_hash(&parent.acc, done, type_of(parent.v) == .Object)
			}
			continue
		}
		if t := type_of(x); t == .Array || t == .Object {
			if k.kind != .Absent {
				fold_hash(&f.acc, hash_text(text_of(k)), true)
			}
			release(h, k)
			open(h, &inline_buf, &sp, &dyn, x) or_return
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

// Computes the stable sort permutation of `by` into `out` (length == len(by)), setting `ties[k]` when `by[out[k]]`
// equals `by[out[k-1]]`.
@(private, require_results)
order_values :: proc(
	h: ^Heap,
	by: []Value,
	out: []int,
	coll := JSON_ORDER,
	descending := false,
	ties: []bool = nil,
) -> Status {
	n := len(by)
	if n < 2 {
		if n == 1 {
			out[0] = 0
		}
		return .Ok
	}
	for i in 0 ..< n {
		out[i] = i
	}
	ints := true
	for v in by {
		if v.kind != .Int {
			ints = false
			break
		}
	}
	if ints {
		_ = int_order(h, by, out, descending) or_return
		for k in 1 ..< len(ties) {
			ties[k] = by[out[k]].i == by[out[k - 1]].i
		}
		return .Ok
	}
	alloc := heap_allocator(h)
	buf := make([]int, n, alloc)
	if buf == nil {
		return fail_memory(h)
	}
	defer delete(buf, alloc)
	src, tmp := out, buf
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
	if raw_data(src) != raw_data(out) {
		copy(out, src)
	}
	for k in 1 ..< len(ties) {
		r := ordering_compare(&o, out[k], out[k - 1]) or_return
		ties[k] = r == 0
	}
	return .Ok
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
	alloc := heap_allocator(h)
	order := make([]int, n, alloc)
	if order == nil {
		return fail_memory(h)
	}
	defer delete(order, alloc)
	order_values(h, by, order, coll, descending, ties) or_return
	permute(h, xs, order) or_return
	if keys != nil {
		permute(h, keys, order) or_return
	}
	return .Ok
}

// The stable order of integer keys `by`, written to `src`: insertion sort for tiny slices, else byte-skipping LSD radix
// sort (single zero-alloc counting pass when keys vary in only one byte).
@(private)
int_order :: proc(h: ^Heap, by: []Value, src: []int, descending: bool) -> (res: []int, status: Status) #no_bounds_check {
	n := len(by)
	if n < 64 {
		for i in 1 ..< n {
			idx := src[i]
			k := by[idx].i
			j := i - 1
			for j >= 0 && (by[src[j]].i < k if descending else by[src[j]].i > k) {
				src[j + 1] = src[j]
				j -= 1
			}
			src[j + 1] = idx
		}
		return src, .Ok
	}
	Pair :: struct {
		k: u64,
		i: int,
	}
	hist: [8][256]u32
	flip := u64(0xFFFF_FFFF_FFFF_FFFF) if descending else u64(0)
	first := (u64(by[0].i) ~ (u64(1) << 63)) ~ flip
	diff := u64(0)
	for v in by {
		u := (u64(v.i) ~ (u64(1) << 63)) ~ flip
		diff |= u ~ first
		hist[0][u & 0xFF] += 1
		hist[1][(u >> 8) & 0xFF] += 1
		hist[2][(u >> 16) & 0xFF] += 1
		hist[3][(u >> 24) & 0xFF] += 1
		hist[4][(u >> 32) & 0xFF] += 1
		hist[5][(u >> 40) & 0xFF] += 1
		hist[6][(u >> 48) & 0xFF] += 1
		hist[7][(u >> 56) & 0xFF] += 1
	}
	if diff == 0 {
		return src, .Ok
	}
	passes: [8]uint
	np := 0
	for b in uint(0) ..< 8 {
		if (diff >> (b * 8)) & 0xFF != 0 {
			passes[np] = b
			np += 1
		}
	}
	if np == 1 {
		shift := passes[0] * 8
		counts := &hist[passes[0]]
		off: [256]u32
		sum := u32(0)
		for b in 0 ..< 256 {
			off[b] = sum
			sum += counts[b]
		}
		for v, i in by {
			u := (u64(v.i) ~ (u64(1) << 63)) ~ flip
			bucket := (u >> shift) & 0xFF
			src[off[bucket]] = i
			off[bucket] += 1
		}
		return src, .Ok
	}
	alloc := heap_allocator(h)
	buf := make([]Pair, 2 * n, alloc)
	if buf == nil {
		return nil, fail_memory(h)
	}
	defer delete(buf, alloc)
	from, to := buf[:n], buf[n:]
	{
		shift := passes[0] * 8
		counts := &hist[passes[0]]
		off: [256]u32
		sum := u32(0)
		for b in 0 ..< 256 {
			off[b] = sum
			sum += counts[b]
		}
		for v, i in by {
			u := (u64(v.i) ~ (u64(1) << 63)) ~ flip
			bucket := (u >> shift) & 0xFF
			from[off[bucket]] = {u, i}
			off[bucket] += 1
		}
	}
	for p in 1 ..< np - 1 {
		shift := passes[p] * 8
		counts := &hist[passes[p]]
		off: [256]u32
		sum := u32(0)
		for b in 0 ..< 256 {
			off[b] = sum
			sum += counts[b]
		}
		for item in from {
			bucket := (item.k >> shift) & 0xFF
			to[off[bucket]] = item
			off[bucket] += 1
		}
		from, to = to, from
	}
	{
		shift := passes[np - 1] * 8
		counts := &hist[passes[np - 1]]
		off: [256]u32
		sum := u32(0)
		for b in 0 ..< 256 {
			off[b] = sum
			sum += counts[b]
		}
		for item in from {
			bucket := (item.k >> shift) & 0xFF
			src[off[bucket]] = item.i
			off[bucket] += 1
		}
	}
	return src, .Ok
}

// Puts `xs[order[i]]` at `xs[i]`.
@(private)
permute :: proc(h: ^Heap, xs: []Value, order: []int) -> Status {
	alloc := heap_allocator(h)
	moved := make([]Value, len(xs), alloc)
	if moved == nil {
		return fail_memory(h)
	}
	defer delete(moved, alloc)
	for k, i in order {
		moved[i] = xs[k]
	}
	runtime.mem_copy_non_overlapping(raw_data(xs), raw_data(moved), len(xs) * size_of(Value))
	return .Ok
}
