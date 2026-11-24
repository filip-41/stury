// The internal subset: its grammar, general and parameter entities, the expansion budget, attribute defaults and the
// rule that stops reading declarations.
package xml_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:thread"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"

@(test)
declarations_of_every_kind_are_accepted :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for text in ([]string {
			"<!DOCTYPE a []><a/>",
			"<!DOCTYPE a [ ]><a/>",
			"<!DOCTYPE a SYSTEM 'a.dtd' [<!ENTITY e 'x'>]><a>&e;</a>",
			"<!DOCTYPE a [<!ELEMENT a EMPTY><!ELEMENT b ANY>]><a/>",
			"<!DOCTYPE a [<!ELEMENT a (#PCDATA|b|c)*><!ELEMENT b (c,(d|e)+,f?)>]><a/>",
			"<!DOCTYPE a [<!ELEMENT a (#PCDATA)>]><a/>",
			"<!DOCTYPE a [<!ATTLIST a b CDATA #IMPLIED c ID #REQUIRED d (x|y) 'x' e NOTATION (n) #FIXED 'n'>]><a c='1'/>",
			"<!DOCTYPE a [<!NOTATION n SYSTEM 'n'><!NOTATION m PUBLIC '-//M'>]><a/>",
			"<!DOCTYPE a [<!ENTITY u SYSTEM 'u.bin' NDATA n><!ENTITY x PUBLIC '-//X' 'x.xml'>]><a/>",
			"<!DOCTYPE a [<!ENTITY % p 'x'><!ENTITY % q SYSTEM 'q.dtd'>]><a/>",
			"<!DOCTYPE a [<!-- c --><?p x?>]><a/>",
			"<!DOCTYPE a [<!ENTITY % d '<!ENTITY e \"y\">'>%d;]><a>&e;</a>",
			"<!DOCTYPE a [<!ENTITY e '&#38;#60;b/>'>]><a>&e;</a>",
			"<!DOCTYPE a [<!ENTITY e '<b>&f;</b>'><!ENTITY f 'x'>]><a>&e;</a>",
		}) {
		testing.expect_value(t, refusal(text), "")
	}
}

@(test)
ill_formed_declarations_are_refused_at_their_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text:  string,
		fault: string,
	}
	for c in ([]Case {
			{"<!DOCTYPE a [<!ELEMENT a (b|c,d)>]><a/>", "element_declaration@29"},
			{"<!DOCTYPE a [<!ELEMENT a (#PCDATA|b)>]><a/>", "element_declaration@35"},
			{"<!DOCTYPE a [<!ATTLIST a b BOGUS #IMPLIED>]><a/>", "attribute_declaration@27"},
			{"<!DOCTYPE a [<!ATTLIST a b CDATA '<'>]><a/>", "attribute_lt@34"},
			{"<!DOCTYPE a [<!ENTITY e 'x' >]><a/>", ""},
			{"<!DOCTYPE a [<!ENTITY e x>]><a/>", "entity_declaration@24"},
			{"<!DOCTYPE a [<!ENTITY e '%p;'>]><a/>", "parameter_reference@25"},
			{"<!DOCTYPE a [<!ENTITY % p '<!ENTITY'>%p; e 'x'>]><a/>", "entity_boundary@37"},
			{"<!DOCTYPE a [<!ENTITY % q SYSTEM 'q.dtd'>%q;%p:q;]><a/>", "qualified_name@45"},
			{"<!DOCTYPE a [<!NOTATION n>]><a/>", "notation_declaration@25"},
			{"<!DOCTYPE a [x]><a/>", "subset@13"},
			{"<!DOCTYPE a [<!ENTITY e 'x'>]><a>&f;</a>", "undeclared_entity@33"},
			{"<!DOCTYPE a [<!ENTITY e '&e;'>]><a>&e;</a>", "recursion@35"},
			{"<!DOCTYPE a [<!ENTITY e '<b>'>]><a>&e;</b></a>", "entity_boundary@35"},
			{"<!DOCTYPE a [<!ENTITY e 'x</a>'>]><a>&e;</a>", "entity_boundary@37"},
			{"<!DOCTYPE a [<!NOTATION n SYSTEM 'n'><!ENTITY u SYSTEM 'u' NDATA n>]><a>&u;</a>", "unparsed_entity@72"},
			{"<!DOCTYPE a [<!ENTITY x SYSTEM 'x.xml'>]><a b='&x;'/>", "external_entity@47"},
			{"<!DOCTYPE a [<!ENTITY e '<'>]><a b='&e;'/>", "attribute_lt@36"},
			{"<!DOCTYPE a [<!ENTITY e '&#60;b/>'>]><a>&e;</a>", "entity_respelled@40"},
		}) {
		testing.expect_value(t, refusal(c.text), c.fault)
	}
}

