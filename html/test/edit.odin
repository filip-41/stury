// HTML edits: an element's content set between its tags and escaped as the element reads it, a text run, a rename of
// both tags, members placed and removed with the white space before them, comment and attribute facts, the nodes the
// tree construction made, and a result whose tree is not the edited tree.
package html_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import json "../../json"
import html ".."
import walktest "../../walktest"

@(private = "file")
Edits :: proc(list: ^core.Edit_List, doc: ^core.Document) -> core.Error

// The node at `path` of `doc`, each step the first member of its name.
@(private = "file")
at :: proc(doc: ^core.Document, path: ..string) -> core.Node_Index {
	node := core.ROOT
	for name in path {
		node, _ = core.member(doc, node, name, .First)
	}
	return node
}

// The `k`-th member of element `parent` named `name`, or `core.NO_NODE`.
@(private = "file")
nth :: proc(doc: ^core.Document, parent: core.Node_Index, name: string, k: int) -> core.Node_Index {
	it := core.members_named(doc, parent, name)
	for i := 0; ; i += 1 {
		node, ok := core.member_next(&it)
		if !ok || i == k {
			return node if ok else core.NO_NODE
		}
	}
}

// The text `src` read as `spec` becomes when `edits` records its edits and the list is committed.
@(private = "file")
edited :: proc(src: string, edits: Edits, spec := html.Spec.Fragment) -> (out: string, err: core.Error) {
	doc, berr := html.build(transmute([]u8)src, spec, allocator = context.temp_allocator)
	if berr != nil {
		return "", berr
	}
	list := html.edit_list_init(&doc, spec, context.temp_allocator)
	if e := edits(&list, &doc); e != nil {
		return "", e
	}
	bytes, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
	return string(bytes), cerr
}

// The value of the JSON text `src`, which the test's temp allocator holds.
@(private = "file")
from_json :: proc(src: string) -> core.Value {
	doc := new(core.Document, context.temp_allocator)
	doc^, _ = json.build(transmute([]u8)src, .Json, allocator = context.temp_allocator)
	return core.Node_Ref{doc, core.ROOT}
}

// Whether `err` is a refusal of the edit rules for `detail`.
@(private = "file")
expect_frozen :: proc(t: ^testing.T, err: core.Error, detail: html.Detail, loc := #caller_location) {
	e, is_edit := err.(core.Document_Error)
	testing.expectf(t, is_edit && e.kind == .Frozen && e.inner.rules == &html.RULES && html.Detail(e.inner.detail) == detail, "%v", err, loc = loc)
}

// Whether `err` refuses an object whose elements read back otherwise in the element they go in.
@(private = "file")
expect_no_spelling :: proc(t: ^testing.T, err: core.Error, loc := #caller_location) {
	e, is_edit := err.(core.Document_Error)
	testing.expectf(t, is_edit && e.kind == .Bad_Value && e.reason == .No_Spelling, "%v", err, loc = loc)
}

@(private = "file")
SRC :: "<div id=a>\n  <p class=x>t</p>\n  <br>\n  <script>run()</script>\n</div>"

@(test)
set_writes_the_content_and_keeps_the_tags :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "div", "p"), typed.Raw("new &amp; <b>more</b>")) or_return
		return write.set(l, at(d, "div", "script"), "if (a < b && c) go()")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>new &amp; <b>more</b></p>\n  <br>\n  <script>if (a < b && c) go()</script>\n</div>")
}

@(test)
set_escapes_a_string_and_writes_an_object_as_elements :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "p"), "a<b & c")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>a&lt;b &amp; c</p>\n  <br>\n  <script>run()</script>\n</div>")
	out, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div"), from_json(`{"i": 1, "q": null, "#text": "t", "s": [true, "u"], "hr": null}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a><i>1</i><q></q>t<s>true</s><s>u</s><hr></div>")
	out, err = edited("<pre>\n\nx</pre><textarea></textarea>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "pre"), "\ny") or_return
		return write.set(l, at(d, "textarea"), "<b>")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<pre>\n\ny</pre><textarea>&lt;b&gt;</textarea>")
}

