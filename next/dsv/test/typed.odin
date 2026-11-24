package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// The typed read of a delimited text: each cell rule, each row form, each refusal, and who owns what a failed read
// leaves.

Cell_Color :: enum u8 {
	Red,
	Green,
	Blue = 7,
}

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
}

Required_Row :: struct {
	a: i32 `csv:"a,required"`,
	b: string,
}

// Reads `src` as CSV into `target` with the cells borrowed from `src`, in the temporary allocator.
read_rows :: proc(src: string, target: ^$T, read := dsv.Unmarshal_Options{}, opts := dsv.Options{}, spec := dsv.Spec.Csv) -> tape.Error {
	read := read
	read.borrow_strings = true
	return dsv.unmarshal(transmute([]u8)src, target, spec, read, opts, context.temp_allocator)
}

// Expects `e` to be a refusal `want` at byte `at`.
expect_refusal :: proc(t: ^testing.T, e: tape.Error, want: dsv.Typed_Refusal, at: u64, loc := #caller_location) -> (path_ok: bool) {
	f, is_fault := e.(tape.Fault)
	if !testing.expectf(t, is_fault && f.kind == .Refused, "got %v, wanted a refusal %v", e, want, loc = loc) {
		return false
	}
	testing.expect_value(t, dsv.Typed_Refusal(f.detail), want, loc)
	testing.expect_value(t, f.at, at, loc)
	return true
}

// Expects `steps` to be the path `want`, a name for a string and an index for an int.
expect_path :: proc(t: ^testing.T, steps: []tape.Step, want: []union {
		int,
		string,
	}, loc := #caller_location) {
	if !testing.expect_value(t, len(steps), len(want), loc) {
		return
	}
	for w, i in want {
		switch v in w {
		case int:
			testing.expect_value(t, steps[i], tape.Step(tape.Index(v)), loc)
		case string:
			testing.expect_value(t, steps[i], tape.Step(tape.Name(v)), loc)
		}
	}
}

// U+FFFD spells three bytes for the one it replaces, so the decode outgrows the cell.
@(test)
tolerated_ill_formed_cell_outgrows_its_span :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: string,
	}
	rows: []Row
	src := "a\n\xfe\n"
	e := dsv.unmarshal(transmute([]u8)src, &rows, .Csv, opts = {tolerate = {.Invalid_Utf8}}, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].a, "�")
}

@(test)
cells_read_by_their_field :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := "id,small,name,ok,score,ratio,may,text,color\n-5,7,\"a,b\",true,1.5,2.25,3,x,Blue\n"
	rows: []Cell_Row
	testing.expect_value(t, read_rows(src, &rows), nil)
	if !testing.expect_value(t, len(rows), 1) {
		return
	}
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
	// A number cell spells a JSON number, so a leading plus is no integer.
	small: []Cell_Row
	expect_refusal(t, read_rows("small\n+7\n", &small), .Expected_Integer, 6)
}

@(test)
an_unquoted_empty_cell_is_absent :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	rows: []Cell_Row
	testing.expect_value(t, read_rows("id,name,may,text\n,,,\n,\"\",,\"\"\n", &rows), nil)
	if !testing.expect_value(t, len(rows), 2) {
		return
	}
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
an_absent_cell_keeps_the_destination :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i64,
		b: string,
	}
	rows := make([]Row, 2, context.temp_allocator)
	rows[0], rows[1] = {7, "kept"}, {8, "kept"}
	// The read replaces the list, so the destination a cell keeps is the one of the new row.
	testing.expect_value(t, read_rows("a,b\n,x\n3,\n", &rows), nil)
	if !testing.expect_value(t, len(rows), 2) {
		return
	}
	testing.expect_value(t, rows[0], Row{0, "x"})
	testing.expect_value(t, rows[1], Row{3, ""})
}

@(test)
a_quoted_number_reads_and_a_doubled_quote_is_one :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		n: i64,
		s: string,
	}
	rows: []Row
	testing.expect_value(t, read_rows("n,s\n\"12\",\"a\"\"b\"\"\"\n", &rows), nil)
	if !testing.expect_value(t, len(rows), 1) {
		return
	}
	testing.expect_value(t, rows[0].n, 12)
	testing.expect_value(t, rows[0].s, `a"b"`)
	// Borrowed or copied, the cell with a doubled quote reads the same.
	copied: []Row
	src := "n,s\n1,\"x\"\"y\"\n"
	testing.expect_value(t, dsv.unmarshal(transmute([]u8)src, &copied, .Csv, allocator = context.temp_allocator), nil)
	if testing.expect_value(t, len(copied), 1) {
		testing.expect_value(t, copied[0].s, `x"y`)
	}
}

