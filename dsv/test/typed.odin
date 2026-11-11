package dsv_tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import rules "../../core/rules"
import typed "../../core/typed"
import write "../../core/write"
import dsv ".."
import model "../../core/model"
import walktest "../../walktest"

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

read_rows :: proc(src: string, target: ^$T, read := typed.Read_Options{}) -> core.Error {
	read := read
	read.borrow_strings = true
	return dsv.unmarshal(transmute([]u8)src, .Csv, target, read = read, opts = {}, allocator = context.temp_allocator)
}

expect_refusal :: proc(t: ^testing.T, e: core.Error, kind: core.Typed_Error_Kind, at: u64, loc := #caller_location) {
	walktest.expect_kind(t, e, kind, loc)
	testing.expect_value(t, walktest.at_of(e), at, loc)
}

// U+FFFD spells three bytes for the one it replaces, so the decode outgrows the cell.
@(test)
tolerated_ill_formed_cell_outgrows_its_span :: proc(t: ^testing.T) {
	Row :: struct {a: string}
	rows: []Row
	src := "a\n\xfe\n"
	e := dsv.unmarshal(transmute([]u8)src, .Csv, &rows, read = {}, opts = {tolerate = {.Invalid_Utf8}}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].a, "�")
}

@(test)
cells_read_by_their_field :: proc(t: ^testing.T) {
	src := "id,small,name,ok,score,ratio,may,text,color,note\n-5,+7,\"a,b\",true,1.5,2.25,3,x,Blue,n\n"
	rows: []Cell_Row
	e := read_rows(src, &rows)
	walktest.expect_nil(t, e)
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
	walktest.expect_nil(t, read_rows("id,name,may,text\n,,,\n,\"\",,\"\"\n", &rows))
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
	walktest.expect_nil(t, read_rows("n,s\n\"12\",\"a\"\"b\"\"\"\n", &rows))
	testing.expect_value(t, rows[0].n, 12)
	testing.expect_value(t, rows[0].s, `a"b"`)
}

@(test)
repeated_and_unknown_columns :: proc(t: ^testing.T) {
	Row :: struct { a: i64 }
	Case :: struct {
		src:  string,
		read: typed.Read_Options,
		kind: core.Typed_Error_Kind,
		at:   u64, // of a refusal
		a:    i64, // of a read
	}
	// The column a repeat leaves out is judged against the field's type, as JSON judges a repeated member it skips.
	for c in ([]Case {
		{"a,a\n1,2\n", {}, .None, 0, 2},
		{"a,a\n1,2\n", {dups = .First}, .None, 0, 1},
		{"a,a\n1,2\n", {dups = .Refuse}, .Duplicate_Key, 2, 0},
		{"a,a\nx,1\n", {}, .Wrong_Kind, 4, 0},
		{"a,a\n1,x\n", {dups = .First}, .Wrong_Kind, 6, 0},
		{"a,a\n1,\n", {dups = .First}, .None, 0, 1},
		{"a,a,a\n1,2,3\n", {}, .None, 0, 3},
		{"zz,a\nx,2\n", {}, .None, 0, 2},
		{"a,zz\n1,x\n", {unknown = .Refuse}, .Unknown_Field, 2, 0},
	}) {
		rows: []Row
		e := read_rows(c.src, &rows, c.read)
		expect_refusal(t, e, c.kind, c.at)
		if c.kind == .None {
			testing.expectf(t, len(rows) == 1 && rows[0].a == c.a, "%q: %v", c.src, rows)
		} else if c.kind == .Unknown_Field {
			testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "zz")
		}
	}
}

