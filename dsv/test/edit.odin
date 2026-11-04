package dsv_tests

import "core:mem"
import "core:testing"
import core "../../core"
import dsv ".."
import walktest "../../walktest"

// Edits over a delimited text: a cell's text, a record's line, and the table's columns, which a commit decides from the
// whole list.

@(private = "file")
Dsv_Read :: struct {
	spec: dsv.Spec,
	opts: dsv.Options,
}

@(private = "file")
read_dsv :: proc(src: []u8, spec: any) -> (core.Document, core.Document_Error) {
	r := spec.(Dsv_Read)
	switch r.spec {
	case .Csv:
		return dsv.build(src, .Csv, r.opts)
	case .Tsv:
		return dsv.build(src, .Tsv, r.opts)
	case .Plain:
		return dsv.build(src, .Plain, r.opts)
	}
	return {}, {kind = .Bad_Value}
}

// Commits `list`, expects `want`, and rebuilds it as `S` under `opts`.
expect_commit :: proc(t: ^testing.T, list: ^core.Edit_List, want: string, $S: dsv.Spec, opts := dsv.Options{}) -> bool {
	return walktest.expect_commit(t, list, want, read_dsv, Dsv_Read{S, opts})
}

check :: proc(t: ^testing.T, src, want: string, $S: dsv.Spec, opts: dsv.Options, edit: proc(list: ^core.Edit_List) -> core.Document_Error) -> bool {
	return walktest.check(t, src, want, read_dsv, Dsv_Read{S, opts}, edit)
}

@(private = "file")
set_cell :: proc(list: ^core.Edit_List, node: core.Node_Index, text: string) -> core.Document_Error {
	return core.set(list, node, text)
}

// A cell becomes its text, quoted or plain as written, and every other byte stays.
@(test)
edit_set_cell :: proc(t: ^testing.T) {
	check(t, "a,b\n1,2\n", "a,b\n9,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "9")
	})
	check(t, "a,b\n\"x,y\",2\n", "a,b\nz,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "z")
	})
	check(t, "a,b\nx,2\n", "a,b\n\"p,q\",2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "\"p,q\"")
	})
	check(t, "a,b\nx,2\n", "a,b\n,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "")
	})
	// A header cell is a cell too, and its text names the column.
	check(t, "a,b\n1,2\n", "z,b\n1,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 2, "z")
	})
	check(t, "a\tb\n1\t2\n", "a\tb\n1\t9\n", .Tsv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 6, "9")
	})
	check(t, "a\tb\nx\t2\n", "a\tb\nx\\ty\t2\n", .Tsv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "x\\ty")
	})
	check(t, "1,2\n3,4", "5,2\n3,4", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 2, "5")
	})
}

// A record inserted first, in the middle and last, and into an empty text. The table's width becomes the record's.
@(test)
edit_insert_record :: proc(t: ^testing.T) {
	check(t, "a,b\n1,2\n", "a,b\n7,8\n1,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("7,8"))
	})
	check(t, "a,b\n1,2\n3,4\n", "a,b\n1,2\n7,8\n3,4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("7,8"))
	})
	check(t, "a,b\n1,2\n", "a,b\n1,2\n7,8\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("7,8"))
	})
	// A text with no final line end has one written before the record, and the record then ends the text.
	check(t, "a,b\n1,2", "a,b\n1,2\n7,8", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("7,8"))
	})
	check(t, "", "7,8\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("7,8"))
	})
	// A headed text with no data record puts the first record after the header.
	check(t, "a,b\n", "a,b\n7,8\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("7,8"))
	})
	check(t, "a,b", "a,b\n7,8", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("7,8"))
	})
	// The text keeps the line end the table uses.
	check(t, "a,b\r\n1,2\r\n", "a,b\r\n1,2\r\n7,8\r\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("7,8"))
	})
	check(t, "1,2\n", "3,4\n1,2\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("3,4"))
	})
	// A quoted cell keeps its delimiters and line ends inside.
	check(t, "a,b\n1,2\n", "a,b\n1,2\n\"x,y\",\"m\nn\"\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("\"x,y\",\"m\nn\""))
	})
	check(t, "a\tb\n1\t2\n", "a\tb\n1\t2\n3\t4\n", .Tsv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("3\t4"))
	})
}

