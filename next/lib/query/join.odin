package query

import "core:fmt"
import "core:math"

// Relational hash-index and join primitives over `query.Value` and `query.Heap`.
// Supports O(1) amortized lookup on any value key (including strings, `1 == 1.0` numeric equality,
// big ints, booleans, null, arrays, objects), duplicate-key grouping preserving insertion order,
// inner/left-outer/semi joins, and key-indexed lookup objects `{key: row}`.
// All internal index allocations flow through `heap_allocator(h)` so `Budget.memory` and OOM
// cleanup remain exact with zero `core:os` or `context.temp_allocator` usage.

Join_Kind :: enum u8 {
	Inner,
	Left,
	Semi,
}

Join_Combine :: enum u8 {
	Pair,        // `[left, right]` (or `[left, null]` for unmatched `.Left` outer join)
	Merge_Right, // `left + right` (right overwrites overlapping keys; `left` if unmatched `.Left`)
	Merge_Left,  // `right + left` (left preserves overlapping keys; `left` if unmatched `.Left`)
}

// Extracts the join key from `row`. Returning `ok = false` or `.Absent` skips indexing/matching that row.
Key_Extractor :: #type proc(ctx: rawptr, h: ^Heap, row: Value) -> (key: Value, ok: bool, status: Status)

@(private = "file")
Index_Group :: struct {
	key:   Value, // retained distinct key
	hash:  u64,
	head:  i32, // head index into builder `next` chain
	tail:  i32, // tail index into builder `next` chain
	lo:    u32, // start offset in `packed` once sealed
	count: u32, // number of right rows in this group
}

// O(1) amortized multi-map hash index from normalized `query.Value` keys to retained right-side rows
// in insertion order. Build via `hash_index_build` / `hash_index_build_field` (or `hash_index_init` +
// `hash_index_add` + `hash_index_seal`) and always release via `hash_index_destroy`.
Hash_Index :: struct {
	h:       ^Heap,
	groups:  [dynamic]Index_Group,
	rows:    [dynamic]Value, // staging rows during build; cleared once `packed` is materialized
	next:    [dynamic]i32,   // intrusive per-row chain during build
	packed:  []Value,        // contiguous retained rows grouped by distinct key after seal
	buckets: []i32,          // open-addressing slots holding (group_idx + 1), 0 = empty
	sealed:  bool,
}

// Initializes an empty incremental `Hash_Index` backed by `h`.
hash_index_init :: proc(idx: ^Hash_Index, h: ^Heap) {
	if idx == nil {
		return
	}
	idx^ = {h = h}
	if h != nil {
		alloc := heap_allocator(h)
		idx.groups.allocator = alloc
		idx.rows.allocator = alloc
		idx.next.allocator = alloc
	}
}

// Releases all retained values and frees all internal allocations held by `idx`. Safe on zero value.
hash_index_destroy :: proc(idx: ^Hash_Index) {
	if idx == nil {
		return
	}
	if h := idx.h; h != nil {
		alloc := heap_allocator(h)
		for g in idx.groups {
			release(h, g.key)
		}
		for r in idx.rows {
			release(h, r)
		}
		for r in idx.packed {
			release(h, r)
		}
		delete(idx.groups)
		delete(idx.rows)
		delete(idx.next)
		delete(idx.packed, alloc)
		delete(idx.buckets, alloc)
	}
	idx^ = {}
}

