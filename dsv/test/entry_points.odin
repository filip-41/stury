package dsv_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import dsv ".."
import testkit "../../testkit"

// The plan and marshal entry points accept a valid input. The other entry points run in `constant_forms`.

Entry_Row :: struct {
	a: i64,
	b: i64,
}

@(test)
plan_and_marshal_accept_valid_input :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n")
	rows: []Entry_Row
	defer delete(rows)
	testkit.expect_nil(t, dsv.unmarshal(src, .Csv, &rows))
	plan, plerr := dsv.plan_make([]Entry_Row, .Csv)
	testkit.expect_nil(t, plerr)
	defer typed.plan_destroy(&plan)
	again: []Entry_Row
	defer delete(again)
	testkit.expect_nil(t, dsv.unmarshal(src, .Csv, &again, &plan))

	text, merr := dsv.marshal(rows, .Csv)
	testkit.expect_nil(t, merr)
	delete(text)
}

// Each constant form for one spec. A document it makes holds no services, so the document is read through the format
// package's own `query`, `edit_list_init` and `write`.
@(private = "file")
constant_forms :: proc(t: ^testing.T, $S: dsv.Spec, text, edited: string) {
	src := transmute([]u8)text
	path, perr := core.parse_path(".[0].a")
	testkit.expect_nil(t, perr)
	defer core.path_destroy(&path)
	paths := [?]core.Path{path}

	testkit.expect_nil(t, dsv.validate(src, S))
	testing.expect(t, dsv.validate(src, S, {delimiter = '\n'}) != nil)

	doc, berr := dsv.build(src, S)
	testkit.expect_nil(t, berr)
	defer core.destroy(&doc)
	answers, qerr := dsv.query(&doc, path)
	testkit.expect_nil(t, qerr)
	defer delete(answers)
	if testing.expect_value(t, len(answers), 1) {
		list := dsv.edit_list_init(&doc, S)
		defer core.edit_list_destroy(&list)
		testkit.expect_nil(t, write.set_node(&list, answers[0].node, typed.Raw("7")))
		out, _, cerr := compose.commit(&list)
		defer delete(out)
		testkit.expect_nil(t, cerr)
		testing.expect_value(t, string(out), edited)
	}
	written, _, werr := dsv.write(&doc, S)
	defer delete(written)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, string(written), text)

	sdoc, serr := dsv.scan(src, S, path)
	testkit.expect_nil(t, serr)
	core.destroy(&sdoc)
	mdoc, merr := dsv.scan(src, S, paths[:])
	testkit.expect_nil(t, merr)
	core.destroy(&mdoc)
	testkit.expect_nil(t, dsv.each_answer(src, S, path, nil, testkit.take_first))
	testkit.expect_nil(t, dsv.each_answer(src, S, paths[:], nil, testkit.take_first))
	fdoc, found, ferr := dsv.find(src, S, path)
	testkit.expect_nil(t, ferr)
	testing.expect(t, found.outcome == .Found)
	core.destroy(&fdoc)
	out, oerr := dsv.set(src, S, path, typed.Raw("7"))
	testkit.expect_nil(t, oerr)
	testing.expect_value(t, string(out), edited)
	delete(out)

	rows: []Entry_Row
	defer delete(rows)
	testkit.expect_nil(t, dsv.unmarshal(src, S, &rows))
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], Entry_Row{1, 2})
	}
	plan, plerr := dsv.plan_make([]Entry_Row, S, reads = dsv.reads(S))
	testkit.expect_nil(t, plerr)
	defer typed.plan_destroy(&plan)
	again, checked, slot: []Entry_Row
	defer delete(again)
	defer delete(checked)
	defer delete(slot)
	testkit.expect_nil(t, dsv.unmarshal(src, S, &again, &plan))
	testkit.expect_nil(t, dsv.check(src, S, &checked, &plan))
	testkit.expect_nil(t, typed.unmarshal_text(src, &slot, []Entry_Row, &plan, {}))
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
	testkit.expect_nil(t, err)
	list := dsv.edit_list_init(&doc, .Csv)
	path, perr := dsv.parse_path(".[0].a")
	testkit.expect_nil(t, perr)
	dsv.destroy(&path)
	dsv.destroy(&list)
	dsv.destroy(&doc)
	testing.expect(t, doc.nodes == nil)
}

// The record entry points of a constant spec frame and judge the records of a text, and a reader that gets
// `record_docs` builds them.
record_forms :: proc(t: ^testing.T, $S: dsv.Spec) {
	src := transmute([]u8)string("a,b\n1,2\n3,4\n")
	faults, err := dsv.records_validate(src, S)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := dsv.records_open(src, S)
	defer dsv.records_close(&it)
	it.docs = dsv.record_docs(S)
	n := 0
	for rec in dsv.records_next(&it) {
		doc, derr := dsv.records_build(&it, rec)
		testkit.expect_nil(t, derr)
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

// A nil `any` is a null, which CSV cannot write at the top, so it is refused as any null is.
@(test)
a_nil_any_is_refused_as_a_null :: proc(t: ^testing.T) {
	nothing: any
	text, err := dsv.marshal(nothing, allocator = context.temp_allocator)
	testing.expect(t, text == nil)
	testkit.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
}
