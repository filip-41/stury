package xml_tests

import "core:testing"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:xml"

// The token writer: the tokens of an object of one member are the text `write` gives of its document.

@(test)
tokens_write_an_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w, .Xml, {indent = 2}) == nil)
	steps := [?]struct {
		kind: write.Token_Kind,
		text: string,
	}{{.Object, ""}, {.Key, "r"}, {.Object, ""}, {.Key, "a"}, {.Number, "1"}, {.Key, "b"}, {.Array, ""}, {.String, "x&y"}, {.String, "z"}, {.Close, ""}, {.Close, ""}, {.Close, ""}}
	for step in steps {
		testing.expect(t, xml.token(&w, step.kind, step.text) == nil)
	}
	text, err := xml.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "<r>\n  <a>1</a>\n  <b>x&amp;y</b>\n  <b>z</b>\n</r>\n", "%v\n%s", err, text)
}

@(test)
an_unfinished_sequence_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	testing.expect(t, xml.token(&w, .Object) == nil)
	_, err := xml.writer_end(&w)
	refused, ok := err.(write.Refused)
	testing.expect(t, ok && refused.why == .Malformed)
}
