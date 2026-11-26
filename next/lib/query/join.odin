package query

import "core:fmt"
import "core:math"
import "stury:lib/core/tape"

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
	if idx.h != nil {
		h := idx.h
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
		if status := hash_index_unseal(idx); status != .Ok {
			return status
		}
	}
	matchable, ms := join_key_matchable(h, key)
	if ms != .Ok {
		return ms
	}
	if !matchable {
		return .Ok
	}
	kh, hstatus := hash(h, key)
	if hstatus != .Ok {
		return hstatus
	}
	if (len(idx.groups) + 1) * 2 > len(idx.buckets) {
		new_cap := max(16, len(idx.buckets) * 2)
		if status := rehash_groups(idx, new_cap); status != .Ok {
			return status
		}
	}
	mask := len(idx.buckets) - 1
	at := int(kh) & mask
	for {
		slot := idx.buckets[at]
		if slot == 0 {
			break
		}
		gi := int(slot - 1)
		if idx.groups[gi].hash == kh {
			same, eq_status := equal(h, idx.groups[gi].key, key)
			if eq_status != .Ok {
				return eq_status
			}
			if same {
				return append_row_to_group(idx, gi, row)
			}
		}
		at = (at + 1) & mask
	}
	return insert_new_group(idx, at, key, kh, row)
}

// Materializes contiguous per-group slices into `idx.packed` so `hash_index_lookup` returns a direct
// `[]Value` slice with zero allocations. Calling `hash_index_seal` on an already sealed index is a no-op.
hash_index_seal :: proc(idx: ^Hash_Index) -> Status {
	if idx == nil || idx.h == nil || idx.sealed {
		return .Ok
	}
	h := idx.h
	alloc := heap_allocator(h)
	total := len(idx.rows)
	if total == 0 {
		delete(idx.rows)
		delete(idx.next)
		idx.rows = nil
		idx.rows.allocator = alloc
		idx.next = nil
		idx.next.allocator = alloc
		idx.sealed = true
		return .Ok
	}
	packed, err := make([]Value, total, alloc)
	if err != nil {
		return fail_memory(h)
	}
	cursor := u32(0)
	for &g in idx.groups {
		g.lo = cursor
		cur := g.head
		for cur >= 0 {
			packed[cursor] = retain(idx.rows[cur])
			cursor += 1
			cur = idx.next[cur]
		}
	}
	for r in idx.rows {
		release(h, r)
	}
	delete(idx.rows)
	delete(idx.next)
	idx.rows = nil
	idx.rows.allocator = alloc
	idx.next = nil
	idx.next.allocator = alloc
	idx.packed = packed
	idx.sealed = true
	return .Ok
}

// Builds and seals a `Hash_Index` over all rows in `collection` (`.Array` elements or `.Object` member
// values) keyed by `extractor`. When `extractor == nil`, rows themselves serve as keys (useful for semi-joins).
@(require_results)
hash_index_build :: proc(h: ^Heap, collection: Value, extractor: Key_Extractor, ctx: rawptr = nil) -> (Hash_Index, Status) {
	if h == nil {
		return {}, .Error
	}
	ct := type_of(collection)
	if ct != .Array && ct != .Object {
		return {}, fail(h, .Types, .Iterate, collection)
	}
	idx: Hash_Index
	hash_index_init(&idx, h)
	ok := false
	defer if !ok {
		hash_index_destroy(&idx)
	}
	n := length_of(h, collection)
	if n > 0 {
		if reserve(&idx.rows, n) != nil || reserve(&idx.next, n) != nil || reserve(&idx.groups, min(n, 64)) != nil {
			return {}, fail_memory(h)
		}
		cap_b := 16
		for cap_b < 2 * n {
			cap_b <<= 1
		}
		if s := rehash_groups(&idx, cap_b); s != .Ok {
			return {}, s
		}
	}
	cur, cs := cursor_open(h, collection)
	if cs != .Ok {
		return {}, cs
	}
	defer cursor_close(&cur)
	for {
		k, row, more, ns := cursor_next(h, &cur)
		release(h, k)
		if ns != .Ok {
			return {}, ns
		}
		if !more {
			break
		}
		key := ABSENT
		has_key := true
		if extractor != nil {
			ks: Status
			key, has_key, ks = extractor(ctx, h, row)
			if ks != .Ok {
				release(h, row)
				release(h, key)
				return {}, ks
			}
		} else {
			key = retain(row)
		}
		if has_key && key.kind != .Absent {
			if as := hash_index_add(&idx, key, row); as != .Ok {
				release(h, row)
				release(h, key)
				return {}, as
			}
		}
		release(h, row)
		release(h, key)
	}
	if ss := hash_index_seal(&idx); ss != .Ok {
		return {}, ss
	}
	ok = true
	return idx, .Ok
}

