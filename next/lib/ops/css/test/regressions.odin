package css_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:testkit"
import "stury:xml"

@(test)
nil_attribute_reader_does_not_crash :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, `<root><a id="1"/><b/></root>`)
	if !ok {
		return
	}
	sel, err := css.compile("a[id]")
	testing.expect(t, err == nil)
	defer css.destroy(&sel)
	found, serr := css.select(&doc, tape.ROOT, &sel, {})
	testing.expect(t, serr == nil)
	defer css.destroy_found(&found)
	testing.expect_value(t, len(found.matches), 0)
	testing.expect(t, !found.partial)
}

@(test)
of_type_respects_fold_option :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, `<root><DIV id="1"/><div id="2"/><span id="3"/><DIV id="4"/></root>`)
	if !ok {
		return
	}
	fold_opts := css.Options{attribute = xml.attribute, fold = true}
	testing.expect_value(t, described(t, &doc, "div:nth-of-type(2)", tape.ROOT, fold_opts), "div#2")
	testing.expect_value(t, described(t, &doc, "div:first-of-type", tape.ROOT, fold_opts), "DIV#1")
	testing.expect_value(t, described(t, &doc, "div:last-of-type", tape.ROOT, fold_opts), "DIV#4")
}

@(test)
partial_document_sets_found_partial_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, `<root><a id="1"/></root>`)
	if !ok {
		return
	}
	part: tape.Partial
	doc.partial = &part
	sel, err := css.compile("a")
	testing.expect(t, err == nil)
	defer css.destroy(&sel)
	found, serr := css.select(&doc, tape.ROOT, &sel, OPTIONS)
	testing.expect(t, serr == nil)
	defer css.destroy_found(&found)
	testing.expect(t, found.partial)
	testing.expect_value(t, len(found.matches), 0)
}
