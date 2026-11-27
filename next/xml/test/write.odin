package xml_tests

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:xml"

// The XML writer: a document is written as a text that reads back as the same values, attributes and comments, and a
// value with no element to stand for it is refused.

@(private = "file")
SAME := [?]string{
	`<a/>`,
	`<a>text &amp; &lt;more&gt;</a>`,
	`<a x="1" y='2'><b>1</b><b>2</b><c/><d k="v">t</d></a>`,
	`<a>one<b/>two<b>x</b>three</a>`,
	`<a><b><c><d/></c></b></a>`,
	`<a><!--note--><b/></a>`,
}

@(test)
xml_texts_write_as_themselves :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in SAME {
		doc, err := xml.build(transmute([]u8)src)
		defer xml.destroy(&doc)
		testing.expectf(t, err == nil, "%s: %v", src, err)
		text, _, werr := xml.write(&doc)
		defer delete(text)
		want := src
		if k == 2 {
			want = `<a x="1" y="2"><b>1</b><b>2</b><c/><d k="v">t</d></a>`
		}
		testing.expectf(t, werr == nil && string(text) == want, "%s: %v\n%s", src, werr, text)
		testing.expectf(t, xml.validate(text) == nil, "%s: %v", text, xml.validate(text))
		back, berr := xml.build(text)
		defer xml.destroy(&back)
		testing.expectf(t, berr == nil, "%v", berr)
		testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {facts = {.Attribute, .Comment}}, "xml")
	}
}

@(test)
json_objects_write_as_xml :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		json, xml: string,
	}
	cases := [?]Case{
		{`{"a":{"b":[1,2],"c":null,"#text":"t<","d":{"e":true}}}`, `<a><b>1</b><b>2</b><c/>t&lt;<d><e>true</e></d></a>`},
		{`{"a":"x"}`, `<a>x</a>`},
		{`{"a":{"b":[{"c":1},{"c":2}]}}`, `<a><b><c>1</c></b><b><c>2</c></b></a>`},
	}
	for c, k in cases {
		doc, _ := json.build(transmute([]u8)c.json)
		defer json.destroy(&doc)
		text, _, err := xml.write(&doc)
		defer delete(text)
		testing.expectf(t, err == nil && string(text) == c.xml, "%d: %v\n%s", k, err, text)
		testing.expectf(t, xml.validate(text) == nil, "%d: %s", k, text)
	}
}

