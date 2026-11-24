// The records of XML: a text is one record, from the reader's position to the input's end, and under `.Members` each
// member of the root.
package xml_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(private = "file")
RECORD_TEXT :: "<?xml version=\"1.0\"?>\n<!-- lead -->\n<a><b>1</b><b>2</b><c x=\"y\"/></a>\n<?pi tail?>\n"

// The record forms of a constant spec and of the reads a chosen format opens frame and judge the text as one record,
// and a find and a scan of it answer as a read of its bytes alone.
@(test)
every_record_form_reads_a_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(RECORD_TEXT)
	r := xml.records_open(src)
	out: [2]tape.Record
	n := xml.records_validate(&r, out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, out[0].err, nil)
	testing.expect_value(t, out[0].lo, 0)
	testing.expect_value(t, out[0].hi, u64(len(src)))

	path := []tape.Step{tape.Name("a"), tape.Name("b")}
	f := xml.records_open(src)
	answers: [2]tape.Span_Answer
	testing.expect_value(t, xml.records_find(&f, path, out[:], answers[:]), 1)
	testing.expect_value(t, string(src[answers[0].lo:answers[0].hi]), "1")
	whole, _ := xml.find(src, path)
	testing.expect_value(t, answers[0], whole)

	demand, _ := xml.demand_of([][]tape.Step{path}, allocator = context.temp_allocator)
	s := xml.records_open(src)
	docs: [2]tape.Document
	testing.expect_value(t, xml.records_scan(&s, &demand, out[:], docs[:], {}, context.temp_allocator), 1)
	at, p, _ := xml.answer({doc = &docs[0]}, 0, 0)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, text_of(&docs[0], at), "1")
	testing.expect_value(t, s.err, nil)

	chosen, err := xml.reads(.Xml).records(xml.as(.Xml), src, .Concatenated, {}, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy_records(chosen)
	testing.expect_value(t, tape.records_validate(chosen, out[:]), 1)
	testing.expect_value(t, out[0].hi, u64(len(src)))
	testing.expect_value(t, tape.records_validate(chosen, out[:]), 0)
	testing.expect_value(t, chosen.err, nil)
}

// An input of no bytes holds no record, a record read from a byte past the first starts there, and a refused text is
// the record's fault at its byte in the input.
@(test)
a_record_is_the_rest_of_the_input :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	out: [2]tape.Record
	empty := xml.records_open(nil)
	testing.expect_value(t, xml.records_validate(&empty, out[:]), 0)
	testing.expect_value(t, empty.err, nil)

	src := transmute([]u8)string("<a/><b>1</b>")
	r := xml.records_open(src)
	r.pos = 4
	testing.expect_value(t, xml.records_validate(&r, out[:]), 1)
	testing.expect_value(t, out[0].lo, 4)
	testing.expect_value(t, out[0].hi, u64(len(src)))
	testing.expect_value(t, out[0].err, nil)

	bad := transmute([]u8)string("<a><b></c></a>")
	b := xml.records_open(bad)
	testing.expect_value(t, xml.records_validate(&b, out[:]), 1)
	f, faulted := out[0].err.(tape.Fault)
	testing.expect_value(t, faulted, true)
	testing.expect_value(t, code_of(out[0].err), "mismatched_tag")
	testing.expect_value(t, f.at, 8)

	big := strings.builder_make(context.temp_allocator)
	strings.write_string(&big, "<r>")
	for i in 0 ..< 20000 {
		fmt.sbprintf(&big, "<e n=\"%d\">t</e>", i)
	}
	strings.write_string(&big, "</r>")
	whole := transmute([]u8)strings.to_string(big)
	w := xml.records_open(whole)
	testing.expect_value(t, xml.records_validate(&w, out[:]), 1)
	testing.expect_value(t, out[0].hi, u64(len(whole)))
	testing.expect_value(t, out[0].err, nil)
	testing.expect_value(t, xml.records_validate(&w, out[:]), 0)
}

// The records refuse the options they cannot take before any is read.
@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("<a/>")
	out: [1]tape.Record
	for framing in ([]tape.Framing{.Lines, .Elements}) {
		r := xml.records_open(src, framing)
		testing.expect(t, xml.records_validate(&r, out[:]) == 0 && r.err == tape.Error(tape.Bad_Option{"framing"}))
	}
	pieces: tape.Pieces
	p := xml.records_open(src, .Members, opts = {pieces = &pieces})
	testing.expect(t, xml.records_validate(&p, out[:]) == 0 && p.err == tape.Error(tape.Bad_Option{"pieces"}))
}

