package xml_tests

import "core:testing"
import "stury:json"
import "stury:testkit"
import "stury:xml"

// Texts v1 writes of the same values, which the writers here write as they do.

@(test)
xml_indent_two_is_v1s_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string(`{"r":{"a":1,"b":["x","y"],"c":{"d":true},"e":null}}`))
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := xml.write(&doc, .Xml, {indent = 2})
	defer delete(text)
	want := "<r>\n  <a>1</a>\n  <b>x</b>\n  <b>y</b>\n  <c>\n    <d>true</d>\n  </c>\n  <e/>\n</r>\n"
	testing.expectf(t, werr == nil && string(text) == want, "%v\n%s", werr, text)
}
