// The internal subset: its grammar, general and parameter entities, the expansion budget, attribute defaults and the
// rule that stops reading declarations.
package xml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import xml ".."
import walktest "../../walktest"

@(test)
declarations_of_every_kind_are_accepted :: proc(t: ^testing.T) {
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
	Case :: struct {
		text:  string,
		fault: string,
	}
	for c in ([]Case {
			{"<!DOCTYPE a [<!ELEMENT a (b|c,d)>]><a/>", "xml.element_declaration@29"},
			{"<!DOCTYPE a [<!ELEMENT a (#PCDATA|b)>]><a/>", "xml.element_declaration@35"},
			{"<!DOCTYPE a [<!ATTLIST a b BOGUS #IMPLIED>]><a/>", "xml.attribute_declaration@27"},
			{"<!DOCTYPE a [<!ATTLIST a b CDATA '<'>]><a/>", "xml.attribute_lt@34"},
			{"<!DOCTYPE a [<!ENTITY e 'x' >]><a/>", ""},
			{"<!DOCTYPE a [<!ENTITY e x>]><a/>", "xml.entity_declaration@24"},
			{"<!DOCTYPE a [<!ENTITY e '%p;'>]><a/>", "xml.parameter_reference@25"},
			{"<!DOCTYPE a [<!ENTITY % p '<!ENTITY'>%p; e 'x'>]><a/>", "xml.entity_boundary@37"},
			{"<!DOCTYPE a [<!NOTATION n>]><a/>", "xml.notation_declaration@25"},
			{"<!DOCTYPE a [x]><a/>", "xml.subset@13"},
			{"<!DOCTYPE a [<!ENTITY e 'x'>]><a>&f;</a>", "xml.undeclared_entity@33"},
			{"<!DOCTYPE a [<!ENTITY e '&e;'>]><a>&e;</a>", "xml.recursion@35"},
			{"<!DOCTYPE a [<!ENTITY e '<b>'>]><a>&e;</b></a>", "xml.entity_boundary@35"},
			{"<!DOCTYPE a [<!ENTITY e 'x</a>'>]><a>&e;</a>", "xml.entity_boundary@37"},
			{"<!DOCTYPE a [<!NOTATION n SYSTEM 'n'><!ENTITY u SYSTEM 'u' NDATA n>]><a>&u;</a>", "xml.unparsed_entity@72"},
			{"<!DOCTYPE a [<!ENTITY x SYSTEM 'x.xml'>]><a b='&x;'/>", "xml.external_entity@47"},
			{"<!DOCTYPE a [<!ENTITY e '<'>]><a b='&e;'/>", "xml.attribute_lt@36"},
			{"<!DOCTYPE a [<!ENTITY e '&#60;b/>'>]><a>&e;</a>", "xml.entity_respelled@40"},
		}) {
		testing.expect_value(t, refusal(c.text), c.fault)
	}
}

@(test)
entity_text_reads_as_its_replacement :: proc(t: ^testing.T) {
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e 'x &#38;amp; y'><!ENTITY f '&e;!'>]><a><b>&f;</b><c>&#38;</c></a>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, k := walktest.text_at(t, &doc, ".a.b")
	testing.expect_value(t, s, "x & y!")
	testing.expect_value(t, k, core.Kind.String)
	s, _ = walktest.text_at(t, &doc, ".a.c")
	testing.expect_value(t, s, "&")
}

@(test)
markup_in_replacement_text_builds_elements :: proc(t: ^testing.T) {
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e '<b>1</b><c k=\"v\"/>'>]><a>&e;<d>2</d></a>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, _ := walktest.text_at(t, &doc, ".a.b")
	testing.expect_value(t, s, "1")
	s, _ = walktest.text_at(t, &doc, ".a.d")
	testing.expect_value(t, s, "2")
	a, _ := core.member(&doc, core.ROOT, "a")
	c, found := core.member(&doc, a, "c")
	testing.expect(t, found)
	buf: [16]u8
	v, has := xml.attribute_value(&doc, c, "k", buf[:])
	testing.expect_value(t, has, true)
	testing.expect_value(t, v, "v")
	testing.expect_value(t, core.length(&doc, a), 3)
}

@(test)
a_parameter_entity_declares_what_follows :: proc(t: ^testing.T) {
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY % d '<!ENTITY e \"from &#38;#37;\">'>%d;]><a>&e;</a>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, _ := walktest.text_at(t, &doc, ".a")
	testing.expect_value(t, s, "from %")
}

