package query

// Order, equality and hashing of values, with no recursion over their depth.

Collation :: struct {
	rank: [Type]u8,
}

JSON_ORDER :: Collation{
	rank = {.Absent = 0, .Null = 1, .False = 2, .True = 3, .Number = 4, .String = 5, .Array = 6, .Object = 7},
}

// Inline stack with dynamic spill for iterative traversals (`equal`, `hash`, `set_path`).
@(private)
Small_Stack :: struct($T: typeid, $N: int) {
	buf: [N]T,
	sp:  int,
	dyn: [dynamic]T,
}

@(private)
small_stack_len :: #force_inline proc "contextless" (s: ^Small_Stack($T, $N)) -> int {
	return s.sp + len(s.dyn)
}

@(private)
small_stack_top :: #force_inline proc "contextless" (s: ^Small_Stack($T, $N)) -> ^T #no_bounds_check {
	return &s.dyn[len(s.dyn) - 1] if len(s.dyn) > 0 else &s.buf[s.sp - 1]
}

@(private)
small_stack_push :: #force_inline proc(h: ^Heap, s: ^Small_Stack($T, $N), item: T) -> Status #no_bounds_check {
	if len(s.dyn) == 0 && s.sp < N {
		s.buf[s.sp] = item
		s.sp += 1
		return .Ok
	}
	if s.dyn.allocator.procedure == nil {
		s.dyn = make([dynamic]T, 0, 2 * N, h.allocator)
	}
	if _, err := append(&s.dyn, item); err != nil {
		return fail_memory(h)
	}
	return .Ok
}

@(private)
small_stack_pop :: #force_inline proc(s: ^Small_Stack($T, $N)) {
	if len(s.dyn) > 0 {
		pop(&s.dyn)
	} else {
		s.sp -= 1
	}
}

@(private)
Compare_Frame :: struct {
	a, b: Value,
	i:    int,
	keys: [dynamic]Value,
}

