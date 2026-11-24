// The document an XML text builds and the reads over it: values, text, attributes, namespaces and paths.
package xml_tests

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(test)
elements_build_values_by_their_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<?xml version="1.0"?><a><b>x &amp; y</b><c/><d><![CDATA[<z>]]></d><e>1<!--c-->2</e></a>`)
	if !ok {
		return
	}
	s, k := text_at(&doc, "a", "b")
	testing.expect_value(t, s, "x & y")
	testing.expect_value(t, k, tape.Kind.String)
	_, k = text_at(&doc, "a", "c")
	testing.expect_value(t, k, tape.Kind.Null)
	s, _ = text_at(&doc, "a", "d")
	testing.expect_value(t, s, "<z>")
	s, _ = text_at(&doc, "a", "e")
	testing.expect_value(t, s, "12")
}

@(test)
line_ends_in_white_space_text_read_as_lf :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<r><a>\r\n</a><b> \r \r\n</b></r>")
	if !ok {
		return
	}
	s, _ := text_at(&doc, "r", "a")
	testing.expect_value(t, s, "\n")
	s, _ = text_at(&doc, "r", "b")
	testing.expect_value(t, s, " \n \n")
}

// A repeated name reads as a group, which the default policy takes by its first member, and `.Last` by its last.
@(test)
text_between_children_is_the_text_member :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<r>t<c>x</c>u\r\nv</r>")
	if !ok {
		return
	}
	r, _ := member_at(&doc, {"r"})
	testing.expect_value(t, int(doc.nodes[r].spelling & tape.MAX_CHILDREN), 3)
	n, p, err := tape.length(reader(&doc), r, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, n, 2)
	hash, found := xml.member(reader(&doc), r, xml.TEXT_KEY)
	testing.expect_value(t, found, tape.Presence.Found)
	testing.expect_value(t, text_of(&doc, hash), "t")
	hash, found = xml.member(reader(&doc), r, xml.TEXT_KEY, .First)
	testing.expect_value(t, found, tape.Presence.Found)
	testing.expect_value(t, text_of(&doc, hash), "t")
	hash, found = xml.member(reader(&doc), r, xml.TEXT_KEY, .Last)
	testing.expect_value(t, found, tape.Presence.Found)
	testing.expect_value(t, text_of(&doc, hash), "u\nv")
	c, _ := xml.named(reader(&doc), r, xml.TEXT_KEY)
	runs := make([dynamic]string, context.temp_allocator)
	for {
		_, v, more := xml.next_child(reader(&doc), &c)
		if more != .Found {
			break
		}
		append(&runs, text_of(&doc, v))
	}
	testing.expect_value(t, len(runs), 2)
	testing.expect(t, len(runs) == 2 && runs[0] == "t" && runs[1] == "u\nv")
}

@(test)
inference_types_a_text_value_only_when_asked :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := `<a><n>12</n><t>true</t><s> 1</s><e><!--x--></e></a>`
	plain, _ := built(t, text)
	_, k := text_at(&plain, "a", "n")
	testing.expect_value(t, k, tape.Kind.String)
	_, k = text_at(&plain, "a", "e")
	testing.expect_value(t, k, tape.Kind.Null)
	inferred, _ := built(t, text, {format = xml.Xml_Options{infer = true}})
	_, k = text_at(&inferred, "a", "n")
	testing.expect_value(t, k, tape.Kind.Number)
	_, k = text_at(&inferred, "a", "t")
	testing.expect_value(t, k, tape.Kind.True)
	_, k = text_at(&inferred, "a", "s")
	testing.expect_value(t, k, tape.Kind.String)
	n, _ := member_at(&inferred, {"a", "n"})
	num, ok := xml.node_number(&inferred, n)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, num, xml.Number{12, .Int})
}

// A text that holds a reference or markup is not one span of digits, so an inferring read leaves it a string whose
// decoded text is its digits.
@(test)
a_decoded_number_stays_a_string :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := strings.concatenate({"<a><d>&#49;2</d><p><?", strings.repeat("x", 200, context.temp_allocator), "?>7.5</p></a>"}, context.temp_allocator)
	doc, ok := built(t, text, {format = xml.Xml_Options{infer = true}})
	if !ok {
		return
	}
	s, k := text_at(&doc, "a", "d")
	testing.expect_value(t, s, "12")
	testing.expect_value(t, k, tape.Kind.String)
	s, k = text_at(&doc, "a", "p")
	testing.expect_value(t, s, "7.5")
	testing.expect_value(t, k, tape.Kind.String)
	plain, _ := built(t, "<a><d>12</d><p>7.5</p></a>", {format = xml.Xml_Options{infer = true}})
	_, k = text_at(&plain, "a", "d")
	testing.expect_value(t, k, tape.Kind.Number)
	p, _ := member_at(&plain, {"a", "p"})
	num, _ := xml.node_number(&plain, p)
	testing.expect_value(t, num.kind, xml.Number_Kind.Float)
	testing.expect_value(t, transmute(f64)num.bits, 7.5)
}

@(test)
attributes_are_facts_of_the_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<a x="1 &amp; 2" y = 'b&#10;c&#xA;' z="t	u"><b k="v"/></a>`)
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	n, _, _ := tape.length(reader(&doc), a, context.temp_allocator)
	testing.expect_value(t, n, 1)
	got := attributes_of(&doc, a)
	want := [?]Attribute{{"x", "1 & 2"}, {"y", "b\nc\n"}, {"z", "t u"}}
	testing.expect_value(t, len(got), len(want))
	for w, i in want {
		testing.expectf(t, i < len(got) && got[i] == w, "attribute %d: %v, want %v", i, got, w)
	}
	v, has := attribute_value(&doc, a, "y")
	testing.expect_value(t, has, true)
	testing.expect_value(t, v, "b\nc\n")
	_, has = attribute_value(&doc, a, "w")
	testing.expect_value(t, has, false)
}

