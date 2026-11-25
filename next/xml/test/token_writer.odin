package xml_tests

import "core:testing"
import "stury:testkit"
import "stury:xml"

// The token writer: the tokens of an object of one member are the text `write` gives of its document.

@(test)
tokens_write_an_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w, .Xml, {indent = 2}) == nil)
	steps := [?]struct {
		kind: xml.Token_Kind,
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
tokens_validate_names_and_indent_mixed_content :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Invalid element name must be refused (neutral Token_Tape format, never treated as native XML).
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	for s in ([?]struct{kind: xml.Token_Kind, text: string}{{.Object, ""}, {.Key, "123 bad>name"}, {.String, "v"}, {.Close, ""}}) {
		testing.expect(t, xml.token(&w, s.kind, s.text) == nil)
	}
	_, bad_err := xml.writer_end(&w)
	r, ok := bad_err.(xml.Refused)
	testing.expectf(t, ok && r.why == .No_Spelling, "bad name: %v", bad_err)

	// Mixed `#text` content under `indent = 2` does not insert whitespace around `#text` children.
	testing.expect(t, xml.writer_start(&w, .Xml, {indent = 2}) == nil)
	for s in ([?]struct{kind: xml.Token_Kind, text: string}{{.Object, ""}, {.Key, "r"}, {.Object, ""}, {.Key, "#text"}, {.String, "hi"}, {.Key, "b"}, {.String, "x"}, {.Close, ""}, {.Close, ""}}) {
		testing.expect(t, xml.token(&w, s.kind, s.text) == nil)
	}
	mixed, merr := xml.writer_end(&w)
	defer delete(mixed)
	testing.expectf(t, merr == nil && string(mixed) == "<r>hi<b>x</b></r>\n", "mixed indent: %v %q", merr, mixed)
}

@(test)
an_unfinished_sequence_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	testing.expect(t, xml.token(&w, .Object) == nil)
	_, err := xml.writer_end(&w)
	refused, ok := err.(xml.Refused)
	testing.expect(t, ok && refused.why == .Malformed)
}
