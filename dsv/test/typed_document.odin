package dsv_tests

import "core:fmt"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import dsv ".."
import walktest "../../walktest"

// The typed read of a built delimited document: a value that reads gives the answer `dsv.unmarshal` gives over the same
// text, and a refusal the same refusal, for each row form, cell rule and option. A partial document reads what its path
// kept.

// Reads `src` through `dsv.unmarshal` and through a document built from it, and expects the same rows and the same
// refusal.
@(private = "file")
agree :: proc(t: ^testing.T, src: string, $T: typeid, $S: dsv.Spec, opts := dsv.Options{}, read := typed.Read_Options{}, loc := #caller_location) {
	bytes := transmute([]u8)src
	want, got: T
	want_err := dsv.unmarshal(bytes, S, &want, read = read, opts = opts, allocator = context.temp_allocator)
	doc, built := dsv.build(bytes, S, opts, .Last, context.temp_allocator)
	defer core.destroy(&doc)
	if built != nil {
		// A text the walk faults on builds no document.
		testing.expectf(t, walktest.fault_of(want_err) != nil, "%q: no document, but the text read as %v", src, want_err, loc = loc)
		return
	}
	plan, planned := dsv.plan_make(T, .Csv, allocator = context.temp_allocator)
	walktest.expect_nil(t, planned, loc)
	got_err := typed.unmarshal(&doc, core.ROOT, &got, &plan, read, context.temp_allocator)
	testing.expectf(t, fmt.tprintf("%v", got_err) == fmt.tprintf("%v", want_err), "%q: text %v, document %v", src, want_err, got_err, loc = loc)
	testing.expectf(t, fmt.tprintf("%v", got) == fmt.tprintf("%v", want), "%q: text %v, document %v", src, want, got, loc = loc)
	free_all(context.temp_allocator)
}

// Map rows compare by entry, since two maps hold the same entries in an order of their own.
@(private = "file")
agree_maps :: proc(t: ^testing.T, src: string, loc := #caller_location) {
	bytes := transmute([]u8)src
	want, got: []map[string]i64
	walktest.expect_nil(t, dsv.unmarshal(bytes, .Csv, &want, allocator = context.temp_allocator), loc)
	doc, _ := dsv.build(bytes, .Csv, allocator = context.temp_allocator)
	plan, _ := dsv.plan_make([]map[string]i64, .Csv, allocator = context.temp_allocator)
	walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &got, &plan, allocator = context.temp_allocator), loc)
	testing.expect_value(t, len(got), len(want), loc)
	for row, i in want {
		testing.expect_value(t, len(got[i]), len(row), loc)
		for key, value in row {
			testing.expect_value(t, got[i][key], value, loc)
		}
	}
	free_all(context.temp_allocator)
}

@(test)
a_document_reads_as_its_text :: proc(t: ^testing.T) {
	all := "id,small,name,ok,score,ratio,may,text,color,note\n-5,+7,\"a,b\",true,1.5,2.25,3,x,Blue,n\n"
	agree(t, all, []Cell_Row, .Csv)
	agree(t, all, []Cell_Row, .Csv, read = {borrow_strings = true})
	agree(t, all, [dynamic]Cell_Row, .Csv)
	agree(t, "id,name,may,text\n,,,\n,\"\",,\"\"\n", []Cell_Row, .Csv)
	agree(t, "n,s\n\"12\",\"a\"\"b\"\"\"\n", []struct { n: i64, s: string }, .Csv)
	agree(t, "n,s\r\n12,x\r\n13,y", []struct { n: i64, s: string }, .Csv)
	agree(t, "a,a\n1,2\n", []struct { a: i64 }, .Csv)
	agree(t, "a,a\n1,2\n", []struct { a: i64 }, .Csv, read = {dups = .First})
	agree(t, "zz,a\nx,2\n", []struct { a: i64 }, .Csv)
	agree(t, "a,zz\n1,x\n", []struct { a: i64 }, .Csv, read = {unknown = .Refuse})
	agree(t, "a,b\n1,true\nx,true\n", []struct { a: i8, b: bool }, .Csv)
	agree(t, "d\nPurple\n", []struct { d: Cell_Color }, .Csv)
	agree(t, "c\n1e\n", []struct { c: f64 }, .Csv)
	agree(t, "a\n128\n", []struct { a: i8 }, .Csv)
}