// A cell inserted into a record: it fills a cell a short record lacks, and otherwise adds a column.
@(test)
edit_insert_cell :: proc(t: ^testing.T) {
	// A table of one record follows the record's width.
	check(t, "1,2\n", "1,2,3\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 2, string("3"))
	})
	check(t, "1,2", "1,2,3", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 2, string("3"))
	})
	check(t, "1,2\n", "1,0,2\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 1, string("0"))
	})
	// A header with no data record is the whole table, so a column may join it.
	check(t, "a,b\n", "a,b,c\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 2, string("c"))
	})
	// A headerless record narrower than the first record is ragged, and an edit may add a cell to it while it stays under the width.
	check(t, "1,2\n3\n", "1,2\n3,4\n", .Csv, {no_header = true, tolerate = {.Ragged}}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 1, string("4"))
	})
	// A headed record is a Map, so an array-element insert is refused as Wrong_Container.
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n3,4\n"), .Csv)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.insert(&list, 4, 2, string("9")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, 4, 0, string("x,y")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, len(list.edits), 0)

	// A headerless record is an Array, and a recorded cell is one cell at a position of the record.
	nh_doc, _ := dsv.build(transmute([]u8)string("1,2\n3,4\n"), .Csv, {no_header = true})
	defer core.destroy(&nh_doc)
	nh_list := core.edit_list_init(&nh_doc)
	defer core.edit_list_destroy(&nh_list)
	testing.expect_value(t, core.insert(&nh_list, 1, 0, string("x,y")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.insert(&nh_list, 1, 9, string("7")).kind, core.Document_Error_Kind.Bad_Position)
	testing.expect_value(t, len(nh_list.edits), 0)
}

// Two cells of one record inserted at one byte keep the order they were recorded in: the cell before the empty last
// cell, then the cell appended after it.
@(test)
edit_insert_cells_order :: proc(t: ^testing.T) {
	check(t, "a,", "a,x,,y", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 1, 1, string("x")); e.kind != .None {
			return e
		}
		return core.insert(list, 1, 2, string("y"))
	})
}

// Removing a record removes its line end, first, middle or last. The header row is no record to remove.
@(test)
edit_remove_record :: proc(t: ^testing.T) {
	check(t, "a,b\n1,2\n3,4\n", "a,b\n3,4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	check(t, "a,b\n1,2\n3,4\n", "a,b\n1,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 7)
	})
	check(t, "a,b\n1,2", "a,b\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	check(t, "1,2\n", "", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 1)
	})
	check(t, "a,b\r\n1,2\r\n", "a,b\r\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	check(t, "a\tb\n1\t2\n", "a\tb\n", .Tsv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	// Two adjacent records removed together remove the line end between them once.
	{
		doc, _ := dsv.build(transmute([]u8)string("a\n1\n2\n3\n"), .Csv, {no_header = true})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 3).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.remove(&list, 5).kind, core.Document_Error_Kind.None)
		testing.expect(t, expect_commit(t, &list, "a\n3\n", .Csv, {no_header = true}))
	}
	// The header row is the table's keys, not a record.
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 0).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, len(list.edits), 0)
}

// Removing a cell removes one delimiter with it, and only where the table still reads. A table of one record follows
// its record's width, and every other record keeps its width.
@(test)
edit_remove_cell :: proc(t: ^testing.T) {
	check(t, "1,2\n", "2\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 2)
	})
	check(t, "1,2\n", "1\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 3)
	})
	check(t, "1,2,3\n", "1,3\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 3)
	})
	// A header cell is a column's name, and removing it drops the column.
	check(t, "a,b\n", "a\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 3)
	})
	// A cell removed from only some records is emptied, and its column stays.
	check(t, "a,b\n1,2\n3,4\n", "a,b\n,2\n3,4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 5)
	})
	// A record cannot become empty.
	single, _ := dsv.build(transmute([]u8)string("1,2\n"), .Csv, {no_header = true})
	defer core.destroy(&single)
	list := core.edit_list_init(&single)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 3).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
	_, _, e := core.commit(&list)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Width)
}