// An object's elements are read back in the element they go in, as a fragment whose context is that element, and one
// they do not read back as is refused: a `tr` straight in a `table` reads inside a `tbody`.
@(test)
an_object_reads_back_in_its_element :: proc(t: ^testing.T) {
	TABLE :: "<table><tr><td>1</td></tr></table>"
	cases := [?]struct {
		edits: Edits,
		want:  string,
	} {
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table"), from_json(`{"tbody": {"tr": {"td": 2}}}`))}, "<table><tbody><tr><td>2</td></tr></tbody></table>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table", "tbody", "tr"), from_json(`{"td": [3, 4]}`))}, "<table><tr><td>3</td><td>4</td></tr></table>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "table", "tbody"), 1, "tr", from_json(`{"td": 5}`))}, "<table><tr><td>1</td></tr><tr><td>5</td></tr></table>"},
	}
	for c, i in cases {
		out, err := edited(TABLE, c.edits)
		testing.expectf(t, err == nil && out == c.want, "case %d: %q %v", i, out, err)
	}
	_, err := edited(TABLE, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "table"), from_json(`{"tr": {"td": 2}}`))
	})
	expect_no_spelling(t, err)
}

@(test)
set_writes_an_array_as_elements_of_the_name :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "p"), from_json(`[1, null, {"i": 2}]`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div id=a>\n  <p class=x>1</p>\n  <p></p>\n  <p><i>2</i></p>\n  <br>\n  <script>run()</script>\n</div>")
}

@(test)
set_of_text_writes_the_run :: proc(t: ^testing.T) {
	src := "<div><a></a> hi <b></b></div>"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "#text"), "1 < 2")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div><a></a>1 &lt; 2<b></b></div>")
	_, err = edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "#text"), from_json(`{"c": 1}`))
	})
	expect_frozen(t, err, .Text_Markup)
}

@(test)
set_through_a_path_and_from_the_document :: proc(t: ^testing.T) {
	src := "<div><section><p>1</p></section><span>2</span><script>a<b</script></div>"
	out, err := html.set(transmute([]u8)src, .Fragment, core.Path{steps = {core.Name("div"), core.Name("span")}}, typed.Raw("<i>q</i>"), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "<div><section><p>1</p></section><span><i>q</i></span><script>a<b</script></div>")
	moved, merr := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "div", "span"), core.Node_Ref{d, at(d, "div", "section")}) or_return
		return write.set(l, at(d, "div", "section", "p"), core.Node_Ref{d, at(d, "div", "script")})
	})
	walktest.expect_nil(t, merr)
	testing.expect_value(t, moved, "<div><section><p>a&lt;b</p></section><span><p>1</p></span><script>a<b</script></div>")
}

@(test)
a_document_keeps_its_doctype_and_tags :: proc(t: ^testing.T) {
	src := "<!DOCTYPE html>\n<html lang=en><head><title>T</title></head>\n<body>\n<p>x</p>\n</body></html>\n"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "html", "head", "title"), "A & B") or_return
		return write.insert(l, at(d, "html", "body"), 1, "p", "y")
	}, .Document)
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<!DOCTYPE html>\n<html lang=en><head><title>A &amp; B</title></head>\n<body>\n<p>x</p>\n<p>y</p>\n</body></html>\n")
}

// Each element of a repeated name and each run of `#text` is a member of its own, which a set, an insert, a removal and
// a rename reach without moving the members around it.
@(test)
edits_reach_each_element_of_a_repeated_name :: proc(t: ^testing.T) {
	SRC :: "<div>hello <b k=1>bold</b> tail<b>x</b><i>y</i></div>"
	cases := [?]struct {
		edits: Edits,
		want:  string,
	} {
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, at(d, "div"), "b", 1), "y")}, "<div>hello <b k=1>bold</b> tail<b>y</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, at(d, "div"), "#text", 1), " T")}, "<div>hello <b k=1>bold</b> T<b>x</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "div"), 4, "b", "n")}, "<div>hello <b k=1>bold</b> tail<b>x</b><b>n</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, nth(d, at(d, "div"), "b", 0))}, "<div>hello  tail<b>x</b><i>y</i></div>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, at(d, "div"), "b", 1) - 1, "em")}, "<div>hello <b k=1>bold</b> tail<em>x</em><i>y</i></div>"},
	}
	for c in cases {
		out, err := edited(SRC, c.edits)
		walktest.expect_nil(t, err)
		testing.expect_value(t, out, c.want)
	}
}

