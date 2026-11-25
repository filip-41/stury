package query_test

import "core:mem"
import "core:testing"
import "stury:json"
import "stury:lib/query"
import "stury:testkit"

// A heap over a tracking allocator, which `heap_done` checks gave back every block.
@(private)
Test_Heap :: struct {
	h:     query.Heap,
	track: mem.Tracking_Allocator,
}

@(private)
heap_start :: proc(x: ^Test_Heap) {
	mem.tracking_allocator_init(&x.track, context.allocator)
	query.heap_init(&x.h, mem.tracking_allocator(&x.track))
}

@(private)
heap_done :: proc(t: ^testing.T, x: ^Test_Heap, loc := #caller_location) {
	query.heap_destroy(&x.h)
	testing.expectf(t, len(x.track.allocation_map) == 0, "%d blocks not given back", len(x.track.allocation_map), loc = loc)
	mem.tracking_allocator_destroy(&x.track)
}

@(private)
read_json :: proc(t: ^testing.T, h: ^query.Heap, text: string, loc := #caller_location) -> query.Value {
	doc, err := json.build(transmute([]u8)text, allocator = h.allocator)
	testing.expectf(t, err == nil, "%s does not read: %v", text, err, loc = loc)
	v, s := query.document_value(h, doc, true)
	testing.expect(t, s == .Ok, loc = loc)
	return v
}

@(private)
as_json :: proc(h: ^query.Heap, v: query.Value, opts := query.Json_Options{}) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	_ = query.write_json(h, &out, v, opts)
	return string(out[:])
}

@(test)
integers_stay_exact_past_i64 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	a := query.int_value(100000000000)
	p, _ := query.num_mul(h, a, a)
	testing.expect_value(t, as_json(h, p), "10000000000000000000000")
	doc := read_json(t, h, "9007199254740993")
	q, _ := query.num_add(h, doc, query.int_value(0))
	query.release(h, doc)
	testing.expect_value(t, as_json(h, q), "9007199254740993")
	d, _ := query.num_div(h, p, a)
	testing.expect_value(t, as_json(h, d), "100000000000")
	testing.expect(t, d.kind == .Int)
	half, _ := query.num_div(h, query.int_value(1), query.int_value(2))
	testing.expect_value(t, as_json(h, half), "0.5")
	big_neg, _ := query.num_neg(h, query.int_value(min(i64)))
	testing.expect_value(t, as_json(h, big_neg), "9223372036854775808")
	back, _ := query.num_add(h, big_neg, query.int_value(-1))
	testing.expect(t, back.kind == .Int && back.i == max(i64))
	for v in ([]query.Value{p, q, d, big_neg}) {
		query.release(h, v)
	}
}

@(test)
integers_and_doubles_meet_by_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	one := query.int_value(1)
	testing.expect(t, query.numbers_equal(one, query.double_value(1)))
	testing.expect_value(t, query.compare_numbers(query.int_value(max(i64)), query.double_value(9223372036854775808.0)), -1)
	testing.expect_value(t, query.compare_numbers(query.double_value(0.5), one), -1)
	h1, _ := query.hash(h, one)
	h2, _ := query.hash(h, query.double_value(1))
	testing.expect_value(t, h1, h2)
	nan := query.double_value(transmute(f64)u64(0x7FF8000000000000))
	testing.expect(t, !query.numbers_equal(nan, nan))
	testing.expect_value(t, query.compare_numbers(nan, query.int_value(min(i64))), -1)
}

@(test)
documents_read_through_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	doc := read_json(t, h, `{"b": [1, 2.5, "xé"], "a": {"k": null}, "b": 7}`)
	defer query.release(h, doc)
	testing.expect_value(t, query.type_of(doc), query.Type.Object)
	testing.expect_value(t, query.length_of(h, doc), 2)
	b, _ := query.member(h, doc, "b")
	defer query.release(h, b)
	testing.expect_value(t, as_json(h, b), "7")
	missing, _ := query.member(h, doc, "zz")
	testing.expect_value(t, missing.kind, query.Kind.Absent)
	testing.expect_value(t, as_json(h, doc, {sort_keys = true}), `{"a":{"k":null},"b":7}`)
	arr := read_json(t, h, `[1, 2.5, "xé", "plain"]`)
	defer query.release(h, arr)
	s, _ := query.element(h, arr, -2)
	defer query.release(h, s)
	testing.expect_value(t, query.text_of(s), "xé")
	testing.expect_value(t, query.codepoint_count(query.text_of(s)), 2)
}

@(test)
built_values_change_in_place_when_held_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	a, _ := query.make_array(h, 0)
	for i in 0 ..< 1000 {
		testing.expect(t, query.append_owned(h, &a, query.int_value(i64(i))) == .Ok)
	}
	shared := query.retain(a)
	testing.expect(t, query.append_owned(h, &a, query.TRUE) == .Ok)
	testing.expect_value(t, query.length_of(h, shared), 1000)
	testing.expect_value(t, query.length_of(h, a), 1001)
	query.release(h, shared)
	o, _ := query.make_object(h, 0)
	for i in 0 ..< 40 {
		k, _ := query.text_value(h, string([]u8{'k', u8('a' + i % 26), u8('0' + i / 26)}))
		testing.expect(t, query.object_put(h, &o, k, query.int_value(i64(i))) == .Ok)
	}
	v, _ := query.member(h, o, "kz0")
	testing.expect_value(t, v.i, 25)
	testing.expect(t, query.object_delete(h, &o, "kz0") == .Ok)
	testing.expect(t, !query.has_member(h, o, "kz0"))
	testing.expect_value(t, query.length_of(h, o), 39)
	acc := query.text_borrowed("")
	for _ in 0 ..< 1000 {
		testing.expect(t, query.text_append(h, &acc, "abc") == .Ok)
	}
	testing.expect_value(t, len(query.text_of(acc)), 3000)
	query.release(h, acc)
	query.release(h, o)
	query.release(h, a)
}