@(test)
entity_text_reads_as_its_replacement :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e 'x &#38;amp; y'><!ENTITY f '&e;!'>]><a><b>&f;</b><c>&#38;</c></a>")
	if !ok {
		return
	}
	s, k := text_at(&doc, "a", "b")
	testing.expect_value(t, s, "x & y!")
	testing.expect_value(t, k, tape.Kind.String)
	s, _ = text_at(&doc, "a", "c")
	testing.expect_value(t, s, "&")
}

@(test)
markup_in_replacement_text_builds_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e '<b>1</b><c k=\"v\"/>'>]><a>&e;<d>2</d></a>")
	if !ok {
		return
	}
	s, _ := text_at(&doc, "a", "b")
	testing.expect_value(t, s, "1")
	s, _ = text_at(&doc, "a", "d")
	testing.expect_value(t, s, "2")
	a, _ := member_at(&doc, {"a"})
	c, found := member_at(&doc, {"a", "c"})
	testing.expect(t, found)
	v, has := attribute_value(&doc, c, "k")
	testing.expect_value(t, has, true)
	testing.expect_value(t, v, "v")
	n, _, _ := tape.length(reader(&doc), a, context.temp_allocator)
	testing.expect_value(t, n, 3)
}

@(test)
a_parameter_entity_declares_what_follows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY % d '<!ENTITY e \"from &#38;#37;\">'>%d;]><a>&e;</a>")
	if !ok {
		return
	}
	s, _ := text_at(&doc, "a")
	testing.expect_value(t, s, "from %")
}

@(test)
the_first_binding_of_a_name_wins :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e '1'><!ENTITY e '2'><!ATTLIST a k CDATA 'x' k CDATA 'y'>]><a>&e;</a>")
	if !ok {
		return
	}
	s, _ := text_at(&doc, "a")
	testing.expect_value(t, s, "1")
	a, _ := member_at(&doc, {"a"})
	v, has := attribute_value(&doc, a, "k")
	testing.expect_value(t, has, true)
	testing.expect_value(t, v, "x")
}

@(test)
declared_defaults_fill_absent_attributes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := "<!DOCTYPE r [<!ATTLIST e d CDATA 'dx' f CDATA #FIXED 'fx' i CDATA #IMPLIED q CDATA #REQUIRED>]>" + "<r><e q='1'/><e q='2' d='own'/></r>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	r, _ := member_at(&doc, {"r"})
	want := [2][]Attribute{{{"q", "1"}, {"d", "dx"}, {"f", "fx"}}, {{"q", "2"}, {"d", "own"}, {"f", "fx"}}}
	c, _ := xml.named(reader(&doc), r, "e")
	for row in want {
		_, e, p := xml.next_child(reader(&doc), &c)
		testing.expect_value(t, p, tape.Presence.Found)
		got := attributes_of(&doc, e)
		testing.expectf(t, len(got) == len(row), "%v, want %v", got, row)
		for w, i in row {
			testing.expectf(t, i < len(got) && got[i] == w, "attribute %d: %v, want %v", i, got, w)
		}
	}
}

