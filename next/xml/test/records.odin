// The records of XML: a text is one record, from the reader's position to the input's end, and under `.Members` each
// member of the root.
package xml_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
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
	testing.expect_value(t, xml.records_validate(&r, out[:]), 0)
	testing.expect_value(t, r.index, 1)
	testing.expect_value(t, r.err, nil)

	path := []tape.Step{tape.Name("a"), tape.Name("b")}
	f := xml.records_open(src)
	answers: [2]tape.Span_Answer
	testing.expect_value(t, xml.records_find(&f, path, out[:], answers[:]), 1)
	testing.expect_value(t, out[0].err, nil)
	testing.expect_value(t, out[0].lo, 0)
	testing.expect_value(t, out[0].hi, u64(len(src)))
	testing.expect_value(t, string(src[answers[0].lo:answers[0].hi]), "1")
	whole, _ := xml.find(src, path)
	testing.expect_value(t, answers[0], whole)

	demand, _ := xml.demand_of([][]tape.Step{path}, allocator = context.temp_allocator)
	s := xml.records_open(src)
	docs: [2]tape.Document
	testing.expect_value(t, xml.records_scan(&s, &demand, out[:], docs[:], {}, context.temp_allocator), 1)
	at, p, _ := xml.answer({doc = &docs[0]}, 0, 0)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, testkit.scalar_text(&docs[0], at), "1")
	testing.expect_value(t, s.err, nil)

	chosen, err := xml.reads(.Xml).records(xml.as(.Xml), src, .Concatenated, {}, nil, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy_records(chosen)
	testing.expect_value(t, tape.records_validate(chosen, out[:]), 0)
	testing.expect_value(t, chosen.index, 1)
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
	testing.expect_value(t, empty.index, 0)
	testing.expect_value(t, empty.err, nil)

	src := transmute([]u8)string("<a/><b>1</b>")
	r := xml.records_open(src)
	r.pos = 4
	answers: [2]tape.Span_Answer
	testing.expect_value(t, xml.records_find(&r, {}, out[:], answers[:]), 1)
	testing.expect_value(t, out[0].lo, 4)
	testing.expect_value(t, out[0].hi, u64(len(src)))
	testing.expect_value(t, out[0].err, nil)

	bad := transmute([]u8)string("<a><b></c></a>")
	b := xml.records_open(bad)
	testing.expect_value(t, xml.records_validate(&b, out[:]), 1)
	f, faulted := out[0].err.(tape.Fault)
	testing.expect_value(t, faulted, true)
	testing.expect_value(t, testkit.code_of(out[0].err), "mismatched_tag")
	testing.expect_value(t, f.at, 8)

	big := strings.builder_make(context.temp_allocator)
	strings.write_string(&big, "<r>")
	for i in 0 ..< 20000 {
		fmt.sbprintf(&big, "<e n=\"%d\">t</e>", i)
	}
	strings.write_string(&big, "</r>")
	whole := transmute([]u8)strings.to_string(big)
	w := xml.records_open(whole)
	testing.expect_value(t, xml.records_validate(&w, out[:]), 0)
	testing.expect_value(t, w.index, 1)
	testing.expect_value(t, w.err, nil)
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
	for path in ([][]tape.Step{{tape.Index(0)}, {tape.Name("{u}a")}, {tape.Name("a"), tape.All{}}}) {
		at := xml.records_open(src, .Members, path = path)
		testing.expect(t, xml.records_validate(&at, out[:]) == 0 && at.err == tape.Error(tape.Bad_Option{"path"}))
	}
	whole := xml.records_open(src, .Concatenated, path = {tape.Name("a")})
	testing.expect(t, xml.records_validate(&whole, out[:]) == 0 && whole.err == tape.Error(tape.Bad_Option{"path"}))
	all := xml.records_open(src, .Members, opts = {dups = .All}, path = {tape.Name("a")})
	testing.expect(t, xml.records_validate(&all, out[:]) == 0 && all.err == tape.Error(tape.Bad_Option{"dups"}))
}

