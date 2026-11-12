// XML edits: an element's content set between its tags, a text run, the root element, a rename of both tags, members
// placed and removed with the white space before them, comment and attribute facts, and the edits XML refuses.
package xml_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import json "../../json"
import xml ".."
import walktest "../../walktest"

@(private = "file")
Edits :: proc(list: ^core.Edit_List, doc: ^core.Document) -> core.Error

// The first member of element `parent` named `name`, or `core.NO_NODE`.
@(private = "file")
member :: proc(doc: ^core.Document, parent: core.Node_Index, name: string) -> core.Node_Index {
	it := core.pairs(doc, parent)
	buf: [256]u8
	for key, val in core.pair_next(&it) {
		if text, _ := core.text(doc, key, buf[:]); text == name {
			return val
		}
	}
	return core.NO_NODE
}

// The value of the root element.
@(private = "file")
root :: proc(doc: ^core.Document) -> core.Node_Index {
	return core.ROOT + 2
}

// The text `src` becomes when `edits` records its edits and the list is committed.
@(private = "file")
edited :: proc(src: string, edits: Edits) -> (out: string, err: core.Error) {
	doc, berr := xml.build(transmute([]u8)src, .Xml, allocator = context.temp_allocator)
	if berr != nil {
		return "", berr
	}
	list := xml.edit_list_init(&doc, .Xml, context.temp_allocator)
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

@(private = "file")
SRC :: "<?xml version=\"1.0\"?>\n<!-- head -->\n<r a=\"1\">\n  <x k=\"v\">t</x>\n  <y/>\n</r>\n"

@(test)
set_writes_the_content_and_keeps_the_tags :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, member(d, root(d), "x"), typed.Raw("new &amp; <b>more</b>")) or_return
		return write.set(l, member(d, root(d), "y"), 5)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<?xml version=\"1.0\"?>\n<!-- head -->\n<r a=\"1\">\n  <x k=\"v\">new &amp; <b>more</b></x>\n  <y>5</y>\n</r>\n")
}

@(test)
set_escapes_a_string_and_writes_an_object_as_elements :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, member(d, root(d), "x"), "a<b & c") or_return
		return write.set(l, member(d, root(d), "y"), from_json(`{"p": 1, "q": null, "#text": "t", "s": [true, "u"]}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<?xml version=\"1.0\"?>\n<!-- head -->\n<r a=\"1\">\n  <x k=\"v\">a&lt;b &amp; c</x>\n  <y><p>1</p><q/>t<s>true</s><s>u</s></y>\n</r>\n")
}

@(test)
set_writes_an_array_as_elements_of_the_name :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "x"), from_json(`[1, null, {"p": 2}]`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<?xml version=\"1.0\"?>\n<!-- head -->\n<r a=\"1\">\n  <x k=\"v\">1</x>\n  <x/>\n  <x><p>2</p></x>\n  <y/>\n</r>\n")
}

@(test)
set_of_the_document_writes_the_root_element :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, core.ROOT, from_json(`{"n": {"m": 1}}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<?xml version=\"1.0\"?>\n<!-- head -->\n<n><m>1</m></n>\n")
}

@(test)
set_of_text_writes_the_run :: proc(t: ^testing.T) {
	src := "<r><a/> hi <b/></r>"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "#text"), "yo")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r><a/>yo<b/></r>")
	_, err = edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "#text"), from_json(`{"c": 1}`))
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
}

@(test)
set_through_a_path_moves_a_value_of_the_document :: proc(t: ^testing.T) {
	src := "<r><x><p>1</p></x><y>2</y></r>"
	out, err := xml.set(transmute([]u8)src, .Xml, core.Path{steps = {core.Name("r"), core.Name("y")}}, typed.Raw("<q/>"), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(out), "<r><x><p>1</p></x><y><q/></y></r>")
	moved, merr := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "y"), core.Node_Ref{d, member(d, root(d), "x")})
	})
	walktest.expect_nil(t, merr)
	testing.expect_value(t, moved, "<r><x><p>1</p></x><y><p>1</p></y></r>")
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

// Each element of a repeated name and each run of `#text` is a member of its own, which a set, an insert, a removal and
// a rename reach without moving the members around it.
@(test)
edits_reach_each_element_of_a_repeated_name :: proc(t: ^testing.T) {
	SRC :: "<r>hello <b k=\"1\">bold</b> tail<b>x</b><c>y</c></r>"
	cases := [?]struct {
		edits: Edits,
		want:  string,
	} {
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, root(d), "b", 1), "y")}, "<r>hello <b k=\"1\">bold</b> tail<b>y</b><c>y</c></r>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, root(d), "b", 0), "B")}, "<r>hello <b k=\"1\">B</b> tail<b>x</b><c>y</c></r>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, root(d), "#text", 1), " T")}, "<r>hello <b k=\"1\">bold</b> T<b>x</b><c>y</c></r>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.insert(l, root(d), 4, "b", "n")}, "<r>hello <b k=\"1\">bold</b> tail<b>x</b><b>n</b><c>y</c></r>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return core.remove(l, nth(d, root(d), "b", 0))}, "<r>hello  tail<b>x</b><c>y</c></r>"},
		{proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {return write.set(l, nth(d, root(d), "b", 1) - 1, "z")}, "<r>hello <b k=\"1\">bold</b> tail<z>x</z><c>y</c></r>"},
	}
	for c in cases {
		out, err := edited(SRC, c.edits)
		walktest.expect_nil(t, err)
		testing.expect_value(t, out, c.want)
	}
	out, err := edited("<entry>pre <b>old</b> post</entry>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "b"), "B")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<entry>pre <b>B</b> post</entry>")
}