// Inserts `(key, row)` into `idx`, preserving insertion order for duplicate keys. Both values are retained
// on success. Rows with `.Absent` or `NaN` keys are skipped (returning `.Ok`) because they can never match.
hash_index_add :: proc(idx: ^Hash_Index, key, row: Value) -> Status {
	if idx == nil || idx.h == nil {
		return .Error
	}
	h := idx.h
	if idx.sealed {
		hash_index_unseal(idx) or_return
	}
	if !(join_key_matchable(h, key) or_return) {
		return .Ok
	}
	kh := hash(h, key) or_return
	if (len(idx.groups) + 1) * 2 > len(idx.buckets) {
		rehash_groups(idx, max(16, len(idx.buckets) * 2)) or_return
	}
	mask := len(idx.buckets) - 1
	at := int(kh) & mask
	for {
		slot := idx.buckets[at]
		if slot == 0 {
			break
		}
		gi := int(slot - 1)
		if idx.groups[gi].hash == kh && (equal(h, idx.groups[gi].key, key) or_return) {
			row_idx := stage_row(idx, row) or_return
			g := &idx.groups[gi]
			idx.next[g.tail] = row_idx
			g.tail = row_idx
			g.count += 1
			return .Ok
		}
		at = (at + 1) & mask
	}
	row_idx := stage_row(idx, row) or_return
	if _, err := append(&idx.groups, Index_Group{hash = kh, head = row_idx, tail = row_idx, count = 1}); err != nil {
		release(h, pop(&idx.rows))
		pop(&idx.next)
		return fail_memory(h)
	}
	idx.groups[len(idx.groups) - 1].key = retain(key)
	idx.buckets[at] = i32(len(idx.groups))
	return .Ok
}

// Materializes contiguous per-group slices into `idx.packed` so `hash_index_lookup` returns a direct
// `[]Value` slice with zero allocations. Calling `hash_index_seal` on an already sealed index is a no-op.
hash_index_seal :: proc(idx: ^Hash_Index) -> Status {
	if idx == nil || idx.h == nil || idx.sealed {
		return .Ok
	}
	h := idx.h
	alloc := heap_allocator(h)
	if total := len(idx.rows); total > 0 {
		packed, err := make([]Value, total, alloc)
		if err != nil {
			return fail_memory(h)
		}
		cursor := u32(0)
		for &g in idx.groups {
			g.lo = cursor
			for cur := g.head; cur >= 0; cur = idx.next[cur] {
				packed[cursor] = retain(idx.rows[cur])
				cursor += 1
			}
		}
		for r in idx.rows {
			release(h, r)
		}
		idx.packed = packed
	}
	delete(idx.rows)
	delete(idx.next)
	idx.rows = nil
	idx.rows.allocator = alloc
	idx.next = nil
	idx.next.allocator = alloc
	idx.sealed = true
	return .Ok
}

// Builds and seals a `Hash_Index` over all rows in `collection` (`.Array` elements or `.Object` member
// values) keyed by `extractor`. When `extractor == nil`, rows themselves serve as keys (useful for semi-joins).
@(require_results)
hash_index_build :: proc(h: ^Heap, collection: Value, extractor: Key_Extractor, ctx: rawptr = nil) -> (out: Hash_Index, status: Status) {
	if h == nil {
		return {}, .Error
	}
	if ct := type_of(collection); ct != .Array && ct != .Object {
		return {}, fail(h, .Types, .Iterate, collection)
	}
	idx: Hash_Index
	hash_index_init(&idx, h)
	defer if status != .Ok {
		hash_index_destroy(&idx)
	}
	if n := length_of(h, collection); n > 0 {
		if reserve(&idx.rows, n) != nil || reserve(&idx.next, n) != nil || reserve(&idx.groups, min(n, 64)) != nil {
			return {}, fail_memory(h)
		}
		cap_b := 16
		for cap_b < 2 * n {
			cap_b <<= 1
		}
		rehash_groups(&idx, cap_b) or_return
	}
	cur := cursor_open(h, collection) or_return
	defer cursor_close(&cur)
	for {
		k, row, more := cursor_next(h, &cur) or_return
		release(h, k)
		if !more {
			break
		}
		defer release(h, row)
		key, has_key := extract_join_key(h, extractor, ctx, row) or_return
		defer release(h, key)
		if has_key && key.kind != .Absent {
			hash_index_add(&idx, key, row) or_return
		}
	}
	hash_index_seal(&idx) or_return
	return idx, .Ok
}