// Convenience wrapper building a `Hash_Index` keyed by object member `key_field` on each row.
@(require_results)
hash_index_build_field :: proc(h: ^Heap, collection: Value, key_field: string) -> (idx: Hash_Index, status: Status) {
	ctx := Field_Key_Ctx{field = key_field}
	return hash_index_build(h, collection, field_key_extractor, &ctx)
}

// Looks up all right rows matching `key` in O(1) amortized time without allocating.
// Returned values are borrowed from `idx`; retain any values kept past `hash_index_destroy`.
@(require_results)
hash_index_lookup :: proc(idx: ^Hash_Index, key: Value) -> (matches: []Value, status: Status) {
	if idx == nil || idx.h == nil || len(idx.groups) == 0 {
		return nil, .Ok
	}
	matchable, ms := join_key_matchable(idx.h, key)
	if ms != .Ok {
		return nil, ms
	}
	if !matchable {
		return nil, .Ok
	}
	if !idx.sealed {
		hash_index_seal(idx) or_return
	}
	gi, found, gs := find_group(idx, key)
	if gs != .Ok || !found {
		return nil, gs
	}
	g := idx.groups[gi]
	return idx.packed[g.lo:g.lo + g.count], .Ok
}

// Reports whether at least one row in `idx` matches `key`.
@(require_results)
hash_index_has :: proc(idx: ^Hash_Index, key: Value) -> (found: bool, status: Status) {
	if idx == nil || idx.h == nil || len(idx.groups) == 0 {
		return false, .Ok
	}
	matchable, ms := join_key_matchable(idx.h, key)
	if ms != .Ok {
		return false, ms
	}
	if !matchable {
		return false, .Ok
	}
	_, found, status = find_group(idx, key)
	return
}

// Returns the number of rows matching `key`.
@(require_results)
hash_index_count :: proc(idx: ^Hash_Index, key: Value) -> (count: int, status: Status) {
	if idx == nil || idx.h == nil || len(idx.groups) == 0 {
		return 0, .Ok
	}
	matchable, ms := join_key_matchable(idx.h, key)
	if ms != .Ok {
		return 0, ms
	}
	if !matchable {
		return 0, .Ok
	}
	gi, found, gs := find_group(idx, key)
	if gs != .Ok || !found {
		return 0, gs
	}
	return int(idx.groups[gi].count), .Ok
}

