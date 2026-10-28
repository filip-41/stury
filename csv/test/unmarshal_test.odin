package csv_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import csv "../"

Color :: enum u8 {
	Red,
	Green,
	Blue = 7,
}

Row :: struct {
	id:    i64,
	small: i8,
	name:  string `csv:"full name"`,
	ok:    bool,
	score: f64,
	ratio: f32,
	color: Color,
	note:  Maybe(int),
	r:     rune,
	big:   u128,
	skip:  int `csv:"-"`,
}

// `unmarshal`, also checking that `unmarshal_check` of the same text gives the same answer.
read :: proc(t: ^testing.T, src: string, out: ^$T, opts := csv.Unmarshal_Opts{}, loc := #caller_location) -> Maybe(csv.Unmarshal_Error) {
	err := csv.unmarshal(transmute([]byte)src, out, opts, allocator = context.temp_allocator)
	expect_check_agrees(t, transmute([]byte)src, T, opts, err, loc)
	return err
}

expect_check_agrees :: proc(t: ^testing.T, src: []byte, $T: typeid, opts: csv.Unmarshal_Opts, want: Maybe(csv.Unmarshal_Error), loc := #caller_location) {
	got := csv.unmarshal_check(src, T, opts)
	testing.expectf(t, fmt.tprintf("%v", got) == fmt.tprintf("%v", want), "%q: unmarshal_check %v, unmarshal %v", string(src), got, want, loc = loc)
}

@(test)
test_unmarshal_rows :: proc(t: ^testing.T) {
	src := "id,small,full name,ok,score,ratio,color,note,r,big\n" +
		"1,-128,\"Ann \"\"A\"\"\",true,1.5,0.1,Green,,é,340282366920938463463374607431768211455\r\n" +
		"+2,127,Bob,false,-2e3,3,Blue,5,\"\"\"\",0\n"
	rows: []Row
	testing.expect_value(t, read(t, src, &rows), nil)
	if !testing.expect_value(t, len(rows), 2) {
		return
	}
	testing.expect_value(t, rows[0].id, 1)
	testing.expect_value(t, rows[0].small, -128)
	testing.expect_value(t, rows[0].name, `Ann "A"`)
	testing.expect_value(t, rows[0].ok, true)
	testing.expect_value(t, rows[0].score, 1.5)
	testing.expect_value(t, rows[0].ratio, f32(0.1))
	testing.expect_value(t, rows[0].color, Color.Green)
	testing.expect_value(t, rows[0].note, nil)
	testing.expect_value(t, rows[0].r, 'é')
	testing.expect_value(t, rows[0].big, max(u128))
	testing.expect_value(t, rows[1].id, 2)
	testing.expect_value(t, rows[1].name, "Bob")
	testing.expect_value(t, rows[1].score, -2000)
	testing.expect_value(t, rows[1].color, Color.Blue)
	testing.expect_value(t, rows[1].note, 5)
	testing.expect_value(t, rows[1].r, '"')
}

// An f64 cell is the correctly rounded projection, not the exactness `get_float` asks for: an underflow and a
// rounding are values, and only a number with no binary64 is out of range.
Um_Score :: struct {
	score: f64,
}

@(test)
test_unmarshal_float_projection :: proc(t: ^testing.T) {
	rows: []Um_Score
	testing.expect_value(t, read(t, "score\n1e-400\n", &rows), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].score, 0)
	}
	rows = nil
	testing.expect_value(t, read(t, "score\n0.1\n", &rows), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect_value(t, rows[0].score, 0.1)
	}
	// An underflow keeps its sign: `-1e-400` is -0.
	rows = nil
	testing.expect_value(t, read(t, "score\n-1e-400\n", &rows), nil)
	if testing.expect_value(t, len(rows), 1) {
		testing.expect(t, rows[0].score == 0 && transmute(u64)rows[0].score >> 63 == 1)
	}
	err := read(t, "score\n1e400\n", &rows)
	e, refused := err.?
	testing.expect(t, refused && e.kind == .Out_Of_Range && e.offset == 6)
}

Refusal :: struct {
	src:  string,
	kind: csv.Unmarshal_Error_Kind,
	at:   u64,
	path: string,
}