@(private = "file")
Column_Edit :: proc(list: ^core.Edit_List) -> core.Document_Error

// Expects `edit` to record and the commit to refuse the list with `want`.
@(private = "file")
refused :: proc(t: ^testing.T, src: string, opts: dsv.Options, want: core.Document_Error_Kind, edit: Column_Edit) {
	doc, err := dsv.build(transmute([]u8)src, .Csv, opts)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, edit(&list).kind, core.Document_Error_Kind.None)
	out, _, e := core.commit(&list)
	delete(out)
	testing.expectf(t, e.kind == want, "%q: commit %v, want %v", src, e.kind, want)
}

// Removes each node in turn.
@(private = "file")
remove_all :: proc(list: ^core.Edit_List, nodes: ..core.Node_Index) -> core.Document_Error {
	for n in nodes {
		if e := core.remove(list, n); e.kind != .None {
			return e
		}
	}
	return {}
}

// A wide record's cells past the header's last are cells like any other, and its positional column drops with them. A
// header named by position has no cell to set, and a column added or dropped before the positional ones would rename
// them, so both are refused.
@(test)
edit_wide_record :: proc(t: ^testing.T) {
	ragged := dsv.Options{tolerate = {.Ragged}}
	check(t, "a,b\n1,2,3\n4,5\n", "a,b\n1,2,9\n4,5\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set(list, 8, "9")
	})
	check(t, "a,b\n1,2,3\n4,5\n", "a,b\n1,2\n4,5\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 8)
	})
	check(t, "a,b\n1,2,3\n4,5\n", "a,b\n1,2,3\n4,5,z\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set_member(list, 9, "3", "z")
	})
	refused(t, "a,b\n1,2,3\n4,5\n", ragged, .Bad_Index, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set(list, 4, "c")
	})
	refused(t, "a,b\n1,2,3\n4,5\n", ragged, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 2)
	})
	refused(t, "a,b\n1,2,3\n4,5\n", ragged, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set_member(list, 9, "c", "z")
	})
}

// A cell removed from every record that holds it drops its column with the header cell. A short record is skipped.
@(test)
edit_drop_column :: proc(t: ^testing.T) {
	check(t, "a,b,c\n1,2,3\n4,5,6\n", "b,c\n2,3\n5,6\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 6, 10)
	})
	check(t, "a,b,c\n1,2,3\n4,5,6\n", "a,c\n1,3\n4,6\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 7, 11)
	})
	check(t, "a,b,c\n1,2,3\n4,5,6\n", "a,b\n1,2\n4,5\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 8, 12)
	})
	// The header cell alone names the same column.
	check(t, "a,b,c\n1,2,3\n4,5,6\n", "a,c\n1,3\n4,6\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 3)
	})
	check(t, "a,b\r\n1,2\r\n3,4\r\n", "a\r\n1\r\n3\r\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 6, 9)
	})
	check(t, "a,\"b,c\",d\n1,\"2\n3\",4\n", "\"b,c\",d\n\"2\n3\",4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 6)
	})
	// A headerless text has no names, and a column is every record's cell at one position.
	check(t, "1,2\n3,4\n", "1\n3\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 3, 6)
	})
	ragged := dsv.Options{tolerate = {.Ragged}}
	check(t, "a,b,c\n1\n2,3\n4,5,6\n", "a,c\n1\n2\n4,6\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 9, 12)
	})
	check(t, "a,b,c\n1\n2,3\n4,5,6\n", "a,b\n1\n2,3\n4,5\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 13)
	})
	// A removed record does not hold the column.
	check(t, "a,b\n1,2\n3,4\n", "a\n1\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 7, 6)
	})
	// The refusals: no column left, and a line that would stop reading as the record it was.
	refused(t, "a\n1\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	refused(t, "a,b\n1,2\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 2, 3)
	})
	refused(t, "a\n1\n2\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	refused(t, "a,b\n1,#2\n", {comment = '#'}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 2)
	})
	refused(t, "a,b,c\n1,#2,3\n", {comment = '#'}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 2)
	})
	refused(t, "a,\xEF\xBB\xBFb\n1,2\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 2)
	})
	// A quoted cell starts with its quote, so it may become the first.
	check(t, "a,b\n1,\"#2\"\n", "b\n\"#2\"\n", .Csv, {comment = '#'}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 2)
	})
	// One cell removed twice is a conflict, and so is a set of a cell the list drops.
	refused(t, "a,b\n1,2\n", {}, .Conflicting_Edits, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 5, 5)
	})
	refused(t, "a,b\n1,2\n", {}, .Conflicting_Edits, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.remove(list, 2); e.kind != .None {
			return e
		}
		return core.set(list, 5, string("9"))
	})
}