// Combines a matched `(left, right)` pair (or `(left, NULL)` when `!has_right` under left outer join)
// according to `combine`.
@(require_results)
join_combine_rows :: proc(h: ^Heap, left, right: Value, has_right: bool, combine: Join_Combine) -> (res: Value, status: Status) {
	switch combine {
	case .Pair:
		arr := make_array(h, 2) or_return
		if s := append_owned(h, &arr, retain(left)); s != .Ok {
			release(h, arr)
			return NULL, s
		}
		rval := retain(right) if has_right else NULL
		if s := append_owned(h, &arr, rval); s != .Ok {
			release(h, arr)
			return NULL, s
		}
		return arr, .Ok
	case .Merge_Right:
		if !has_right {
			return retain(left), .Ok
		}
		if type_of(left) != .Object || type_of(right) != .Object {
			return join_combine_rows(h, left, right, true, .Pair)
		}
		return object_merge(h, left, right, deep = false)
	case .Merge_Left:
		if !has_right {
			return retain(left), .Ok
		}
		if type_of(left) != .Object || type_of(right) != .Object {
			return join_combine_rows(h, left, right, true, .Pair)
		}
		return object_merge(h, right, left, deep = false)
	}
	return NULL, .Error
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
) -> (
	res: Value,
	status: Status,
) {
	if h == nil {
		return NULL, .Error
	}
	lt := type_of(left)
	if lt != .Array && lt != .Object {
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
		k, lrow, more, ns := cursor_next(h, &cur)
		release(h, k)
		if ns != .Ok {
			return NULL, ns
		}
		if !more {
			break
		}
		lkey := ABSENT
		has_key := true
		if left_key != nil {
			ks: Status
			lkey, has_key, ks = left_key(ctx, h, lrow)
			if ks != .Ok {
				release(h, lrow)
				release(h, lkey)
				return NULL, ks
			}
		} else {
			lkey = retain(lrow)
		}
		matches: []Value
		if has_key && lkey.kind != .Absent {
			ls: Status
			matches, ls = hash_index_lookup(&idx, lkey)
			if ls != .Ok {
				release(h, lrow)
				release(h, lkey)
				return NULL, ls
			}
		}
		release(h, lkey)

		switch kind {
		case .Inner:
			for rrow in matches {
				joined, js := join_combine_rows(h, lrow, rrow, true, combine)
				if js != .Ok {
					release(h, lrow)
					return NULL, js
				}
				if as := append_owned(h, &out, joined); as != .Ok {
					release(h, lrow)
					return NULL, as
				}
			}
		case .Left:
			if len(matches) == 0 {
				joined, js := join_combine_rows(h, lrow, ABSENT, false, combine)
				if js != .Ok {
					release(h, lrow)
					return NULL, js
				}
				if as := append_owned(h, &out, joined); as != .Ok {
					release(h, lrow)
					return NULL, as
				}
			} else {
				for rrow in matches {
					joined, js := join_combine_rows(h, lrow, rrow, true, combine)
					if js != .Ok {
						release(h, lrow)
						return NULL, js
					}
					if as := append_owned(h, &out, joined); as != .Ok {
						release(h, lrow)
						return NULL, as
					}
				}
			}
		case .Semi:
			if len(matches) > 0 {
				if as := append_owned(h, &out, retain(lrow)); as != .Ok {
					release(h, lrow)
					return NULL, as
				}
			}
		}
		release(h, lrow)
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
) -> (
	res: Value,
	status: Status,
) {
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
) -> (
	Value,
	Status,
) {
	if h == nil {
		return NULL, .Error
	}
	ct := type_of(collection)
	if ct != .Array && ct != .Object {
		return NULL, fail(h, .Types, .Iterate, collection)
	}
	n := length_of(h, collection)
	if !group_dups {
		obj, obj_status := make_object(h, n)
		if obj_status != .Ok {
			return NULL, obj_status
		}
		ok := false
		defer if !ok {
			release(h, obj)
		}
		cur, cur_status := cursor_open(h, collection)
		if cur_status != .Ok {
			return NULL, cur_status
		}
		defer cursor_close(&cur)
		for {
			k, row, more, ns := cursor_next(h, &cur)
			release(h, k)
			if ns != .Ok {
				return NULL, ns
			}
			if !more {
				break
			}
			key := ABSENT
			has_key := true
			if extractor != nil {
				ks: Status
				key, has_key, ks = extractor(ctx, h, row)
				if ks != .Ok {
					release(h, row)
					release(h, key)
					return NULL, ks
				}
			} else {
				key = retain(row)
			}
			matchable, ms := join_key_matchable(h, key)
			if ms != .Ok {
				release(h, row)
				release(h, key)
				return NULL, ms
			}
			if !has_key || !matchable {
				release(h, row)
				release(h, key)
				continue
			}
			kstr, kstatus := canonical_index_key(h, key)
			release(h, key)
			if kstatus != .Ok {
				release(h, row)
				return NULL, kstatus
			}
			if kstr.kind == .Absent {
				release(h, row)
				continue
			}
			if os := object_put(h, &obj, kstr, row); os != .Ok {
				return NULL, os
			}
		}
		ok = true
		return obj, .Ok
	}

	Group_Bucket :: struct {
		key: Value,
		arr: Value,
	}
	alloc := heap_allocator(h)
	idx_obj, idx_status := make_object(h, n)
	if idx_status != .Ok {
		return NULL, idx_status
	}
	buckets: [dynamic]Group_Bucket
	buckets.allocator = alloc
	if n > 0 {
		if reserve(&buckets, min(n, 64)) != nil {
			release(h, idx_obj)
			return NULL, fail_memory(h)
		}
	}
	defer {
		release(h, idx_obj)
		for &bk in buckets {
			release(h, bk.key)
			release(h, bk.arr)
		}
		delete(buckets)
	}

	cur, cur_status := cursor_open(h, collection)
	if cur_status != .Ok {
		return NULL, cur_status
	}
	defer cursor_close(&cur)
	for {
		k, row, more, ns := cursor_next(h, &cur)
		release(h, k)
		if ns != .Ok {
			return NULL, ns
		}
		if !more {
			break
		}
		key := ABSENT
		has_key := true
		if extractor != nil {
			ks: Status
			key, has_key, ks = extractor(ctx, h, row)
			if ks != .Ok {
				release(h, row)
				release(h, key)
				return NULL, ks
			}
		} else {
			key = retain(row)
		}
		matchable, ms := join_key_matchable(h, key)
		if ms != .Ok {
			release(h, row)
			release(h, key)
			return NULL, ms
		}
		if !has_key || !matchable {
			release(h, row)
			release(h, key)
			continue
		}
		kstr, kstatus := canonical_index_key(h, key)
		release(h, key)
		if kstatus != .Ok {
			release(h, row)
			return NULL, kstatus
		}
		if kstr.kind == .Absent {
			release(h, row)
			continue
		}
		existing, es := member(h, idx_obj, text_of(kstr))
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
			if os := object_put(h, &idx_obj, retain(kstr), int_value(gi)); os != .Ok {
				return NULL, os
			}
		} else {
			gi := int(existing.i)
			release(h, kstr)
			// `buckets[gi].arr` stays at refcount 1 so `append_owned` grows geometrically in O(1) amortized.
			if as := append_owned(h, &buckets[gi].arr, row); as != .Ok {
				return NULL, as
			}
		}
	}

	release(h, idx_obj)
	idx_obj = ABSENT

	out, out_status := make_object(h, len(buckets))
	if out_status != .Ok {
		return NULL, out_status
	}
	ok := false
	defer if !ok {
		release(h, out)
	}
	for &bk in buckets {
		bk_key, bk_arr := bk.key, bk.arr
		bk = {}
		if put_status := object_put(h, &out, bk_key, bk_arr); put_status != .Ok {
			return NULL, put_status
		}
	}
	ok = true
	return out, .Ok
}