@(test)
rename_respells_both_tags :: proc(t: ^testing.T) {
	out, err := edited("<DIV><P>1</P><li>2</div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, at(d, "div", "p") - 1, "h1") or_return
		write.set(l, at(d, "div", "li") - 1, "dd") or_return
		return write.set(l, at(d, "div") - 1, "section")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<section><h1>1</h1><dd>2</section>")
	_, err = edited("<div></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div") - 1, "Section")
	})
	expect_frozen(t, err, .Not_Name)
}

@(test)
insert_and_remove_lay_out_a_member_as_its_neighbour :: proc(t: ^testing.T) {
	src := "<ul>\n  <li>1</li>\n  <li>2</li><!-- note -->\n</ul>"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.insert(l, at(d, "ul"), 0, "li", 0) or_return
		return write.insert(l, at(d, "ul"), 2, "li", from_json(`{"#text": "t", "b": "e"}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<ul>\n  <li>0</li>\n  <li>1</li>\n  <li>2</li><!-- note -->\n  <li>t<b>e</b></li>\n</ul>")
	out, err = edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, at(d, "ul", "li"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<ul>\n  <li>2</li><!-- note -->\n</ul>")
}

@(test)
facts_stand_where_html_reads_them :: proc(t: ^testing.T) {
	out, err := edited("<div x=0 y='1'><a>1</a><b>2</b></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_fact(l, at(d, "div", "a"), .Comment_Inline, " after a ") or_return
		core.set_facts(l, at(d, "div", "b"), .Attribute, {`k="1"`, `m='&amp;'`}) or_return
		return core.set_fact(l, at(d, "div"), .Attribute, `z=2`)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<div z=2><a>1</a><!-- after a --><b k=\"1\" m='&amp;'>2</b></div>")
	_, err = edited("<div></div>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, at(d, "div"), .Comment, "a --> b")
	})
	expect_frozen(t, err, .Comment_Body)
}

@(test)
attribute_bodies_html_cannot_read_as_written_are_refused :: proc(t: ^testing.T) {
	cases := [?]Edits {
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `K=1`)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `a=1 b=2`)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `a="1`)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "div"), .Attribute, `a=1>`)},
	}
	for c in cases {
		_, err := edited("<div></div>", c)
		expect_frozen(t, err, .Attribute_Body)
	}
}

// A node the tree construction implied, moved or copied stands nowhere in the source, so an edit of it, or an insert
// next to it, is refused, and a text read across a start tag the tree dropped holds the tag's effect.
@(test)
nodes_the_tree_made_are_refused :: proc(t: ^testing.T) {
	cases := [?]struct {
		src:   string,
		spec:  html.Spec,
		edits: Edits,
	} {
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "html", "body"), 1)}},
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, at(d, "html", "head"))}},
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "html"), 2, "q", 1)}},
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.set_fact(l, at(d, "html", "body"), .Attribute, "a=1")}},
		{"<table><tr><td>1</table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table", "tbody"), 1)}},
		{"<table><tr><td>1</table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "table"), 0, "caption", 1)}},
		{"<table>a<tr><td>1</td></tr></table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "#text"), "b")}},
		{"<b>1<p>2</b>3</p>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "p", "b"), 4)}},
		{"<b>1<p>2</b>3</p>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "p", "b") - 1, "i")}},
	}
	for c, i in cases {
		_, err := edited(c.src, c.edits, c.spec)
		e, is_edit := err.(core.Document_Error)
		testing.expectf(t, is_edit && e.kind == .Frozen && html.Detail(e.inner.detail) == .Constructed, "case %d: %v", i, err)
	}
	_, err := edited("<p>a<html lang=x>b</p>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "html", "body", "p"), "c")
	}, .Document)
	expect_frozen(t, err, .Split)
}

// An edit that writes only at the bytes the source spells keeps the nodes the tree construction made around them: a
// member of an implied element, an insert between its members, and a set of an element whose implied descendants it
// replaces.
@(test)
edits_around_the_nodes_the_tree_made_keep_them :: proc(t: ^testing.T) {
	cases := [?]struct {
		src:   string,
		spec:  html.Spec,
		edits: Edits,
		want:  string,
	} {
		{"<p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "html", "body", "p"), "y")}, "<p>y"},
		{"<p>a</p><p>b</p>", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "html", "body"), 1, "q", 1)}, "<p>a</p><q>1</q><p>b</p>"},
		{"<p>a</p><p>b</p>", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, at(d, "html", "body", "p"))}, "<p>b</p>"},
		{"<table><tr><td>1</td></tr></table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table"), typed.Raw("<tr><td>2</td></tr>"))}, "<table><tr><td>2</td></tr></table>"},
		{"<table><tr><td>1</td></tr></table>", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "table", "tbody", "tr", "td"), 3)}, "<table><tr><td>3</td></tr></table>"},
	}
	for c, i in cases {
		out, err := edited(c.src, c.edits, c.spec)
		testing.expectf(t, err == nil && out == c.want, "case %d: %q %v", i, out, err)
	}
}