// Under `.Ragged` a wide record's cell past the header's last reads the field its 1-based position names. A header cell
// of that name repeats it, so the duplicate policy decides the wide record's cell, and a narrower record reads the
// header's column.
@(test)
a_wide_record_names_its_cells_by_position :: proc(t: ^testing.T) {
	Row :: struct { a: i64, three: i64 `csv:"3"` }
	read :: proc(src: string, rows: ^[]Row, read := typed.Read_Options{}) -> core.Error {
		return dsv.unmarshal(transmute([]u8)src, .Csv, rows, read = read, opts = {tolerate = {.Ragged}}, allocator = context.temp_allocator)
	}
	rows: []Row
	walktest.expect_nil(t, read("a,b\n1,2,3\n4\n5,6,7,8\n", &rows))
	testing.expect_value(t, len(rows), 3)
	testing.expect(t, rows[0] == {1, 3} && rows[1] == {4, 0} && rows[2] == {5, 7})
	expect_refusal(t, read("a\n1,2\n", &rows, {unknown = .Refuse}), .Unknown_Field, 0)
	src := "3,a\n1,2\n4,5,6\n"
	walktest.expect_nil(t, read(src, &rows))
	testing.expect(t, rows[0].three == 1 && rows[1].three == 6)
	walktest.expect_nil(t, read(src, &rows, {dups = .First}))
	testing.expect(t, rows[0].three == 1 && rows[1].three == 4)
	expect_refusal(t, read(src, &rows, {dups = .Refuse}), .Duplicate_Key, 0)
	expect_refusal(t, read("3,a\n1,2\n4,5,x\n", &rows, {dups = .First}), .Wrong_Kind, 12)
	e := dsv.unmarshal(transmute([]u8)string("a,b\n1,2,3\n"), .Csv, &rows, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Walk)
	maps: []map[string]i64
	e = dsv.unmarshal(transmute([]u8)string("rap\r\n1,x\r\n"), .Csv, &maps, read = {}, opts = {tolerate = {.Ragged}}, allocator = context.temp_allocator)
	expect_refusal(t, e, .Wrong_Kind, 7)
	detail := walktest.typed_of(e)
	testing.expect(t, detail.n_steps == 2 && detail.steps[1] == core.Step(core.Name("2")))
}

@(test)
refusals_name_the_row_and_the_field :: proc(t: ^testing.T) {
	Row :: struct { a: i8, b: bool, c: f64, d: Cell_Color }
	rows: []Row
	e := read_rows("a,b\n1,true\nx,true\n", &rows)
	expect_refusal(t, e, .Wrong_Kind, 11)
	testing.expect_value(t, walktest.typed_of(e).n_steps, 2)
	testing.expect_value(t, i64(walktest.typed_of(e).steps[0].(core.Index)), 1)
	testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "a")
	expect_refusal(t, read_rows("a\n128\n", &rows), .Above_Maximum, 2)
	expect_refusal(t, read_rows("b\nTrue\n", &rows), .Wrong_Kind, 2)
	expect_refusal(t, read_rows("c\n1e\n", &rows), .Wrong_Kind, 2)
	expect_refusal(t, read_rows("c\n1e400\n", &rows), .Above_Maximum, 2)
	expect_refusal(t, read_rows("c\nNaN\n", &rows), .Wrong_Kind, 2)
	expect_refusal(t, read_rows("c\nInfinity\n", &rows), .Wrong_Kind, 2)
	expect_refusal(t, read_rows("d\nPurple\n", &rows), .Not_A_Member, 2)
	expect_refusal(t, read_rows("a,b\n1\n", &rows), .Walk, 5)
}

@(test)
a_required_field_refuses_at_the_header_or_the_cell :: proc(t: ^testing.T) {
	rows: []Required_Row
	e := read_rows("b\nx\n", &rows)
	expect_refusal(t, e, .Missing_Field, 0)
	testing.expect_value(t, string(walktest.typed_of(e).steps[0].(core.Name)), "a")
	// A required column's absence wins over a fault in the first record.
	expect_refusal(t, read_rows("b\n\"", &rows), .Missing_Field, 0)
	e = read_rows("b,a\nx,1\ny,\n", &rows)
	expect_refusal(t, e, .Missing_Field, 10)
	testing.expect_value(t, i64(walktest.typed_of(e).steps[0].(core.Index)), 1)
	// In the columns' own order too, since the check at a row's close counts the row's members.
	walktest.expect_nil(t, read_rows("b,a\ny,\"2\"", &rows))
	testing.expect_value(t, rows[0].a, 2)
}

