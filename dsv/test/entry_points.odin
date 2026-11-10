package dsv_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import dsv ".."
import walktest "../../walktest"

// Every public entry point of the format package returns nil on a valid input.

Entry_Row :: struct {
	a: i64,
	b: i64,
}

take_first :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	return false
}

@(test)
every_entry_point_accepts_valid_input :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n")
	path, perr := core.parse_path(".[0].a")
	walktest.expect_nil(t, perr)
	defer core.path_destroy(&path)
	paths := [?]core.Path{path}

	walktest.expect_nil(t, dsv.validate(src, .Csv))

	doc, berr := dsv.build(src, .Csv)
	walktest.expect_nil(t, berr)
	core.destroy(&doc)

	sdoc, serr := dsv.scan(src, .Csv, path)
	walktest.expect_nil(t, serr)
	core.destroy(&sdoc)
	mdoc, merr := dsv.scan(src, .Csv, paths[:])
	walktest.expect_nil(t, merr)
	core.destroy(&mdoc)

	walktest.expect_nil(t, dsv.each_answer(src, .Csv, path, nil, take_first))
	walktest.expect_nil(t, dsv.each_answer(src, .Csv, paths[:], nil, take_first))

	fdoc, _, ferr := dsv.find(src, .Csv, path)
	walktest.expect_nil(t, ferr)
	core.destroy(&fdoc)

	out, oerr := dsv.set(src, .Csv, path, "7")
	walktest.expect_nil(t, oerr)
	delete(out)

	rows: []Entry_Row
	defer delete(rows)
	walktest.expect_nil(t, dsv.unmarshal(src, .Csv, &rows))
	plan, plerr := dsv.plan_make([]Entry_Row, .Csv)
	walktest.expect_nil(t, plerr)
	defer typed.plan_destroy(&plan)
	again: []Entry_Row
	defer delete(again)
	walktest.expect_nil(t, dsv.unmarshal(src, .Csv, &again, &plan))

	text, merr2 := dsv.marshal(rows, .Csv)
	walktest.expect_nil(t, merr2)
	delete(text)
}

// Each constant form for one spec. A document it makes holds no services, so the document is read through the format
// package's own `query`, `edit_list_init` and `write`.
@(private = "file")
constant_forms :: proc(t: ^testing.T, $S: dsv.Spec, text, edited: string) {
	src := transmute([]u8)text
	path, perr := core.parse_path(".[0].a")
	walktest.expect_nil(t, perr)
	defer core.path_destroy(&path)
	paths := [?]core.Path{path}

	walktest.expect_nil(t, dsv.validate(src, S))
	testing.expect(t, dsv.validate(src, S, {delimiter = '\n'}) != nil)

	doc, berr := dsv.build(src, S)
	walktest.expect_nil(t, berr)
	defer core.destroy(&doc)
	answers, qerr := dsv.query(&doc, path)
	walktest.expect_nil(t, qerr)
	defer delete(answers)
	if testing.expect_value(t, len(answers), 1) {
		list := dsv.edit_list_init(&doc, S)
		defer core.edit_list_destroy(&list)
		walktest.expect_nil(t, core.set(&list, answers[0].node, "7"))
		out, _, cerr := compose.commit(&list)
		defer delete(out)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(out), edited)
	}
	written, _, werr := dsv.write(&doc, S)
	defer delete(written)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(written), text)

	sdoc, serr := dsv.scan(src, S, path)
	walktest.expect_nil(t, serr)
	core.destroy(&sdoc)
	mdoc, merr := dsv.scan(src, S, paths[:])
	walktest.expect_nil(t, merr)
	core.destroy(&mdoc)
	walktest.expect_nil(t, dsv.each_answer(src, S, path, nil, take_first))
	walktest.expect_nil(t, dsv.each_answer(src, S, paths[:], nil, take_first))
	fdoc, found, ferr := dsv.find(src, S, path)
	walktest.expect_nil(t, ferr)
	testing.expect(t, found.outcome == .Found)
	core.destroy(&fdoc)
	out, oerr := dsv.set(src, S, path, "7")
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, string(out), edited)
	delete(out)

	rows: []Entry_Row
	defer delete(rows)
	walktest.expect_nil(t, dsv.unmarshal(src, S, &rows))
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], Entry_Row{1, 2})
	}
	plan, plerr := dsv.plan_make([]Entry_Row, S, reads = dsv.reads(S))
	walktest.expect_nil(t, plerr)
	defer typed.plan_destroy(&plan)
	again, checked, slot: []Entry_Row
	defer delete(again)
	defer delete(checked)
	defer delete(slot)
	walktest.expect_nil(t, dsv.unmarshal(src, S, &again, &plan))
	walktest.expect_nil(t, dsv.check(src, S, &checked, &plan))
	walktest.expect_nil(t, typed.unmarshal_text(src, &slot, []Entry_Row, &plan, {}))
	testing.expect_value(t, len(again), 1)
	testing.expect_value(t, len(checked), 1)
	testing.expect_value(t, len(slot), 1)
}

@(test)
every_constant_form_serves_every_spec :: proc(t: ^testing.T) {
	constant_forms(t, .Csv, "a,b\n1,2\n", "a,b\n7,2\n")
	constant_forms(t, .Tsv, "a\tb\n1\t2\n", "a\tb\n7\t2\n")
	constant_forms(t, .Plain, "a,b\n1,2\n", "a,b\n7,2\n")
}

// `destroy` is one group over each owner the format package exports.
@(test)
destroy_serves_each_owner :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
	walktest.expect_nil(t, err)
	list := dsv.edit_list_init(&doc, .Csv)
	path, perr := dsv.parse_path(".[0].a")
	walktest.expect_nil(t, perr)
	dsv.destroy(&path)
	dsv.destroy(&list)
	dsv.destroy(&doc)
	testing.expect(t, doc.nodes == nil)
}

// The record entry points of a constant spec frame and judge the records of a text, and a reader that gets
// `record_docs` builds them.
record_forms :: proc(t: ^testing.T, $S: dsv.Spec) {
	src := transmute([]u8)string("a,b\n1,2\n3,4\n")
	faults, err := dsv.records_check(src, S)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := dsv.records_open(src, S)
	defer dsv.records_close(&it)
	it.docs = dsv.record_docs(S)
	n := 0
	for rec in dsv.records_next(&it) {
		doc, derr := dsv.records_build(&it, rec)
		walktest.expect_nil(t, derr)
		dsv.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 2)
	wr: dsv.Record_Writer
	testing.expect_value(t, dsv.writer_init(&wr, {}, S), core.Typed_Error_Kind.None)
	dsv.destroy(&wr)
}

@(test)
every_record_form_serves_every_spec :: proc(t: ^testing.T) {
	record_forms(t, .Csv)
	record_forms(t, .Tsv)
}