@(test)
order_is_by_type_then_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	vals := read_json(t, h, `[{"b":1}, {"a":2}, [1,2], [1], "b", "a", 3, 1.5, true, false, null]`)
	defer query.release(h, vals)
	built, _ := query.built(h, vals)
	defer query.release(h, built)
	items := query.items_of(built)
	testing.expect(t, query.sort_values(h, items) == .Ok)
	testing.expect_value(t, as_json(h, built), `[null,false,true,1.5,3,"a","b",[1],[1,2],{"a":2},{"b":1}]`)
	l, r := read_json(t, h, `{"a":[1,{"b":2.0}],"c":"x"}`), read_json(t, h, `{"c":"x","a":[1,{"b":2}]}`)
	same, _ := query.equal(h, l, r)
	testing.expect(t, same)
	query.release(h, l)
	query.release(h, r)
}

// A sort reads objects inside objects into forms to a few levels and compares past them as `compare` does: every pair
// of the sorted list is in `compare`'s order, and objects equal by `equal` sort next to each other.
@(test)
objects_in_objects_sort_as_compare_orders_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	vals := read_json(
		t,
		h,
		`[{"a":{"y":2,"x":1}},{"a":{"x":1,"y":1}},{"a":{"x":1}},{"a":{"x":{"p":{"q":{"r":{"s":2}}}}}},{"a":{"x":{"p":{"q":{"r":{"s":1}}}}}},` +
		`{"a":{"x":{"p":{"q":{"r":{"s":1,"t":0}}}}}},{"a":[{"x":1}]},{"a":1},{"a":{"y":1,"x":1}},{"b":{"x":1}},{"a":{"x":{"p":[1]}}},{"a":{"x":{"p":{}}}}]`,
	)
	defer query.release(h, vals)
	sorted, s := query.sort_by(h, vals)
	testing.expect(t, s == .Ok)
	defer query.release(h, sorted)
	items := query.items_of(sorted)
	for i in 0 ..< len(items) {
		for j in i + 1 ..< len(items) {
			r, _ := query.compare(h, items[i], items[j])
			testing.expectf(t, r <= 0, "%s sorts before %s", as_json(h, items[i]), as_json(h, items[j]))
		}
	}
	testing.expect_value(
		t,
		as_json(h, sorted),
		`[{"a":1},{"a":[{"x":1}]},{"a":{"x":1}},{"a":{"x":{"p":[1]}}},{"a":{"x":{"p":{}}}},{"a":{"x":{"p":{"q":{"r":{"s":1}}}}}},` +
		`{"a":{"x":{"p":{"q":{"r":{"s":2}}}}}},{"a":{"x":{"p":{"q":{"r":{"s":1,"t":0}}}}}},{"a":{"x":1,"y":1}},{"a":{"y":1,"x":1}},{"a":{"y":2,"x":1}},{"b":{"x":1}}]`,
	)
	l, _ := query.built(h, items[8])
	r, _ := query.built(h, items[9])
	same, _ := query.equal(h, l, r)
	testing.expect(t, same)
	other, _ := query.equal(h, l, items[10])
	testing.expect(t, !other)
	query.release(h, l)
	query.release(h, r)
}

@(test)
objects_order_by_keys_then_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	vals := read_json(t, h, `[{"b":1,"a":2},{"a":1,"b":9},{"a":1},{"c":0},{},{"a":1,"b":2},{"a":"s","b":1.5},{"a":[{"z":1}]},{"a":[{"z":0}]},[{"a":1}],[{"a":0}]]`)
	defer query.release(h, vals)
	sorted, s := query.sort_by(h, vals)
	testing.expect(t, s == .Ok)
	defer query.release(h, sorted)
	testing.expect_value(
		t,
		as_json(h, sorted),
		`[[{"a":0}],[{"a":1}],{},{"a":1},{"a":[{"z":0}]},{"a":[{"z":1}]},{"a":1,"b":2},{"a":1,"b":9},{"b":1,"a":2},{"a":"s","b":1.5},{"c":0}]`,
	)
	first, _ := query.runs_by(h, vals, query.ABSENT, .First)
	defer query.release(h, first)
	testing.expect_value(t, query.length_of(h, first), 11)
	least, _ := query.extreme_by(h, vals, query.ABSENT, false)
	defer query.release(h, least)
	testing.expect_value(t, as_json(h, least), `[{"a":0}]`)
	dups := read_json(t, h, `[{"a":1,"b":2},{"b":2,"a":1},{"a":1}]`)
	defer query.release(h, dups)
	groups, _ := query.runs_by(h, dups, query.ABSENT, .Group)
	defer query.release(h, groups)
	testing.expect_value(t, as_json(h, groups), `[[{"a":1}],[{"a":1,"b":2},{"b":2,"a":1}]]`)
}

@(test)
deep_copies_read_no_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	text := `{"a":[1,2.5,{"b":"x\n"},[]],"c":{"d":null,"e":12345678901234567890,"f":"plain"},"g":true}`
	doc := read_json(t, h, text)
	flat, s := query.built_deep(h, doc)
	testing.expect(t, s == .Ok)
	query.release(h, doc)
	testing.expect_value(t, as_json(h, flat), text)
	defer query.release(h, flat)
	scalar := query.built_deep(h, query.int_value(3)) or_else query.NULL
	testing.expect_value(t, as_json(h, scalar), "3")
}