@(test)
attribute_values_are_normalized_by_their_type :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := "<!DOCTYPE a [<!ENTITY s 'p&#9;q'><!ATTLIST a t NMTOKENS #IMPLIED c CDATA #IMPLIED d CDATA '  x\ty  '>]>" + "<a t='  one \r\n two  ' c=' &s;&#9;\r\nz' u='a&#10;b'/>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	for w in ([]Attribute{{"t", "one two"}, {"c", " p q\t z"}, {"u", "a\nb"}, {"d", "  x y  "}}) {
		v, has := attribute_value(&doc, a, w.name)
		testing.expect_value(t, has, true)
		testing.expect_value(t, v, w.value)
	}
}

// A text that refers to the DTD's entities decodes by the DTD its document holds, with no memory. A `find` answer
// has no document, so its text with no memory is refused, and it reads with the DTD read from the text, as a scan's
// document gives it.
@(test)
an_entity_text_decodes_by_the_dtd_its_document_holds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("<!DOCTYPE a [<!ENTITY e 'xyz'>]><a>&e;&e;</a>")
	doc, err := xml.build(src)
	defer xml.destroy(&doc)
	testing.expect_value(t, err, nil)
	a, _ := member_at(&doc, {"a"})
	buf: [16]u8
	text, ok := xml.node_text(&doc, a, buf[:])
	testing.expect(t, ok && text == "xyzxyz")
	f, ferr := xml.find(src, {xml.Name("a")})
	testing.expect_value(t, ferr, nil)
	_, none_ok := xml.node_text(xml.as(.Xml), src, xml.answer_node(f), buf[:])
	testing.expect(t, !none_ok)
	read, read_ok := xml.node_text_read(xml.as(.Xml), src, xml.answer_node(f), context.temp_allocator)
	testing.expect(t, read_ok && read == "xyzxyz")
	d, _ := xml.demand_of({{xml.Name("a")}}, allocator = context.temp_allocator)
	s, serr := xml.scan(src, &d)
	defer xml.destroy(&s)
	testing.expect_value(t, serr, nil)
	at, _ := xml.member({&s, nil}, xml.ROOT, "a")
	scanned, scanned_ok := xml.node_text(&s, at, buf[:])
	testing.expect(t, scanned_ok && scanned == "xyzxyz")
}

@(test)
a_default_declares_a_namespace :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, "<!DOCTYPE p:a [<!ATTLIST p:a xmlns:p CDATA #FIXED 'urn:p'>]><p:a/>")
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"p:a"})
	uri, _ := xml.namespace(&doc, a)
	testing.expect_value(t, uri, "urn:p")
	testing.expect_value(t, refusal("<!DOCTYPE p:a [<!ATTLIST p:a xmlns:q CDATA #FIXED 'urn:q'>]><p:a/>"), "unbound_prefix@60")
}

@(test)
a_prefixed_default_has_its_names_judged :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, refusal("<!DOCTYPE a [<!ATTLIST a q:k CDATA 'v'>]><a/>"), "unbound_prefix@41")
	testing.expect_value(t, refusal(`<!DOCTYPE a [<!ATTLIST a q:k CDATA 'v'>]><a xmlns:p="u" xmlns:q="u" p:k="1"/>`), "duplicate_expanded@41")
	testing.expect_value(t, refusal(`<!DOCTYPE a [<!ATTLIST a k CDATA 'v'>]><a xmlns:p="u" p:k="1"/>`), "")
}

@(test)
billion_laughs_is_refused_by_the_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<!DOCTYPE a [<!ENTITY l0 'lol'>")
	for i in 1 ..= 9 {
		fmt.sbprintf(&b, "<!ENTITY l%d '", i)
		for _ in 0 ..< 10 {
			fmt.sbprintf(&b, "&l%d;", i - 1)
		}
		strings.write_string(&b, "'>")
	}
	strings.write_string(&b, "]><a>&l9;</a>")
	err := xml.validate(b.buf[:], .Xml)
	testing.expect_value(t, code_of(err), "exceeded Expansion")
}