// An insert of a name the header lacks adds one column, however many records name it, and the others get an empty cell.
@(test)
edit_add_column :: proc(t: ^testing.T) {
	check(t, "a,b\n1,2\n3,4\n", "a,b,c\n1,2,9\n3,4,\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 2, string("c"), string("9"))
	})
	check(t, "a,b\n1,2\n3,4\n", "a,b,c\n1,2,8\n3,4,9\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 4, 2, string("c"), string("8")); e.kind != .None {
			return e
		}
		return core.insert(list, 7, 2, string("c"), string("9"))
	})
	check(t, "a,b\n1,2\n", "a,b,c,d\n1,2,8,9\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 4, 2, string("c"), string("8")); e.kind != .None {
			return e
		}
		return core.insert(list, 4, 2, string("d"), string("9"))
	})
	// A position inside the record places the column, and every record naming it must agree.
	check(t, "a,b\n1,2\n3,4\n", "a,c,b\n1,9,2\n3,,4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 1, string("c"), string("9"))
	})
	refused(t, "a,b\n1,2\n3,4\n", {}, .Bad_Position, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 4, 1, string("c"), string("8")); e.kind != .None {
			return e
		}
		return core.insert(list, 7, 0, string("c"), string("9"))
	})
	// A name is spelled as a cell of the text, and a header cell inserted by name is the same column.
	check(t, "a\n1\n", "a,\"x,\"\"y\"\n1,9\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 3, 1, string("x,\"y"), string("9"))
	})
	check(t, "a\tb\n1\t2\n", "a\tb\tx\\ty\n1\t2\t9\n", .Tsv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 2, string("x\ty"), string("9"))
	})
	check(t, "a,b\n1,2\n3,4\n", "a,b,c\n1,2,9\n3,4,\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 1, 2, string("c")); e.kind != .None {
			return e
		}
		return core.insert(list, 4, 2, string("c"), string("9"))
	})
	// A header cell inserted alone adds an empty column.
	check(t, "a,b\n1,2\n3,4\n", "c,a,b\n,1,2\n,3,4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 0, string("c"))
	})
	// Plain cannot spell a name holding its delimiter.
	{
		doc, _ := dsv.build(transmute([]u8)string("a|b\n1|2\n"), .Plain, dsv.Options{delimiter = '|'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.insert(&list, 4, 2, string("x|y"), string("9")).kind, core.Document_Error_Kind.None)
		_, _, e := core.commit(&list)
		testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Value)
	}
	// A record that holds the name already refuses it.
	refused(t, "a,b\n1,2\n", {}, .Duplicate_Key, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 2, string("b"), string("9"))
	})
	// A headerless record's position is the column, and the records at one position share it.
	check(t, "1,2\n3,4\n", "1,2,9\n3,4,\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 2, string("9"))
	})
	check(t, "1,2\n3,4\n", "1,2,8\n3,4,9\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 1, 2, string("8")); e.kind != .None {
			return e
		}
		return core.insert(list, 4, 2, string("9"))
	})
	check(t, "1,2\n3,4\n", "8,1,2\n,3,4\n", .Csv, {no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 0, string("8"))
	})
	// A column goes while another comes, and an inserted record is judged against what the table becomes.
	check(t, "a,b\n1,2\n", "a,c\n1,9\n3,4\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.remove(list, 3); e.kind != .None {
			return e
		}
		if e := core.insert(list, 4, 2, string("c"), string("9")); e.kind != .None {
			return e
		}
		return core.insert(list, core.ROOT, 1, string("3,4"))
	})
	refused(t, "a,b\n1,2\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("7"))
	})
	refused(t, "a,b\n1,2\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.remove(list, 3); e.kind != .None {
			return e
		}
		return core.insert(list, core.ROOT, 0, string("7,8"))
	})
	refused(t, "", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, core.ROOT, 0, string("1,2")); e.kind != .None {
			return e
		}
		return core.insert(list, core.ROOT, 0, string("3"))
	})
}