@(test)
test_unmarshal_refusals :: proc(t: ^testing.T) {
	cases := []Refusal {
		{"id\nabc\n", .Wrong_Kind, 3, "[0].id"},
		{"small\n300\n", .Out_Of_Range, 6, "[0].small"},
		{"small\n-129\n", .Out_Of_Range, 6, "[0].small"},
		{"id\n99999999999999999999\n", .Out_Of_Range, 3, "[0].id"},
		{"id\n18446744073709551616\n", .Out_Of_Range, 3, "[0].id"},
		{"big\n340282366920938463463374607431768211456\n", .Out_Of_Range, 4, "[0].big"},
		{"id\n+\n", .Wrong_Kind, 3, "[0].id"},
		{"id\n-\n", .Wrong_Kind, 3, "[0].id"},
		{"id\n12345678x\n", .Wrong_Kind, 3, "[0].id"},
		{"id\n1234567890123456789x\n", .Wrong_Kind, 3, "[0].id"},
		{"id\n\"\"\n", .Wrong_Kind, 3, "[0].id"},
		{"id\n 1\n", .Wrong_Kind, 3, "[0].id"},
		{"ok\nyes\n", .Wrong_Kind, 3, "[0].ok"},
		{"score\n.\n", .Wrong_Kind, 6, "[0].score"},
		{"score\n-.e1\n", .Wrong_Kind, 6, "[0].score"},
		{"score\n1e\n", .Wrong_Kind, 6, "[0].score"},
		{"score\nnan\n", .Wrong_Kind, 6, "[0].score"},
		{"score\n1e400\n", .Out_Of_Range, 6, "[0].score"},
		{"ratio\n1e39\n", .Out_Of_Range, 6, "[0].ratio"},
		{"color\nPurple\n", .Not_A_Member, 6, "[0].color"},
		{"r\nab\n", .Wrong_Kind, 2, "[0].r"},
		{"note\nx\n", .Wrong_Kind, 5, "[0].note"},
		{"id\n1\n2\nx\n", .Wrong_Kind, 7, "[2].id"},
		{"id\n1\n\"2\n", .Syntax, 8, "[1]"},
		{"id,ok\n1,true\n2\n", .Syntax, 13, "[1]"},
	}
	for c in cases {
		rows: [dynamic]Row
		err := read(t, c.src, &rows)
		e, refused := err.?
		if !testing.expectf(t, refused, "%q: accepted", c.src) {
			continue
		}
		testing.expectf(t, e.kind == c.kind && e.offset == c.at, "%q: %v at %d, want %v at %d", c.src, e.kind, e.offset, c.kind, c.at)
		testing.expectf(t, path_text(e) == c.path, "%q: path %q, want %q", c.src, path_text(e), c.path)
	}
}

Strict :: struct {
	id:   int `csv:",required"`,
	name: string,
}

@(test)
test_unmarshal_columns :: proc(t: ^testing.T) {
	{
		rows: []Strict
		err := read(t, "name,extra\nx,y\n", &rows)
		testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Missing_Field)
		testing.expect_value(t, path_text(err.?), ".id")
	}
	{
		rows: []Strict
		err := read(t, "id,name\n1,a\n,b\n", &rows)
		testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Missing_Field)
		testing.expect_value(t, err.?.offset, 12)
		testing.expect_value(t, path_text(err.?), "[1].id")
		testing.expect_value(t, len(rows), 2)
	}
	{
		rows: []Strict
		err := read(t, "id,name,extra\n1,a,b\n", &rows, {unknown_fields = .Refuse})
		testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Unknown_Field)
		testing.expect_value(t, path_text(err.?), ".extra")
		testing.expect(t, rows == nil, "a header refusal leaves the destination")
	}
	{
		rows: []Strict
		testing.expect_value(t, read(t, "id,name,extra\n1,a,b\n", &rows), nil)
		testing.expect_value(t, len(rows), 1)
	}
	{
		rows: []Strict
		testing.expect_value(t, read(t, "7;x\n8;y", &rows, {no_header = true, dialect = {delimiter = ';'}}), nil)
		testing.expect_value(t, len(rows), 2)
		testing.expect_value(t, rows[1], Strict{8, "y"})
	}
	{
		rows: []Strict
		testing.expect_value(t, read(t, "", &rows), nil)
		testing.expect_value(t, len(rows), 0)
	}
}

@(test)
test_unmarshal_bare_points :: proc(t: ^testing.T) {
	rows: []struct {
		score: f64,
	}
	testing.expect_value(t, read(t, "score\n.5\n1.\n-.25e2\n", &rows), nil)
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, rows[0].score, 0.5)
	testing.expect_value(t, rows[1].score, 1)
	testing.expect_value(t, rows[2].score, -25)
}

