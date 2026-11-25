package query

import "core:slice"

// The order of many values among themselves, for a sort, a run or an extreme over n values. An object, or an array of
// one object, is read once into a form: its keys, sorted, are one of the distinct key lists, ranked once, and its values
// in key order are scalars read out of their document, and objects, to `FORM_LEVELS` levels, forms of their own.
// Comparing two forms is then a rank and a walk over values, with no allocation and no lookup by key.

@(private)
NO_SHAPE :: max(u32)

// The levels of objects in objects read into forms, which bounds the native depth of making and comparing them.
@(private)
FORM_LEVELS :: 4

// An object's prepared form: the rank of its key list among the distinct ones, and where its values lie in `Ordering.pool`.
@(private)
Form :: struct {
	shape:   u32, // `NO_SHAPE` for a value that is no object
	wrapped: bool, // the object is the only element of an array
	at:      u32,
	n:       u32,
}

// A distinct key list: its keys are `Ordering.names[at:at + n]`.
@(private)
Shape :: struct {
	hash: u64,
	at:   int,
	n:    int,
}

Ordering :: struct {
	h:      ^Heap,
	coll:   Collation,
	by:     []Value,
	forms:  []Form, // empty when no value of `by` is an object
	pool:   [dynamic]Value, // the values of every form, owned
	nest:   [dynamic]u32, // by index in `pool`, a value's form in `subs` plus one, 0 or past the end for none
	subs:   [dynamic]Form, // the forms of objects inside forms
	names:  [dynamic]Value, // the keys of every shape, owned
	shapes: [dynamic]Shape,
	table:  []u32, // the shapes by the hash of their keys: a shape's index plus one, 0 for none
}

// Prepares `by` for `ordering_compare`, `by[i]` being value `i`. `by` outlives the ordering and is not changed.
@(require_results)
ordering_init :: proc(h: ^Heap, by: []Value, coll: Collation) -> (o: Ordering, status: Status) {
	o = {h = h, coll = coll, by = by}
	has_object := false
	for v in by {
		if _, ok := object_of(v); ok {
			has_object = true
			break
		}
	}
	if !has_object {
		return o, .Ok
	}
	o.forms = make([]Form, len(by), h.allocator)
	if o.forms == nil {
		return o, fail_memory(h)
	}
	defer if status != .Ok {
		ordering_destroy(&o)
	}
	entries := make([dynamic]Entry, 0, 16, h.allocator)
	defer delete(entries)
	for v, i in by {
		obj, ok := object_of(v)
		if !ok {
			o.forms[i].shape = NO_SHAPE
			continue
		}
		form_object(&o, &entries, obj, &o.forms[i]) or_return
		o.forms[i].wrapped = v.kind == .Array
	}
	form_nested(&o, &entries) or_return
	rank_shapes(&o) or_return
	return o, .Ok
}

ordering_destroy :: proc(o: ^Ordering) {
	for v in o.pool {
		release(o.h, v)
	}
	for v in o.names {
		release(o.h, v)
	}
	delete(o.forms, o.h.allocator)
	delete(o.pool)
	delete(o.nest)
	delete(o.subs)
	delete(o.names)
	delete(o.shapes)
	delete(o.table, o.h.allocator)
	o^ = {}
}

// The order of values `i` and `j` of the ordering's `by`: -1, 0 or 1.
@(require_results)
ordering_compare :: proc(o: ^Ordering, i, j: int) -> (res: int, status: Status) #no_bounds_check {
	if len(o.forms) > 0 {
		x, y := o.forms[i], o.forms[j]
		if x.shape != NO_SHAPE && y.shape != NO_SHAPE && x.wrapped == y.wrapped {
			return #force_inline compare_forms(o, x, y, 2 if x.wrapped else 1)
		}
	}
	return compare(o.h, o.by[i], o.by[j], o.coll)
}