// The records of `src` under `.Members`, each as its offsets, key and document, and how they ended, one line each.
@(private = "file")
member_lines :: proc(src: string, opts := xml.Options{}) -> string {
	b := strings.builder_make(context.temp_allocator)
	whole, _ := xml.demand_of([][]tape.Step{{}}, nil, nil, true, context.temp_allocator)
	r := xml.records_open(transmute([]u8)src, .Members, opts = opts)
	defer xml.records_close(&r)
	out: [2]tape.Record
	docs: [2]tape.Document
	for {
		n := xml.records_scan(&r, &whole, out[:], docs[:], {}, context.temp_allocator)
		for rec, k in out[:n] {
			key := "#text" if rec.key.n == 0 else src[rec.key.lo:][:rec.key.n]
			fmt.sbprintf(&b, "%d-%d %s %s%s\n", rec.lo, rec.hi, key, testkit.render_doc(&docs[k]), code_of(rec.err))
		}
		if n < len(out) {
			break
		}
	}
	fmt.sbprintf(&b, "end %s", code_of(r.err))
	return strings.to_string(b)
}

// Each member of the root is a record keyed by its name, its child elements whole and its `#text` runs between them,
// read in place under the namespaces and the DTD around it. Comments and instructions between members are passed, a
// root with no child holds none, and a fault ends the records after every member before it.
@(test)
members_are_the_root_members :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, member_lines(`<r a="1"><b x="1">t</b><b/>text<!--c--><c><d>2</d></c> </r>`), "9-23 b t\n23-27 b \n27-39 #text text<!--c-->\n39-54 c {d:2}\nend ")
	testing.expect_value(t, member_lines("<r>only text</r>"), "end ")
	testing.expect_value(t, member_lines("<r/>"), "end ")
	testing.expect_value(t, member_lines(`<r xmlns:n="u"><n:a>1</n:a><n:b k="2"/></r>`), "15-27 n:a 1\n27-39 n:b \nend ")
	testing.expect_value(t, member_lines(`<!DOCTYPE r [<!ENTITY e "x"><!ATTLIST b d CDATA "v">]><r><b>&e;</b><b/></r>`), "57-67 b &e;\n67-71 b \nend ")
	testing.expect_value(t, member_lines("<r><b>1</b><b>2</c></r>"), "3-11 b 1\nend mismatched_tag")
	testing.expect_value(t, member_lines("<r><a>1</a></r>x"), "3-11 a 1\nend junk_after_root")
	testing.expect_value(t, member_lines("<r><a>1</a>", {budget = {steps = 2}}), "3-11 a 1\nend truncated")
	testing.expect_value(t, member_lines("<r><a><b/></a><c><d/></c></r>", {budget = {steps = 3}}), "3-14 a {b:}\nend exceeded Steps")
	// A member the hook refuses is the record's refusal, and the records go on past it.
	testing.expect_value(t, member_lines("<r><a><b/><c/><d/></a><e/></r>", {budget = {nodes = 4}}), "3-22 a exceeded Nodes\n22-26 e \nend ")
}

// Each record under `.Members` of a generated document is the member of the whole document's root at its place: its
// key, its document whole, and its attributes. A text the build refuses gives the error `validate` gives.
@(test)
members_agree_with_the_whole_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0a6)
	whole_demand, _ := xml.demand_of([][]tape.Step{{}}, nil, nil, true, context.temp_allocator)
	for _ in 0 ..< testkit.rounds(40) {
		src := random_document()
		defer delete(src)
		texts := [2][]u8{src, mutated(src)}
		defer delete(texts[1])
		for text in texts {
			doc, berr := xml.build(text, .Xml, {}, context.temp_allocator)
			r := xml.records_open(text, .Members)
			out: [64]tape.Record
			docs: [64]tape.Document
			n := xml.records_scan(&r, &whole_demand, out[:], docs[:], {}, context.temp_allocator)
			xml.records_close(&r)
			if berr != nil {
				testing.expectf(t, r.err == berr, "%q: records end %v, build %v", text, r.err, berr)
				continue
			}
			testing.expectf(t, r.err == nil, "%q: records end %v", text, r.err)
			root, _ := member_at(&doc, {"r"})
			k := 0
			for at := int(root) + 1; doc.nodes[root].kind == .Object && at < int(root) + int(doc.nodes[root].n); k += 1 {
				key := doc.nodes[at]
				value := at + 1
				next := value + (int(doc.nodes[value].n) if doc.nodes[value].kind > .Plain else 1)
				if !testing.expectf(t, k < n, "%q: %d records, member %d", text, n, k) {
					break
				}
				b := strings.builder_make(context.temp_allocator)
				testkit.render_node(&b, &doc, value)
				got := testkit.render_doc(&docs[k])
				testing.expectf(t, got == strings.to_string(b) && out[k].key.lo == key.lo && out[k].key.n == key.n, "%q member %d: %s %v, whole %s %v", text, k, got, out[k].key, strings.to_string(b), key)
				// An instruction marks the node after it, which past an element's last child the whole document has
				// outside the element and a record has not, so instructions are left out.
				facts, got_facts := 0, 0
				for f in doc.facts {
					facts += int(int(f.node) >= value && int(f.node) < next && f.kind != .Instruction)
				}
				for f in docs[k].facts {
					got_facts += int(f.kind != .Instruction)
				}
				testing.expectf(t, got_facts == facts, "%q member %d: %d facts, whole %d", text, k, got_facts, facts)
				at = next
			}
			testing.expectf(t, k == n, "%q: %d records, %d members", text, n, k)
		}
	}
}