// Convenience lookup-object builder keyed by object member `key_field`.
@(require_results)
index_by_field :: proc(h: ^Heap, collection: Value, key_field: string, group_dups := false) -> (res: Value, status: Status) {
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
			s := fmt.bprintf(buf[:], "%d", iv)
			return text_value(h, s)
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
extract_object_field :: proc(h: ^Heap, row: Value, field: string) -> (Value, bool, Status) {
	if type_of(row) != .Object {
		return ABSENT, false, .Ok
	}
	v, s := member(h, row, field)
	if s != .Ok {
		return ABSENT, false, s
	}
	if v.kind == .Absent {
		return ABSENT, false, .Ok
	}
	return v, true, .Ok
}

@(private = "file")
format_json_owned :: proc(h: ^Heap, v: Value) -> (Value, Status) {
	alloc := heap_allocator(h)
	buf := make([dynamic]u8, 0, 32, alloc)
	if buf == nil {
		return ABSENT, fail_memory(h)
	}
	defer delete(buf)
	if ws := write_json(h, &buf, v, {sort_keys = true}); ws != .Ok {
		return ABSENT, ws
	}
	return text_value(h, string(buf[:]))
}

@(private = "file")
is_nan_scalar :: proc(h: ^Heap, v: Value) -> (bool, Status) {
	if type_of(v) != .Number {
		return false, .Ok
	}
	if v.kind == .Int || v.kind == .Big {
		return false, .Ok
	}
	if v.kind == .Double {
		return math.is_nan(v.f), .Ok
	}
	if h != nil {
		num, ns := number_of(h, v)
		if ns != .Ok {
			return false, ns
		}
		defer release(h, num)
		return num.kind == .Double && math.is_nan(num.f), .Ok
	}
	if v.kind == .Node {
		d := (^Doc_Block)(v.p)
		if n, ok := tape.node_number(&d.doc, tape.Node_Index(v.n)); ok {
			if n.kind == .Float {
				return math.is_nan(transmute(f64)n.bits), .Ok
			}
			if n.kind == .Wide {
				if d.doc.format != nil && .Binary in d.doc.format.caps {
					return false, .Error
				}
				return math.is_nan(wide_double(node_bytes(v))), .Ok
			}
		}
	}
	if v.kind == .Overlay {
		return math.is_nan(overlay_as_f64(v)), .Ok
	}
	return false, .Ok
}

@(private = "file")
join_key_matchable :: proc(h: ^Heap, v: Value) -> (bool, Status) {
	if v.kind == .Absent {
		return false, .Ok
	}
	nan, st := is_nan_scalar(h, v)
	return !nan, st
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
		if idx.groups[cand].hash == kh {
			same := equal(h, idx.groups[cand].key, key) or_return
			if same {
				return cand, true, .Ok
			}
		}
	}
}