@(test)
repeated_and_unknown_columns :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i64,
	}
	Case :: struct {
		src:  string,
		read: dsv.Unmarshal_Options,
		opts: dsv.Options,
		want: union {
			i64,
			dsv.Typed_Refusal,
		}, // the row's `a`, or a refusal
		at:   u64, // of a refusal
	}
	// Under `.First` the column a repeat leaves out is judged for its syntax only, as JSON judges a repeated member it
	// skips, and under `.Last` the earlier column is judged against the field's type.
	for c in ([]Case {
			{"a,a\n1,2\n", {}, {}, i64(2), 0},
			{"a,a\n1,2\n", {}, {dups = .First}, i64(1), 0},
			{"a,a\nx,1\n", {}, {}, dsv.Typed_Refusal.Expected_Integer, 4},
			{"a,a\n1,x\n", {}, {}, dsv.Typed_Refusal.Expected_Integer, 6},
			{"a,a\n1,x\n", {}, {dups = .First}, i64(1), 0},
			{"a,a\n1,\n", {}, {dups = .First}, i64(1), 0},
			{"a,a,a\n1,2,3\n", {}, {}, i64(3), 0},
			{"zz,a\nx,2\n", {}, {}, i64(2), 0},
			{"a,zz\n1,x\n", {refuse_unknown = true}, {}, dsv.Typed_Refusal.Unknown_Field, 2},
		}) {
		rows: []Row
		e := read_rows(c.src, &rows, c.read, c.opts)
		switch w in c.want {
		case i64:
			testing.expectf(t, e == nil && len(rows) == 1 && rows[0].a == w, "%q: %v, %v", c.src, e, rows)
		case dsv.Typed_Refusal:
			expect_refusal(t, e, w, c.at)
		}
	}
	// A repeated header column is a fault of the build under `.Refuse`.
	rows: []Row
	e := read_rows("a,a\n1,2\n", &rows, opts = {dups = .Refuse})
	f, is_fault := e.(tape.Fault)
	testing.expectf(t, is_fault && f.kind == .Duplicate_Key, "got %v", e)
	testing.expect_value(t, f.at, 2)
}

// A text of many rows where some rows hold fewer or more cells than the header, read under `.Ragged`.
@(test)
ragged_rows_read_what_they_hold :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i64,
		b: i64,
		c: i64,
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "a,b,c\n")
	N :: 200
	for i in 0 ..< N {
		switch i % 3 {
		case 0:
			fmt.sbprintf(&b, "%d,%d,%d\n", i, i + 1, i + 2)
		case 1:
			fmt.sbprintf(&b, "%d\n", i)
		case 2:
			fmt.sbprintf(&b, "%d,%d,%d,%d\n", i, i + 1, i + 2, i + 3)
		}
	}
	rows: []Row
	e := read_rows(strings.to_string(b), &rows, opts = {tolerate = {.Ragged}})
	testing.expect_value(t, e, nil)
	if !testing.expect_value(t, len(rows), N) {
		return
	}
	for r, i in rows {
		i := i64(i)
		want := Row{i, i + 1, i + 2} if i % 3 != 1 else Row{i, 0, 0}
		testing.expectf(t, r == want, "row %d: %v, wanted %v", i, r, want)
	}
	// Without the tolerance a short row is the walk's fault, not a refusal.
	again: []Row
	e = read_rows(strings.to_string(b), &again)
	f, is_fault := e.(tape.Fault)
	testing.expectf(t, is_fault && f.kind == .Bad_Width, "got %v", e)
}