// The object of `v`, which is `v` or the one element of the array `v`.
@(private)
object_of :: proc(v: Value) -> (obj: Value, ok: bool) {
	if v.kind == .Array {
		items := items_of(v)
		if len(items) == 1 && type_of(items[0]) == .Object {
			return items[0], true
		}
		return v, false
	}
	return v, v.kind != .Absent && type_of(v) == .Object
}

@(private)
// `above` is the frames the walk of `compare` would hold above a pair of members: the objects' own, and those around
// them.
compare_forms :: proc(o: ^Ordering, x, y: Form, above: int) -> (res: int, status: Status) #no_bounds_check {
	if x.shape != y.shape {
		return 1 if x.shape > y.shape else -1, .Ok
	}
	xs, ys := o.pool[x.at:][:x.n], o.pool[y.at:][:y.n]
	for k in 0 ..< len(xs) {
		r, open := compare_head(xs[k], ys[k], o.coll)
		if open {
			r = compare_members(o, int(x.at) + k, int(y.at) + k, above) or_return
		}
		if r != 0 {
			return r, .Ok
		}
	}
	return 0, .Ok
}

// The order of the containers at `i` and `j` of the pool, through their forms when both have one. Kept out of
// `compare_forms`, so that its walk over scalars stays in its caller.
@(private)
compare_members :: #force_no_inline proc(o: ^Ordering, i, j: int, above: int) -> (res: int, status: Status) {
	if above > depth_limit(o.h) {
		return 0, fail(o.h, .Depth, .Compare)
	}
	if i < len(o.nest) && j < len(o.nest) && o.nest[i] != 0 && o.nest[j] != 0 {
		x, y := o.nest[i], o.nest[j]
		return compare_forms(o, o.subs[x - 1], o.subs[y - 1], above + 1)
	}
	return compare_below(o.h, o.pool[i], o.pool[j], o.coll, above)
}

// The form of object `obj`: its shape and its values in key order.
@(private)
form_object :: proc(o: ^Ordering, entries: ^[dynamic]Entry, obj: Value, form: ^Form) -> (status: Status) {
	h := o.h
	clear(entries)
	defer if status != .Ok {
		for e in entries {
			release(h, e.key)
			release(h, e.value)
		}
		clear(entries)
	}
	c := cursor_open(h, obj) or_return
	defer cursor_close(&c)
	for {
		k, x, more := cursor_next(h, &c) or_return
		if !more {
			break
		}
		if _, err := append(entries, Entry{k, x}); err != nil {
			release(h, k)
			release(h, x)
			return fail_memory(h)
		}
	}
	sort_texts(entries[:])
	// Room for everything the form adds is made first, so that nothing after it fails and the entries stay owned by
	// `entries` until then.
	n := len(entries)
	if !room(&o.pool, n) || !room(&o.names, n) || !room(&o.shapes, 1) {
		return fail_memory(h)
	}
	if (len(o.shapes) + 1) * 2 > len(o.table) {
		grow_shapes(o) or_return
	}
	form.shape = u32(intern_shape(o, entries[:]))
	form.at, form.n = u32(len(o.pool)), u32(n)
	for e in entries {
		append(&o.pool, scalar_form(h, e.value))
	}
	clear(entries)
	return .Ok
}

// Reads the objects among the values of the forms into forms of their own, a level at a time, the values of one level
// lying in the pool after those of the level above.
@(private)
form_nested :: #force_no_inline proc(o: ^Ordering, entries: ^[dynamic]Entry) -> Status {
	lo, hi := 0, len(o.pool)
	for _ in 1 ..< FORM_LEVELS {
		for k in lo ..< hi {
			v := o.pool[k]
			if v.kind == .Absent || type_of(v) != .Object {
				continue
			}
			sub: Form
			form_object(o, entries, v, &sub) or_return
			if _, err := append(&o.subs, sub); err != nil {
				return fail_memory(o.h)
			}
			if len(o.nest) <= k && resize(&o.nest, max(k + 1, 2 * len(o.nest))) != nil {
				return fail_memory(o.h)
			}
			o.nest[k] = u32(len(o.subs))
		}
		lo, hi = hi, len(o.pool)
	}
	return .Ok
}