@(test)
names_and_content_are_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<a xmlns="u" xmlns:p="v"><b>x<p:c>y</p:c>z</b></a>`)
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	b, _ := member_at(&doc, {"a", "b"})
	testing.expect_value(t, text_of(&doc, b - 1), "b")
	buf: [16]u8
	ns, has := xml.namespace(&doc, b, buf[:])
	testing.expect_value(t, has, true)
	testing.expect_value(t, ns, "u")
	content, cok := xml.content(&doc, b, context.temp_allocator)
	testing.expect_value(t, cok, true)
	testing.expect_value(t, content, "xyz")
	c, found := xml.member(reader(&doc), b, "p:c")
	testing.expect_value(t, found, tape.Presence.Found)
	ns, _ = xml.namespace(&doc, c, buf[:])
	testing.expect_value(t, ns, "v")
	ns, _ = xml.namespace(&doc, a, buf[:])
	testing.expect_value(t, ns, "u")
}

// A name steps by its spelling as written, a prefix included, and the namespace of an element is read from its place.
@(test)
a_name_reads_as_written_and_its_namespace_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<feed xmlns="http://a" xmlns:x="http://x"><entry>1</entry><x:entry>2</x:entry><entry xmlns="">3</entry></feed>`)
	if !ok {
		return
	}
	feed, _ := member_at(&doc, {"feed"})
	r := reader(&doc)
	got, found := xml.member(r, feed, "x:entry")
	testing.expect_value(t, found, tape.Presence.Found)
	testing.expect_value(t, text_of(&doc, got), "2")
	_, found = xml.member(r, feed, "{http://x}entry")
	testing.expect_value(t, found, tape.Presence.Missing)
	c, _ := xml.named(r, feed, "entry")
	want := [?]struct {
		text, uri: string,
	}{{"1", "http://a"}, {"3", ""}}
	for w in want {
		_, v, p := xml.next_child(r, &c)
		testing.expect_value(t, p, tape.Presence.Found)
		buf: [16]u8
		uri, _ := xml.namespace(&doc, v, buf[:])
		testing.expect_value(t, text_of(&doc, v), w.text)
		testing.expect_value(t, uri, w.uri)
	}
	_, _, p := xml.next_child(r, &c)
	testing.expect_value(t, p, tape.Presence.Missing)
	x, _ := xml.member(r, feed, "x:entry")
	buf: [16]u8
	uri, _ := xml.namespace(&doc, x, buf[:])
	testing.expect_value(t, uri, "http://x")
}

@(test)
a_container_ends_at_its_end_tag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := "<a><b x='1'>t<c/>u<!--k--></b> <d><e/></d><!--z--></a><!--tail-->"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	b, _ := member_at(&doc, {"a", "b"})
	d, _ := member_at(&doc, {"a", "d"})
	span :: proc(doc: ^tape.Document, at: tape.Node_Index) -> string {
		end, ok := doc.format.close_end(doc, at)
		return string(doc.src[doc.nodes[at].lo:end]) if ok else "?"
	}
	testing.expect_value(t, span(&doc, b), "<b x='1'>t<c/>u<!--k--></b>")
	testing.expect_value(t, span(&doc, d), "<d><e/></d>")
	testing.expect_value(t, span(&doc, a), "<a><b x='1'>t<c/>u<!--k--></b> <d><e/></d><!--z--></a>")
}