@(require_results)
compare :: proc(h: ^Heap, a, b: Value, coll := JSON_ORDER) -> (res: int, status: Status) {
	return compare_below(h, a, b, coll, 0)
}

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
					return int(na > nb) - int(na < nb), .Ok
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
		if open {
			if len(stack) + below > depth_limit(h) {
				release(h, x)
				release(h, y)
				return 0, fail(h, .Depth, .Compare)
			}
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

@(private)
compare_head :: proc(h: ^Heap, a, b: Value, coll: Collation) -> (int, bool) {
	ta, tb := type_of(a), type_of(b)
	ra, rb := coll.rank[ta], coll.rank[tb]
	if ra != rb {
		return int(ra > rb) - int(ra < rb), false
	}
	if ta != tb {
		return 0, false
	}
	#partial switch ta {
	case .Number:        return compare_numbers(a, b, heap_allocator(h)), false
	case .String:        x, y := text_of(a), text_of(b); return int(x > y) - int(x < y), false
	case .Array, .Object: return 0, true
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
	drop_values(h, &f.keys)
	f^ = {}
}

@(private)
compare_keys :: proc(h: ^Heap, f: ^Compare_Frame) -> (res: int, status: Status) {
	f.keys = sorted_keys(h, f.a) or_return
	bk := sorted_keys(h, f.b) or_return
	defer drop_values(h, &bk)
	for i in 0 ..< min(len(f.keys), len(bk)) {
		x, y := text_of(f.keys[i]), text_of(bk[i])
		if x != y {
			return int(x > y) - int(x < y), .Ok
		}
	}
	return int(len(f.keys) > len(bk)) - int(len(f.keys) < len(bk)), .Ok
}

@(private, require_results)
sorted_keys :: proc(h: ^Heap, v: Value) -> (res: [dynamic]Value, status: Status) {
	keys := make([dynamic]Value, 0, length_of(h, v), h.allocator)
	defer if status != .Ok {
		drop_values(h, &keys)
	}
	c := cursor_open(h, v) or_return
	defer cursor_close(&c)
	for {
		k, x, more := cursor_next(h, &c) or_return
		if !more {
			break
		}
		release(h, x)
		if _, err := append(&keys, k); err != nil {
			release(h, k)
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

@(private)
sort_texts :: proc(keys: []$T) where T == Value || T == Entry {
	text :: #force_inline proc(x: T) -> string {
		when T == Entry { return text_of(x.key) } else { return text_of(x) }
	}
	n := len(keys)
	if n <= 32 {
		for i in 1 ..< n {
			k, j := keys[i], i
			for j > 0 && text(keys[j - 1]) > text(k) {
				keys[j] = keys[j - 1]
				j -= 1
			}
			keys[j] = k
		}
		return
	}
	sift :: proc(keys: []T, root, end: int) {
		r := root
		for {
			ch := 2 * r + 1
			if ch >= end {
				return
			}
			if ch + 1 < end && text(keys[ch]) < text(keys[ch + 1]) {
				ch += 1
			}
			if text(keys[r]) >= text(keys[ch]) {
				return
			}
			keys[r], keys[ch] = keys[ch], keys[r]
			r = ch
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

@(require_results)
equal :: proc(h: ^Heap, a, b: Value) -> (res: bool, status: Status) #no_bounds_check {
	same, open := equal_head(h, a, b)
	if !open {
		return same, .Ok
	}
	if a.kind == .Array && b.kind == .Array {
		ba, bb := (^Array_Block)(a.p), (^Array_Block)(b.p)
		if (ba.flags | bb.flags) & BLOCK_HAS_CONTAINER == 0 {
			xs, ys := array_items(ba), array_items(bb)
			for i in 0 ..< len(xs) {
				if eq, _ := equal_head(h, xs[i], ys[i]); !eq {
					return false, .Ok
				}
			}
			return true, .Ok
		}
	} else if a.kind == .Object && b.kind == .Object {
		ba, bb := (^Object_Block)(a.p), (^Object_Block)(b.p)
		if (ba.flags | bb.flags) & BLOCK_HAS_CONTAINER == 0 {
			entries_b := object_entries(bb)
			for e in object_entries(ba) {
				j := find_key(bb, text_of(e.key))
				if j < 0 {
					return false, .Ok
				}
				if eq, _ := equal_head(h, e.value, entries_b[j].value); !eq {
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
	push_eq :: proc(h: ^Heap, st: ^Small_Stack(Eq_Frame, 8), a, b: Value) -> Status {
		f := Eq_Frame{a = a, b = b, n = length_of(h, a)}
		if (a.kind == .Node || a.kind == .Overlay) && type_of(a) == .Object {
			c, s := cursor_open(h, a)
			if s != .Ok {
				release(h, a)
				release(h, b)
				return s
			}
			f.c, f.has_cursor = c, true
		}
		if s := small_stack_push(h, st, f); s != .Ok {
			drop_eq(h, &f)
			return s
		}
		return .Ok
	}
	st: Small_Stack(Eq_Frame, 8)
	defer {
		for k in 0 ..< st.sp {
			drop_eq(h, &st.buf[k])
		}
		for &f in st.dyn {
			drop_eq(h, &f)
		}
		delete(st.dyn)
	}
	push_eq(h, &st, retain(a), retain(b)) or_return
	for small_stack_len(&st) > 0 {
		f := small_stack_top(&st)
		x, y: Value
		if type_of(f.a) == .Array {
			if f.i >= f.n {
				drop_eq(h, f)
				small_stack_pop(&st)
				continue
			}
			x = retain(items_of(f.a)[f.i]) if f.a.kind == .Array else (element(h, f.a, f.i) or_return)
			y = retain(items_of(f.b)[f.i]) if f.b.kind == .Array else (element(h, f.b, f.i) or_return)
			f.i += 1
		} else if f.a.kind == .Object {
			if f.i >= f.n {
				drop_eq(h, f)
				small_stack_pop(&st)
				continue
			}
			e := entries_of(f.a)[f.i]
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
				small_stack_pop(&st)
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
		if open {
			if small_stack_len(&st) > depth_limit(h) {
				release(h, x)
				release(h, y)
				return false, fail(h, .Depth, .Equal)
			}
			push_eq(h, &st, x, y) or_return
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
	case .Number: return numbers_equal(a, b, heap_allocator(h)), false
	case .String: return text_of(a) == text_of(b), false
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

@(require_results)
hash :: proc(h: ^Heap, v: Value) -> (res: u64, status: Status) {
	Hash_Frame :: struct { v: Value, c: Cursor, acc: u64 }
	if t := type_of(v); t != .Array && t != .Object {
		return hash_scalar(v), .Ok
	}
	st: Small_Stack(Hash_Frame, 8)
	defer {
		for k in 0 ..< st.sp {
			cursor_close(&st.buf[k].c)
			release(h, st.buf[k].v)
		}
		for &f in st.dyn {
			cursor_close(&f.c)
			release(h, f.v)
		}
		delete(st.dyn)
	}
	open :: proc(h: ^Heap, st: ^Small_Stack(Hash_Frame, 8), v: Value) -> Status {
		c, s := cursor_open(h, v)
		if s != .Ok {
			release(h, v)
			return s
		}
		hf := Hash_Frame{v = v, c = c, acc = u64(0xA5A5) if type_of(v) == .Array else u64(0x5A5A)}
		if ps := small_stack_push(h, st, hf); ps != .Ok {
			cursor_close(&c)
			release(h, v)
			return ps
		}
		return .Ok
	}
	open(h, &st, retain(v)) or_return
	result: u64
	for small_stack_len(&st) > 0 {
		f := small_stack_top(&st)
		k, x, more := cursor_next(h, &f.c) or_return
		if !more {
			done := mix64(f.acc + u64(length_of(h, f.v)))
			cursor_close(&f.c)
			release(h, f.v)
			small_stack_pop(&st)
			if small_stack_len(&st) == 0 {
				result = done
			} else {
				parent := small_stack_top(&st)
				fold_hash(&parent.acc, done, type_of(parent.v) == .Object)
			}
			continue
		}
		if t := type_of(x); t == .Array || t == .Object {
			if k.kind != .Absent {
				fold_hash(&f.acc, hash_text(text_of(k)), true)
			}
			release(h, k)
			open(h, &st, x) or_return
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
	case .Number: return hash_number(v)
	case .String: return hash_text(text_of(v))
	}
	return mix64(u64(t) + 1)
}

@(private, require_results)
order_values :: proc(h: ^Heap, by: []Value, out: []int, coll := JSON_ORDER, descending := false, ties: []bool = nil) -> Status {
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
	for width := 1; width < n; width *= 2 {
		for lo := 0; lo < n; lo += 2 * width {
			mid, hi := min(lo + width, n), min(lo + 2 * width, n)
			i, j, k := lo, mid, lo
			for i < mid && j < hi {
				r := ordering_compare(&o, src[j], src[i]) or_return
				if descending ? r > 0 : r < 0 {
					tmp[k], j = src[j], j + 1
				} else {
					tmp[k], i = src[i], i + 1
				}
				k += 1
			}
			for ; i < mid; i += 1 { tmp[k] = src[i]; k += 1 }
			for ; j < hi; j += 1  { tmp[k] = src[j]; k += 1 }
		}
		src, tmp = tmp, src
	}
	if raw_data(src) != raw_data(out) {
		copy(out, src)
	}
	for k in 1 ..< len(ties) {
		ties[k] = (ordering_compare(&o, out[k], out[k - 1]) or_return) == 0
	}
	return .Ok
}

@(require_results)
sort_values :: proc(h: ^Heap, xs: []Value, keys: []Value = nil, coll := JSON_ORDER, descending := false, ties: []bool = nil) -> Status {
	n := len(xs)
	if n < 2 {
		return .Ok
	}
	alloc := heap_allocator(h)
	order := make([]int, n, alloc)
	if order == nil {
		return fail_memory(h)
	}
	defer delete(order, alloc)
	order_values(h, keys if keys != nil else xs, order, coll, descending, ties) or_return
	permute(h, xs, order) or_return
	if keys != nil {
		permute(h, keys, order) or_return
	}
	return .Ok
}

@(private)
int_order :: proc(h: ^Heap, by: []Value, src: []int, descending: bool) -> (res: []int, status: Status) #no_bounds_check {
	n := len(by)
	if n < 64 {
		for i in 1 ..< n {
			idx, k, j := src[i], by[src[i]].i, i - 1
			for j >= 0 && (by[src[j]].i < k if descending else by[src[j]].i > k) {
				src[j + 1] = src[j]
				j -= 1
			}
			src[j + 1] = idx
		}
		return src, .Ok
	}
	Pair :: struct { k: u64, i: int }
	hist: [8][256]u32
	flip := u64(0xFFFF_FFFF_FFFF_FFFF) if descending else u64(0)
	key_u64 :: #force_inline proc "contextless" (i: i64, flip: u64) -> u64 { return (u64(i) ~ (u64(1) << 63)) ~ flip }
	first, diff := key_u64(by[0].i, flip), u64(0)
	for v in by {
		u := key_u64(v.i, flip)
		diff |= u ~ first
		#unroll for b in uint(0) ..< 8 {
			hist[b][(u >> (b * 8)) & 0xFF] += 1
		}
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
	radix_offsets :: proc "contextless" (counts: ^[256]u32) -> (off: [256]u32) #no_bounds_check {
		sum := u32(0)
		for b in 0 ..< 256 {
			off[b], sum = sum, sum + counts[b]
		}
		return
	}
	if np == 1 {
		shift, off := passes[0] * 8, radix_offsets(&hist[passes[0]])
		for v, i in by {
			bucket := (key_u64(v.i, flip) >> shift) & 0xFF
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
	shift0, off0 := passes[0] * 8, radix_offsets(&hist[passes[0]])
	for v, i in by {
		u := key_u64(v.i, flip)
		bucket := (u >> shift0) & 0xFF
		from[off0[bucket]] = {u, i}
		off0[bucket] += 1
	}
	for p in 1 ..< np - 1 {
		shift, off := passes[p] * 8, radix_offsets(&hist[passes[p]])
		for item in from {
			bucket := (item.k >> shift) & 0xFF
			to[off[bucket]] = item
			off[bucket] += 1
		}
		from, to = to, from
	}
	shift_last, off_last := passes[np - 1] * 8, radix_offsets(&hist[passes[np - 1]])
	for item in from {
		bucket := (item.k >> shift_last) & 0xFF
		src[off_last[bucket]] = item.i
		off_last[bucket] += 1
	}
	return src, .Ok
}

@(private)
permute :: proc(h: ^Heap, xs: []Value, order: []int) -> Status {
	alloc := heap_allocator(h)
	copy_xs := make([]Value, len(xs), alloc)
	if copy_xs == nil {
		return fail_memory(h)
	}
	defer delete(copy_xs, alloc)
	copy(copy_xs, xs)
	for at, i in order {
		xs[i] = copy_xs[at]
	}
	return .Ok
}