@(test)
the_first_binding_of_a_name_wins :: proc(t: ^testing.T) {
	doc, ok := built(t, "<!DOCTYPE a [<!ENTITY e '1'><!ENTITY e '2'><!ATTLIST a k CDATA 'x' k CDATA 'y'>]><a>&e;</a>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, _ := walktest.text_at(t, &doc, ".a")
	testing.expect_value(t, s, "1")
	a, _ := core.member(&doc, core.ROOT, "a")
	buf: [16]u8
	v, has := xml.attribute_value(&doc, a, "k", buf[:])
	testing.expect_value(t, has, true)
	testing.expect_value(t, v, "x")
}

@(test)
declared_defaults_fill_absent_attributes :: proc(t: ^testing.T) {
	text := "<!DOCTYPE r [<!ATTLIST e d CDATA 'dx' f CDATA #FIXED 'fx' i CDATA #IMPLIED q CDATA #REQUIRED>]>" +
		"<r><e q='1'/><e q='2' d='own'/></r>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	r, _ := core.member(&doc, core.ROOT, "r")
	want := [2][][2]string{{{"q", "1"}, {"d", "dx"}, {"f", "fx"}}, {{"q", "2"}, {"d", "own"}, {"f", "fx"}}}
	for row, n in want {
		e, _ := core.child_at(&doc, r, n)
		it := core.attributes_of(&doc, e)
		for w in row {
			name, value, found := walktest.attribute_texts(&it)
			testing.expect(t, found)
			testing.expect_value(t, name, w[0])
			testing.expect_value(t, value, w[1])
		}
		_, _, found := walktest.attribute_texts(&it)
		testing.expect_value(t, found, false)
	}
}

@(test)
attribute_values_are_normalized_by_their_type :: proc(t: ^testing.T) {
	text := "<!DOCTYPE a [<!ENTITY s 'p&#9;q'><!ATTLIST a t NMTOKENS #IMPLIED c CDATA #IMPLIED d CDATA '  x\ty  '>]>" +
		"<a t='  one \r\n two  ' c=' &s;&#9;\r\nz' u='a&#10;b'/>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	buf: [32]u8
	Want :: struct {
		name, value: string,
	}
	for w in ([]Want{{"t", "one two"}, {"c", " p q\t z"}, {"u", "a\nb"}, {"d", "  x y  "}}) {
		v, has := xml.attribute_value(&doc, a, w.name, buf[:])
		testing.expect_value(t, has, true)
		testing.expect_value(t, v, w.value)
	}
}

@(test)
a_default_declares_a_namespace :: proc(t: ^testing.T) {
	doc, ok := built(t, "<!DOCTYPE p:a [<!ATTLIST p:a xmlns:p CDATA #FIXED 'urn:p'>]><p:a/>")
	if !ok {
		return
	}
	defer core.destroy(&doc)
	testing.expect_value(t, refusal("<!DOCTYPE p:a [<!ATTLIST p:a xmlns:q CDATA #FIXED 'urn:q'>]><p:a/>"), "xml.unbound_prefix@60")
}

@(test)
a_prefixed_default_has_its_names_judged :: proc(t: ^testing.T) {
	testing.expect_value(t, refusal("<!DOCTYPE a [<!ATTLIST a q:k CDATA 'v'>]><a/>"), "xml.unbound_prefix@41")
	testing.expect_value(t, refusal(`<!DOCTYPE a [<!ATTLIST a q:k CDATA 'v'>]><a xmlns:p="u" xmlns:q="u" p:k="1"/>`), "xml.duplicate_expanded@41")
	testing.expect_value(t, refusal(`<!DOCTYPE a [<!ATTLIST a k CDATA 'v'>]><a xmlns:p="u" p:k="1"/>`), "")
}

@(test)
billion_laughs_is_refused_by_the_budget :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<!DOCTYPE a [<!ENTITY l0 'lol'>")
	for i in 1 ..= 9 {
		strings.write_string(&b, "<!ENTITY l")
		strings.write_int(&b, i)
		strings.write_string(&b, " '")
		for _ in 0 ..< 10 {
			strings.write_string(&b, "&l")
			strings.write_int(&b, i - 1)
			strings.write_string(&b, ";")
		}
		strings.write_string(&b, "'>")
	}
	strings.write_string(&b, "]><a>&l9;</a>")
	f, bad := walktest.fault_in(xml.validate(b.buf[:], .Xml))
	testing.expect_value(t, bad, true)
	testing.expect_value(t, f.kind, core.Fault_Kind.Too_Wide)
	testing.expect_value(t, walktest.rule_code(f), "xml.expansion")
}

@(test)
quadratic_blowup_is_refused_by_the_budget :: proc(t: ^testing.T) {
	big := strings.repeat("x", 40_000, context.temp_allocator)
	refs := strings.repeat("&e;", 4_000, context.temp_allocator)
	text := strings.concatenate({"<!DOCTYPE a [<!ENTITY e '", big, "'>]><a b='", refs, "'>", refs, "</a>"}, context.temp_allocator)
	f, bad := walktest.fault_in(xml.validate(transmute([]u8)text, .Xml))
	testing.expect_value(t, bad, true)
	testing.expect_value(t, walktest.rule_code(f), "xml.expansion")
	testing.expect_value(t, f.kind, core.Fault_Kind.Too_Wide)
	testing.expect(t, xml.validate(transmute([]u8)text, .Xml, {max_expansion = 1 << 30}) == nil)
}

@(test)
an_unread_parameter_entity_stops_the_declarations :: proc(t: ^testing.T) {
	stopped := "<!DOCTYPE a [<!ENTITY % ext SYSTEM 'x.dtd'>%ext;<!ENTITY e 'late'><!ATTLIST a k CDATA 'd'>]><a>&e;</a>"
	testing.expect_value(t, refusal(stopped), "xml.unread_entity@95")
	doc, ok := built(t, stopped, {tolerate = {.Unread_Entity}})
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	buf: [16]u8
	_, has := xml.attribute_value(&doc, a, "k", buf[:])
	testing.expect_value(t, has, false)
	testing.expect_value(t, walktest.node_text(t, &doc, a), "&e;")
	testing.expect_value(t, refusal("<!DOCTYPE a [<!ENTITY e 'x'>]><a>&e;</a>"), "")
}

@(test)
an_external_subset_leaves_undeclared_names_unread :: proc(t: ^testing.T) {
	testing.expect_value(t, refusal("<!DOCTYPE a SYSTEM 'a.dtd'><a>&e;</a>"), "xml.unread_entity@30")
	testing.expect_value(t, refusal("<?xml version='1.0' standalone='yes'?><!DOCTYPE a SYSTEM 'a.dtd'><a>&e;</a>"), "xml.undeclared_entity@68")
	_, _, fault := tokens_of("<!DOCTYPE a SYSTEM 'a.dtd'><a>&e;</a>", {tolerate = {.Unread_Entity}})
	testing.expect_value(t, fault == nil, true)
}

@(test)
a_parameter_entity_reference_leaves_undeclared_names_unread :: proc(t: ^testing.T) {
	testing.expect_value(t, refusal("<!DOCTYPE a [<!ENTITY % p ''>%p;]><a>&e;</a>"), "xml.unread_entity@37")
	testing.expect_value(t, refusal("<?xml version='1.0' standalone='yes'?><!DOCTYPE a [<!ENTITY % p ''>%p;]><a>&e;</a>"), "xml.undeclared_entity@75")
}

@(test)
html_names_read_under_an_xhtml_public_id :: proc(t: ^testing.T) {
	text := "<!DOCTYPE html PUBLIC '-//W3C//DTD XHTML 1.0 Strict//EN' 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd'><html>&nbsp;&eacute;</html>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	s, _ := walktest.text_at(t, &doc, ".html")
	testing.expect_value(t, s, " é")
}

@(test)
replacement_nodes_are_views_of_the_subset :: proc(t: ^testing.T) {
	text := "<!DOCTYPE a [<!ENTITY e '<b>1</b>'><!ATTLIST c k CDATA 'v'>]><a>&e;<c>2</c></a>"
	doc, ok := built(t, text)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	subset_hi := u64(strings.index(text, "]>"))
	a, _ := core.member(&doc, core.ROOT, "a")
	b, _ := core.member(&doc, a, "b")
	c, _ := core.member(&doc, a, "c")
	testing.expect(t, doc.nodes[b].lo < subset_hi)
	testing.expect(t, doc.nodes[c].lo > subset_hi)
	it := core.attributes_of(&doc, c)
	_, value, found := walktest.attribute_texts(&it)
	testing.expect(t, found)
	testing.expect_value(t, value, "v")
}

@(test)
a_namespace_is_read_as_its_normalized_value :: proc(t: ^testing.T) {
	doc, ok := built(t, `<!DOCTYPE p:a [<!ENTITY u "urn:x">]><p:a xmlns:p="&u;&#58;y"/>`)
	if !ok {
		return
	}
	defer core.destroy(&doc)
	a, found := core.member(&doc, core.ROOT, "{urn:x:y}a")
	testing.expect(t, found)
	ns, has := core.fact_value(&doc, a, .Namespace)
	testing.expect(t, has)
	testing.expect_value(t, ns.text, "urn:x:y")
}
