package dsv_tests

import "core:mem"
import "core:testing"
import core "../../core"
import dsv ".."
import walktest "../../walktest"

// Edits over a delimited text: a cell's text, a record's line, and the table's width, which the header or the first
// record fixes.

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

// A cell inserted into a record the table lets it join, and the refusal when the record is already the table's width.
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
	// A headed record is a Map, so an array-element insert is refused as Wrong_Container. A header that records follow refuses a column.
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n3,4\n"), .Csv)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.insert(&list, 4, 2, string("9")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, 1, 2, string("c")).kind, core.Document_Error_Kind.Bad_Width)
	testing.expect_value(t, core.insert(&list, 4, 0, string("x,y")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, len(list.edits), 0)

	// A headerless record is an Array and checks cell count against the table width.
	nh_doc, _ := dsv.build(transmute([]u8)string("1,2\n3,4\n"), .Csv, {no_header = true})
	defer core.destroy(&nh_doc)
	nh_list := core.edit_list_init(&nh_doc)
	defer core.edit_list_destroy(&nh_list)
	testing.expect_value(t, core.insert(&nh_list, 1, 2, string("9")).kind, core.Document_Error_Kind.Bad_Width)
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
	// A header cell has role `Key` and is no member to remove. A column leaves only through the header row's own
	// edits, which are refused too.
	{
		doc, _ := dsv.build(transmute([]u8)string("a,b\n"), .Csv)
		defer core.destroy(&doc)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		testing.expect_value(t, core.remove(&list, 3).kind, core.Document_Error_Kind.Bad_Index)
		testing.expect_value(t, len(list.edits), 0)
	}
	// A record at the table's width keeps it, and a record cannot become empty or keep one empty cell.
	doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n3,4\n"), .Csv)
	defer core.destroy(&doc)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 5).kind, core.Document_Error_Kind.None)
	_, _, e := core.commit(&list)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Width)
	core.edit_list_destroy(&list)

	single, _ := dsv.build(transmute([]u8)string("1,2\n"), .Csv, {no_header = true})
	defer core.destroy(&single)
	list = core.edit_list_init(&single)
	defer core.edit_list_destroy(&list)
	testing.expect_value(t, core.remove(&list, 3).kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.remove(&list, 2).kind, core.Document_Error_Kind.None)
	_, _, e = core.commit(&list)
	testing.expect_value(t, e.kind, core.Document_Error_Kind.Bad_Width)
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
	testing.expect_value(t, core.insert(&list, core.ROOT, 0, string("7")).kind, core.Document_Error_Kind.Bad_Width)
	testing.expect_value(t, core.insert(&list, core.ROOT, 3, string("7,8")).kind, core.Document_Error_Kind.Bad_Position)
	testing.expect_value(t, core.insert(&list, 4, 9, string("7")).kind, core.Document_Error_Kind.Wrong_Container)
	testing.expect_value(t, core.insert(&list, 4, 0, string(`k`), string("v")).kind, core.Document_Error_Kind.Wrong_Container)
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
		// An unquoted text with three cells is no record of this two-cell table.
		testing.expect_value(t, core.insert(&list, core.ROOT, 0, string("p;q;r")).kind, core.Document_Error_Kind.Bad_Width)
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
	// A text that ends inside a comment line has a line end written before the record, so the comment keeps its own
	// bytes.
	check(t, "#c", "#c\nx,y", .Csv, opts, proc(list: ^core.Edit_List) -> core.Document_Error {
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