// An edit of the document is read again as every other edit is: the root element it writes reads as it reads alone, and
// an insert or a removal at the top changes the count of elements there by its own.
@(test)
edits_of_the_document_are_read_again :: proc(t: ^testing.T) {
	out, err := edited("<!-- c --><p>x</p>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, core.ROOT, typed.Raw("<html><body><i>1</i></body></html>"))
	}, .Document)
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<!-- c --><html><body><i>1</i></body></html>")
	out, err = edited("<p>x</p>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, core.ROOT, 1, "i", 1)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<p>x</p><i>1</i>")
	cases := [?]struct {
		src:   string,
		spec:  html.Spec,
		edits: Edits,
	} {
		{"<html><body></body></html>", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, core.ROOT, 1, "p", 1)}},
		{"<p>x", .Fragment, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, core.ROOT, 1, "td", 1)}},
		{"<!DOCTYPE html><p>x", .Document, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, core.ROOT, typed.Raw("<p><table></table>"))}},
	}
	for c, i in cases {
		_, refused := edited(c.src, c.edits, c.spec)
		e, is_edit := refused.(core.Document_Error)
		testing.expectf(t, is_edit && e.kind == .Bad_Result && html.Detail(e.inner.detail) == .Reread, "case %d: %v", i, refused)
	}
}

@(test)
content_an_element_cannot_hold_is_refused :: proc(t: ^testing.T) {
	_, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "br"), "x")
	})
	expect_frozen(t, err, .Void)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "script"), typed.Raw("<b>x</b>"))
	})
	expect_frozen(t, err, .Text_Markup)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, at(d, "div", "p"), from_json(`{"B": 1}`))
	})
	expect_no_spelling(t, err)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.reorder(l, at(d, "div"), {1, 0, 2})
	})
	expect_frozen(t, err, .Reordered)
}

// The edited text is read again, and a tree other than the edited one is refused: a `p` the tree construction closes
// where the edit put it inside another, or a cell outside a table.
@(test)
a_result_that_reads_as_another_tree_is_refused :: proc(t: ^testing.T) {
	cases := [?]Edits {
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "div", "p"), typed.Raw("<p>x</p>"))},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "div", "p"), from_json(`{"div": 1}`))},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, at(d, "div", "p"), 0, "td", 1)},
		proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, at(d, "div", "p") - 1, "table")},
	}
	for c, i in cases {
		_, err := edited("<div><p><i>1</i> t</p></div>", c)
		e, is_edit := err.(core.Document_Error)
		testing.expectf(t, is_edit && e.kind == .Bad_Result && html.Detail(e.inner.detail) == .Reread, "case %d: %v", i, err)
	}
}
