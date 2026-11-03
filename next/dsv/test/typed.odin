package dsv_tests

import "core:mem"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import dsv ".."

// The typed read of a delimited text: each cell rule, each row form, each refusal, the collecting sink and who owns what
// a failed read leaves.

Cell_Color :: enum u8 { Red, Green, Blue = 7 }

Cell_Row :: struct {
	id:    i64,
	small: i8,
	name:  string,
	ok:    bool,
	score: f64,
	ratio: f32,
	may:   Maybe(i32),
	text:  Maybe(string),
	color: Cell_Color,
	note:  cstring,
}

Required_Row :: struct {
	a: i32 `csv:"a,required"`,
	b: string,
}

read_rows :: proc(src: string, target: ^$T, read := typed.Read_Options{}) -> core.Typed_Error {
	read := read
	read.borrow_strings = true
	return dsv.unmarshal(transmute([]u8)src, .Csv, target, read, {}, context.temp_allocator)
}

expect_refusal :: proc(t: ^testing.T, e: core.Typed_Error, kind: core.Typed_Error_Kind, at: u64, loc := #caller_location) {
	testing.expect_value(t, e.kind, kind, loc)
	testing.expect_value(t, e.at, at, loc)
}

// U+FFFD spells three bytes for the one it replaces, so the decode outgrows the cell.
@(test)
tolerated_ill_formed_cell_outgrows_its_span :: proc(t: ^testing.T) {
	Row :: struct {a: string}
	rows: []Row
	src := "a\n\xfe\n"
	e := dsv.unmarshal(transmute([]u8)src, .Csv, &rows, {}, {tolerate = {.Invalid_Utf8}}, context.temp_allocator)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].a, "�")
}

@(test)
cells_read_by_their_field :: proc(t: ^testing.T) {
	src := "id,small,name,ok,score,ratio,may,text,color,note\n-5,+7,\"a,b\",true,1.5,2.25,3,x,Blue,n\n"
	rows: []Cell_Row
	e := read_rows(src, &rows)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(rows), 1)
	r := rows[0]
	testing.expect_value(t, r.id, -5)
	testing.expect_value(t, r.small, 7)
	testing.expect_value(t, r.name, "a,b")
	testing.expect_value(t, r.ok, true)
	testing.expect_value(t, r.score, 1.5)
	testing.expect_value(t, r.ratio, 2.25)
	testing.expect_value(t, r.may.?, 3)
	testing.expect_value(t, r.text.?, "x")
	testing.expect_value(t, r.color, Cell_Color.Blue)
	testing.expect_value(t, string(r.note), "n")
}

@(test)
an_unquoted_empty_cell_is_absent :: proc(t: ^testing.T) {
	rows: []Cell_Row
	testing.expect_value(t, read_rows("id,name,may,text\n,,,\n,\"\",,\"\"\n", &rows).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0].id, 0)
	_, some := rows[0].text.?
	testing.expect(t, !some)
	// A quoted `""` is present and empty.
	text, present := rows[1].text.?
	testing.expect(t, present && text == "")
	_, some = rows[1].may.?
	testing.expect(t, !some)
}

@(test)
a_quoted_number_reads_and_a_doubled_quote_is_one :: proc(t: ^testing.T) {
	Row :: struct { n: i64, s: string }
	rows: []Row
	testing.expect_value(t, read_rows("n,s\n\"12\",\"a\"\"b\"\"\"\n", &rows).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].n, 12)
	testing.expect_value(t, rows[0].s, `a"b"`)
}

@(test)
a_repeated_column_reads_as_its_last :: proc(t: ^testing.T) {
	Row :: struct { a: i64 }
	rows: []Row
	testing.expect_value(t, read_rows("a,a\n1,2\n", &rows).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].a, 2)
	testing.expect_value(t, read_rows("a,a\n1,2\n", &rows, {dups = .First}).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].a, 1)
	expect_refusal(t, read_rows("a,a\n1,2\n", &rows, {refuse_duplicates = true}), .Duplicate_Key, 2)
}

@(test)
unknown_columns_pass_or_refuse :: proc(t: ^testing.T) {
	Row :: struct { a: i64 }
	rows: []Row
	testing.expect_value(t, read_rows("zz,a\nx,2\n", &rows).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].a, 2)
	e := read_rows("a,zz\n1,x\n", &rows, {unknown = .Refuse})
	expect_refusal(t, e, .Unknown_Field, 2)
	testing.expect_value(t, string(e.steps[0].(core.Name)), "zz")
}

@(test)
refusals_name_the_row_and_the_field :: proc(t: ^testing.T) {
	Row :: struct { a: i8, b: bool, c: f64, d: Cell_Color }
	rows: []Row
	e := read_rows("a,b\n1,true\nx,true\n", &rows)
	expect_refusal(t, e, .Wrong_Kind, 11)
	testing.expect_value(t, e.n_steps, 2)
	testing.expect_value(t, i64(e.steps[0].(core.Index)), 1)
	testing.expect_value(t, string(e.steps[1].(core.Name)), "a")
	expect_refusal(t, read_rows("a\n128\n", &rows), .Out_Of_Range, 2)
	expect_refusal(t, read_rows("b\nTrue\n", &rows), .Wrong_Kind, 2)
	expect_refusal(t, read_rows("c\n1e\n", &rows), .Wrong_Kind, 2)
	expect_refusal(t, read_rows("d\nPurple\n", &rows), .Not_A_Member, 2)
	expect_refusal(t, read_rows("a,b\n1\n", &rows), .Walk, 5)
}