// Convenience wrapper building a `Hash_Index` keyed by object member `key_field` on each row.
@(require_results)
hash_index_build_field :: proc(h: ^Heap, collection: Value, key_field: string) -> (Hash_Index, Status) {
	ctx := Field_Key_Ctx{field = key_field}
	return hash_index_build(h, collection, field_key_extractor, &ctx)
}

@(private = "file")
lookup_group :: proc(idx: ^Hash_Index, key: Value, need_seal: bool) -> (gi: int, found: bool, status: Status) {
	if idx == nil || idx.h == nil || len(idx.groups) == 0 {
		return 0, false, .Ok
	}
	if !(join_key_matchable(idx.h, key) or_return) {
		return 0, false, .Ok
	}
	if need_seal && !idx.sealed {
		hash_index_seal(idx) or_return
	}
	return find_group(idx, key)
}

// Looks up all right rows matching `key` in O(1) amortized time without allocating.
@(require_results)
hash_index_lookup :: proc(idx: ^Hash_Index, key: Value) -> (matches: []Value, status: Status) {
	gi, found := lookup_group(idx, key, true) or_return
	if !found {
		return nil, .Ok
	}
	g := idx.groups[gi]
	return idx.packed[g.lo:g.lo + g.count], .Ok
}

// Reports whether at least one row in `idx` matches `key`.
@(require_results)
hash_index_has :: proc(idx: ^Hash_Index, key: Value) -> (found: bool, status: Status) {
	_, found, status = lookup_group(idx, key, false)
	return
}

// Returns the number of rows matching `key`.
@(require_results)
hash_index_count :: proc(idx: ^Hash_Index, key: Value) -> (count: int, status: Status) {
	gi, found := lookup_group(idx, key, false) or_return
	return (int(idx.groups[gi].count) if found else 0), .Ok
}

// Combines a matched `(left, right)` pair (or `(left, NULL)` when `!has_right` under left outer join)
// according to `combine`.
@(require_results)
join_combine_rows :: proc(h: ^Heap, left, right: Value, has_right: bool, combine: Join_Combine) -> (res: Value, status: Status) {
	if combine == .Pair {
		arr := make_array(h, 2) or_return
		defer if status != .Ok {
			release(h, arr)
		}
		append_owned(h, &arr, retain(left)) or_return
		append_owned(h, &arr, retain(right) if has_right else NULL) or_return
		return arr, .Ok
	}
	if !has_right {
		return retain(left), .Ok
	}
	if type_of(left) != .Object || type_of(right) != .Object {
		return join_combine_rows(h, left, right, true, .Pair)
	}
	if combine == .Merge_Right {
		return object_merge(h, left, right, deep = false)
	}
	return object_merge(h, right, left, deep = false)
}

// Performs an O(N + M) hash join between `left` and `right` collections using key extractors `left_key`
// and `right_key`. Preserves left input order and, for 1-to-many matches, right input order.
@(require_results)
hash_join :: proc(
	h: ^Heap,
	left, right: Value,
	left_key, right_key: Key_Extractor,
	ctx: rawptr = nil,
	kind := Join_Kind.Inner,
	combine := Join_Combine.Pair,
) -> (res: Value, status: Status) {
	if h == nil {
		return NULL, .Error
	}
	if lt := type_of(left); lt != .Array && lt != .Object {
		return NULL, fail(h, .Types, .Iterate, left)
	}
	idx := hash_index_build(h, right, right_key, ctx) or_return
	defer hash_index_destroy(&idx)

	out := make_array(h, length_of(h, left)) or_return
	defer if status != .Ok {
		release(h, out)
	}
	cur := cursor_open(h, left) or_return
	defer cursor_close(&cur)
	for {
		k, lrow, more := cursor_next(h, &cur) or_return
		release(h, k)
		if !more {
			break
		}
		defer release(h, lrow)
		lkey, has_key := extract_join_key(h, left_key, ctx, lrow) or_return
		defer release(h, lkey)
		matches: []Value
		if has_key && lkey.kind != .Absent {
			matches = hash_index_lookup(&idx, lkey) or_return
		}
		switch kind {
		case .Inner, .Left:
			if len(matches) == 0 {
				if kind == .Left {
					joined := join_combine_rows(h, lrow, ABSENT, false, combine) or_return
					append_owned(h, &out, joined) or_return
				}
			} else {
				for rrow in matches {
					joined := join_combine_rows(h, lrow, rrow, true, combine) or_return
					append_owned(h, &out, joined) or_return
				}
			}
		case .Semi:
			if len(matches) > 0 {
				append_owned(h, &out, retain(lrow)) or_return
			}
		}
	}
	return out, .Ok
}