// Under `.Ragged` a wide record's cell past the header's last reads the field its 1-based position names.
@(test)
a_wide_record_names_its_cells_by_position :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a:     i64,
		three: i64 `csv:"3"`,
	}
	opts := dsv.Options{tolerate = {.Ragged}}
	rows: []Row
	testing.expect_value(t, read_rows("a,b\n1,2,3\n4\n5,6,7,8\n", &rows, opts = opts), nil)
	if !testing.expect_value(t, len(rows), 3) {
		return
	}
	testing.expect(t, rows[0] == {1, 3} && rows[1] == {4, 0} && rows[2] == {5, 7})
	// A cell no field names is refused when the read asks for it.
	e := read_rows("a\n1,2\n", &rows, {refuse_unknown = true}, opts)
	expect_refusal(t, e, .Unknown_Field, 2)
	// A header cell of that name repeats the position, so the duplicate policy decides the wide record's cell.
	src := "3,a\n1,2\n4,5,6\n"
	testing.expect_value(t, read_rows(src, &rows, opts = opts), nil)
	testing.expect(t, len(rows) == 2 && rows[0].three == 1 && rows[1].three == 6)
	first := opts
	first.dups = .First
	testing.expect_value(t, read_rows(src, &rows, opts = first), nil)
	testing.expect(t, len(rows) == 2 && rows[0].three == 1 && rows[1].three == 4)
	// A refused cell of a wide record names the position as the field.
	maps: []map[string]i64
	e = read_rows("rap\r\n1,x\r\n", &maps, opts = opts)
	expect_refusal(t, e, .Expected_Integer, 7)
}

@(test)
refusals_name_the_row_and_the_field :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i8,
		b: bool,
		c: f64,
		d: Cell_Color,
	}
	rows: []Row
	path := make([dynamic]tape.Step, context.temp_allocator)
	e := read_rows("a,b\n1,true\nx,true\n", &rows, {path = &path})
	expect_refusal(t, e, .Expected_Integer, 11)
	expect_path(t, path[:], {1, "a"})
	expect_refusal(t, read_rows("a\n128\n", &rows), .Above_Maximum, 2)
	expect_refusal(t, read_rows("a\n-129\n", &rows), .Below_Minimum, 2)
	expect_refusal(t, read_rows("b\nTrue\n", &rows), .Expected_Bool, 2)
	expect_refusal(t, read_rows("c\n1e\n", &rows), .Expected_Number, 2)
	expect_refusal(t, read_rows("c\n1e400\n", &rows), .Above_Maximum, 2)
	expect_refusal(t, read_rows("c\nNaN\n", &rows), .Expected_Number, 2)
	expect_refusal(t, read_rows("c\nInfinity\n", &rows), .Expected_Number, 2)
	expect_refusal(t, read_rows("d\nPurple\n", &rows), .Not_A_Member, 2)
	// A short row is the walk's fault, which the read gives as `validate` does.
	e = read_rows("a,b\n1\n", &rows)
	f, is_fault := e.(tape.Fault)
	testing.expectf(t, is_fault && f.kind == .Bad_Width, "got %v", e)
	testing.expect_value(t, f.at, 5)
	testing.expect_value(t, e, dsv.validate(transmute([]u8)string("a,b\n1\n"), .Csv))
}

// The refused cell of row 500 is named by its row and its column's name, however many rows came before.
@(test)
a_refused_cell_deep_in_the_text_names_its_row :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		id:    i64,
		field: i32,
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "id,field\n")
	bad := 0
	for i in 0 ..< 1000 {
		if i == 499 {
			bad = strings.builder_len(b)
			fmt.sbprintf(&b, "%d,%s\n", i, "12x")
		} else {
			fmt.sbprintf(&b, "%d,%d\n", i, i)
		}
	}
	rows: []Row
	path := make([dynamic]tape.Step, context.temp_allocator)
	e := read_rows(strings.to_string(b), &rows, {path = &path})
	expect_refusal(t, e, .Expected_Integer, u64(bad + 4))
	expect_path(t, path[:], {499, "field"})
}

