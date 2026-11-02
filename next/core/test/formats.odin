// Tests that hold two formats' packages. They live apart so that no format's own suite imports the other format.
package core_test

import "core:testing"
import core ".."
import dsv "../../dsv"
import json "../../json"

// `json.commit` refuses a delimited document before it splices, since a table is another format family.
@(test)
json_commit_refuses_table :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a\n1\n")
	doc, err := dsv.build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, cerr := json.commit(&list, .Json)
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.Bad_Spec)
	testing.expect(t, out == nil)
}
