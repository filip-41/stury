package json_tests

import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import json ".."
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
	src := transmute([]u8)string(`[{"a":1,"b":2}]`)
	path, perr := core.parse_path(".[0].a")
	walktest.expect_nil(t, perr)
	defer core.path_destroy(&path)
	paths := [?]core.Path{path}

	walktest.expect_nil(t, json.validate(src, .Json))

	doc, berr := json.build(src, .Json)
	walktest.expect_nil(t, berr)
	core.destroy(&doc)

	sdoc, serr := json.scan(src, .Json, path)
	walktest.expect_nil(t, serr)
	core.destroy(&sdoc)
	mdoc, merr := json.scan(src, .Json, paths[:])
	walktest.expect_nil(t, merr)
	core.destroy(&mdoc)

	walktest.expect_nil(t, json.each_answer(src, .Json, path, nil, take_first))
	walktest.expect_nil(t, json.each_answer(src, .Json, paths[:], nil, take_first))

	fdoc, _, ferr := json.find(src, .Json, path)
	walktest.expect_nil(t, ferr)
	core.destroy(&fdoc)

	out, oerr := json.set(src, .Json, path, "7")
	walktest.expect_nil(t, oerr)
	delete(out)

	rows: []Entry_Row
	defer delete(rows)
	walktest.expect_nil(t, json.unmarshal(src, .Json, &rows))
	plan, plerr := json.plan_make([]Entry_Row, .Json)
	walktest.expect_nil(t, plerr)
	defer typed.plan_destroy(&plan)
	again: []Entry_Row
	defer delete(again)
	walktest.expect_nil(t, json.unmarshal(src, .Json, &again, &plan))

	text, merr2 := json.marshal(rows, .Json)
	walktest.expect_nil(t, merr2)
	delete(text)
}

// Each constant form for one spec. A document it makes holds no services, so the document is read through the format
// package's own `query`, `edit_list_init` and `write`.
@(private = "file")
constant_forms :: proc(t: ^testing.T, $S: json.Spec) {
	src := transmute([]u8)string(`[{"a":1,"b":2}]`)
	path, perr := core.parse_path(".[0].a")
	walktest.expect_nil(t, perr)
	defer core.path_destroy(&path)
	paths := [?]core.Path{path}

	walktest.expect_nil(t, json.validate(src, S))
	testing.expect(t, json.validate(transmute([]u8)string(`[1,`), S) != nil)

	doc, berr := json.build(src, S)
	walktest.expect_nil(t, berr)
	defer core.destroy(&doc)
	answers, qerr := json.query(&doc, path)
	walktest.expect_nil(t, qerr)
	defer delete(answers)
	if testing.expect_value(t, len(answers), 1) {
		list := json.edit_list_init(&doc, S)
		defer core.edit_list_destroy(&list)
		walktest.expect_nil(t, core.set(&list, answers[0].node, "7"))
		edited, _, cerr := compose.commit(&list)
		defer delete(edited)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(edited), `[{"a":7,"b":2}]`)
	}
	written, _, werr := json.write(&doc, S)
	defer delete(written)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(written), string(src))

	sdoc, serr := json.scan(src, S, path)
	walktest.expect_nil(t, serr)
	core.destroy(&sdoc)
	mdoc, merr := json.scan(src, S, paths[:])
	walktest.expect_nil(t, merr)
	core.destroy(&mdoc)
	walktest.expect_nil(t, json.each_answer(src, S, path, nil, take_first))
	walktest.expect_nil(t, json.each_answer(src, S, paths[:], nil, take_first))
	fdoc, found, ferr := json.find(src, S, path)
	walktest.expect_nil(t, ferr)
	testing.expect(t, found.outcome == .Found)
	core.destroy(&fdoc)
	out, oerr := json.set(src, S, path, "7")
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, string(out), `[{"a":7,"b":2}]`)
	delete(out)

	rows: []Entry_Row
	defer delete(rows)
	walktest.expect_nil(t, json.unmarshal(src, S, &rows))
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], Entry_Row{1, 2})
	}
	plan, plerr := json.plan_make([]Entry_Row, S, reads = json.reads(S))
	walktest.expect_nil(t, plerr)
	defer typed.plan_destroy(&plan)
	again, checked, slot: []Entry_Row
	defer delete(again)
	defer delete(checked)
	defer delete(slot)
	walktest.expect_nil(t, json.unmarshal(src, S, &again, &plan))
	walktest.expect_nil(t, json.check(src, S, &checked, &plan))
	walktest.expect_nil(t, typed.unmarshal_text(src, &slot, []Entry_Row, &plan, {}))
	testing.expect_value(t, len(again), 1)
	testing.expect_value(t, len(checked), 1)
	testing.expect_value(t, len(slot), 1)
}

@(test)
every_constant_form_serves_every_spec :: proc(t: ^testing.T) {
	constant_forms(t, .Json)
	constant_forms(t, .Jsonc)
	constant_forms(t, .Json5)
}

// `destroy` is one group over each owner the format package exports.
@(test)
destroy_serves_each_owner :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string(`{"a":1}`), .Json)
	walktest.expect_nil(t, err)
	list := json.edit_list_init(&doc, .Json)
	path, perr := json.parse_path(".a")
	walktest.expect_nil(t, perr)
	json.destroy(&path)
	json.destroy(&list)
	json.destroy(&doc)
	testing.expect(t, doc.nodes == nil)
}

// The record entry points of a constant spec frame, judge and read the records of a text, and a reader that gets
// `record_docs` builds them.
record_forms :: proc(t: ^testing.T, $S: json.Spec) {
	src := transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n")
	faults, err := json.records_check(src, S)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := json.records_open(src, S)
	defer json.records_close(&it)
	n := 0
	for rec in json.records_next(&it) {
		testing.expect_value(t, string(rec.text), "{\"a\":1}" if n == 0 else "{\"a\":2}")
		n += 1
	}
	testing.expect_value(t, n, 2)
	it2 := json.records_open(src, S)
	defer json.records_close(&it2)
	it2.docs = json.record_docs(S)
	rec, ok := json.records_next(&it2)
	testing.expect(t, ok)
	doc, derr := json.records_build(&it2, rec)
	walktest.expect_nil(t, derr)
	json.destroy(&doc)
	count: int
	task := proc(n: ^int, piece: ^json.Record_Reader, _: int) -> bool {
		for _ in json.records_next(piece) {
			n^ += 1
		}
		return true
	}
	walktest.expect_nil(t, json.records_each(src, S, .Lines, task, &count))
	testing.expect_value(t, count, 2)
	wr: json.Record_Writer
	testing.expect_value(t, json.writer_init(&wr, {}, S), core.Typed_Error_Kind.None)
	json.destroy(&wr)
}

@(test)
every_record_form_serves_every_spec :: proc(t: ^testing.T) {
	record_forms(t, .Json)
	record_forms(t, .Jsonc)
	record_forms(t, .Json5)
}