// Under `.Ragged` a wide record's cells past the header's are columns named by position, in a document as in its text.
@(test)
a_document_reads_wide_records_as_its_text :: proc(t: ^testing.T) {
	Row :: struct { a: i64, three: i64 `csv:"3"` }
	ragged := dsv.Options{tolerate = {.Ragged}}
	agree(t, "a,b\n1,2,3\n4\n5,6,7,8\n", []Row, .Csv, ragged)
	agree(t, "a\n1\n2,3\n", []Row, .Csv, ragged, {unknown = .Refuse})
	agree(t, "3,a\n1,2\n4,5,6\n", []Row, .Csv, ragged)
	agree(t, "3,a\n1,2\n4,5,6\n", []Row, .Csv, ragged, {dups = .First})
	agree(t, "3,a\n1,2\n4,5,x\n", []Row, .Csv, ragged, {dups = .First})
	// A column named by its position is bound when a cell reaches it, so a refusal of an earlier cell comes first, and a
	// list row's header row holds the header's cells alone.
	agree(t, "a\nx,2,3,4\n", []Row, .Csv, ragged, {unknown = .Refuse})
	agree(t, "c\n1,2,3\n", [][]string, .Csv, ragged)
	agree(t, "a,b\n1,x\n", struct { a: i64, b: string }, .Csv)
	agree(t, "a,b\n1,x\n2,y\n", struct { a: i64, b: string }, .Csv)
	agree(t, "a\nx\n", struct { a: i64 }, .Csv)
	agree(t, "a,a\nx,1\n", struct { a: i64 }, .Csv)
	agree(t, "a,a\n1,x\n", struct { a: i64 }, .Csv, read = {dups = .First})
	agree(t, "b\nx\n", []Required_Row, .Csv)
	agree(t, "b,a\nx,1\ny,\n", []Required_Row, .Csv)
	agree(t, "b,a\ny,\"2\"", []Required_Row, .Csv)
	agree(t, "a,b\n1,x\r\n2,y\r\n", []Required_Row, .Csv)
	agree(t, "a,b\n1\n2,y\n", []Required_Row, .Csv, {tolerate = {.Ragged}})
	agree(t, "a,b\n1\r\n", []Required_Row, .Csv, {tolerate = {.Ragged}})
	agree(t, "b,a\ny\nz,1\n", []Required_Row, .Csv, {tolerate = {.Ragged}})
	agree(t, "b,a\ny\r\nz,1\n", []Required_Row, .Csv, {tolerate = {.Ragged}})
	agree(t, "b,a\nz,1\ny", []Required_Row, .Csv, {tolerate = {.Ragged}})
	agree(t, "a,b\n1,\n", [][]string, .Csv)
	agree(t, "1,\n", [][]Maybe(i32), .Csv)
	agree(t, "a,\"b\"\"\"\n1,\n", []map[string]string, .Csv)
	agree(t, "\"a\"\nx\n", []map[string]i64, .Csv)
	agree_maps(t, "a,b\n1,2\n3,4\n")
	agree(t, "1,x\n2,y\n", []struct { a: i64, b: string }, .Csv, {no_header = true})
	agree(t, "1\n", []map[string]i64, .Csv, {no_header = true})
	agree(t, "1,2\n3\n", [][]i64, .Csv, {no_header = true, tolerate = {.Ragged}})
	agree(t, "a,b\n", []struct { a: i64 }, .Csv)
	agree(t, "a,b\n", [][]string, .Csv)
	agree(t, "", []struct { a: i64 }, .Csv)
	agree(t, "", [][]string, .Csv)
	agree(t, "# note\n", []struct { a: i64 }, .Csv, {comment = '#'})
	agree(t, "# note\na\n1\n# more\n2\n", []struct { a: i64 }, .Csv, {comment = '#'})
}