@(test)
quadratic_blowup_is_refused_by_the_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	big := strings.repeat("x", 40_000, context.temp_allocator)
	refs := strings.repeat("&e;", 4_000, context.temp_allocator)
	text := strings.concatenate({"<!DOCTYPE a [<!ENTITY e '", big, "'>]><a b='", refs, "'>", refs, "</a>"}, context.temp_allocator)
	err := xml.validate(transmute([]u8)text, .Xml)
	testing.expect_value(t, code_of(err), "exceeded Expansion")
	testing.expect_value(t, xml.validate(transmute([]u8)text, .Xml, {budget = {expansion = 1 << 30}}), nil)
}

@(test)
an_unread_parameter_entity_stops_the_declarations :: proc(t: ^testing.T) {
	testkit.deadline(t)
	stopped := "<!DOCTYPE a [<!ENTITY % ext SYSTEM 'x.dtd'>%ext;<!ENTITY e 'late'><!ATTLIST a k CDATA 'd'>]><a>&e;</a>"
	testing.expect_value(t, refusal(stopped), "unread_entity@95")
	doc, ok := built(t, stopped, {tolerate = {.Unread_Entity}})
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	_, has := attribute_value(&doc, a, "k")
	testing.expect_value(t, has, false)
	testing.expect_value(t, text_of(&doc, a), "&e;")
	testing.expect_value(t, refusal("<!DOCTYPE a [<!ENTITY e 'x'>]><a>&e;</a>"), "")
}

@(test)
an_external_subset_leaves_undeclared_names_unread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, refusal("<!DOCTYPE a SYSTEM 'a.dtd'><a>&e;</a>"), "unread_entity@30")
	testing.expect_value(t, refusal("<?xml version='1.0' standalone='yes'?><!DOCTYPE a SYSTEM 'a.dtd'><a>&e;</a>"), "undeclared_entity@68")
	unread := "<!DOCTYPE a SYSTEM 'a.dtd'><a>&e;</a>"
	_, _, err := tokens_of(unread, {tolerate = {.Unread_Entity}})
	testing.expect_value(t, err, nil)
	doc, ok := built(t, unread, {tolerate = {.Unread_Entity}})
	if !ok {
		return
	}
	a, _ := member_at(&doc, {"a"})
	testing.expect_value(t, text_of(&doc, a), "&e;")
	f, ferr := xml.find(transmute([]u8)unread, {xml.Name("a")}, opts = {tolerate = {.Unread_Entity}})
	testing.expect_value(t, ferr, nil)
	read, read_ok := xml.node_text_read(xml.as(.Xml), transmute([]u8)unread, xml.answer_node(f), context.temp_allocator)
	testing.expect(t, read_ok && read == "&e;")
}

@(test)
a_parameter_entity_reference_leaves_undeclared_names_unread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, refusal("<!DOCTYPE a [<!ENTITY % p ''>%p;]><a>&e;</a>"), "unread_entity@37")
	testing.expect_value(t, refusal("<?xml version='1.0' standalone='yes'?><!DOCTYPE a [<!ENTITY % p ''>%p;]><a>&e;</a>"), "undeclared_entity@75")
}

@(test)
html_names_read_under_an_xhtml_public_id :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := "<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0 Strict//EN' 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd'><html>&nbsp;&eacute;</html>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	s, _ := text_at(&doc, "html")
	testing.expect_value(t, s, " é")
}

@(test)
replacement_nodes_are_views_of_the_subset :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := "<!DOCTYPE a [<!ENTITY e '<b>1</b>'><!ATTLIST c k CDATA 'v'>]><a>&e;<c>2</c></a>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	subset_hi := u64(strings.index(text, "]>"))
	b, _ := member_at(&doc, {"a", "b"})
	c, _ := member_at(&doc, {"a", "c"})
	testing.expect(t, doc.nodes[b].lo < subset_hi)
	testing.expect(t, doc.nodes[c].lo > subset_hi)
	v, found := attribute_value(&doc, c, "k")
	testing.expect(t, found)
	testing.expect_value(t, v, "v")
}