// A short record fills a column it lacks, padding the ones before it, and stays short when nothing is written past it.
@(test)
edit_fill_short_record :: proc(t: ^testing.T) {
	ragged := dsv.Options{tolerate = {.Ragged}}
	check(t, "a,b,c\n1\n", "a,b,c\n1,,9\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 5, 1, string("c"), string("9"))
	})
	check(t, "a,b\n1\n2,3\n", "a,b,c\n1\n2,3,\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 2, string("c"))
	})
	check(t, "a,b\n1\n2,3\n", "a,b,c\n1,,9\n2,3,\n", .Csv, ragged, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 1, string("c"), string("9"))
	})
	check(t, "1,2\n3\n", "1,2\n3,4\n", .Csv, {no_header = true, tolerate = {.Ragged}}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 4, 1, string("4"))
	})
	refused(t, "a,b\n1\n", ragged, .Conflicting_Edits, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 4, 1, string("b"), string("8")); e.kind != .None {
			return e
		}
		return core.insert(list, 4, 1, string("b"), string("9"))
	})
}

// A set to the empty text changes no column, so only a line left as one empty cell is refused.
@(test)
edit_set_empty :: proc(t: ^testing.T) {
	check(t, "a,b\n1,2\n", "a,b\n,2\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set(list, 5, string(""))
	})
	refused(t, "a\n1\n2\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set(list, 4, string(""))
	})
	refused(t, "a\n1\n", {}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set(list, 2, string(""))
	})
	refused(t, "1,2\n3\n", {no_header = true, tolerate = {.Ragged}}, .Bad_Width, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.set(list, 5, string(""))
	})
}

// A column edit judges the lines it changes, and a line it leaves alone may hold what no edit could write.
@(test)
edit_column_keeps_other_lines :: proc(t: ^testing.T) {
	check(t, "a,b\n\"\"\n1,2\n3,4\n", "a\n\"\"\n1\n3\n", .Csv, {tolerate = {.Ragged}}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return remove_all(list, 8, 11)
	})
}

// The refused edits, each with the kind that names what is wrong.
@(test)
edit_errors :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 0, string("x")).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.set(&list, 4, string("x")).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.set(&list, 99, string("x")).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.set(&list, 5, string("x,y")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.set(&list, 5, string("x\ny")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.insert(&list, 4, 0, string("x,y")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, core.ROOT, 3, string("7,8")).kind, core.Document_Error_Kind.Bad_Position)
	testing.expect_value(t, core.insert(&list, 4, 9, string("7")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, 5, 0, string(`k`), string("v")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.remove(&list, 0).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, core.remove(&list, 99).kind, core.Document_Error_Kind.Bad_Index)
	testing.expect_value(t, len(list.edits), 0)

	nh_doc, _ := dsv.build(transmute([]u8)string("1,2\n3,4\n"), .Csv, {no_header = true})
	defer core.destroy(&nh_doc)
	nh_list := core.edit_list_init(&nh_doc)
	defer core.edit_list_destroy(&nh_list)
	testing.expect_value(t, core.insert(&nh_list, 1, 0, string("x,y")).kind, core.Document_Error_Kind.Bad_Value)
	testing.expect_value(t, core.insert(&nh_list, 1, 9, string("7")).kind, core.Document_Error_Kind.Bad_Position)

	// An empty record text reads as no record, so inserting it is refused.
	empty := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&empty)
	testing.expect_value(t, core.insert(&empty, core.ROOT, 0, string("")).kind, core.Document_Error_Kind.Bad_Value)
}