@(test)
a_required_field_refuses_at_the_header_or_the_cell :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	rows: []Required_Row
	path := make([dynamic]tape.Step, context.temp_allocator)
	e := read_rows("b\nx\n", &rows, {path = &path})
	expect_refusal(t, e, .Missing_Field, 3)
	expect_path(t, path[:], {0, "a"})
	// A required column's absence is judged before the fault in the first record.
	e = read_rows("b\n\"", &rows)
	f, is_fault := e.(tape.Fault)
	testing.expectf(t, is_fault && f.kind != .Refused, "got %v", e)
	// An empty cell of a required column is absent.
	e = read_rows("b,a\nx,1\ny,\n", &rows, {path = &path})
	expect_refusal(t, e, .Missing_Field, 10)
	expect_path(t, path[:], {1, "a"})
	// In either order of the columns a present cell reads.
	testing.expect_value(t, read_rows("b,a\ny,\"2\"\n", &rows), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].a, 2)
	}
	testing.expect_value(t, read_rows("a,b\n1,2\n3,4\n", &rows), nil)
	testing.expect_value(t, len(rows), 2)
}

@(test)
list_and_map_rows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	lists: [][]string
	testing.expect_value(t, read_rows("a,b\n1,\n", &lists, opts = {format = dsv.Dsv_Options{no_header = true}}), nil)
	if testing.expect_value(t, len(lists), 2) {
		testing.expect_value(t, lists[0][1], "b")
		testing.expect_value(t, lists[1][1], "")
	}
	maybes: [][]Maybe(i32)
	testing.expect_value(t, read_rows("1,\n", &maybes, opts = {format = dsv.Dsv_Options{no_header = true}}), nil)
	if testing.expect_value(t, len(maybes), 1) && testing.expect_value(t, len(maybes[0]), 2) {
		_, some := maybes[0][1].?
		testing.expect(t, !some)
	}
	maps: []map[string]string
	testing.expect_value(t, read_rows("a,\"b\"\"\"\n1,\n", &maps), nil)
	if testing.expect_value(t, len(maps), 1) {
		testing.expect_value(t, maps[0]["a"], "1")
		_, has := maps[0][`b"`]
		testing.expect(t, !has)
	}
	ints: []map[string]i64
	path := make([dynamic]tape.Step, context.temp_allocator)
	e := read_rows("\"a\"\nx\n", &ints, {path = &path})
	expect_refusal(t, e, .Expected_Integer, 4)
	expect_path(t, path[:], {0, "a"})
}

@(test)
the_specs_spell_their_cells :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: string,
		b: i64,
	}
	rows: []Row
	testing.expect_value(t, read_rows("a\tb\nx\\ty\t1\n", &rows, spec = .Tsv), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].a, "x\ty")
	}
	testing.expect_value(t, read_rows("a,b\n\"x\",1\n", &rows, spec = .Plain), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].a, `"x"`)
	}
	// A delimiter of the options takes the place of the spec's.
	testing.expect_value(t, read_rows("a;b\nx;2\n", &rows, opts = {format = dsv.Dsv_Options{delimiter = ';'}}), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], Row{"x", 2})
	}
}

@(test)
no_header_reads_each_record_as_a_list :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	no_header := dsv.Options{format = dsv.Dsv_Options{no_header = true}}
	lists: [][]i64
	testing.expect_value(t, read_rows("1,2\n3,4\n", &lists, opts = no_header), nil)
	if testing.expect_value(t, len(lists), 2) {
		testing.expect_value(t, lists[1][0], 3)
		testing.expect_value(t, lists[1][1], 4)
	}
	// A record is an array, which a struct reads by position and a map does not take.
	Row :: struct {
		a: i64,
		b: string,
		c: i64 `csv:",required"`,
	}
	rows: []Row
	testing.expect_value(t, read_rows("1,x,3,z\n2,y,4,w\n", &rows, opts = no_header), nil)
	if testing.expect_value(t, len(rows), 2) {
		testing.expect_value(t, rows[0], Row{1, "x", 3})
		testing.expect_value(t, rows[1], Row{2, "y", 4})
	}
	expect_refusal(t, read_rows("1,x\n", &rows, opts = no_header), .Missing_Field, 3)
	maps: []map[string]i64
	expect_refusal(t, read_rows("1\n", &maps, opts = no_header), .Expected_Object, 0)
}