@(test)
a_scan_answers_one_path_without_building_the_rest :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := `<a><b><c>1</c></b><b><c>2</c></b><d x="y">z</d></a>`
	src := transmute([]u8)text
	path := []tape.Step{tape.Name("a"), tape.Name("d")}
	answer, err := xml.find(src, path)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, answer.outcome, tape.Presence.Found)
	testing.expect_value(t, string(src[answer.lo + u64(answer.head):answer.hi - u64(answer.tail)]), "z")
	demand, _ := xml.demand_of([][]tape.Step{path}, allocator = context.temp_allocator)
	doc, serr := xml.scan(src, &demand, allocator = context.temp_allocator)
	testing.expect_value(t, serr, nil)
	at, p, _ := xml.answer({doc = &doc}, 0, 0)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, text_of(&doc, at), "z")
	bad := `<a><d>z</d><e></f></a>`
	_, err = xml.find(transmute([]u8)bad, path)
	testing.expect_value(t, code_of(err), "mismatched_tag")
}

// An attribute fact's span runs from its name through its closing quote, its body is its value as written, and its name
// and value are the tokens `xml.attribute` gives.
@(test)
an_attribute_fact_holds_its_value_between_its_markers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<a x="1 &amp; 2" y = 'b'/>`)
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	bodies := make([dynamic]string, context.temp_allocator)
	values := make([dynamic]tape.Token, context.temp_allocator)
	for f in doc.facts {
		if f.node != a || f.kind != .Attribute {
			continue
		}
		lead, tail := u64(f.spelling & 0xFF), u64(f.spelling >> 8 & 0xFF)
		append(&bodies, string(doc.src[f.lo + lead:f.lo + u64(f.n) - tail]))
		name, value := xml.attribute(&doc, f)
		testing.expect_value(t, name.role, tape.Role.Key)
		testing.expect_value(t, value.kind, tape.Kind.String)
		append(&values, value)
	}
	testing.expect_value(t, len(bodies), 2)
	if len(bodies) != 2 {
		return
	}
	testing.expect_value(t, bodies[0], "1 &amp; 2")
	testing.expect_value(t, bodies[1], "b")
	testing.expect(t, values[0].spelling & tape.SPELLING_DECODE != 0)
	testing.expect_value(t, values[1].spelling, 0)
	testing.expect_value(t, string(doc.src[values[1].lo:values[1].lo + u64(values[1].n)]), "b")
	testing.expect_value(t, text_of(&doc, a - 1), "a")
}

// A value that starts more than 255 bytes past its name's first byte is past what the fact's lead holds.
@(test)
an_attribute_far_from_its_name_is_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
			a, _ := member_at(&doc, {"a"})
			got := attributes_of(&doc, a)
			if !testing.expect_value(t, len(got), 1) {
				continue
			}
			testing.expect_value(t, len(got[0].name), width if text[3] == 'n' else 1)
			testing.expect_value(t, got[0].value, "v\"w" if text[3] == 'n' else "v'w")
		}
	}
	long := strings.concatenate({"<!DOCTYPE a [<!ATTLIST a k (", strings.repeat("x|", 200, context.temp_allocator), "y) 'y'>]><a/>"}, context.temp_allocator)
	doc, ok := built(t, long)
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	v, has := attribute_value(&doc, a, "k")
	testing.expect(t, has)
	testing.expect_value(t, v, "y")
}

// A name an element's members repeat is read as a group, each member in document order, and the document keeps a member
// for each.
@(test)
a_repeated_name_reads_as_a_group_of_its_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<r>hello <b k="1">bold</b> tail<b>x</b><c>y</c></r>`)
	if !ok {
		return
	}
	r, _ := member_at(&doc, {"r"})
	reads := reader(&doc)
	testing.expect_value(t, int(doc.nodes[r].spelling & tape.MAX_CHILDREN), 5)
	n, _, _ := tape.length(reads, r, context.temp_allocator)
	testing.expect_value(t, n, 3)
	read_group :: proc(doc: ^tape.Document, r: tape.Node_Index, name: string) -> string {
		c, _ := xml.named(reader(doc), r, name)
		b := strings.builder_make(context.temp_allocator)
		for {
			_, v, p := xml.next_child(reader(doc), &c)
			if p != .Found {
				break
			}
			strings.write_string(&b, text_of(doc, v))
			strings.write_byte(&b, '|')
		}
		return strings.to_string(b)
	}
	testing.expect_value(t, read_group(&doc, r, "b"), "bold|x|")
	testing.expect_value(t, read_group(&doc, r, xml.TEXT_KEY), "hello | tail|")
	testing.expect_value(t, read_group(&doc, r, "c"), "y|")
	// Each distinct name is one member of the value, taken by its first element, and as written all five appear.
	c, _, _ := xml.children(reads, r, context.temp_allocator)
	defer xml.destroy(&c)
	keys := make([dynamic]string, context.temp_allocator)
	for {
		k, _, p := xml.next_child(reads, &c)
		if p != .Found {
			break
		}
		append(&keys, text_of(&doc, k))
	}
	testing.expect_value(t, strings.join(keys[:], ",", context.temp_allocator), "#text,b,#text,b,c")
	last, p := xml.member(reads, r, "b", .Last)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, text_of(&doc, last), "x")
}