// Setting a record's only cell to nothing would leave a line that reads as no record, so the commit refuses it.
@(test)
edit_empty_record :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("1,2\n"), .Csv, {no_header = true})
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.set(&list, 2, string("")).kind, core.Document_Error_Kind.None)
	out, _, e := core.commit(&list)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(out), ",2\n")
	delete(out)

	single, _ := dsv.build(transmute([]u8)string("1\n"), .Csv, {no_header = true})
	defer core.destroy(&single)
	one := core.edit_list_init(&single)
	defer core.edit_list_destroy(&one)
	testing.expect_value(t, core.set(&one, 2, string("")).kind, core.Document_Error_Kind.None)
	out, _, e = core.commit(&one)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Width)
}

@(test)
edit_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	doc, err := dsv.build(transmute([]u8)string("a,b\n1,2\n3,4\n"), .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	list := core.edit_list_init(&doc, allocator = alloc)
	testing.expect_value(t, core.set(&list, 5, string("9")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.insert(&list, core.ROOT, 2, string("7,8")).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.set(&list, 6, string("9")).kind, core.Document_Error_Kind.None)
	out, _, cerr := core.commit(&list, allocator = alloc)
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.None)
	delete(out, allocator = alloc)
	core.edit_list_destroy(&list)
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations left", len(track.allocation_map))
}

@(test)
edit_out_of_memory :: proc(t: ^testing.T) {
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv)
	defer core.destroy(&doc)
	f := walktest.Failing_Alloc{inner = context.allocator, fail_at = -1}
	alloc := walktest.failing_allocator(&f)
	list := core.edit_list_init(&doc, allocator = alloc)
	defer core.edit_list_destroy(&list)
	landed := false
	for fail_at in 0 ..< 8 {
		f.n = 0
		f.fail_at = fail_at
		e := core.insert(&list, core.ROOT, 1, string("7,8"))
		if e.kind == .No_Memory {
			testing.expect_value(t, len(list.edits), 0)
			continue
		}
		testing.expect_value(t, e.kind, core.Document_Error_Kind.None)
		landed = true
		break
	}
	testing.expect(t, landed)
	f.fail_at = -1
	committed := false
	for fail_at in 0 ..< 32 {
		f.n = 0
		f.fail_at = fail_at
		out, _, e := core.commit(&list, allocator = alloc)
		if e.kind == .No_Memory {
			continue
		}
		testing.expect_value(t, e.kind, core.Document_Error_Kind.None)
		testing.expect_value(t, string(out), "a,b\n1,2\n7,8\n")
		delete(out, allocator = alloc)
		committed = true
		break
	}
	testing.expect(t, committed)
	f.fail_at = -1
}

// The edit services use the document's options, so the cell separator is its delimiter, and a recorded cell or record
// is judged with its delimiter and comment byte.
@(test)
edit_options :: proc(t: ^testing.T) {
	// A semicolon CSV text writes semicolons, and a comma is a cell byte.
	opts := dsv.Options{delimiter = ';'}
	check(t, "a;b\n1;2\n", "a;b\n9;2\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "9")
	})
	check(t, "a;b\n1;2\n", "a;b\n1;2\n3;4\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("3;4"))
	})
	check(t, "1;2\n", "1;2;3\n", .Csv, dsv.Options{delimiter = ';', no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, 1, 2, string("3"))
	})
	check(t, "a;b\nx;2\n", "a;b\na,b;2\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "a,b")
	})
	// A recorded cell or record holding the delimiter unquoted is two cells, so it is refused. A quoted CSV cell
	// holding it is one cell, so it is accepted.
	{
		doc, _ := dsv.build(transmute([]u8)string("a;b\nx;2\n"), .Csv, opts)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set(&list, 5, string("p;q")).kind, core.Document_Error_Kind.Bad_Value)
		testing.expect_value(t, core.set(&list, 5, string("\"p;q\"")).kind, core.Document_Error_Kind.None)
	}
	// Plain has no quoting, so it cannot hold the delimiter at all.
	{
		doc, _ := dsv.build(transmute([]u8)string("a|b\nx|2\n"), .Plain, dsv.Options{delimiter = '|'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set(&list, 5, string("p|q")).kind, core.Document_Error_Kind.Bad_Value)
		testing.expect_value(t, core.set(&list, 5, string("\"p|q\"")).kind, core.Document_Error_Kind.Bad_Value)
		testing.expect_value(t, core.set(&list, 5, string("p q")).kind, core.Document_Error_Kind.None)
	}
	// Plain writes its delimiter between cells and its line end between records like the other specs.
	check(t, "a|b\n1|2\n", "a|b\n9|2\n", .Plain, dsv.Options{delimiter = '|'}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return set_cell(list, 5, "9")
	})
	check(t, "a|b\n1|2\n", "a|b\n1|2\n3|4\n", .Plain, dsv.Options{delimiter = '|'}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("3|4"))
	})
}