@(test)
test_unmarshal_borrow :: proc(t: ^testing.T) {
	src := "name\nplain\n\"q\"\"d\"\n"
	rows: []struct {
		name: string,
	}
	testing.expect_value(t, read(t, src, &rows, {borrow_strings = true}), nil)
	testing.expect(t, raw_data(rows[0].name) == raw_data(src[5:]))
	testing.expect_value(t, rows[1].name, `q"d`)
}

Nested :: struct {
	id:   int,
	list: []int,
}

@(test)
test_unmarshal_unsupported :: proc(t: ^testing.T) {
	rows: []Nested
	err := read(t, "id,list\n1,2\n", &rows)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Unsupported)
	testing.expect_value(t, path_text(err.?), "[].list")
	testing.expect(t, rows == nil)
	plain: []int
	testing.expect_value(t, read(t, "1\n", &plain).?.kind, csv.Unmarshal_Error_Kind.Unsupported)
}

@(test)
test_unmarshal_enum_ints :: proc(t: ^testing.T) {
	plan := csv.type_plan_init([]Row, {enums = .Int})
	defer csv.destroy(&plan)
	rows: []Row
	src := "color\n7\n1\n"
	testing.expect_value(t, csv.unmarshal(transmute([]byte)src, &rows, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, rows[0].color, Color.Blue)
	testing.expect_value(t, rows[1].color, Color.Green)
	src = "color\n263\n"
	testing.expect_value(t, csv.unmarshal(transmute([]byte)src, &rows, plan = &plan, allocator = context.temp_allocator).?.kind, csv.Unmarshal_Error_Kind.Out_Of_Range)
}

// A cstring ends at a NUL, so a cell holding one is `.Out_Of_Range`, as JSON refuses `\u0000`.
@(test)
test_unmarshal_cstring_nul :: proc(t: ^testing.T) {
	Named :: struct {
		name: cstring,
	}
	rows: []Named
	tsv := csv.Unmarshal_Opts{dialect = csv.TSV}
	testing.expect_value(t, read(t, "name\na\\0b\n", &rows, tsv).?.kind, csv.Unmarshal_Error_Kind.Out_Of_Range)
	testing.expect_value(t, read(t, "name\n\"a\x00b\"\n", &rows).?.kind, csv.Unmarshal_Error_Kind.Out_Of_Range)
	if testing.expect_value(t, read(t, "name\na\\\\0b\n", &rows, tsv), nil) {
		testing.expect_value(t, string(rows[0].name), `a\0b`)
	}
}

// A run with an arena leaks nothing outside it.
@(test)
test_unmarshal_arena :: proc(t: ^testing.T) {
	buf: [4096]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	rows: []Strict
	src := "id,name\n1,\"a\"\"b\"\n"
	testing.expect_value(t, csv.unmarshal(transmute([]byte)src, &rows, allocator = mem.arena_allocator(&arena)), nil)
	testing.expect_value(t, rows[0].name, `a"b`)
}

path_text :: proc(e: csv.Unmarshal_Error) -> string {
	e := e
	b := strings.builder_make(context.temp_allocator)
	for s in e.steps[:e.n_steps] {
		switch v in s {
		case csv.Name:
			fmt.sbprintf(&b, ".%s", string(v))
		case csv.Index:
			fmt.sbprintf(&b, "[%d]", i64(v))
		case csv.Any:
			strings.write_string(&b, "[]")
		}
	}
	return strings.to_string(b)
}

// A list row reads every record, the first too, one element per cell: an absent cell is the zero value, or nil
// in a `Maybe`. A refused cell's path is `[row][cell]`.
@(test)
test_unmarshal_list_rows :: proc(t: ^testing.T) {
	src := "a,b\n1,\n\"x\"\"y\",\"\"\n"
	rows: [][]string
	testing.expect(t, read(t, src, &rows) == nil)
	testing.expect_value(t, fmt.tprint(rows), `[["a", "b"], ["1", ""], ["x\"y", ""]]`)
	maybes: [dynamic][dynamic]Maybe(string)
	testing.expect(t, read(t, src, &maybes, {no_header = true}) == nil)
	testing.expect_value(t, fmt.tprint(maybes), `[["a", "b"], ["1", nil], ["x\"y", ""]]`)
	ragged: [][]int
	testing.expect(t, read(t, "1\n2,3\n", &ragged, {dialect = {ragged = true}}) == nil)
	testing.expect_value(t, fmt.tprint(ragged), "[[1], [2, 3]]")
	err := read(t, "1,2\n3,x\n", &ragged)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, path_text(err.?), "[1][1]")
	// Under `.Lazy` every cell of a list row is read, so each is judged.
	err = read(t, "a,\xff\n", &rows, {strictness = .Lazy})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Syntax)
	testing.expect_value(t, path_text(err.?), "[0]")
	nested: [][][]int
	err = read(t, "1\n", &nested)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Unsupported)
	testing.expect_value(t, path_text(err.?), "[][]")
	testing.expect(t, nested == nil)
}