@(test)
list_and_map_rows :: proc(t: ^testing.T) {
	lists: [][]string
	walktest.expect_nil(t, read_rows("a,b\n1,\n", &lists))
	testing.expect_value(t, len(lists), 2)
	testing.expect_value(t, lists[0][1], "b")
	testing.expect_value(t, lists[1][1], "")
	maybes: [][]Maybe(i32)
	walktest.expect_nil(t, read_rows("1,\n", &maybes))
	_, some := maybes[0][1].?
	testing.expect(t, !some)
	maps: []map[string]string
	walktest.expect_nil(t, read_rows("a,\"b\"\"\"\n1,\n", &maps))
	testing.expect_value(t, maps[0]["a"], "1")
	_, has := maps[0][`b"`]
	testing.expect(t, !has)
	ints: []map[string]i64
	e := read_rows("\"a\"\nx\n", &ints)
	expect_refusal(t, e, .Wrong_Kind, 4)
	testing.expect_value(t, string(walktest.typed_of(e).steps[1].(core.Name)), "a")
	e = dsv.unmarshal(transmute([]u8)string("1\n"), .Csv, &ints, read = {}, opts = {no_header = true}, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
}

@(test)
the_specs_spell_their_cells :: proc(t: ^testing.T) {
	Row :: struct { a: string, b: i64 }
	rows: []Row
	src := "a\tb\nx\\ty\t1\n"
	walktest.expect_nil(t, dsv.unmarshal(transmute([]u8)src, .Tsv, &rows, read = {}, opts = {}, allocator = context.temp_allocator))
	testing.expect_value(t, rows[0].a, "x\ty")
	plain := "a,b\n\"x\",1\n"
	walktest.expect_nil(t, dsv.unmarshal(transmute([]u8)plain, .Plain, &rows, read = {}, opts = {}, allocator = context.temp_allocator))
	testing.expect_value(t, rows[0].a, `"x"`)
}

@(test)
no_header_reads_fields_in_order :: proc(t: ^testing.T) {
	Row :: struct { a: i64, b: string }
	rows: []Row
	e := dsv.unmarshal(transmute([]u8)string("1,x\n2,y\n"), .Csv, &rows, read = {borrow_strings = true}, opts = {no_header = true}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[1].b, "y")
}

@(test)
a_text_with_no_record_keeps_or_empties_the_target :: proc(t: ^testing.T) {
	Row :: struct { a: i64 }
	keep := []Row{{1}}
	walktest.expect_nil(t, read_rows("", &keep))
	testing.expect_value(t, len(keep), 1)
	walktest.expect_nil(t, read_rows("a\n", &keep))
	testing.expect_value(t, len(keep), 0)
}

@(test)
a_plan_refuses_a_type_no_text_reads :: proc(t: ^testing.T) {
	Nested :: struct { a: []int }
	for id in ([]typeid{int, []^int, []Nested, []map[int]string, [][][]int}) {
		_, e := dsv.plan_make(id, .Csv, allocator = context.temp_allocator)
		walktest.expect_kind(t, e, core.Typed_Error_Kind.Unsupported)
	}
}

@(test)
collecting_reads_past_each_refusal :: proc(t: ^testing.T) {
	Row :: struct { a: i8, b: i64 }
	rows: []Row
	sink: typed.Sink
	defer delete(sink.errors)
	e := read_rows("a,b\nx,1\n2,y\n3,4\n", &rows, {sink = &sink})
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
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
	e := dsv.unmarshal(transmute([]u8)string("name,n\n\"a\"\"b\",1\ncopy,2\nz,x\n"), .Csv, &rows, read = {}, opts = {}, allocator = alloc)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Wrong_Kind)
	testing.expect_value(t, len(rows), 3)
	for r in rows {
		delete(r.name, alloc)
	}
	delete(rows, alloc)
	testing.expect_value(t, len(tracker.allocation_map), 0)
	// A column a wide record names by its position is refused when the read binds it, past the rows before it.
	rows = nil
	e = dsv.unmarshal(transmute([]u8)string("name,n\ncopy,1\nz,2,x\n"), .Csv, &rows, read = {unknown = .Refuse}, opts = {tolerate = {.Ragged}}, allocator = alloc)
	expect_refusal(t, e, .Unknown_Field, 0)
	testing.expect_value(t, len(rows), 2)
	for r in rows {
		delete(r.name, alloc)
	}
	delete(rows, alloc)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}

@(test)
a_required_member_reads_as_any_other :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i32 `csv:"a,required"`,
		b: i32,
	}
	rows: []Row
	e := dsv.unmarshal(transmute([]u8)string("a,b\n1,2\n3,4\n"), dsv.Spec.Csv, &rows, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(rows), 2)
	rows = nil
	e = dsv.unmarshal(transmute([]u8)string("a,b\n,2\n"), dsv.Spec.Csv, &rows, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, e, core.Typed_Error_Kind.Missing_Field)
}

@(test)
a_plans_read_slot_reads_the_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		a, b: i32,
	}
	plan, err := dsv.plan_make([]Row, .Csv, reads = dsv.reads(.Csv), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect(t, plan.read != nil && plan.node_read != nil)
	testing.expect(t, plan.check != nil)
	rows: []Row
	e := typed.unmarshal_text(transmute([]u8)string("a,b\n1,2\n"), &rows, []Row, &plan, {}, context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].b, 2)
}