@(test)
a_document_reads_each_spec_and_tolerance_as_its_text_does :: proc(t: ^testing.T) {
	Row :: struct { a: string, b: i64 }
	agree(t, "a\tb\nx\\ty\t1\n", []Row, .Tsv)
	agree(t, "a\tb\n\"x\"\t1\n", []Row, .Plain)
	agree(t, "a;b\n\"x;y\";1\n", []Row, .Csv, {delimiter = ';'})
	agree(t, "a,b\n\"\xff\",1\n\xfe,2\n", []Row, .Csv, {tolerate = {.Invalid_Utf8}})
	agree(t, "a,b\n\"\xffq\"\"\",1\n", []Row, .Csv, {tolerate = {.Invalid_Utf8}}, {borrow_strings = true})
	agree(t, "a,b\n\"x\"y,1\n", []Row, .Csv, {tolerate = {.Bare_Quote}})
	text := make([dynamic]u8, context.temp_allocator)
	append(&text, "id,name,score\n")
	for i in 0 ..< 300 {
		append(&text, fmt.tprintf("%d,name %d,%d.5\n", i, i, i))
	}
	append(&text, "\"0\",\"q\"\"\",1")
	agree(t, string(text[:]), []struct { id: i64, name: string, score: f64 }, .Csv)
	agree(t, string(text[:]), [][]string, .Csv)
}

@(private = "file")
Pair :: struct {
	id:   i64,
	name: string,
}

@(private = "file")
scan_rows :: proc(t: ^testing.T, src, path: string, $S: dsv.Spec, T: typeid, opts := dsv.Options{}, loc := #caller_location) -> (doc: core.Document) {
	parsed, perr := core.parse_path(path)
	defer core.path_destroy(&parsed)
	walktest.expect_nil(t, perr, loc)
	err: core.Error
	doc, err = dsv.scan(transmute([]u8)src, S, parsed, opts = opts, allocator = context.temp_allocator)
	walktest.expect_nil(t, err, loc)
	return
}

@(test)
a_partial_document_reads_what_its_path_kept :: proc(t: ^testing.T) {
	headed := "id,name\n1,ann\n2,bob\n"
	rows: []Pair
	plan, _ := dsv.plan_make([]Pair, .Csv, allocator = context.temp_allocator)
	// A cell kept by name binds to the field its key names, and the root lists the records the path kept.
	doc := scan_rows(t, headed, ".[1].name", .Csv, []Pair)
	e := typed.unmarshal(&doc, core.ROOT, &rows, &plan, {borrow_strings = true}, context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0], Pair{0, "bob"})
	// A cell kept by position has its header cell beside it.
	doc = scan_rows(t, headed, ".[1][0]", .Csv, []Pair)
	walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &rows, &plan, {}, context.temp_allocator))
	testing.expect_value(t, rows[0], Pair{2, ""})
	// A record kept whole reads as a list of that one row, and as the same row the whole text gives.
	doc = scan_rows(t, headed, ".[1]", .Csv, []Pair)
	walktest.expect_nil(t, typed.unmarshal(&doc, doc.answers[0], &rows, &plan, {borrow_strings = true}, context.temp_allocator))
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0], Pair{2, "bob"})
	doc = scan_rows(t, headed, ".[]", .Csv, []Pair)
	walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &rows, &plan, {borrow_strings = true}, context.temp_allocator))
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0], Pair{1, "ann"})
	lists: [][]string
	list_plan, _ := dsv.plan_make([][]string, .Csv, allocator = context.temp_allocator)
	doc = scan_rows(t, headed, ".[1]", .Csv, [][]string)
	walktest.expect_nil(t, typed.unmarshal(&doc, doc.answers[0], &lists, &list_plan, {borrow_strings = true}, context.temp_allocator))
	testing.expect_value(t, len(lists), 1)
	testing.expect_value(t, lists[0][1], "bob")
	// A cell reads in no plan.
	doc = scan_rows(t, headed, ".[1].name", .Csv, []Pair)
	walktest.expect_kind(t, typed.unmarshal(&doc, doc.answers[0], &rows, &plan, {}, context.temp_allocator), core.Typed_Error_Kind.Unsupported)
	free_all(context.temp_allocator)
}