@(test)
rename_respells_both_tags :: proc(t: ^testing.T) {
	out, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.set(l, member(d, root(d), "x") - 1, "zed") or_return
		return write.set(l, member(d, root(d), "y") - 1, "w")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<?xml version=\"1.0\"?>\n<!-- head -->\n<r a=\"1\">\n  <zed k=\"v\">t</zed>\n  <w/>\n</r>\n")
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "x") - 1, "a:b")
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
}

@(test)
insert_lays_out_a_member_as_its_neighbour :: proc(t: ^testing.T) {
	src := "<r>\n  <a>1</a>\n  <b>2</b><!-- note -->\n</r>"
	out, err := edited(src, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		write.insert(l, root(d), 0, "z", 0) or_return
		return write.insert(l, root(d), 2, "c", from_json(`{"#text": "t", "d": "e"}`))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r>\n  <z>0</z>\n  <a>1</a>\n  <b>2</b><!-- note -->\n  <c>t<d>e</d></c>\n</r>")
	path := core.Path{steps = {core.Name("r"), core.Name("c")}}
	set, serr := xml.set(transmute([]u8)src, .Xml, path, "x", allocator = context.temp_allocator)
	walktest.expect_nil(t, serr)
	testing.expect_value(t, string(set), "<r>\n  <a>1</a>\n  <b>2</b><!-- note -->\n  <c>x</c>\n</r>")
}

@(test)
remove_takes_the_white_space_before_an_element :: proc(t: ^testing.T) {
	out, err := edited("<r>\n  <a>1</a>\n  <b>2</b>\n</r>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, member(d, root(d), "a"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r>\n  <b>2</b>\n</r>")
	out, err = edited("<r><a/>hi<b/></r>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove(l, member(d, root(d), "#text"))
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r><a/><b/></r>")
}

@(test)
comment_facts_stand_where_xml_reads_them :: proc(t: ^testing.T) {
	out, err := edited("<r><a>1</a><b>2</b></r>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_fact(l, member(d, root(d), "a"), .Comment_Inline, " after a ") or_return
		core.set_fact(l, root(d), .Comment, " head ") or_return
		return core.set_fact(l, core.ROOT, .Comment, " prolog ")
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<!-- prolog --><r><!-- head --><a>1</a><!-- after a --><b>2</b></r>")
	out, err = edited("<!-- p --><r><a>1</a><!-- one --></r>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_fact(l, member(d, root(d), "a"), .Comment_Inline, "two") or_return
		return core.remove_fact(l, core.ROOT, .Comment)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r><a>1</a><!--two--></r>")
	_, err = edited("<r/>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.set_fact(l, core.ROOT, .Comment, "a -- b")
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
}

@(test)
attribute_facts_replace_the_attributes_of_an_element :: proc(t: ^testing.T) {
	out, err := edited("<r x=\"0\" y='1'><a>1</a></r>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		core.set_facts(l, member(d, root(d), "a"), .Attribute, {`k="1"`, `m='2'`}) or_return
		return core.set_fact(l, root(d), .Attribute, `z="&amp;"`)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r z=\"&amp;\"><a k=\"1\" m='2'>1</a></r>")
	out, err = edited("<r x=\"0\" y='1'/>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.remove_fact(l, root(d), .Attribute)
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r/>")
	out, err = edited("<r x = '\"'  y=\"&#65;\"/>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		context.allocator = context.temp_allocator
		bodies, _ := core.comments(core.Node_Ref{d, root(d)}, .Attribute)
		return core.set_facts(l, root(d), .Attribute, {bodies[1], bodies[0], `z="1"`})
	})
	walktest.expect_nil(t, err)
	testing.expect_value(t, out, "<r y=\"&#65;\" x='\"' z=\"1\"/>")
}

@(test)
edits_xml_cannot_hold_are_refused :: proc(t: ^testing.T) {
	_, err := edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "x"), typed.Raw("<p>"))
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Value)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "x"), "")
	})
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.insert(l, core.ROOT, 1, "s", 1)
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Result)
	_, err = edited(SRC, proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return core.reorder(l, root(d), {1, 0})
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
	_, err = edited("<!DOCTYPE r [<!ENTITY e \"<p>1</p>\">]><r>&e;</r>", proc(l: ^core.Edit_List, d: ^core.Document) -> core.Error {
		return write.set(l, member(d, root(d), "p"), 2)
	})
	walktest.expect_kind(t, err, core.Document_Error_Kind.Frozen)
}