@(test)
a_repeated_header_reads_as_last_by_default :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i32,
	}
	src := transmute([]u8)string("a,a\n1,2\n")
	d, l: []Row
	_ = dsv.unmarshal(src, dsv.Spec.Csv, &d, read = {}, opts = {}, allocator = context.temp_allocator)
	_ = dsv.unmarshal(src, dsv.Spec.Csv, &l, read = {dups = .Last}, opts = {}, allocator = context.temp_allocator)
	testing.expect_value(t, d[0].a, 2)
	testing.expect_value(t, l[0].a, d[0].a)
}

@(test)
a_check_reports_every_missing_column_of_a_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i32 `csv:"a,required"`,
		b: i32 `csv:"b,required"`,
		c: i32,
		d: i32 `csv:"d,required"`,
	}
	plan, err := dsv.plan_make([]Row, .Csv, dsv.Options{tolerate = {.Ragged}}, reads = dsv.reads(.Csv), allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	text := transmute([]u8)string("a,b,c,d\n1\n2,3,4,5\n6\n")
	rows: []Row
	sink: typed.Sink
	sink.entries.allocator = context.temp_allocator
	first := typed.check_text(text, &rows, []Row, &plan, {sink = &sink}, context.temp_allocator)
	walktest.expect_kind(t, first, core.Typed_Error_Kind.Missing_Field)
	if !testing.expect_value(t, len(sink.entries), 4) {
		return
	}
	// Each short row names b, then d, and the entries keep the row's order.
	want := [?]string{"/0/b", "/0/d", "/2/b", "/2/d"}
	for e, i in sink.entries {
		testing.expect_value(t, e.kind, core.Typed_Error_Kind.Missing_Field)
		b := strings.builder_make(context.temp_allocator)
		core.write_pointer(strings.to_writer(&b), e.path)
		testing.expect_value(t, strings.to_string(b), want[i])
	}
	// A read that does not check stops at the first.
	rows = nil
	plain: typed.Sink
	plain.errors.allocator = context.temp_allocator
	_ = typed.unmarshal_text(text, &rows, []Row, &plan, {sink = &plain}, context.temp_allocator)
	testing.expect_value(t, len(plain.errors), 2)
	typed.sink_destroy(&sink)
}

@(private = "file")
Cents :: distinct i64

@(test)
a_model_reads_and_writes_carriers_in_cells :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	reg: model.Registry
	from :: proc(c: ^string, out: ^Cents, allocator: runtime.Allocator) -> core.Typed_Error_Kind {
		return .None
	}
	to :: proc(v: ^Cents, allocator: runtime.Allocator) -> (string, core.Typed_Error_Kind) {
		return "0", .None
	}
	model.register(&reg, model.Custom(Cents, string){from, to})
	Row :: struct {
		price: model.Decimal,
	}
	m, compiled := model.compile(&reg, []Row, dsv.checks(.Csv))
	walktest.expect_nil(t, compiled)
	rows: []Row
	walktest.expect_nil(t, model.load(&m, transmute([]u8)string("price\n12.50\n"), &rows))
	testing.expect(t, len(rows) == 1 && rows[0].price.text == "12.50")
	text, written := write.marshal(rows, &m.plan, allocator = context.temp_allocator)
	walktest.expect_nil(t, written)
	testing.expect_value(t, string(text), "price\n12.50\n")
	_, refused := model.compile(&reg, []struct{ c: Cents }, dsv.checks(.Csv))
	walktest.expect_kind(t, refused, core.Typed_Error_Kind.Unsupported)
	Either :: union {
		i64,
		string,
	}
	first: model.Registry
	model.register(&first, model.Union_Rule{type = Either, mode = .First_Match})
	_, refused = model.compile(&first, []struct{ e: Either }, dsv.checks(.Csv))
	walktest.expect_kind(t, refused, core.Typed_Error_Kind.Unsupported)
	Small :: distinct i64
	judged: model.Registry
	not_integer := rules.Description{allocator = context.allocator}
	defer rules.description_destroy(&not_integer)
	append(&not_integer.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, not = 1}, rules.Node{kinds = {.Integer}, array = -1, object = -1})
	model.register(&judged, Small, &not_integer)
	_, refused = model.compile(&judged, []struct{ s: Small }, dsv.checks(.Csv))
	walktest.expect_kind(t, refused, core.Typed_Error_Kind.Unsupported)
}