// Convenience hash join matching `left[left_field]` against `right[right_field]`.
@(require_results)
hash_join_fields :: proc(
	h: ^Heap,
	left, right: Value,
	left_field, right_field: string,
	kind := Join_Kind.Inner,
	combine := Join_Combine.Merge_Left,
) -> (Value, Status) {
	Pair_Ctx :: struct {
		left_field, right_field: string,
	}
	extract_l :: proc(ctx: rawptr, hp: ^Heap, row: Value) -> (Value, bool, Status) {
		return extract_object_field(hp, row, (^Pair_Ctx)(ctx).left_field)
	}
	extract_r :: proc(ctx: rawptr, hp: ^Heap, row: Value) -> (Value, bool, Status) {
		return extract_object_field(hp, row, (^Pair_Ctx)(ctx).right_field)
	}
	c := Pair_Ctx{left_field = left_field, right_field = right_field}
	return hash_join(h, left, right, extract_l, extract_r, &c, kind, combine)
}

// Builds a key-indexed lookup object `{key_text: row}` (or `{key_text: [rows]}` when `group_dups`
// is true) in a single O(N) pass over `collection`. Scalar keys use canonical text (`"1"` for `1` and `1.0`).
@(require_results)
index_by :: proc(
	h: ^Heap,
	collection: Value,
	extractor: Key_Extractor,
	ctx: rawptr = nil,
	group_dups := false,
) -> (res: Value, status: Status) {
	if h == nil {
		return NULL, .Error
	}
	if ct := type_of(collection); ct != .Array && ct != .Object {
		return NULL, fail(h, .Types, .Iterate, collection)
	}
	Group_Bucket :: struct {
		key, arr: Value,
	}
	alloc := heap_allocator(h)
	n := length_of(h, collection)
	obj := make_object(h, n) or_return
	buckets: [dynamic]Group_Bucket
	buckets.allocator = alloc
	defer {
		if status != .Ok || group_dups {
			release(h, obj)
		}
		for &bk in buckets {
			release(h, bk.key)
			release(h, bk.arr)
		}
		delete(buckets)
	}
	if group_dups && n > 0 && reserve(&buckets, min(n, 64)) != nil {
		return NULL, fail_memory(h)
	}
	cur := cursor_open(h, collection) or_return
	defer cursor_close(&cur)
	for {
		k, row, more := cursor_next(h, &cur) or_return
		release(h, k)
		if !more {
			break
		}
		key, has_key, ks := extract_join_key(h, extractor, ctx, row)
		if ks != .Ok {
			release(h, row)
			release(h, key)
			return NULL, ks
		}
		matchable, ms := join_key_matchable(h, key)
		if ms != .Ok || !has_key || !matchable {
			release(h, row)
			release(h, key)
			if ms != .Ok {
				return NULL, ms
			}
			continue
		}
		kstr, kstatus := canonical_index_key(h, key)
		release(h, key)
		if kstatus != .Ok || kstr.kind == .Absent {
			release(h, row)
			if kstatus != .Ok {
				return NULL, kstatus
			}
			continue
		}
		if !group_dups {
			object_put(h, &obj, kstr, row) or_return
			continue
		}
		existing, es := member(h, obj, text_of(kstr))
		if es != .Ok {
			release(h, kstr)
			release(h, row)
			return NULL, es
		}
		if existing.kind == .Absent {
			bucket, bs := make_array(h, 1)
			if bs != .Ok {
				release(h, kstr)
				release(h, row)
				return NULL, bs
			}
			if ps := append_owned(h, &bucket, row); ps != .Ok {
				release(h, bucket)
				release(h, kstr)
				return NULL, ps
			}
			gi := i64(len(buckets))
			if _, aerr := append(&buckets, Group_Bucket{key = kstr, arr = bucket}); aerr != nil {
				release(h, bucket)
				release(h, kstr)
				return NULL, fail_memory(h)
			}
			object_put(h, &obj, retain(kstr), int_value(gi)) or_return
		} else {
			release(h, kstr)
			append_owned(h, &buckets[int(existing.i)].arr, row) or_return
		}
	}
	if !group_dups {
		return obj, .Ok
	}
	release(h, obj)
	obj = ABSENT
	out := make_object(h, len(buckets)) or_return
	defer if status != .Ok {
		release(h, out)
	}
	for &bk in buckets {
		bk_key, bk_arr := bk.key, bk.arr
		bk = {}
		object_put(h, &out, bk_key, bk_arr) or_return
	}
	return out, .Ok
}

