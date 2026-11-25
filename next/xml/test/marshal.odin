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

@(test)
a_value_marshals_to_its_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	value := Document{r = {a = 1, b = "x<y"}}
	text, err := xml.marshal(&value)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "<r><a>1</a><b>x&lt;y</b></r>", "%v\n%s", err, text)
}
