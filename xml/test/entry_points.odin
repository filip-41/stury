// The format package's entry points, in the form that binds a constant spec and the form that takes one at run time.
package xml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import xml ".."
import walktest "../../walktest"

@(private = "file")
Seen :: struct {
	found: int,
}

@(private = "file")
count_found :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	if a.outcome == .Found {
		(^Seen)(state).found += 1
	}
	return true
}

// Every entry point with `spec`, a constant in one caller and a value chosen at run time in the other.
@(private = "file")
entry_points :: proc(t: ^testing.T, spec: xml.Spec, bound: bool) {
	src := transmute([]u8)string(`<a><b>1</b><c k="v">2</c><b>3</b></a>`)
	b, perr := core.parse_path(".a.b")
	walktest.expect_nil(t, perr)
	defer core.path_destroy(&b)
	c, cerr := core.parse_path(".a.c")
	walktest.expect_nil(t, cerr)
	defer core.path_destroy(&c)
	paths := [?]core.Path{b, c}

	doc, sdoc, mdoc, fdoc: core.Document
	answer: core.Answer
	berr, serr, merr, ferr, one, many, verr: core.Error
	seen_one, seen_many: Seen
	if bound {
		verr = xml.validate(src, .Xml)
		doc, berr = xml.build(src, .Xml)
		sdoc, serr = xml.scan(src, .Xml, c)
		mdoc, merr = xml.scan(src, .Xml, paths[:])
		fdoc, answer, ferr = xml.find(src, .Xml, c)
		one = xml.each_answer(src, .Xml, c, &seen_one, count_found)
		many = xml.each_answer(src, .Xml, paths[:], &seen_many, count_found)
	} else {
		verr = xml.validate(src, spec)
		doc, berr = xml.build(src, spec)
		sdoc, serr = xml.scan(src, spec, c)
		mdoc, merr = xml.scan(src, spec, paths[:])
		fdoc, answer, ferr = xml.find(src, spec, c)
		one = xml.each_answer(src, spec, c, &seen_one, count_found)
		many = xml.each_answer(src, spec, paths[:], &seen_many, count_found)
	}
	defer core.destroy(&doc)
	defer core.destroy(&sdoc)
	defer core.destroy(&mdoc)
	defer core.destroy(&fdoc)
	for err in ([?]core.Error{verr, berr, serr, merr, ferr, one, many}) {
		walktest.expect_nil(t, err)
	}
	// A document read as a constant spec holds no services, and one read through the handle holds them.
	testing.expect_value(t, core.services_of(doc.as) == nil, bound)
	testing.expect_value(t, len(sdoc.answers), 1)
	testing.expect_value(t, walktest.node_text(t, &sdoc, sdoc.answers[0].node), "2")
	testing.expect_value(t, len(mdoc.answers), 2)
	// The answers come in text order, and the last `b` stands after `c`.
	testing.expect_value(t, walktest.node_text(t, &mdoc, mdoc.answers[0].node), "2")
	testing.expect_value(t, walktest.node_text(t, &mdoc, mdoc.answers[1].node), "3")
	testing.expect_value(t, answer.outcome, core.Presence.Found)
	testing.expect_value(t, seen_one.found, 1)
	testing.expect_value(t, seen_many.found, 2)

	answers, qerr := xml.query(&doc, b, {dups = .All})
	defer delete(answers)
	walktest.expect_nil(t, qerr)
	testing.expect_value(t, len(answers), 2)
	testing.expect_value(t, walktest.node_text(t, &doc, answers[0].node), "1")
	testing.expect_value(t, walktest.node_text(t, &doc, answers[1].node), "3")
}

@(test)
every_entry_point_reads_by_a_constant_spec_and_a_chosen_one :: proc(t: ^testing.T) {
	entry_points(t, .Xml, true)
	chosen := xml.Spec.Xml
	entry_points(t, chosen, false)
}

@(test)
a_repeated_name_is_refused_only_when_asked :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<a><b>1</b><b>2</b></a>`)
	doc, err := xml.build(src, .Xml, {}, .Refuse)
	defer core.destroy(&doc)
	f, bad := walktest.fault_in(err)
	testing.expect(t, bad)
	testing.expect_value(t, f.kind, core.Fault_Kind.Duplicate_Key)
	testing.expect_value(t, f.at, u64(strings.index(string(src), "b>2")))
	path, _ := core.parse_path(".a.b")
	defer core.path_destroy(&path)
	_, serr := xml.scan(src, .Xml, path, {}, {dups = .Refuse})
	_, refused := walktest.fault_in(serr)
	testing.expect(t, refused)
}

// A handle's list reaches XML's edit services.
@(test)
a_handle_edits_a_document :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<a><b>1</b></a>`)
	doc, err := core.build(src, xml.as(.Xml))
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	a, _ := core.member(&doc, core.ROOT, "a")
	walktest.expect_nil(t, write.insert(&list, a, 1, "c", typed.Raw("2")))
	out, _, cerr := compose.commit(&list)
	defer delete(out)
	walktest.expect_nil(t, cerr)
	testing.expect_value(t, string(out), "<a><b>1</b><c>2</c></a>")
}

@(test)
a_handle_keeps_its_options :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`<!DOCTYPE a [<!ENTITY e 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'>]><a><n>12</n><t>&e;&e;&e;&e;</t></a>`)
	doc, err := core.build(src, xml.as(.Xml, {infer = true, max_expansion = 1 << 20}))
	walktest.expect_nil(t, err)
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	n, _ := core.member(&doc, a, "n")
	testing.expect_value(t, core.kind(&doc, n), core.Kind.Number)
	f, bad := walktest.fault_in(core.validate(src, xml.as(.Xml, {max_expansion = 100})))
	testing.expect(t, bad)
	testing.expect_value(t, walktest.rule_code(f), "xml.expansion")
	deep := transmute([]u8)string(`<a><b><c/></b></a>`)
	f, bad = walktest.fault_in(core.validate(deep, xml.as(.Xml, {max_depth = 2})))
	testing.expect(t, bad)
	testing.expect_value(t, f.kind, core.Fault_Kind.Too_Deep)
}