// The records of `src` under `.Members`, each as its offsets, key and document, and how they ended, one line each.
@(private = "file")
member_lines :: proc(src: string, opts := xml.Options{}, path: []tape.Step = nil) -> string {
	b := strings.builder_make(context.temp_allocator)
	whole, _ := xml.demand_of([][]tape.Step{{}}, nil, nil, true, context.temp_allocator)
	r := xml.records_open(transmute([]u8)src, .Members, opts = opts, path = path)
	defer tape.destroy_records(&r)
	out: [2]tape.Record
	docs: [2]tape.Document
	for {
		n := xml.records_scan(&r, &whole, out[:], docs[:], {}, context.temp_allocator)
		for rec, k in out[:n] {
			key := "#text" if rec.key.n == 0 else src[rec.key.lo:][:rec.key.n]
			fmt.sbprintf(&b, "%d-%d %s %s%s\n", rec.lo, rec.hi, key, testkit.render_doc(&docs[k]), testkit.code_of(rec.err))
		}
		if n < len(out) {
			break
		}
	}
	fmt.sbprintf(&b, "end %s", testkit.code_of(r.err))
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
		texts := [2][]u8{src, testkit.mutate(src, XML_MUTATE_ALPHABET)}
		for text in texts {
			doc, berr := xml.build(text, .Xml, {}, context.temp_allocator)
			r := xml.records_open(text, .Members)
			out: [64]tape.Record
			docs: [64]tape.Document
			n := xml.records_scan(&r, &whole_demand, out[:], docs[:], {}, context.temp_allocator)
			tape.destroy_records(&r)
			if berr != nil {
				testing.expectf(t, r.err == berr, "%q: records end %v, build %v", text, r.err, berr)
				continue
			}
			testing.expectf(t, r.err == nil, "%q: records end %v", text, r.err)
			root, _ := testkit.member_at(&doc, {"r"})
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
				// Each fact of the member's nodes, at the same node of the record, which starts at the member's value.
				facts := make([dynamic]tape.Fact, context.temp_allocator)
				for f in doc.facts {
					if int(f.node) >= value && int(f.node) < next {
						placed := f
						placed.node -= tape.Node_Index(value)
						append(&facts, placed)
					}
				}
				testing.expectf(t, slice.equal(docs[k].facts, facts[:]), "%q member %d: facts %v, whole %v", text, k, docs[k].facts, facts[:])
				at = next
			}
			testing.expectf(t, k == n, "%q: %d records, %d members", text, n, k)
		}
	}
}

// The members of a long text read in pieces in small windows, each from the last one's `keep`, need no window much
// longer than a member: the records keep no byte of the members they gave. A text with an internal subset keeps it,
// as every read in pieces does.
@(test)
members_in_pieces_keep_only_the_member_being_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<?xml version="1.0"?><!DOCTYPE r SYSTEM "r.dtd"><r xmlns:n="u">`)
	for i in 0 ..< 2000 {
		fmt.sbprintf(&b, `<n:m k="%d">&#65;%d</n:m> t`, i, i)
	}
	strings.write_string(&b, "</r>")
	src := transmute([]u8)strings.to_string(b)
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	WINDOW :: 64
	end := WINDOW
	r := xml.records_open(src[:end], .Members, opts = {pieces = &p})
	defer tape.destroy_records(&r)
	out: [8]tape.Record
	answers: [8]tape.Span_Answer
	read, longest := 0, 0
	for {
		for {
			n := xml.records_find(&r, {tape.Name("#text")}, out[:], answers[:])
			read += n
			if n < len(out) {
				break
			}
		}
		if !p.more || p.last {
			break
		}
		end = min(int(p.keep) + WINDOW, len(src))
		for end <= int(p.at) {
			end += 1
		}
		longest = max(longest, end - int(p.keep))
		p.from, p.last = p.keep, end == len(src)
		if !testing.expect_value(t, xml.records_window(&r, src[p.keep:end]), nil) {
			return
		}
	}
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, read, 4000)
	testing.expectf(t, longest < 200, "a window of %d bytes", longest)
}

