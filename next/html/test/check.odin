// Streaming `html.check` and `html.check_fragment` parity against `schema/check.check_document(html.build)`.
package html_tests

import "core:testing"
import "stury:html"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"

@(test)
test_html_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Schema: {html: {head: null/object, body: {article: {title: string minLength 2, tag?: array of ^[a-z]+$, #text?: string}}}}
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

	art_members := make([]rules.Member, 2)
	art_members[0] = {name = "title", node = title_n, required = true}
	art_members[1] = {name = "tag", node = tag_n}
	append(&d.objects, rules.Object{members = art_members, additional = false_n, keys = rules.NONE})
	art_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})

	body_members := make([]rules.Member, 1)
	body_members[0] = {name = "article", node = art_n, required = true}
	append(&d.objects, rules.Object{members = body_members, additional = false_n, keys = rules.NONE})
	body_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 1})

	any_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Null, .Object}, array = -1, object = -1})
	head_members := make([]rules.Member, 2)
	head_members[0] = {name = "head", node = any_n}
	head_members[1] = {name = "body", node = body_n, required = true}
	append(&d.objects, rules.Object{members = head_members, additional = false_n, keys = rules.NONE})
	html_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 2})

	root_members := make([]rules.Member, 1)
	root_members[0] = {name = "html", node = html_n, required = true}
	append(&d.objects, rules.Object{members = root_members, additional = false_n, keys = rules.NONE})
	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 3})
	d.root = root

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	Case :: struct {
		input: string,
		valid: bool,
	}
	cases := [?]Case {
		{`<!DOCTYPE html><article><title>Dune</title><tag>scifi</tag><tag>classic</tag></article>`, true},
		{`<!DOCTYPE html><article><title>Dune</title><tag>scifi</tag></article>`, true},
		{`<!DOCTYPE html><article><title>X</title></article>`, false},
		{`<!DOCTYPE html><article><title>Dune</title><tag>BAD!</tag></article>`, false},
		{`<!DOCTYPE html><article><title>Dune</title><tag>scifi</tag><tag>BAD!</tag></article>`, false},
		{`<!DOCTYPE html><article><title>Dune</title><unknown>1</unknown></article>`, false},
	}
	for c in cases {
		src := transmute([]u8)c.input
		rs := html.check(src, &plan)
		defer check.result_destroy(&rs)
		testing.expectf(t, rs.valid == c.valid, "html stream %q: got %v want %v", c.input, rs.valid, c.valid)

		sink_s: check.Sink
		check.sink_init(&sink_s)
		defer check.sink_destroy(&sink_s)
		rss := html.check(src, &plan, .Html, {}, &sink_s)
		defer check.result_destroy(&rss)
		testing.expect_value(t, rss.valid, c.valid)

		doc, berr := html.build(src)
		testing.expect_value(t, berr, nil)
		defer html.destroy(&doc)

		rd := check.check_document(&doc, &plan)
		defer check.result_destroy(&rd)
		testing.expect_value(t, rd.valid, c.valid)

		sink_d: check.Sink
		check.sink_init(&sink_d)
		defer check.sink_destroy(&sink_d)
		rds := check.check_document(&doc, &plan, {}, &sink_d)
		defer check.result_destroy(&rds)
		testing.expect_value(t, rds.valid, c.valid)
		testing.expect_value(t, len(sink_s.entries), len(sink_d.entries))
	}
}

@(test)
test_html_check_fragment_and_dups_refuse :: proc(t: ^testing.T) {
	testkit.deadline(t)
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	str_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 2}, array = -1, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})
	members := make([]rules.Member, 1)
	members[0] = {name = "title", node = str_n, required = true}
	append(&d.objects, rules.Object{members = members, additional = false_n, keys = rules.NONE})
	d.root = rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	ok_r := html.check_fragment(transmute([]u8)string(`<title>Hello</title>`), &plan)
	defer check.result_destroy(&ok_r)
	testing.expect_value(t, ok_r.valid, true)

	bad_r := html.check_fragment(transmute([]u8)string(`<title>Hi</title><title>Dupe</title>`), &plan, {}, {dups = .Refuse})
	defer check.result_destroy(&bad_r)
	testing.expect(t, !bad_r.valid && bad_r.err.kind == .Duplicate_Key)

	// Custom fragment `context_name = "tr"` preserves `<td>` (body context would drop it).
	d_tr: rules.Description
	d_tr.allocator = context.allocator
	defer rules.description_destroy(&d_tr)
	cell_n := rules.Node_Index(len(d_tr.nodes))
	append(&d_tr.nodes, rules.Node{kinds = {.String}, rules = {min_length = 2}, array = -1, object = -1})
	tr_false := rules.Node_Index(len(d_tr.nodes))
	append(&d_tr.nodes, rules.Node{kinds = {}, array = -1, object = -1})
	tr_members := make([]rules.Member, 1)
	tr_members[0] = {name = "td", node = cell_n, required = true}
	append(&d_tr.objects, rules.Object{members = tr_members, additional = tr_false, keys = rules.NONE})
	d_tr.root = rules.Node_Index(len(d_tr.nodes))
	append(&d_tr.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	plan_tr, perr := check.compile(&d_tr)
	testing.expect_value(t, perr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan_tr)

	tr_ok := html.check_fragment(transmute([]u8)string(`<td>Hello</td>`), &plan_tr, {context_name = "tr"})
	defer check.result_destroy(&tr_ok)
	testing.expect_value(t, tr_ok.valid, true)

	tr_drop := html.check_fragment(transmute([]u8)string(`<td>Hello</td>`), &plan_tr)
	defer check.result_destroy(&tr_drop)
	testing.expect_value(t, tr_drop.valid, false)
}
