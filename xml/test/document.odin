// The document an XML text builds and the reads over it: values, text, attributes, namespaces and paths.
package xml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import json "../../json"
import xml ".."
import walktest "../../walktest"

@(private)
built :: proc(t: ^testing.T, text: string, opts := xml.Options{}) -> (doc: core.Document, ok: bool) {
	d, err := xml.build(transmute([]u8)text, .Xml, opts)
	testing.expectf(t, err == nil, "%v", err)
	return d, err == nil
}

@(test)
elements_build_values_by_their_name :: proc(t: ^testing.T) {
	doc, ok := built(t, `<?xml version="1.0"?><a><b>x &amp; y</b><c/><d><![CDATA[<z>]]></d><e>1<!--c-->2</e></a>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, k := walktest.text_at(t, &doc, ".a.b")
	testing.expect_value(t, s, "x & y")
	testing.expect_value(t, k, core.Kind.String)
	_, k = walktest.text_at(t, &doc, ".a.c")
	testing.expect_value(t, k, core.Kind.Null)
	s, _ = walktest.text_at(t, &doc, ".a.d")
	testing.expect_value(t, s, "<z>")
	s, _ = walktest.text_at(t, &doc, ".a.e")
	testing.expect_value(t, s, "12")
}

@(test)
line_ends_in_white_space_text_read_as_lf :: proc(t: ^testing.T) {
	doc, ok := built(t, "<r><a>\r\n</a><b> \r \r\n</b></r>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, _ := walktest.text_at(t, &doc, ".r.a")
	testing.expect_value(t, s, "\n")
	s, _ = walktest.text_at(t, &doc, ".r.b")
	testing.expect_value(t, s, " \n \n")
}

@(test)
text_between_children_is_the_text_member :: proc(t: ^testing.T) {
	doc, ok := built(t, "<r>t<c>x</c>u\r\nv</r>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	r, _ := core.member(&doc, core.ROOT, "r")
	testing.expect_value(t, core.length(&doc, r), 3)
	hash, found := core.member(&doc, r, "#text")
	testing.expect(t, found)
	testing.expect_value(t, walktest.node_text(t, &doc, hash), "u\nv")
	hash, found = core.member(&doc, r, "#text", .First)
	testing.expect_value(t, walktest.node_text(t, &doc, hash), "t")
}

@(test)
inference_types_a_text_value_only_when_asked :: proc(t: ^testing.T) {
	text := `<a><n>12</n><t>true</t><s> 1</s><e><!--x--></e></a>`
	plain, _ := built(t, text)
	defer core.destroy(&plain)
	_, k := walktest.text_at(t, &plain, ".a.n")
	testing.expect_value(t, k, core.Kind.String)
	_, k = walktest.text_at(t, &plain, ".a.e")
	testing.expect_value(t, k, core.Kind.Null)
	inferred, _ := built(t, text, {infer = true})
	defer core.destroy(&inferred)
	_, k = walktest.text_at(t, &inferred, ".a.n")
	testing.expect_value(t, k, core.Kind.Number)
	_, k = walktest.text_at(t, &inferred, ".a.t")
	testing.expect_value(t, k, core.Kind.True)
	_, k = walktest.text_at(t, &inferred, ".a.s")
	testing.expect_value(t, k, core.Kind.String)
	n, _ := core.member(&inferred, core.ROOT, "a")
	n, _ = core.member(&inferred, n, "n")
	v, num := core.int_value(&inferred, n)
	testing.expect_value(t, num, true)
	testing.expect_value(t, v, 12)
}

// A number whose text is no one span, by a reference or markup inside it, is its decoded digits wherever a number is
// read: its value, an order and a comparison.
@(test)
a_decoded_number_reads_by_its_digits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := strings.concatenate({"<a><d>&#49;2</d><p><?", strings.repeat("x", 200, context.temp_allocator), "?>7.5</p></a>"}, context.temp_allocator)
	doc, ok := built(t, text, {infer = true})
	if !ok {
		return
	}
	defer core.destroy(&doc)
	plain, _ := built(t, "<a><d>12</d><p>7.5</p></a>", {infer = true})
	defer core.destroy(&plain)
	p, _ := walktest.member_at(t, &doc, ".a.p")
	f, has := core.float_value(&doc, p)
	testing.expect(t, has)
	testing.expect_value(t, f, 7.5)
	testing.expect(t, core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&plain, core.ROOT}))
	d, _ := walktest.member_at(t, &doc, ".a.d")
	buf: [core.HEX_ROOM]u8
	twelve, digits, read := core.double_of(core.Node_Ref{&doc, d}, buf[:])
	testing.expect(t, read)
	testing.expect_value(t, twelve, 12)
	testing.expect_value(t, digits, "12")
}

@(test)
attributes_are_facts_of_the_element :: proc(t: ^testing.T) {
	doc, ok := built(t, `<a x="1 &amp; 2" y = 'b&#10;c&#xA;' z="t	u"><b k="v"/></a>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	testing.expect_value(t, core.length(&doc, a), 1)
	it := core.attributes_of(&doc, a)
	want := [?][2]string{{"x", "1 & 2"}, {"y", "b\nc\n"}, {"z", "t u"}}
	for w in want {
		name, value, found := walktest.attribute_texts(&it)
		testing.expect(t, found)
		testing.expect_value(t, name, w[0])
		testing.expect_value(t, value, w[1])
	}
	_, _, found := walktest.attribute_texts(&it)
	testing.expect_value(t, found, false)
	v, has := walktest.attribute_text(&doc, a, "y")
	testing.expect_value(t, has, true)
	testing.expect_value(t, v, "b\nc\n")
	_, has = walktest.attribute_text(&doc, a, "w")
	testing.expect_value(t, has, false)
}

@(test)
names_and_content_are_facts :: proc(t: ^testing.T) {
	doc, ok := built(t, `<a xmlns="u" xmlns:p="v"><b>x<p:c>y</p:c>z</b></a>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	b, _ := core.member(&doc, a, "b")
	name, _ := core.fact_value(&doc, b, .Name)
	testing.expect_value(t, name.text, "b")
	ns, has := core.fact_value(&doc, b, .Namespace)
	testing.expect_value(t, has, true)
	testing.expect_value(t, ns.text, "u")
	content, _ := core.fact_value(&doc, b, .Content)
	testing.expect_value(t, content.text, "xyz")
	c, found := core.member(&doc, b, "p:c")
	testing.expect_value(t, found, true)
	ns, _ = core.fact_value(&doc, c, .Namespace)
	testing.expect_value(t, ns.text, "v")
}

@(test)
an_expanded_name_matches_by_namespace_and_local_name :: proc(t: ^testing.T) {
	doc, ok := built(t, `<feed xmlns="http://a" xmlns:x="http://x"><entry>1</entry><x:entry>2</x:entry><entry xmlns="">3</entry></feed>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	feed, _ := core.member(&doc, core.ROOT, "{http://a}feed")
	got, found := core.member(&doc, feed, "{http://a}entry")
	testing.expect_value(t, found, true)
	testing.expect_value(t, walktest.node_text(t, &doc, got), "1")
	got, found = core.member(&doc, feed, "{http://x}entry")
	testing.expect_value(t, found, true)
	testing.expect_value(t, walktest.node_text(t, &doc, got), "2")
	got, found = core.member(&doc, feed, "{}entry")
	testing.expect_value(t, found, true)
	testing.expect_value(t, walktest.node_text(t, &doc, got), "3")
	_, found = core.member(&doc, feed, "{http://b}entry")
	testing.expect_value(t, found, false)
	got, found = core.member(&doc, feed, "x:entry")
	testing.expect_value(t, walktest.node_text(t, &doc, got), "2")
}

@(test)
a_container_ends_at_its_end_tag :: proc(t: ^testing.T) {
	text := "<a><b x='1'>t<c/>u<!--k--></b> <d><e/></d><!--z--></a><!--tail-->"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	b, _ := core.member(&doc, a, "b")
	d, _ := core.member(&doc, a, "d")
	testing.expect_value(t, string(core.span(&doc, b)), "<b x='1'>t<c/>u<!--k--></b>")
	testing.expect_value(t, string(core.span(&doc, d)), "<d><e/></d>")
	testing.expect_value(t, string(core.span(&doc, a)), "<a><b x='1'>t<c/>u<!--k--></b> <d><e/></d><!--z--></a>")
}

@(test)
a_scan_answers_one_path_without_building_the_rest :: proc(t: ^testing.T) {
	text := `<a><b><c>1</c></b><b><c>2</c></b><d x="y">z</d></a>`
	path, _ := core.parse_path(".a.d")
	defer core.path_destroy(&path)
	doc, answer, err := xml.find(transmute([]u8)text, .Xml, path)
	testing.expect(t, err == nil)
	defer core.destroy(&doc)
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	testing.expect_value(t, walktest.node_text(t, &doc, answer.node), "z")
	bad := `<a><d>z</d><e></f></a>`
	_, _, err = xml.find(transmute([]u8)bad, .Xml, path)
	f, walked := walktest.fault_in(err)
	testing.expect(t, walked)
	testing.expect_value(t, walktest.rule_code(f), "xml.mismatched_tag")
}

@(test)
an_expanded_path_step_answers_from_the_built_document :: proc(t: ^testing.T) {
	text := `<f xmlns="u"><e>1</e></f>`
	path, _ := core.parse_path(`.["{u}f"]["{u}e"]`)
	defer core.path_destroy(&path)
	doc, answer, err := xml.find(transmute([]u8)text, .Xml, path)
	testing.expect(t, err == nil)
	defer core.destroy(&doc)
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	testing.expect_value(t, walktest.node_text(t, &doc, answer.node), "1")
}

// An attribute fact's body is its value as written, which core slices by the fact's lead and tail, and its name and
// value are the tokens the format's `attribute` gives.
@(test)
an_attribute_fact_holds_its_value_between_its_markers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, ok := built(t, `<a x="1 &amp; 2" y = 'b'/>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	it := core.facts_of(&doc, a, .Attribute)
	body, found := core.fact_next(&it)
	testing.expect(t, found)
	testing.expect_value(t, body, "1 &amp; 2")
	body, _ = core.fact_next(&it)
	testing.expect_value(t, body, "b")
	attributes := core.attributes_of(&doc, a)
	name, value, held := core.attribute_next(&attributes)
	testing.expect(t, held)
	testing.expect_value(t, name.role, core.Role.Key)
	testing.expect_value(t, value.kind, core.Kind.Plain)
	testing.expect(t, value.spelling & core.SPELLING_DECODE != 0)
	testing.expect(t, core.key_equals(&doc, a - 1, "a"))
	_, value, _ = core.attribute_next(&attributes)
	testing.expect_value(t, value.spelling, 0)
	testing.expect_value(t, string(doc.src[value.lo:value.lo + u64(value.n)]), "b")
}

// A value that starts more than 255 bytes past its name's first byte is past what the fact's lead holds.
@(test)
an_attribute_far_from_its_name_is_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for width in ([]int{250, 251, 252, 253, 254, 255, 256, 300, 70000}) {
		name := strings.repeat("n", width, context.temp_allocator)
		gap := strings.repeat(" ", width, context.temp_allocator)
		for text in ([]string{strings.concatenate({"<a ", name, "='v\"w'/>"}, context.temp_allocator), strings.concatenate({"<a k", gap, "=", gap, "\"v'w\"/>"}, context.temp_allocator)}) {
			if width > int(max(u16)) && text[3] == 'n' {
				continue
			}
			doc, ok := built(t, text)
			if !ok {
				continue
			}
			defer core.destroy(&doc)
			a, _ := core.member(&doc, core.ROOT, "a")
			it := core.attributes_of(&doc, a)
			got, value, found := walktest.attribute_texts(&it)
			testing.expect(t, found)
			testing.expect_value(t, len(got), width if text[3] == 'n' else 1)
			testing.expect_value(t, value, "v\"w" if text[3] == 'n' else "v'w")
		}
	}
	long := strings.concatenate({"<!DOCTYPE a [<!ATTLIST a k (", strings.repeat("x|", 200, context.temp_allocator), "y) 'y'>]><a/>"}, context.temp_allocator)
	doc, ok := built(t, long)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	v, has := walktest.attribute_text(&doc, a, "k")
	testing.expect(t, has)
	testing.expect_value(t, v, "y")
}

// A copy of a document holds its own DTD, so it reads an entity's text after the document it was copied from is gone.
@(test)
a_clone_keeps_the_declarations :: proc(t: ^testing.T) {
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e 'long replacement text'>]><a k='&e;'>&e;</a>")
	if !ok {
		return
	}
	copy, err := core.clone(&doc)
	core.destroy(&doc)
	testing.expect(t, err == nil)
	defer core.destroy(&copy)
	a, _ := core.member(&copy, core.ROOT, "a")
	testing.expect_value(t, walktest.node_text(t, &copy, a), "long replacement text")
	v, has := walktest.attribute_text(&copy, a, "k")
	testing.expect(t, has)
	testing.expect_value(t, v, "long replacement text")
	it := core.attributes_of(&copy, a)
	_, value, _ := walktest.attribute_texts(&it)
	testing.expect_value(t, value, "long replacement text")
}

// A name an element's members repeat is one member of the node's value, an array of each element in document order,
// as the readers, a built value and a write to JSON read it, while the document keeps a member for each.
@(test)
a_repeated_name_reads_as_an_array_of_its_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, ok := built(t, `<r>hello <b k="1">bold</b> tail<b>x</b><c>y</c></r>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	r, _ := core.member(&doc, core.ROOT, "r")
	ref := core.Node_Ref{&doc, r}
	testing.expect_value(t, core.length(&doc, r), 5)
	testing.expect_value(t, core.value_length(ref), 3)
	b, found := core.value_member(ref, "b")
	group, grouped := b.(^core.Array)
	testing.expect(t, found && grouped && len(group.items) == 2)
	c, _ := core.value_member(ref, "c")
	_, single := c.(core.Node_Ref)
	testing.expect(t, single)
	text, _, err := core.write(&doc, {}, json.as(.Json), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	want := `{"r":{"#text":["hello "," tail"],"b":["bold","x"],"c":"y"}}`
	testing.expect_value(t, string(text), want)
	same, jerr := json.build(transmute([]u8)want, .Json)
	walktest.expect_nil(t, jerr)
	defer core.destroy(&same)
	root := core.Node_Ref{&same, core.ROOT}
	testing.expect(t, core.equal(core.Node_Ref{&doc, core.ROOT}, root))
	context.allocator = context.temp_allocator
	testing.expect(t, core.equal(core.built_value(core.Node_Ref{&doc, core.ROOT}), root))
	testing.expect(t, !core.equal(core.built_value(core.Node_Ref{&doc, core.ROOT}, .Last), root))
}