// A comment line is no record and no part of one. A record edit beside it leaves its bytes and its line end.
@(test)
edit_beside_comment :: proc(t: ^testing.T) {
	opts := dsv.Options{comment = '#', no_header = true}
	// A comment line above the removed record stays.
	check(t, "#c\na,b\n1,2\n", "1,2\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 1)
	})
	// A comment line between records stays when either record is removed.
	check(t, "a,b\n#c\n1,2\n", "#c\n1,2\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 1)
	})
	check(t, "a,b\n#c\n1,2\n", "a,b\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 4)
	})
	// A comment line below the removed record stays, with its line end.
	check(t, "a,b\n#c\n", "#c\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 1)
	})
	check(t, "#c\r\na\tb\r\n", "", .Tsv, dsv.Options{comment = '#', no_header = true}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.remove(list, 1)
	})
	// A record inserted before a record that a comment line introduces is written before the comment, so the comment
	// stays with its record. A record inserted after the last record is written before a trailing comment line.
	check(t, "#c\na,b\n", "x,y\n#c\na,b\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("x,y"))
	})
	check(t, "a,b\n#c\n", "a,b\nx,y\n#c\n", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 1, string("x,y"))
	})
	// A comment with no record after it is the root's foot, and a new record goes before a foot.
	check(t, "#c", "x,y\n#c", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("x,y"))
	})
	// A cell whose text starts a line with the comment byte reads as no record, so it is refused. A quoted CSV cell
	// is a cell, because the quote comes first.
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, dsv.Options{comment = '#'})
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.set(&list, 5, string("#x")).kind, core.Document_Error_Kind.Bad_Value)
		testing.expect_value(t, core.set(&list, 5, string("\"#x\"")).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, core.ROOT, 0, string("#x,y")).kind, core.Document_Error_Kind.Bad_Value)
	}
}

// A table built with a tolerance commits with no edit and with an edit. An edit keeps the tolerance the source
// needed, and a ragged table stays ragged.
@(test)
edit_tolerated_source :: proc(t: ^testing.T) {
	src := "a,b\n1\n"
	opts := dsv.Options{tolerate = {.Ragged}}
	doc, err := dsv.build(transmute([]u8)string(src), .Csv, opts)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, cerr := core.commit(&list)
	if !testing.expectf(t, cerr.kind == .None, "empty commit: %v", cerr) {
		return
	}
	testing.expect_value(t, string(out), src)
	delete(out)
	testing.expect_value(t, set_cell(&list, 5, "5").kind, core.Document_Error_Kind.None)
	expect_commit(t, &list, "a,b\n5\n", .Csv, opts)
}

// A record insert writes the line end the text uses, even when the only data record has none of its own.
@(test)
edit_record_sep_crlf :: proc(t: ^testing.T) {
	check(t, "a,b\r\n1,2", "a,b\r\nv,v\r\n1,2", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("v,v"))
	})
	check(t, "a,b\r\n1,2\r\n3,4\r\n", "a,b\r\nv,v\r\n1,2\r\n3,4\r\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("v,v"))
	})
	check(t, "a,b\r\n", "a,b\r\nv,v\r\n", .Csv, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		return core.insert(list, core.ROOT, 0, string("v,v"))
	})
}