@(private = "file")
append_row_to_group :: proc(idx: ^Hash_Index, gi: int, row: Value) -> Status {
	row_idx := i32(len(idx.rows))
	if _, err := append(&idx.rows, ABSENT); err != nil {
		return fail_memory(idx.h)
	}
	if _, err := append(&idx.next, i32(-1)); err != nil {
		pop(&idx.rows)
		return fail_memory(idx.h)
	}
	idx.rows[row_idx] = retain(row)
	g := &idx.groups[gi]
	idx.next[g.tail] = row_idx
	g.tail = row_idx
	g.count += 1
	return .Ok
}

@(private = "file")
insert_new_group :: proc(idx: ^Hash_Index, slot: int, key: Value, kh: u64, row: Value) -> Status {
	row_idx := i32(len(idx.rows))
	if _, err := append(&idx.rows, ABSENT); err != nil {
		return fail_memory(idx.h)
	}
	if _, err := append(&idx.next, i32(-1)); err != nil {
		pop(&idx.rows)
		return fail_memory(idx.h)
	}
	g := Index_Group{
		hash  = kh,
		head  = row_idx,
		tail  = row_idx,
		count = 1,
	}
	if _, err := append(&idx.groups, g); err != nil {
		pop(&idx.next)
		pop(&idx.rows)
		return fail_memory(idx.h)
	}
	idx.rows[row_idx] = retain(row)
	idx.groups[len(idx.groups) - 1].key = retain(key)
	idx.buckets[slot] = i32(len(idx.groups))
	return .Ok
}

@(private = "file")
hash_index_unseal :: proc(idx: ^Hash_Index) -> Status {
	h := idx.h
	alloc := heap_allocator(h)
	n := len(idx.packed)
	if n > 0 {
		if reserve(&idx.rows, n) != nil || reserve(&idx.next, n) != nil {
			return fail_memory(h)
		}
		for &g in idx.groups {
			first := i32(len(idx.rows))
			for j in u32(0) ..< g.count {
				cur := i32(len(idx.rows))
				if _, err := append(&idx.rows, ABSENT); err != nil {
					return fail_memory(h)
				}
				if _, err := append(&idx.next, i32(-1)); err != nil {
					pop(&idx.rows)
					return fail_memory(h)
				}
				idx.rows[cur] = retain(idx.packed[g.lo + j])
				if j > 0 {
					idx.next[cur - 1] = cur
				}
			}
			g.head = first
			g.tail = first + i32(g.count) - 1
			g.lo = 0
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