// Convenience lookup-object builder keyed by object member `key_field`.
@(require_results)
index_by_field :: proc(h: ^Heap, collection: Value, key_field: string, group_dups := false) -> (Value, Status) {
	ctx := Field_Key_Ctx{field = key_field}
	return index_by(h, collection, field_key_extractor, &ctx, group_dups)
}

// Converts a scalar/value join key to canonical string form without touching `context.temp_allocator`,
// ensuring numeric equivalence (`1` and `1.0` both format to `"1"`), sorted keys on compound objects,
// and distinct markers for `+Inf`/`-Inf`.
@(require_results)
canonical_index_key :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	switch type_of(v) {
	case .Absent:
		return ABSENT, .Ok
	case .Null:
		return text_borrowed("null"), .Ok
	case .False:
		return text_borrowed("false"), .Ok
	case .True:
		return text_borrowed("true"), .Ok
	case .String:
		return text_value(h, text_of(v))
	case .Number:
		num := number_of(h, v) or_return
		defer release(h, num)
		if num.kind == .Double {
			if math.is_nan(num.f) {
				return ABSENT, .Ok
			}
			if math.is_inf(num.f, 1) {
				return text_borrowed("Infinity"), .Ok
			}
			if math.is_inf(num.f, -1) {
				return text_borrowed("-Infinity"), .Ok
			}
		}
		if iv, is_int := as_i64(num); is_int {
			buf: [32]u8
			return text_value(h, fmt.bprintf(buf[:], "%d", iv))
		}
		return format_json_owned(h, num)
	case .Array, .Object:
		return format_json_owned(h, v)
	}
	return ABSENT, .Ok
}

// ---- Private helpers

@(private = "file")
Field_Key_Ctx :: struct {
	field: string,
}

@(private = "file")
field_key_extractor :: proc(ctx: rawptr, h: ^Heap, row: Value) -> (Value, bool, Status) {
	return extract_object_field(h, row, (^Field_Key_Ctx)(ctx).field)
}

@(private = "file")
extract_object_field :: proc(h: ^Heap, row: Value, field: string) -> (res: Value, ok: bool, status: Status) {
	if type_of(row) != .Object {
		return ABSENT, false, .Ok
	}
	v := member(h, row, field) or_return
	return v, v.kind != .Absent, .Ok
}

