package query

// Reshaping arrays of records: fill_forward, melt (wide -> long), and pivot (long -> wide).

@(require_results)
fill_forward :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if type_of(v) != .Array {
		return NULL, fail(h, .Types, .Iterate, v)
	}
	xs := built(h, v) or_return
	defer release(h, xs)
	seen := make_object(h, 0) or_return
	defer release(h, seen)
	last := NULL
	defer release(h, last)
	out := make_array(h, len(items_of(xs))) or_return
	defer if status != .Ok { release(h, out) }
	for x in items_of(xs) {
		append_owned(h, &out, fill_one(h, x, &last, &seen) or_return) or_return
	}
	return out, .Ok
}

@(private)
fill_one :: proc(h: ^Heap, x: Value, last, seen: ^Value) -> (res: Value, status: Status) {
	#partial switch type_of(x) {
	case .Null:   return retain(last^), .Ok
	case .Object:
	case:
		release(h, last^)
		last^ = retain(x)
		return retain(x), .Ok
	}
	row := built(h, x) or_return
	defer if status != .Ok { release(h, row) }
	for e in entries_of(row) {
		if type_of(e.value) != .Null {
			object_put(h, seen, retain(e.key), retain(e.value)) or_return
		}
	}
	for e in entries_of(row) {
		if type_of(e.value) == .Null {
			if before := member(h, seen^, text_of(e.key)) or_return; before.kind != .Absent {
				object_put(h, &row, retain(e.key), before) or_return
			}
		}
	}
	return row, .Ok
}

@(require_results)
melt :: proc(h: ^Heap, v, ids, var, val: Value) -> (res: Value, status: Status) {
	xs := reshaped(h, v, ids, var, val) or_return
	defer release(h, xs)
	out := make_array(h, len(items_of(xs))) or_return
	defer if status != .Ok { release(h, out) }
	for r in items_of(xs) {
		melt_row(h, r, ids, var, val, &out) or_return
	}
	return out, .Ok
}

@(private)
melt_row :: proc(h: ^Heap, r, ids, var, val: Value, out: ^Value) -> Status {
	row := built(h, r) or_return
	defer release(h, row)
	id := id_of(h, row, ids) or_return
	defer release(h, id)
	for e in entries_of(row) {
		if in_ids(h, e.key, ids) or_return {
			continue
		}
		long := retain(id)
		s := object_put(h, &long, retain(var), retain(e.key))
		if s == .Ok { s = object_put(h, &long, retain(val), retain(e.value)) }
		if s == .Ok { s = append_owned(h, out, long) } else { release(h, long) }
		if s != .Ok { return s }
	}
	return .Ok
}

@(require_results)
pivot :: proc(h: ^Heap, v, ids, var, val: Value, coll := JSON_ORDER) -> (res: Value, status: Status) {
	xs := reshaped(h, v, ids, var, val) or_return
	defer release(h, xs)
	rows := items_of(xs)
	keys := make_array(h, len(rows)) or_return
	defer release(h, keys)
	names := make_array(h, len(rows)) or_return
	defer release(h, names)
	for r in rows {
		append_owned(h, &keys, id_of(h, r, ids) or_return) or_return
		append_owned(h, &names, member_or_null(h, r, var) or_return) or_return
	}
	cols := runs_by(h, names, ABSENT, .First, coll) or_return
	defer release(h, cols)
	groups := runs_by(h, xs, keys, .Group, coll) or_return
	defer release(h, groups)
	out := make_array(h, len(items_of(groups))) or_return
	defer if status != .Ok { release(h, out) }
	for g in items_of(groups) {
		append_owned(h, &out, pivot_group(h, items_of(g), ids, var, val, items_of(cols)) or_return) or_return
	}
	return out, .Ok
}

@(private)
pivot_group :: proc(h: ^Heap, rows: []Value, ids, var, val: Value, cols: []Value) -> (res: Value, status: Status) {
	wide := id_of(h, rows[0], ids) or_return
	defer if status != .Ok { release(h, wide) }
	for c in cols {
		if type_of(c) != .String {
			return NULL, fail(h, .Types, .Index, wide, c, detail = "object key")
		}
		x := NULL
		#reverse for r in rows {
			name := member_or_null(h, r, var) or_return
			same, s := equal(h, name, c)
			release(h, name)
			if s == .Ok && same { x, s = member_or_null(h, r, val) }
			if s != .Ok { return NULL, s }
			if same { break }
		}
		object_put(h, &wide, retain(c), x) or_return
	}
	return wide, .Ok
}

@(private)
reshaped :: proc(h: ^Heap, v, ids, var, val: Value) -> (res: Value, status: Status) {
	if type_of(v) != .Array {
		return NULL, fail(h, .Types, .Iterate, v)
	}
	if type_of(ids) != .Array || type_of(var) != .String || type_of(val) != .String {
		return NULL, fail(h, .Types, .Reshape, ids)
	}
	xs := built(h, v) or_return
	for r in items_of(xs) {
		if type_of(r) != .Object {
			release(h, xs)
			return NULL, fail(h, .Types, .Keys, r)
		}
	}
	return xs, .Ok
}

@(private)
id_of :: proc(h: ^Heap, r, ids: Value) -> (res: Value, status: Status) {
	row := built(h, r) or_return
	defer release(h, row)
	id := make_object(h, 0) or_return
	defer if status != .Ok { release(h, id) }
	for e in entries_of(row) {
		if in_ids(h, e.key, ids) or_return {
			object_put(h, &id, retain(e.key), retain(e.value)) or_return
		}
	}
	return id, .Ok
}

@(private)
in_ids :: proc(h: ^Heap, key, ids: Value) -> (res: bool, status: Status) {
	c := cursor_open(h, ids) or_return
	defer cursor_close(&c)
	for {
		_, id, more := cursor_next(h, &c) or_return
		if !more {
			return false, .Ok
		}
		same, s := equal(h, key, id)
		release(h, id)
		if s != .Ok || same {
			return same, s
		}
	}
}

@(private)
member_or_null :: proc(h: ^Heap, r, key: Value) -> (res: Value, status: Status) {
	x := member(h, r, text_of(key)) or_return
	return NULL if x.kind == .Absent else x, .Ok
}
