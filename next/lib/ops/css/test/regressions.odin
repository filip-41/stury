package css_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
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

@(test)
cut_doc_is_partial_and_borrowed_query_doc_is_complete :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, ok := document(t, `<root><DIV id="1"/><div id="2"/><DIV id="3"/></root>`)
	if !ok {
		return
	}
	// A `.Cut` document with `doc.partial == nil` must report `found.partial = true`.
	cut_doc := doc
	cut_doc.flags += {.Cut}
	sel, err := css.compile("div")
	testing.expect(t, err == nil)
	defer css.destroy(&sel)
	cut_found, cerr := css.select(&cut_doc, tape.ROOT, &sel, {attribute = xml.attribute, fold = true})
	testing.expect(t, cerr == nil)
	defer css.destroy_found(&cut_found)
	testing.expect(t, cut_found.partial)

	// A complete `build.query` result (`.Borrowed` with `doc.partial != nil` and no `CONTAINER_PARTIAL`) selects normally.
	paths := [][]tape.Step{{tape.Name("root")}}
	dm, derr := tape.demand_of(paths)
	testing.expect(t, derr == nil)
	defer tape.destroy(&dm)
	qdoc, qerr := build.query({&doc, nil}, &dm)
	testing.expect(t, qerr == nil)
	defer tape.destroy(&qdoc)
	qfound, qserr := css.select(&qdoc, tape.ROOT, &sel, {attribute = xml.attribute, fold = true})
	testing.expect(t, qserr == nil)
	defer css.destroy_found(&qfound)
	testing.expect(t, !qfound.partial)
	testing.expect_value(t, len(qfound.matches), 3)
	// Folded group indices must treat `<DIV>` and `<div>` as one sibling group (0, 1, 2).
	for m, i in qfound.matches {
		steps := qfound.steps[m.lo:][:m.n]
		testing.expect_value(t, steps[len(steps) - 1].index, i32(i))
	}
}