@(test)
values_with_no_element_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src in ([?]string{`{"a":[]}`, `{"a":[[1]]}`, `{"a":1,"b":2}`, `[1]`, `{"a b":1}`, `{"1a":1}`, `{"a":"\u0001"}`, `{"a":[1],"#text":2}`, `{"a":{"b":{"#text":{"c":1}}}}`}) {
		doc, _ := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		text, _, err := xml.write(&doc)
		defer delete(text)
		refused, ok := err.(write.Refused)
		testing.expectf(t, ok && refused.why == .No_Spelling, "%s: %v %s", src, err, text)
	}
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`))
	defer json.destroy(&doc)
	_, _, err := xml.write(&doc, .Xml, {ascii = true})
	testing.expect(t, err != nil)
}

// The writer copies a text of an XML read that its reader read with no decode as it stands, so such a text must hold
// no byte that would need a reference: no `<`, `&` or CR, and no control byte but tab and line feed.
@(test)
xml_texts_with_no_decode_hold_no_byte_to_escape :: proc(t: ^testing.T) {
	testkit.deadline(t)
	sources := [?]string{
		"<a>1 > 0</a>",
		"<a>x &gt; y &amp; z</a>",
		"<a><![CDATA[<&>]]></a>",
		"<a>l1\r\nl2</a>",
		"<a>tab\there\nline</a>",
		"<a>a &#60; b<b/>c &#13; d</a>",
		"<a><b>1</b><b>x > y</b><!--c--><b>]]&gt;</b></a>",
	}
	for src in sources {
		doc, err := xml.build(transmute([]u8)src)
		defer xml.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", src, err)
		for n, i in doc.nodes {
			if n.kind != .String || n.role != .Value || n.spelling & tape.SPELLING_DECODE != 0 {
				continue
			}
			for c in tape.span_bytes(&doc, n.lo, n.n) {
				bad := c == '<' || c == '&' || c == '\r' || c < 0x20 && c != '\t' && c != '\n'
				testing.expectf(t, !bad, "%q: node %d holds byte %d with no decode", src, i, c)
			}
		}
		text, _, werr := xml.write(&doc)
		defer delete(text)
		testing.expectf(t, werr == nil && xml.validate(text) == nil, "%q: %v\n%s", src, werr, text)
		back, berr := xml.build(text)
		defer xml.destroy(&back)
		testing.expectf(t, berr == nil, "%q: %v", text, berr)
		testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {facts = {.Attribute, .Comment}}, "xml")
	}
}

@(test)
xml_write_hardening_and_consistency :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Spec 0x80 (deleted FROM_TOKENS bit) is refused with Bad_Option{"spec"}.
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`))
	defer json.destroy(&doc)
	_, _, serr := xml.write(&doc, xml.Spec(0x80))
	testing.expect_value(t, serr, xml.Write_Error(xml.Bad_Option{"spec"}))

	// 2. Root `#text`, colons in non-XML names, invalid Unicode name chars, and U+FFFE/U+FFFF are refused.
	for bad in ([?]string{
		`{"#text":"hello"}`,
		`{"a:b":1}`,
		`{":":1}`,
		"{\"\u00a0\":1}",
		"{\"a\":\"\ufffe\"}",
		"{\"a\":\"\uffff\"}",
		"{\"r\":{\"#text\":\"ok\ufffe\"}}",
	}) {
		bdoc, berr := json.build(transmute([]u8)bad)
		defer json.destroy(&bdoc)
		testing.expectf(t, berr == nil, "build %q: %v", bad, berr)
		_, _, werr := xml.write(&bdoc)
		r, ok := werr.(xml.Refused)
		testing.expectf(t, ok && r.why == .No_Spelling, "%q: %v", bad, werr)
	}

	// Valid Unicode XML name succeeds.
	udoc, _ := json.build(transmute([]u8)string(`{"élém":"ok"}`))
	defer json.destroy(&udoc)
	utext, _, uerr := xml.write(&udoc)
	defer delete(utext)
	testing.expectf(t, uerr == nil && string(utext) == "<élém>ok</élém>" && xml.validate(utext) == nil, "unicode name: %v %q", uerr, utext)

	// 3. Comments with U+FFFE/U+FFFF or invalid UTF-8 are dropped cleanly so output validates.
	for csrc in ([?]string{"// bad \ufffe\n{\"r\":1}", "// bad \uffff\n{\"r\":1}"}) {
		cdoc, cerr := json.build(transmute([]u8)csrc, .Jsonc)
		defer json.destroy(&cdoc)
		testing.expect(t, cerr == nil)
		ctext, cdropped, cwerr := xml.write(&cdoc)
		defer delete(ctext)
		testing.expectf(t, cwerr == nil && .Comment in cdropped && xml.validate(ctext) == nil, "%q: %v %v %q", csrc, cwerr, cdropped, ctext)
	}
	bad_cmt := transmute([]u8)strings.clone("// bad X\n{\"r\":1}")
	defer delete(bad_cmt)
	cdoc, cerr := json.build(bad_cmt, .Jsonc)
	defer json.destroy(&cdoc)
	testing.expect(t, cerr == nil)
	bad_cmt[7] = 0xff
	ctext, cdropped, cwerr := xml.write(&cdoc)
	defer delete(ctext)
	testing.expectf(t, cwerr == nil && .Comment in cdropped && xml.validate(ctext) == nil, "bad utf8 comment: %v %v %q", cwerr, cdropped, ctext)

	// 4. `>` is handled consistently between plain leaf elements and attributed/mixed elements on XML reads.
	raw_src := `<r><a k="1">1 > 0</a><b>1 > 0</b><c>1 > 0<d/></c></r>`
	rdoc, rerr := xml.build(transmute([]u8)raw_src)
	defer xml.destroy(&rdoc)
	testing.expect(t, rerr == nil)
	rout, _, rwerr := xml.write(&rdoc)
	defer delete(rout)
	testing.expectf(t, rwerr == nil && string(rout) == raw_src && xml.validate(rout) == nil, "raw > consistency: %v\n%s", rwerr, rout)
}

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