@(private = "file")
extract_join_key :: proc(h: ^Heap, extractor: Key_Extractor, ctx: rawptr, row: Value) -> (Value, bool, Status) {
	if extractor != nil {
		return extractor(ctx, h, row)
	}
	return retain(row), true, .Ok
}

@(private = "file")
format_json_owned :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	buf := make([dynamic]u8, 0, 32, heap_allocator(h))
	if buf == nil {
		return ABSENT, fail_memory(h)
	}
	defer delete(buf)
	write_json(h, &buf, v, {sort_keys = true}) or_return
	return text_value(h, string(buf[:]))
}

@(private = "file")
join_key_matchable :: proc(h: ^Heap, v: Value) -> (ok: bool, status: Status) {
	if v.kind == .Absent {
		return false, .Ok
	}
	if type_of(v) != .Number || v.kind == .Int || v.kind == .Big {
		return true, .Ok
	}
	if v.kind == .Double {
		return !math.is_nan(v.f), .Ok
	}
	if h != nil {
		num := number_of(h, v) or_return
		defer release(h, num)
		return !(num.kind == .Double && math.is_nan(num.f)), .Ok
	}
	return !math.is_nan(as_f64(v)), .Ok
}

@(private = "file")
rehash_groups :: proc(idx: ^Hash_Index, new_cap: int) -> Status {
	alloc := heap_allocator(idx.h)
	buckets, err := make([]i32, new_cap, alloc)
	if err != nil {
		return fail_memory(idx.h)
	}
	mask := new_cap - 1
	for g, gi in idx.groups {
		at := int(g.hash) & mask
		for buckets[at] != 0 {
			at = (at + 1) & mask
		}
		buckets[at] = i32(gi + 1)
	}
	delete(idx.buckets, alloc)
	idx.buckets = buckets
	return .Ok
}

@(private = "file")
find_group :: proc(idx: ^Hash_Index, key: Value) -> (gi: int, found: bool, status: Status) {
	h := idx.h
	kh := hash(h, key) or_return
	if len(idx.buckets) == 0 {
		return 0, false, .Ok
	}
	mask := len(idx.buckets) - 1
	for at := int(kh) & mask; ; at = (at + 1) & mask {
		slot := idx.buckets[at]
		if slot == 0 {
			return 0, false, .Ok
		}
		cand := int(slot - 1)
		if idx.groups[cand].hash == kh && (equal(h, idx.groups[cand].key, key) or_return) {
			return cand, true, .Ok
		}
	}
}

@(private = "file")
stage_row :: proc(idx: ^Hash_Index, row: Value) -> (row_idx: i32, status: Status) {
	row_idx = i32(len(idx.rows))
	if _, err := append(&idx.rows, ABSENT); err != nil {
		return 0, fail_memory(idx.h)
	}
	if _, err := append(&idx.next, i32(-1)); err != nil {
		pop(&idx.rows)
		return 0, fail_memory(idx.h)
	}
	idx.rows[row_idx] = retain(row)
	return row_idx, .Ok
}

@(private = "file")
hash_index_unseal :: proc(idx: ^Hash_Index) -> Status {
	h := idx.h
	alloc := heap_allocator(h)
	if n := len(idx.packed); n > 0 {
		if reserve(&idx.rows, n) != nil || reserve(&idx.next, n) != nil {
			return fail_memory(h)
		}
		for &g in idx.groups {
			first := i32(len(idx.rows))
			for j in u32(0) ..< g.count {
				cur := stage_row(idx, idx.packed[g.lo + j]) or_return
				if j > 0 {
					idx.next[cur - 1] = cur
				}
			}
			g.head, g.tail, g.lo = first, first + i32(g.count) - 1, 0
		}
		for r in idx.packed {
			release(h, r)
		}
		delete(idx.packed, alloc)
		idx.packed = nil
	}
	idx.sealed = false
	return .Ok
}
