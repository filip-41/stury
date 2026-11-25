package xml_tests

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