@(test)
a_partial_document_with_no_header_reads_a_cell_it_did_not_keep_as_absent :: proc(t: ^testing.T) {
	Row :: struct { a: i64, b: string }
	src := "1,ann\n2,bob\n"
	rows: []Row
	plan, _ := dsv.plan_make([]Row, .Csv, allocator = context.temp_allocator)
	doc := scan_rows(t, src, ".[1][1]", .Csv, []Row, {no_header = true})
	walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &rows, &plan, {borrow_strings = true}, context.temp_allocator))
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0], Row{0, "bob"})
	doc = scan_rows(t, src, ".[1]", .Csv, []Row, {no_header = true})
	walktest.expect_nil(t, typed.unmarshal(&doc, doc.answers[0], &rows, &plan, {borrow_strings = true}, context.temp_allocator))
	testing.expect_value(t, rows[0], Row{2, "bob"})
	lists: [][]string
	list_plan, _ := dsv.plan_make([][]string, .Csv, allocator = context.temp_allocator)
	doc = scan_rows(t, src, ".[1][1]", .Csv, [][]string, {no_header = true})
	walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &lists, &list_plan, {borrow_strings = true}, context.temp_allocator))
	testing.expect_value(t, len(lists), 1)
	testing.expect_value(t, len(lists[0]), 2)
	testing.expect_value(t, lists[0][0], "")
	testing.expect_value(t, lists[0][1], "bob")
	free_all(context.temp_allocator)
}

@(test)
a_document_read_refuses_what_a_text_read_cannot_take :: proc(t: ^testing.T) {
	src := transmute([]u8)string("id,name\n1,ann\n")
	doc, _ := dsv.build(src, .Csv, allocator = context.temp_allocator)
	plan, _ := dsv.plan_make([]Pair, .Csv, allocator = context.temp_allocator)
	rows: []Pair
	walktest.expect_kind(t, typed.unmarshal(&doc, core.ROOT, &rows, &plan, {dups = .Refuse}, context.temp_allocator), core.Typed_Error_Kind.Bad_Option)
	// The header row's cells are keys, and a cell is no row.
	walktest.expect_kind(t, typed.unmarshal(&doc, 2, &rows, &plan, {}, context.temp_allocator), core.Typed_Error_Kind.Bad_Option)
	walktest.expect_kind(t, typed.unmarshal(&doc, 5, &rows, &plan, {}, context.temp_allocator), core.Typed_Error_Kind.Unsupported)
	headless, _ := dsv.build(src, .Csv, {no_header = true}, allocator = context.temp_allocator)
	maps: []map[string]string
	map_plan, _ := dsv.plan_make([]map[string]string, .Csv, allocator = context.temp_allocator)
	walktest.expect_kind(t, typed.unmarshal(&headless, core.ROOT, &maps, &map_plan, {}, context.temp_allocator), core.Typed_Error_Kind.Unsupported)
	free_all(context.temp_allocator)
}

@(test)
a_plan_not_made_by_dsv_refuses_a_document :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i64,
		b: string,
	}
	src := "a,b\n1,x\n"
	doc, _ := dsv.build(transmute([]u8)src, .Csv, allocator = context.temp_allocator)
	plan, planned := typed.plan_build([]Row, doc.as, allocator = context.temp_allocator)
	testing.expect_value(t, planned.kind, core.Typed_Error_Kind.None)
	rows: []Row
	e := typed.unmarshal(&doc, core.ROOT, &rows, &plan, {}, context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Plan_Mismatch)
	testing.expect_value(t, len(rows), 0)
	e = dsv.unmarshal(transmute([]u8)src, .Csv, &rows, &plan, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Plan_Mismatch)
	e = typed.unmarshal(&doc, core.ROOT, &rows, nil, {}, context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(rows), 1)
}
