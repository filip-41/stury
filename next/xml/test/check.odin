// Streaming `xml.check` vs `check.check_document(xml.build)` parity (including DTD entities & grouped children).
package xml_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:xml"

@(test)
test_xml_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Schema: {book: {title: string minLength 2, tag?: array of string matching ^[a-z]+$}}
	// Per stury's markup contract, repeated XML sibling elements group into an array in document order.
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	title_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 2}, array = -1, object = -1})
	tag_item_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {pattern = "^[a-z]+$"}, array = -1, object = -1})
	append(&d.arrays, rules.Array{items = tag_item_n})
	tag_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Array}, array = 0, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

	book_members := make([]rules.Member, 2)
	book_members[0] = {name = "title", node = title_n, required = true}
	book_members[1] = {name = "tag", node = tag_n}
	append(&d.objects, rules.Object{members = book_members, additional = false_n, keys = rules.NONE})

	book_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})

	root_members := make([]rules.Member, 1)
	root_members[0] = {name = "book", node = book_n, required = true}
	append(&d.objects, rules.Object{members = root_members, additional = false_n, keys = rules.NONE})

	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 1})
	d.root = root

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	Case :: struct {
		input: string,
		valid: bool,
	}
	cases := [?]Case{
		{`<book><title>Dune</title><tag>scifi</tag><tag>classic</tag></book>`, true},
		{`<book><title>Dune</title><tag>scifi</tag></book>`, true},
		{`<!DOCTYPE book [<!ENTITY t "Foundation">]><book><title>&t;</title></book>`, true},
		{`<book><title>X</title></book>`, false},
		{`<book><title>Dune</title><tag>BAD!</tag></book>`, false},
		{`<book><title>Dune</title><tag>scifi</tag><tag>BAD!</tag></book>`, false},
		{`<book><title>Dune</title><unknown>1</unknown></book>`, false},
	}

	for c in cases {
		src := transmute([]u8)c.input
		r_s := xml.check(src, &plan)
		defer check.result_destroy(&r_s)
		testing.expectf(t, r_s.valid == c.valid, "xml stream on %q: got %v want %v", c.input, r_s.valid, c.valid)

		sink_s: check.Sink
		check.sink_init(&sink_s)
		defer check.sink_destroy(&sink_s)
		r_ss := xml.check(src, &plan, .Xml, {}, &sink_s)
		defer check.result_destroy(&r_ss)
		testing.expect_value(t, r_ss.valid, c.valid)

		doc, berr := xml.build(src)
		testing.expect_value(t, berr, nil)
		defer tape.destroy(&doc)

		r_d := check.check_document(&doc, &plan)
		defer check.result_destroy(&r_d)
		testing.expect_value(t, r_d.valid, c.valid)

		sink_d: check.Sink
		check.sink_init(&sink_d)
		defer check.sink_destroy(&sink_d)
		r_ds := check.check_document(&doc, &plan, {}, &sink_d)
		defer check.result_destroy(&r_ds)
		testing.expect_value(t, r_ds.valid, c.valid)
		testing.expect_value(t, len(sink_s.entries), len(sink_d.entries))
	}
}
