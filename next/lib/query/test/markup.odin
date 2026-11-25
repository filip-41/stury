package query_test

import "core:testing"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(private)
read_xml :: proc(t: ^testing.T, h: ^query.Heap, text: string, loc := #caller_location) -> query.Value {
	doc, err := xml.build(transmute([]u8)text, .Xml, {}, h.allocator)
	testing.expectf(t, err == nil, "%s does not read: %v", text, err, loc = loc)
	v, s := query.document_value(h, doc, true)
	testing.expect(t, s == .Ok, loc = loc)
	return v
}

@(private)
MARKUP_LIST :: `<r><a>1</a><b>x</b><a>2</a><a>3</a></r>`

@(test)
a_repeated_name_reads_as_an_array_in_document_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	doc := read_xml(t, h, MARKUP_LIST)
	defer query.release(h, doc)
	r, _ := query.member(h, doc, "r")
	defer query.release(h, r)
	a, _ := query.member(h, r, "a")
	defer query.release(h, a)
	b, _ := query.member(h, r, "b")
	defer query.release(h, b)
	testing.expect_value(t, as_json(h, a), `["1","2","3"]`)
	testing.expect_value(t, as_json(h, b), `"x"`)
	testing.expect_value(t, query.length_of(h, r), 2)
	testing.expect(t, query.has_member(h, r, "a"))
	second, _ := query.element(h, a, 1)
	testing.expect_value(t, as_json(h, second), `"2"`)
	query.release(h, second)
	testing.expect_value(t, as_json(h, r), `{"a":["1","2","3"],"b":"x"}`)
}

@(test)
a_markup_object_is_built_with_one_member_per_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	doc := read_xml(t, h, MARKUP_LIST)
	defer query.release(h, doc)
	r, _ := query.member(h, doc, "r")
	defer query.release(h, r)
	copy, s := query.built(h, r)
	testing.expect(t, s == .Ok)
	defer query.release(h, copy)
	testing.expect_value(t, query.length_of(h, copy), 2)
	testing.expect_value(t, as_json(h, copy), `{"a":["1","2","3"],"b":"x"}`)
	c, _ := query.cursor_open(h, r)
	defer query.cursor_close(&c)
	names := make([dynamic]u8, context.temp_allocator)
	for {
		k, v, more, _ := query.cursor_next(h, &c)
		if !more {
			break
		}
		append(&names, ..transmute([]u8)query.text_of(k))
		query.release(h, k)
		query.release(h, v)
	}
	testing.expect_value(t, string(names[:]), "ab")
}