// A set or insert inside a record the same list removes is refused, including a cell of no bytes at the record's first
// byte. The removal takes the written bytes, so the edit cannot read back.
@(test)
edit_edit_inside_removed_record :: proc(t: ^testing.T) {
	{
		// The first cell is empty, so its set writes no bytes at the record's first byte.
		doc, err := dsv.build(transmute([]u8)string("|1\n"), .Plain, dsv.Options{no_header = true, delimiter = '|'})
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "build: %v", err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.set(&list, 2, string("x")).kind, core.Document_Error_Kind.None)
		out, _, cerr := core.commit(&list)
		if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, cerr.kind == .Conflicting_Edits, "set: commit %v", cerr)
	}
	{
		// The record is the table's only one, so it may take a cell.
		doc, err := dsv.build(transmute([]u8)string("1\n"), .Plain, dsv.Options{no_header = true})
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "build: %v", err) {
			return
		}
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 1).kind, core.Document_Error_Kind.None)
		testing.expect_value(t, core.insert(&list, 1, 0, string("x")).kind, core.Document_Error_Kind.None)
		out, _, cerr := core.commit(&list)
		if len(out) > 0 {
			delete(out)
		}
		testing.expectf(t, cerr.kind == .Conflicting_Edits, "insert: commit %v", cerr)
	}
}

// Two records inserted at the ends of one run of removed records keep their `at` order in the output.
@(test)
edit_inserts_at_removed_run_end :: proc(t: ^testing.T) {
	check(t, "h\n1\n2\n", "h\nA\nB\n2\n", .Plain, {}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, core.ROOT, 1, string("B")); e.kind != .None {
			return e
		}
		if e := core.insert(list, core.ROOT, 0, string("A")); e.kind != .None {
			return e
		}
		return core.remove(list, 3)
	})
}

// A cell appended to the last record and a record appended after it are written at the text's end. The cell's bytes
// come first, or they would join the record after it.
@(test)
edit_insert_cell_and_record_at_text_end :: proc(t: ^testing.T) {
	check(t, "a;b;c", "a;b;d\ne;f;g", .Csv, {no_header = true, delimiter = ';'}, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, 1, 3, string("d")); e.kind != .None {
			return e
		}
		if e := core.remove(list, 4); e.kind != .None {
			return e
		}
		return core.insert(list, core.ROOT, 1, string("e;f;g"))
	})
}

// A record appended after the last record is removed ends with a line end. The root's foot comment then keeps a line
// of its own and reads back on the root.
@(test)
edit_append_after_removed_last :: proc(t: ^testing.T) {
	opts := dsv.Options{comment = '#'}
	check(t, "h\n1\n#f\n", "h\nA\n#f\n", .Plain, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
		if e := core.insert(list, core.ROOT, 1, string("A")); e.kind != .None {
			return e
		}
		return core.remove(list, 3)
	})
	doc, err := dsv.build(transmute([]u8)string("h\nA\n#f\n"), .Plain, opts)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "build: %v", err) {
		return
	}
	it := core.facts_of(&doc, core.ROOT, .Comment_Foot)
	b, ok := core.fact_next(&it)
	testing.expectf(t, ok && string(b) == "f", "foot: %q %v", b, ok)
}

// A cell a list both sets and removes is a conflict at the cell, in either order of the list, though the removal alone
// would leave a one-cell line empty.
@(test)
set_and_remove_of_a_cell :: proc(t: ^testing.T) {
	for text in ([]string{"z", ""}) {
		for set_first in ([]bool{true, false}) {
			src := "a\n1\n2\n"
			doc, err := dsv.build(transmute([]u8)src, .Csv)
			defer core.destroy(&doc)
			testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
			list := core.edit_list_init(&doc)
			defer core.edit_list_destroy(&list)
			cell := core.Node_Index(4)
			if set_first {
				testing.expect_value(t, core.set(&list, cell, text).kind, core.Document_Error_Kind.None)
			}
			testing.expect_value(t, core.remove(&list, cell).kind, core.Document_Error_Kind.None)
			if !set_first {
				testing.expect_value(t, core.set(&list, cell, text).kind, core.Document_Error_Kind.None)
			}
			out, _, e := core.commit(&list)
			delete(out)
			testing.expectf(t, e.kind == .Conflicting_Edits && e.at == 2, "%q set first %v: %v", text, set_first, e)
		}
	}
}
