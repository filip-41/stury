package xml_tests

import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
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

@(private = "file")
Step :: struct {
	kind: xml.Token_Kind,
	text: string,
}

// Takes each of `steps`, which must be taken.
@(private = "file")
take :: proc(t: ^testing.T, w: ^xml.Writer, steps: []Step) {
	for s in steps {
		testing.expectf(t, xml.token(w, s.kind, s.text) == nil, "%v", s)
	}
}

@(test)
writer_start_refuses_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		opts: xml.Write_Options,
		want: string,
	}{{{format = tape.Dsv_Options{}}, "format"}, {{framing = .Lines}, "options"}, {{ascii = true}, "options"}, {{sort_keys = true}, "options"}, {{grow_header = true}, "header"}, {{header = {"a"}}, "header"}, {{node = 1}, "node"}}
	for c in cases {
		w: xml.Writer
		err := xml.writer_start(&w, .Xml, c.opts)
		testing.expectf(t, err == xml.Write_Error(xml.Bad_Option{c.want}), "%v: %v", c.want, err)
	}
	w: xml.Writer
	testing.expect_value(t, xml.writer_start(&w, xml.Spec(1)), xml.Write_Error(xml.Bad_Option{"spec"}))
	// A typed write starts no node of its value either.
	Value :: struct {
		r: int,
	}
	value := Value{1}
	_, merr := xml.marshal(&value, .Xml, {node = 1})
	testing.expect_value(t, merr, xml.Write_Error(xml.Bad_Option{"node"}))
}

@(test)
tokens_write_into_a_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w, .Xml, {}, strings.to_writer(&b)) == nil)
	take(t, &w, {{.Object, ""}, {.Key, "r"}, {.String, "v"}, {.Close, ""}})
	text, err := xml.writer_end(&w)
	testing.expectf(t, err == nil && text == nil && strings.to_string(b) == "<r>v</r>", "%v %q", err, strings.to_string(b))
}

@(test)
a_dropped_writer_frees_its_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	take(t, &w, {{.Object, ""}, {.Key, "r"}, {.Object, ""}, {.Key, "a"}, {.String, "v"}})
	xml.writer_drop(&w)
}

// An empty array under a name stands for no element, so it is refused at its node.
@(test)
an_empty_array_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	take(t, &w, {{.Object, ""}, {.Key, "r"}, {.Object, ""}, {.Key, "a"}, {.Array, ""}, {.Close, ""}, {.Close, ""}, {.Close, ""}})
	_, err := xml.writer_end(&w)
	testing.expect_value(t, err, xml.Write_Error(xml.Refused{4, .No_Spelling}))
}

// A refusal of a token or of an unfinished text counts closes, and one of `write` names a node, which does not.
@(test)
refusal_indexes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	prefix := []Step{{.Object, ""}, {.Key, "r"}, {.Object, ""}, {.Key, "a"}, {.Object, ""}, {.Close, ""}}
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	take(t, &w, prefix)
	testing.expect_value(t, xml.token(&w, .Key, "\xff"), xml.Write_Error(xml.Refused{6, .No_Spelling}))
	_, err := xml.writer_end(&w)
	testing.expect_value(t, err, xml.Write_Error(xml.Refused{6, .Malformed}))

	testing.expect(t, xml.writer_start(&w) == nil)
	take(t, &w, prefix)
	take(t, &w, {{.Key, "1bad"}, {.Null, ""}, {.Close, ""}, {.Close, ""}})
	_, err = xml.writer_end(&w)
	testing.expect_value(t, err, xml.Write_Error(xml.Refused{5, .No_Spelling}))
}

// A name an element's children repeat is a member each time, as an XML read holds it, so it is written each time.
@(test)
repeated_names_write_each_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: xml.Writer
	testing.expect(t, xml.writer_start(&w) == nil)
	take(t, &w, {{.Object, ""}, {.Key, "r"}, {.Object, ""}, {.Key, "a"}, {.Number, "1"}, {.Key, "a"}, {.Number, "2"}, {.Close, ""}, {.Close, ""}})
	text, err := xml.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "<r><a>1</a><a>2</a></r>", "%v %q", err, text)
	doc, berr := xml.build(text)
	defer xml.destroy(&doc)
	testing.expectf(t, berr == nil && len(doc.nodes) == 7, "%v %d", berr, len(doc.nodes))
}