// Makes room in `a` for `n` more elements, growing by doubling.
@(private)
room :: proc(a: ^[dynamic]$T, n: int) -> bool {
	want := len(a) + n
	if want <= cap(a) {
		return true
	}
	return reserve(a, max(want, 2 * cap(a))) == nil
}

// `v` as it is compared: a document's number as an integer or double, its string with no escape as borrowed text. The
// document outlives the ordering, as `by` holds it.
@(private)
scalar_form :: proc(h: ^Heap, v: Value) -> Value {
	if v.kind != .Node {
		return v
	}
	t := node_token(v)
	#partial switch t.kind {
	case .Number:
		r := settle(v)
		release(h, v)
		return r
	case .String, .Plain:
		r := text_borrowed(text_of(v))
		release(h, v)
		return r
	}
	return v
}

// The index of the shape of the sorted `entries`' keys, added when new. It takes the keys over, releasing them when the
// shape is known.
@(private)
intern_shape :: proc(o: ^Ordering, entries: []Entry) -> int {
	hash := u64(len(entries))
	for e in entries {
		hash = mix64(hash ~ hash_text(text_of(e.key)))
	}
	mask := len(o.table) - 1
	at := int(hash) & mask
	for o.table[at] != 0 {
		s := o.shapes[o.table[at] - 1]
		if s.hash == hash && s.n == len(entries) && same_keys(o.names[s.at:][:s.n], entries) {
			for e in entries {
				release(o.h, e.key)
			}
			return int(o.table[at]) - 1
		}
		at = (at + 1) & mask
	}
	append(&o.shapes, Shape{hash = hash, at = len(o.names), n = len(entries)})
	for e in entries {
		append(&o.names, e.key)
	}
	o.table[at] = u32(len(o.shapes))
	return len(o.shapes) - 1
}

@(private)
same_keys :: proc(names: []Value, entries: []Entry) -> bool {
	for e, k in entries {
		if text_of(names[k]) != text_of(e.key) {
			return false
		}
	}
	return true
}

// Doubles the table of shapes, from 16 slots, and files the shapes again.
@(private)
grow_shapes :: proc(o: ^Ordering) -> Status {
	table := make([]u32, max(16, 2 * len(o.table)), o.h.allocator)
	if table == nil {
		return fail_memory(o.h)
	}
	mask := len(table) - 1
	for s, i in o.shapes {
		at := int(s.hash) & mask
		for table[at] != 0 {
			at = (at + 1) & mask
		}
		table[at] = u32(i + 1)
	}
	delete(o.table, o.h.allocator)
	o.table = table
	return .Ok
}

// Replaces the shape of every form by its rank among the distinct key lists, in the order of key lists.
@(private)
rank_shapes :: proc(o: ^Ordering) -> Status {
	n := len(o.shapes)
	ids := make([]u32, 2 * n, o.h.allocator)
	if ids == nil {
		return fail_memory(o.h)
	}
	defer delete(ids, o.h.allocator)
	sorted, rank := ids[:n], ids[n:]
	for i in 0 ..< n {
		sorted[i] = u32(i)
	}
	slice.sort_by_with_data(sorted, proc(a, b: u32, data: rawptr) -> bool {
		o := (^Ordering)(data)
		x, y := o.shapes[a], o.shapes[b]
		xs, ys := o.names[x.at:][:x.n], o.names[y.at:][:y.n]
		for k in 0 ..< min(len(xs), len(ys)) {
			p, q := text_of(xs[k]), text_of(ys[k])
			if p != q {
				return p < q
			}
		}
		return len(xs) < len(ys)
	}, o)
	for id, r in sorted {
		rank[id] = u32(r)
	}
	for &f in o.forms {
		if f.shape != NO_SHAPE {
			f.shape = rank[f.shape]
		}
	}
	for &f in o.subs {
		f.shape = rank[f.shape]
	}
	return .Ok
}
