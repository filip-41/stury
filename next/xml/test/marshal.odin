package xml_tests

import "core:testing"
import "stury:testkit"
import "stury:xml"

// Typed writes: a value written as XML is the text of its element.

@(private = "file")
Document :: struct {
	r: struct {
		a: int,
		b: string,
	},
}

@(private = "file")
Bad_Name_Doc :: struct {
	x: int `xml:"123 bad>name"`,
}

@(test)
a_value_marshals_to_its_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	value := Document{r = {a = 1, b = "x<y"}}
	plan, perr := xml.plan_make(Document)
	testing.expect(t, perr == nil)
	defer xml.plan_destroy(&plan)
	text, err := xml.marshal(&value, .Xml, {}, &plan)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "<r><a>1</a><b>x&lt;y</b></r>", "%v\n%s", err, text)

	// Invalid XML element name from struct tag is refused.
	bad := Bad_Name_Doc{x = 1}
	_, berr := xml.marshal(&bad)
	r, ok := berr.(xml.Refused)
	testing.expectf(t, ok && r.why == .No_Spelling, "bad marshal name: %v", berr)
}