@(private = "file")
FACT_TEXTS := [?]string{
	`<?xml version="1.0"?><!DOCTYPE r><!-- c1 --><r a="1"><!-- c2 --><x>1</x><!-- c3 --><y/>text<?pi z?><!-- c4 --></r><!-- end -->`,
	`<r><a>1</a><!-- after a -->
<b>2</b><!-- foot --></r>`,
	`<r><a>1</a><a>2<!-- in --></a><?go on?></r>`,
}

// A description of the facts of `doc`: each node's facts' kinds and texts.
describe :: proc(doc: ^tape.Document) -> string {
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

// What the writer reads back: the facts the writer holds.
@(private = "file")
KEPT :: tape.Facts{.Comment, .Comment_Inline, .Comment_Foot, .Instruction, .Instruction_Foot, .Attribute}

// The documents whose text reads back as other values: an entity that expands to nothing reads as an empty string, which
// is written as an empty element, and that reads as null.
@(private = "file")
EMPTY_ENTITY := [?]string{"xmltest/valid/sa/023.xml", "xmltest/valid/sa/085.xml", "xmltest/valid/sa/086.xml"}

// The documents whose comment stands apart from the root element by a blank line, which makes it the document's, and
// a text written with none between them reads it as the element's.
@(private = "file")
APART := [?]string{"ibm/valid/P18/ibm18v01.xml", "ibm/valid/P20/ibm20v01.xml", "ibm/valid/P20/ibm20v02.xml", "ibm/valid/P21/ibm21v01.xml"}

// The document whose default attribute holds a parameter entity's reference, which a read of the text reads as the
// reference and the first read as the first byte (a reader fault the writer does not make).
@(private = "file")
DEFAULT_PE := "xmltest/valid/sa/094.xml"

@(test)
suite_documents_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	if !os.exists(strings.concatenate({SUITE_DIR, "files"}, context.temp_allocator)) {
		log.info("the suite is not fetched: run python3 next/xml/test/conformance/fetch.py")
		return
	}
	read, written, failures := 0, 0, 0
	rest := CASES
	suite: for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, "\t", context.temp_allocator)
		kind, path, entities := fields[0], fields[1], fields[2]
		if kind != "valid" {
			continue
		}
		src, rerr := os.read_entire_file_from_path(strings.concatenate({SUITE_DIR, "files/", path}, context.temp_allocator), context.temp_allocator)
		if rerr != nil {
			continue
		}
		opts: xml.Options
		if entities != "none" {
			opts.tolerate = {.Unread_Entity}
		}
		doc, err := xml.build(src, .Xml, opts, context.temp_allocator)
		if err != nil {
			continue
		}
		read += 1
		text, _, werr := xml.write(&doc, .Xml, {}, context.temp_allocator)
		if werr != nil {
			continue
		}
		written += 1
		back, berr := xml.build(text, .Xml, opts, context.temp_allocator)
		if berr != nil {
			failures += 1
			fmt.eprintfln("%s: the text written does not read: %s\n%s", path, testkit.code_of(berr), text)
			continue
		}
		for known in EMPTY_ENTITY {
			if known == path {
				continue suite
			}
		}
		for known in APART {
			if known == path {
				continue suite
			}
		}
		if path == DEFAULT_PE {
			continue
		}
		// The attributes a document type gives an element, and the comments in the subset a text with external parts
		// leaves unread, are not the writer's to keep.
		same := tape.Facts{} if entities != "none" else KEPT
		if !testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {facts = same}, path) {
			failures += 1
		}
	}
	log.infof("%d valid documents read, %d written", read, written)
	testing.expect(t, read > 100 && written > 100)
	testing.expectf(t, failures == 0, "%d documents", failures)
}