// A map row's keys are the header's decoded names; an absent cell is no entry. A repeated name is read as
// `duplicates` says, a ragged record's extra cells are unknown, and there is no map row without a header.
@(test)
test_unmarshal_map_rows :: proc(t: ^testing.T) {
	rows: []map[string]string
	testing.expect(t, read(t, "a,b\n1,\n,\"\"\n", &rows) == nil)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, len(rows[0]), 1)
	testing.expect_value(t, rows[0]["a"], "1")
	testing.expect_value(t, len(rows[1]), 1)
	b, has_b := rows[1]["b"]
	testing.expect(t, has_b && b == "")
	testing.expect(t, read(t, "x\\ty\n1\n", &rows, {dialect = csv.TSV}) == nil)
	testing.expect_value(t, rows[0]["x\ty"], "1")
	Dup :: struct {
		duplicates: csv.Duplicates,
		src, want:  string,
	}
	for c in ([]Dup{{.Default, "a,a\n1,2\n", "2"}, {.First, "a,a\n1,2\n", "1"}, {.All, "a,a\n1,\n", "1"}, {.All, "a,a\n1,2\n", "2"}}) {
		testing.expect(t, read(t, c.src, &rows, {duplicates = c.duplicates}) == nil)
		testing.expect_value(t, rows[0]["a"], c.want)
	}
	err := read(t, "a,a\n1,2\n", &rows, {duplicates = .Refuse})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Duplicate_Key)
	testing.expect_value(t, path_text(err.?), ".a")
	testing.expect(t, read(t, "a\n1,2\n", &rows, {dialect = {ragged = true}}) == nil)
	testing.expect_value(t, len(rows[0]), 1)
	err = read(t, "a\n1,2\n", &rows, {dialect = {ragged = true}, unknown_fields = .Refuse})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Unknown_Field)
	testing.expect_value(t, read(t, "a\n1\n", &rows, {no_header = true}).?.kind, csv.Unmarshal_Error_Kind.Unsupported)
	ints: [dynamic]map[string]Maybe(int)
	err = read(t, "a,b\n1,\n2,x\n", &ints)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, path_text(err.?), "[1].b")
	testing.expect_value(t, fmt.tprint(ints[0]), "map[a=1]")
	by_int: []map[int]string
	testing.expect_value(t, read(t, "1\n2\n", &by_int).?.kind, csv.Unmarshal_Error_Kind.Unsupported)
}

// A refused read leaves its partial rows in the allocator the caller gave, and keeps none of its own scratch:
// an arena freed whole after the refusal leaves nothing allocated, for every row shape and strictness.
@(test)
test_unmarshal_refused_leaks_nothing :: proc(t: ^testing.T) {
	Row :: struct {
		name: string,
		n:    int,
	}
	src := transmute([]byte)string("name,n\n\"a\"\"b\",1\nc,bad\n")
	refused :: proc(t: ^testing.T, src: []byte, $T: typeid, strictness: csv.Strictness) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			plan := csv.type_plan_init(T)
			arena: mem.Dynamic_Arena
			mem.dynamic_arena_init(&arena)
			rows: T
			err := csv.unmarshal(src, &rows, {strictness = strictness}, &plan, mem.dynamic_arena_allocator(&arena))
			testing.expectf(t, err != nil && err.?.kind == .Wrong_Kind, "%v %v: %v", typeid_of(T), strictness, err)
			mem.dynamic_arena_destroy(&arena)
			csv.destroy(&plan)
		}
		testing.expectf(t, len(track.allocation_map) == 0, "%v %v: %d allocations left", typeid_of(T), strictness, len(track.allocation_map))
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
	for strictness in ([]csv.Strictness{.Strict, .Lazy}) {
		refused(t, src, []Row, strictness)
		refused(t, src, [dynamic][]int, strictness)
		refused(t, src, []map[string]int, strictness)
	}
}
