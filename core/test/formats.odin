// Tests that hold two formats' packages. They live apart so that no format's own suite imports the other format.
package core_test

import "core:testing"
import core ".."
import dsv "../../dsv"
import json "../../json"

// A commit to JSON refuses a delimited document before it splices, since a table is another format family.
@(test)
json_commit_refuses_table :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a\n1\n")
	doc, err := dsv.build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, cerr := core.commit(&list, json.as(.Json))
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.Bad_Spec)
	testing.expect(t, out == nil)
}

// `format` reads and writes back in the handle's format, a table as a table and a text as JSON.
@(test)
format_serves_every_format :: proc(t: ^testing.T) {
	table, terr := core.format(transmute([]u8)string("a,b\n1,\"x\"\n"), dsv.as(.Csv))
	defer delete(table)
	testing.expect_value(t, terr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(table), "a,b\n1,x\n")
	text, jerr := core.format(transmute([]u8)string(`{a: [1,],}`), json.as(.Json5), core.PRETTY)
	defer delete(text)
	testing.expect_value(t, jerr.kind, core.Typed_Error_Kind.None)
	_, none := core.format(transmute([]u8)string(`1`), core.As{})
	testing.expect_value(t, none.kind, core.Typed_Error_Kind.Unsupported)
}
