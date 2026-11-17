// The format package's entry points, and the calls in `core` with a handle.
package xml_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import xml ".."
import walktest "../../walktest"

@(private = "file")
entry_points :: proc(src: []u8, c: core.Path, paths: []core.Path, r: ^walktest.Entry_Reads) {
	r.errs[0] = xml.validate(src, .Xml)
	r.doc, r.errs[1] = xml.build(src, .Xml)
	r.sdoc, r.errs[2] = xml.scan(src, .Xml, c)
	r.mdoc, r.errs[3] = xml.scan(src, .Xml, paths)
	r.fdoc, r.answer, r.errs[4] = xml.find(src, .Xml, c)
	r.errs[5] = xml.each_answer(src, .Xml, c, &r.one, walktest.count_found)
	r.errs[6] = xml.each_answer(src, .Xml, paths, &r.many, walktest.count_found)
}

@(test)
every_entry_point_reads_by_a_constant_spec_and_a_chosen_one :: proc(t: ^testing.T) {
	chosen := xml.Spec.Xml
	walktest.expect_entry_points(t, xml.as(chosen), entry_points)
}

@(test)
a_repeated_name_is_refused_only_when_asked :: proc(t: ^testing.T) {
	walktest.expect_repeated_name_refused_only_when_asked(t, proc(src: []u8, path: core.Path) -> (built, scanned, answered: core.Error) {
		doc, err := xml.build(src, .Xml, {}, .Refuse)
		defer core.destroy(&doc)
		_, serr := xml.scan(src, .Xml, path, {}, {dups = .Refuse})
		return err, serr, xml.each_answer(src, .Xml, path, nil, proc(state: rawptr, a: core.Token_Answer) -> bool {return true})
	})
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
