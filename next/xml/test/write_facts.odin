package xml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

// The facts an XML text holds are written: a text written from an XML document reads back with the same values,
// attributes, comments, instructions and declarations.

@(private = "file")
FACT_TEXTS := [?]string{
	`<?xml version="1.0"?><!DOCTYPE r><!-- c1 --><r a="1"><!-- c2 --><x>1</x><!-- c3 --><y/>text<?pi z?><!-- c4 --></r><!-- end -->`,
	`<r><a>1</a><!-- after a -->
<b>2</b><!-- foot --></r>`,
	`<r><a>1</a><a>2<!-- in --></a><?go on?></r>`,
}

// A description of the facts of `doc`: each node's facts' kinds and texts.
describe ::proc(doc: ^tape.Document) -> string {
	b: strings.Builder
	for _, i in doc.nodes {
		at := tape.Node_Index(i)
		fmt.sbprintf(&b, "%d", i)
		for f in tape.facts_of(doc, at) {
			fmt.sbprintf(&b, " %v:%q", f.kind, string(tape.span_bytes(doc, f.lo, f.n)))
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(test)
xml_facts_are_written_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in FACT_TEXTS {
		doc, err := xml.build(transmute([]u8)src)
		defer xml.destroy(&doc)
		testing.expectf(t, err == nil, "%d: %v", k, err)
		text, dropped, werr := xml.write(&doc)
		defer delete(text)
		testing.expectf(t, werr == nil && dropped == {}, "%d: %v %v\n%s", k, werr, dropped, text)
		back, berr := xml.build(text)
		defer xml.destroy(&back)
		testing.expectf(t, berr == nil, "%d: %v\n%s", k, berr, text)
		want, got := describe(&doc), describe(&back)
		defer delete(want)
		defer delete(got)
		testing.expectf(t, want == got, "%d: facts differ\n%s\n%s\nwant\n%s\ngot\n%s", k, src, text, want, got)
	}
}