// A list of rows that are lists reads every record, the header's line as the first, and a target that is one row reads
// the first record and refuses a second.
@(test)
the_header_is_a_list_rows_first_and_one_row_takes_one_record :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	lists: [][]string
	testing.expect_value(t, read_rows("a,b\n1,\n", &lists), nil)
	if testing.expect_value(t, len(lists), 2) {
		testing.expect_value(t, lists[0][1], "b")
		testing.expect_value(t, lists[1][0], "1")
	}
	fixed: [][2]string
	testing.expect_value(t, read_rows("a,b\n1,2\n", &fixed), nil)
	testing.expect(t, len(fixed) == 2 && fixed[0] == {"a", "b"} && fixed[1] == {"1", "2"})
	Row :: struct {
		a: i64,
		b: string,
	}
	row := Row{7, "kept"}
	testing.expect_value(t, read_rows("a\n", &row), nil)
	testing.expect_value(t, row, Row{7, "kept"})
	testing.expect_value(t, read_rows("b,a\nx,1\n", &row), nil)
	testing.expect_value(t, row, Row{1, "x"})
	expect_refusal(t, read_rows("a,b\n1,x\n2,y\n", &row), .Too_Many, 8)
	testing.expect_value(t, read_rows("1,x\n", &row, opts = {format = dsv.Dsv_Options{no_header = true}}), nil)
	testing.expect_value(t, row, Row{1, "x"})
	m: map[string]string
	testing.expect_value(t, read_rows("a,b\n1,x\n", &m), nil)
	testing.expect(t, len(m) == 2 && m["a"] == "1" && m["b"] == "x")
}

// A text with no record is an empty list, a header alone too.
@(test)
a_text_with_no_record_empties_the_target :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i64,
	}
	rows := []Row{{1}}
	testing.expect_value(t, read_rows("", &rows), nil)
	testing.expect_value(t, len(rows), 0)
	rows = []Row{{1}}
	testing.expect_value(t, read_rows("a\n", &rows), nil)
	testing.expect_value(t, len(rows), 0)
}

// An unquoted empty cell is absent whatever holds it, so a map has no entry for it and a required column refuses it.
@(test)
an_absent_cell_leaves_no_entry_and_fails_a_required_column :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	maps: []map[string]i64
	testing.expect_value(t, read_rows("a,b\n1,\n,2\n", &maps), nil)
	if testing.expect_value(t, len(maps), 2) {
		_, has_b := maps[0]["b"]
		_, has_a := maps[1]["a"]
		testing.expect(t, !has_b, "an empty cell of the first row")
		testing.expect(t, !has_a, "an empty cell of the second row")
	}
	rows: []Required_Row
	path := make([dynamic]tape.Step, context.temp_allocator)
	e := read_rows("b,a\nx,\ny,1\n", &rows, {path = &path})
	expect_refusal(t, e, .Missing_Field, 6)
	expect_path(t, path[:], {0, "a"})
	e = read_rows("a,b\n1,x\n,y\n", &rows, {path = &path})
	expect_refusal(t, e, .Missing_Field, 8)
	expect_path(t, path[:], {1, "a"})
}

@(test)
a_plan_refuses_a_type_no_text_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Nested :: struct {
		a: []int,
	}
	_, e := dsv.plan_make(int, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil) // a plan of any type that v2 reads, the records' type is judged by the read
	rows: []Nested
	e = read_rows("a\n1\n", &rows)
	testing.expectf(t, e != nil, "a list member reads from one cell: %v", e)
	nested: [][]Nested
	e = read_rows("1\n", &nested, opts = {format = dsv.Dsv_Options{no_header = true}})
	testing.expectf(t, e != nil, "a list of lists of structs: %v", e)
}

// A refused read's list stays reachable from the target, so freeing the target frees all of it.
@(test)
a_refusal_leaves_what_it_allocated_with_the_target :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Row :: struct {
		name: string,
		n:    i64,
	}
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	alloc := mem.tracking_allocator(&tracker)
	rows: []Row
	src := "name,n\n\"a\"\"b\",1\ncopy,2\nz,x\n"
	e := dsv.unmarshal(transmute([]u8)src, &rows, .Csv, allocator = alloc)
	expect_refusal(t, e, .Expected_Integer, u64(len(src) - 2))
	for r in rows {
		delete(r.name, alloc)
	}
	delete(rows, alloc)
	testing.expect_value(t, len(tracker.allocation_map), 0)
	// A cell a wide record names by its position is refused past the rows before it.
	rows = nil
	src = "name,n\ncopy,1\nz,2,x\n"
	e = dsv.unmarshal(transmute([]u8)src, &rows, .Csv, {refuse_unknown = true}, {tolerate = {.Ragged}}, alloc)
	_, is_fault := e.(tape.Fault)
	testing.expect(t, is_fault)
	for r in rows {
		delete(r.name, alloc)
	}
	delete(rows, alloc)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}

