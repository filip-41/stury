package json_tests

import "core:testing"
import core "../../core"
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