@(test)
a_namespace_is_read_as_its_normalized_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := built(t, `<!DOCTYPE p:a [<!ENTITY u "urn:x">]><p:a xmlns:p="&u;&#58;y"/>`)
	if !ok {
		return
	}
	a, found := member_at(&doc, {"p:a"})
	testing.expect(t, found)
	uri, p := xml.namespace(&doc, a)
	testing.expect_value(t, p, tape.Presence.Found)
	testing.expect_value(t, uri, "urn:x:y")
}

// A document holds its DTD's tables, so the texts that refer to its entities decode with no memory, from threads at
// once, and the documents of a scan in pieces and of member records decode them as the whole build does.
@(test)
entity_texts_decode_with_no_memory_on_threads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "<!DOCTYPE r [")
	for i in 0 ..< 300 {
		fmt.sbprintf(&b, "<!ENTITY e%d 'value %d'>", i, i)
	}
	strings.write_string(&b, "]><r>")
	for i in 0 ..< 300 {
		fmt.sbprintf(&b, "<a k='&e%d;'>&e%d;&amp;</a>", i, i)
	}
	strings.write_string(&b, "</r>")
	src := transmute([]u8)strings.to_string(b)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	doc, err := xml.build(src, .Xml, {}, mem.tracking_allocator(&track))
	defer xml.destroy(&doc)
	testing.expect_value(t, err, nil)
	made := track.total_allocation_count
	Reading :: struct {
		doc:  ^xml.Document,
		read: int,
	}
	read_all :: proc(r: ^Reading) {
		buf: [64]u8
		for at in 0 ..< len(r.doc.nodes) {
			if text, ok := xml.node_text(r.doc, xml.Node_Index(at), buf[:]); ok && strings.has_prefix(text, "value ") {
				r.read += 1
			}
		}
		for f in r.doc.facts {
			if f.kind != .Attribute {
				continue
			}
			_, value := xml.attribute(r.doc, f)
			if text, ok := xml.node_text(r.doc, value, buf[:]); ok && strings.has_prefix(text, "value ") {
				r.read += 1
			}
		}
	}
	readings: [4]Reading
	threads: [4]^thread.Thread
	for &r, i in readings {
		r.doc = &doc
		threads[i] = thread.create_and_start_with_poly_data(&r, read_all)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for r in readings {
		testing.expect_value(t, r.read, 600)
	}
	testing.expect_value(t, track.total_allocation_count, made)
	whole := texts_of(&doc)
	d, _ := xml.demand_of({{xml.Name("r")}}, allocator = context.temp_allocator)
	pieces := tape.Pieces{last = true}
	defer tape.destroy(&pieces)
	held, herr := xml.scan(src, &d, .Xml, {}, {pieces = &pieces})
	defer xml.destroy(&held)
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, texts_of(&held), whole)
	r := xml.records_open(src, .Members)
	defer tape.destroy_records(&r)
	member: [1]xml.Record
	docs: [1]xml.Document
	whole_member, _ := xml.demand_of({{}}, allocator = context.temp_allocator)
	got := 0
	for xml.records_scan(&r, &whole_member, member[:], docs[:]) == 1 {
		got += strings.count(texts_of(&docs[0]), "value ")
		xml.destroy(&docs[0])
	}
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, got, 300)
}

// The texts of the string nodes of `doc`, one after another.
@(private = "file")
texts_of :: proc(doc: ^xml.Document) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	buf: [64]u8
	for at in 0 ..< len(doc.nodes) {
		if doc.nodes[at].kind == .String && doc.nodes[at].role == .Value {
			text, _ := xml.node_text(doc, xml.Node_Index(at), buf[:])
			strings.write_string(&b, text)
		}
	}
	return strings.to_string(b)
}
