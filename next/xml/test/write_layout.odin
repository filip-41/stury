package xml_tests

import "core:testing"
import "stury:json"
import "stury:testkit"
import "stury:xml"

// The layout of the XML writer: indented text reads back as the same values and facts, and the comments of a document
// of another format are written.

@(test)
indented_text_reads_back_as_the_same_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `<r a="1"><!-- lead --><x><y>1</y><y>2</y></x><z>text<b/>more</z><w/><!-- tail --></r>`
	doc, err := xml.build(transmute([]u8)src)
	defer xml.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := xml.write(&doc, .Xml, {indent = 2})
	defer delete(text)
	want := "<r a=\"1\">\n  <!-- lead -->\n  <x>\n    <y>1</y>\n    <y>2</y>\n  </x>\n  <z>text<b/>more</z>\n  <w/><!-- tail -->\n</r>\n"
	testing.expectf(t, werr == nil && string(text) == want, "%v\n%s", werr, text)
	back, berr := xml.build(text)
	defer xml.destroy(&back)
	testing.expect(t, berr == nil)
	want_facts, got_facts := describe(&doc), describe(&back)
	defer delete(want_facts)
	defer delete(got_facts)
	testing.expectf(t, want_facts == got_facts && len(doc.nodes) == len(back.nodes), "facts differ\n%s\n%s", want_facts, got_facts)
}

@(test)
comments_of_other_formats_are_written :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string(`{"r":{"a":1, /* a tail */ "b":2}}`), .Jsonc)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	text, dropped, werr := xml.write(&doc)
	defer delete(text)
	testing.expectf(t, werr == nil && dropped == {} && string(text) == "<r><a>1</a><!-- a tail --><b>2</b></r>", "%v %v\n%s", werr, dropped, text)
}
