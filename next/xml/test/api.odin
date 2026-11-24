package xml_tests

import "core:testing"
import "stury:testkit"
import "stury:xml"

// A program that reads XML imports `xml` alone: build and read a document, its attributes and an element's string
// value, find a value with no document, scan the values paths reach, and tell a fault from an answer.
@(test)
xml_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`<r id="7"><name>stury</name><tag>a</tag><tag>b</tag><size>12</size></r>`)
	doc, err := xml.build(src)
	defer xml.destroy(&doc)
	testing.expect_value(t, err, nil)
	rd := xml.Reader{&doc, nil}
	r, _ := xml.member(rd, xml.ROOT, "r")
	at, p := xml.member(rd, r, "name")
	buf: [16]u8
	name, ok := xml.node_text(&doc, at, buf[:])
	testing.expect(t, p == .Found && ok && name == "stury")
	attributes := 0
	for f in xml.facts_of(&doc, r) {
		if f.kind == .Attribute {
			k, v := xml.attribute(&doc, f)
			key, _ := xml.node_text(doc.format, doc.src, k, buf[:])
			testing.expect_value(t, key, "id")
			value, _ := xml.node_text(&doc, v, buf[:])
			testing.expect_value(t, value, "7")
			attributes += 1
		}
	}
	testing.expect_value(t, attributes, 1)
	whole, _ := xml.content(&doc, r, context.temp_allocator)
	testing.expect_value(t, whole, "sturyab12")
	path := []xml.Step{xml.Name("r"), xml.Name("tag")}
	a, ferr := xml.find(src, path)
	tag, _ := xml.node_text(xml.as(.Xml), src, xml.answer_node(a), buf[:])
	testing.expect(t, ferr == nil && a.outcome == .Found && tag == "a")
	sized, _ := xml.find(src, {xml.Name("r"), xml.Name("size")}, .Xml, {}, {format = xml.Xml_Options{infer = true}})
	size, is_number := xml.node_number(xml.as(.Xml), src, xml.answer_node(sized))
	testing.expect(t, is_number && size == xml.Number{12, .Int})
	d, derr := xml.demand_of({path})
	defer xml.destroy(&d)
	s, serr := xml.scan(src, &d)
	defer xml.destroy(&s)
	first, fp, has := xml.answer({&s, nil}, 0, 0)
	second, sp, more := xml.answer({&s, nil}, 0, 1)
	text, _ := xml.node_text(&s, second, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && more && fp == .Found && sp == .Found && first != second && text == "b")
	bad := transmute([]u8)string("<r>\n<a></b></r>")
	_, berr := xml.build(bad)
	fault, faulted := berr.(xml.Fault)
	testing.expect(t, faulted && fault.at == 9)
	msg: [64]u8
	testing.expect(t, len(xml.error_message(msg[:], berr, bad)) > 0)
	_, refused := xml.find(src, path, .Xml, {}, {dups = .All})
	option, is_option := refused.(xml.Bad_Option)
	testing.expect(t, is_option && option.option == "dups")
}