// The records at a path are the members of the element the path reaches below the root element, each keyed by its name
// and read under the namespaces and the DTD of the text around it. Every element before it that the path does not take is
// judged and passed, and the elements of its key that it takes follow one another in document order under `.Group`, the
// first only under `.First`.
@(test)
members_at_a_path_are_the_members_of_the_element_it_reaches :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	a := []tape.Step{tape.Name("a")}
	ab := []tape.Step{tape.Name("a"), tape.Name("b")}
	text := `<r><x><b>1</b></x><a><c k="1">t</c>tail<d/></a><a><e/></a></r>`
	testing.expect_value(t, member_lines(text, path = a), "21-35 c t\n35-39 #text tail\n39-43 d \n50-54 e \nend ")
	testing.expect_value(t, member_lines(text, {dups = .First}, a), "21-35 c t\n35-39 #text tail\n39-43 d \nend ")
	testing.expect_value(t, member_lines(text, {dups = .Last}, a), "21-35 c t\n35-39 #text tail\n39-43 d \nend duplicate_key")
	testing.expect_value(t, member_lines("<r><a/><a><e/></a></r>", {dups = .Last}, a), "10-14 e \nend ")
	testing.expect_value(t, member_lines(`<r><b/><a><b><n/></b><b>x<m/>y</b></a></r>`, path = ab), "13-17 n \n24-25 #text x\n25-29 m \n29-30 #text y\nend ")
	// No element, or one with no child element, holds no member.
	testing.expect_value(t, member_lines(text, path = {tape.Name("none")}), "end ")
	testing.expect_value(t, member_lines("<r><a>text</a></r>", path = a), "end ")
	testing.expect_value(t, member_lines("<r/>", path = a), "end ")
	// A member reads under the namespaces declared around it, and a fault ends the records after every member before it.
	testing.expect_value(t, member_lines(`<r xmlns:n="u"><a xmlns="d"><n:b>1</n:b><c/></a></r>`, path = a), "28-40 n:b 1\n40-44 c \nend ")
	testing.expect_value(t, member_lines("<r><a><b>1</b><c></d></a></r>", path = a), "6-14 b 1\nend mismatched_tag")
	testing.expect_value(t, member_lines("<r><x><y></x></r>", path = a), "end mismatched_tag")
}

// The records at a path read in pieces, in windows of any size, are those the whole text gives.
@(test)
members_at_a_path_agree_in_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Case :: struct {
		text: string,
		path: []tape.Step,
	}
	cases := []Case {
		{`<?xml version="1.0"?><r xmlns:n="u"><x k="1">skip<y>1</y></x><a><c k="1">t&#65;</c>tail<n:d/><!--c--></a>` +
		`<x/><a><e>1</e>gap<f><g/></f></a></r>`, {tape.Name("a")}},
		{`<r xmlns:n="u"><a><x><b>no</b></x><b k="1"><c>1</c>t<n:d/></b>between<b>q</b></a><a><b/><b>z</b></a></r>`, {tape.Name("a"), tape.Name("b")}},
		{`<!DOCTYPE r [<!ENTITY e "v">]><r><a><b><c>&e;</c><c>x&e;</c></b></a><a><b><c/>&e;</b></a></r>`, {tape.Name("a"), tape.Name("b")}},
	}
	for c in cases {
		src := transmute([]u8)c.text
		want := member_lines(c.text, path = c.path)
		testing.expectf(t, strings.count(want, "\n") >= 3, "%q holds no records: %q", c.text, want)
		for window in ([]int{1, 2, 3, 5, 8, 13, 40}) {
			b := strings.builder_make(context.temp_allocator)
			whole, _ := xml.demand_of([][]tape.Step{{}}, nil, nil, true, context.temp_allocator)
			p := tape.Pieces{allocator = context.temp_allocator}
			end := min(window, len(src))
			p.last = end == len(src)
			r := xml.records_open(src[:end], .Members, opts = {pieces = &p}, path = c.path)
			out: [2]tape.Record
			docs: [2]tape.Document
			for {
				for {
					n := xml.records_scan(&r, &whole, out[:], docs[:], {}, context.temp_allocator)
					for rec, k in out[:n] {
						fmt.sbprintf(&b, "%d-%d %s %s%s\n", rec.lo, rec.hi, c.text[rec.key.lo:][:rec.key.n] if rec.key.n > 0 else "#text", testkit.render_doc(&docs[k]), testkit.code_of(rec.err))
					}
					if n < len(out) {
						break
					}
				}
				if !p.more || p.last || r.err != nil {
					break
				}
				end = min(int(p.keep) + window, len(src))
				for end <= int(p.at) {
					end += 1
				}
				p.from, p.last = p.keep, end == len(src)
				if !testing.expect_value(t, xml.records_window(&r, src[p.keep:end]), nil) {
					return
				}
			}
			fmt.sbprintf(&b, "end %s", testkit.code_of(r.err))
			tape.destroy_records(&r)
			got := strings.to_string(b)
			testing.expectf(t, got == want, "%q window %d: %q, whole %q", c.text, window, got, want)
		}
	}
}
