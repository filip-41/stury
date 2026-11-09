package dsv_tests

import "core:testing"
import core "../../core"
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