@(test)
a_required_field_refuses_at_the_header_or_the_cell :: proc(t: ^testing.T) {
	rows: []Required_Row
	e := read_rows("b\nx\n", &rows)
	expect_refusal(t, e, .Missing_Field, 0)
	testing.expect_value(t, string(e.steps[0].(core.Name)), "a")
	// A required column's absence wins over a fault in the first record.
	expect_refusal(t, read_rows("b\n\"", &rows), .Missing_Field, 0)
	e = read_rows("b,a\nx,1\ny,\n", &rows)
	expect_refusal(t, e, .Missing_Field, 10)
	testing.expect_value(t, i64(e.steps[0].(core.Index)), 1)
	// In the columns' own order too, since the check at a row's close counts the row's members.
	testing.expect_value(t, read_rows("b,a\ny,\"2\"", &rows).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].a, 2)
}

@(test)
list_and_map_rows :: proc(t: ^testing.T) {
	lists: [][]string
	testing.expect_value(t, read_rows("a,b\n1,\n", &lists).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(lists), 2)
	testing.expect_value(t, lists[0][1], "b")
	testing.expect_value(t, lists[1][1], "")
	maybes: [][]Maybe(i32)
	testing.expect_value(t, read_rows("1,\n", &maybes).kind, core.Typed_Error_Kind.None)
	_, some := maybes[0][1].?
	testing.expect(t, !some)
	maps: []map[string]string
	testing.expect_value(t, read_rows("a,\"b\"\"\"\n1,\n", &maps).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, maps[0]["a"], "1")
	_, has := maps[0][`b"`]
	testing.expect(t, !has)
	ints: []map[string]i64
	e := read_rows("\"a\"\nx\n", &ints)
	expect_refusal(t, e, .Wrong_Kind, 4)
	testing.expect_value(t, string(e.steps[1].(core.Name)), "a")
	e = dsv.unmarshal(transmute([]u8)string("1\n"), .Csv, &ints, {}, {no_header = true}, context.temp_allocator)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.Unsupported)
}

@(test)
the_specs_spell_their_cells :: proc(t: ^testing.T) {
	Row :: struct { a: string, b: i64 }
	rows: []Row
	src := "a\tb\nx\\ty\t1\n"
	testing.expect_value(t, dsv.unmarshal(transmute([]u8)src, .Tsv, &rows, {}, {}, context.temp_allocator).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].a, "x\ty")
	plain := "a,b\n\"x\",1\n"
	testing.expect_value(t, dsv.unmarshal(transmute([]u8)plain, .Plain, &rows, {}, {}, context.temp_allocator).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, rows[0].a, `"x"`)
}

@(test)
no_header_reads_fields_in_order :: proc(t: ^testing.T) {
	Row :: struct { a: i64, b: string }
	rows: []Row
	e := dsv.unmarshal(transmute([]u8)string("1,x\n2,y\n"), .Csv, &rows, {borrow_strings = true}, {no_header = true}, context.temp_allocator)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[1].b, "y")
}

@(test)
a_text_with_no_record_keeps_or_empties_the_target :: proc(t: ^testing.T) {
	Row :: struct { a: i64 }
	keep := []Row{{1}}
	testing.expect_value(t, read_rows("", &keep).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(keep), 1)
	testing.expect_value(t, read_rows("a\n", &keep).kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(keep), 0)
}

@(test)
a_plan_refuses_a_type_no_text_reads :: proc(t: ^testing.T) {
	Nested :: struct { a: []int }
	for id in ([]typeid{int, []^int, []Nested, []map[int]string, [][][]int}) {
		_, e := dsv.plan_make(id, .Csv, allocator = context.temp_allocator)
		testing.expect_value(t, e.kind, core.Typed_Error_Kind.Unsupported)
	}
}

@(test)
collecting_reads_past_each_refusal :: proc(t: ^testing.T) {
	Row :: struct { a: i8, b: i64 }
	rows: []Row
	sink: typed.Collected
	defer delete(sink.errors)
	e := read_rows("a,b\nx,1\n2,y\n3,4\n", &rows, {collect = &sink})
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(sink.errors), 2)
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, rows[0].b, 1)
	testing.expect_value(t, rows[1].a, 2)
	testing.expect_value(t, rows[2].b, 4)
	testing.expect_value(t, sink.errors[1].kind, core.Typed_Error_Kind.Wrong_Kind)
}

// A refused read's list stays reachable from the target, so freeing the target frees all of it.
@(test)
a_refusal_leaves_what_it_allocated_with_the_target :: proc(t: ^testing.T) {
	Row :: struct { name: string, n: i64 }
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	alloc := mem.tracking_allocator(&tracker)
	rows: []Row
	e := dsv.unmarshal(transmute([]u8)string("name,n\n\"a\"\"b\",1\ncopy,2\nz,x\n"), .Csv, &rows, {}, {}, alloc)
	testing.expect_value(t, e.kind, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(rows), 3)
	for r in rows {
		delete(r.name, alloc)
	}
	delete(rows, alloc)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}