// A copied empty cell is the zero string, so a caller deleting each string frees nothing of the text, the last cell
// of an unterminated text too.
@(test)
copied_empty_cells_are_the_zero_string :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Row :: struct {
		a, b: string,
	}
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	alloc := mem.tracking_allocator(&tracker)
	rows: []Row
	testing.expect_value(t, dsv.unmarshal(transmute([]u8)string("a,b\n,x\ny,"), &rows, .Csv, allocator = alloc), nil)
	if testing.expect_value(t, len(rows), 2) {
		testing.expect(t, raw_data(rows[0].a) == nil && raw_data(rows[1].b) == nil)
	}
	for r in rows {
		delete(r.a, alloc)
		delete(r.b, alloc)
	}
	delete(rows, alloc)
	testing.expect_value(t, len(tracker.bad_free_array), 0)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}

// A repeated column under `.Last` frees the cell it replaces, in every record, borrowed or copied.
@(test)
a_repeated_column_frees_what_it_replaces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Row :: struct {
		s: string,
	}
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	alloc := mem.tracking_allocator(&tracker)
	src := "s,n,s\n\"a\"\"b\",1,\"c\"\"d\"\nplain,2,\"e\"\"f\"\n\"g\"\"h\",3,last\n"
	for borrow in ([]bool{false, true}) {
		rows: []Row
		testing.expect_value(t, dsv.unmarshal(transmute([]u8)src, &rows, .Csv, {borrow_strings = borrow}, allocator = alloc), nil)
		if testing.expect_value(t, len(rows), 3) {
			testing.expect_value(t, rows[0].s, `c"d`)
			testing.expect_value(t, rows[2].s, "last")
		}
		for r in rows {
			if !borrow || r.s != "last" {
				delete(r.s, alloc)
			}
		}
		delete(rows, alloc)
		testing.expectf(t, len(tracker.allocation_map) == 0, "borrow %v: %d blocks live", borrow, len(tracker.allocation_map))
	}
}

@(test)
a_made_plan_reads_the_rows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a, b: i32,
	}
	plan, err := dsv.plan_make([]Row, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	rows: []Row
	e := read_rows("a,b\n1,2\n", &rows, {plan = &plan})
	testing.expect_value(t, e, nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0], Row{1, 2})
	}
	// A plan of another type is refused.
	other: []Cell_Row
	e = read_rows("id\n1\n", &other, {plan = &plan})
	_, bad := e.(tape.Bad_Option)
	testing.expectf(t, bad, "got %v", e)
	dsv.plan_destroy(&plan)
}

@(test)
a_repeated_header_reads_as_last_by_default :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i32,
	}
	d, l: []Row
	testing.expect_value(t, read_rows("a,a\n1,2\n", &d), nil)
	testing.expect_value(t, read_rows("a,a\n1,2\n", &l, opts = {dups = .Last}), nil)
	if testing.expect_value(t, len(d), 1) && testing.expect_value(t, len(l), 1) {
		testing.expect_value(t, d[0].a, 2)
		testing.expect_value(t, l[0].a, d[0].a)
	}
}

// The typed read law over random delimited texts: a read into a `testkit.Value` is what the build converts
// to, an empty cell, which the build holds as null, absent, and a text the build refuses is refused
// alike.
@(test)
unmarshal_agrees_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7ed)
	read_value :: proc(f: ^tape.Format, src: []u8, v: ^testkit.Value, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error {
		spec: dsv.Spec
		for s in dsv.Spec {
			if dsv.as(s) == f {
				spec = s
			}
		}
		return dsv.unmarshal(src, v, spec, opts = opts, allocator = allocator)
	}
	a: testkit.Typed_Agreement
	for _ in 0 ..< testkit.rounds(400) {
		src, spec, opts := random_text(rand.int_max(2) == 0)
		testkit.unmarshal_agrees(t, dsv.reads(spec), dsv.as(spec), read_value, src, opts, "generated", &a, nulls_absent = true)
	}
	testing.expectf(t, a.read > 100 && a.refused > 20, "%v", a)
}
