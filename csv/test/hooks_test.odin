package csv_tests

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import csv "../"

Date :: struct {
	year, month, day: int,
}

date_write :: proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
	d := (^Date)(v)^
	return csv.marshal_into(out, fmt.tprintf("%04d-%02d-%02d", d.year, d.month, d.day))
}

date_read :: proc(v: csv.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
	parts := strings.split(v.decoded, "-", context.temp_allocator)
	if len(parts) != 3 {
		return .Wrong_Kind
	}
	y, ok1 := strconv.parse_int(parts[0])
	m, ok2 := strconv.parse_int(parts[1])
	d, ok3 := strconv.parse_int(parts[2])
	if !ok1 || !ok2 || !ok3 {
		return .Wrong_Kind
	}
	if m < 1 || m > 12 {
		return .Out_Of_Range
	}
	(^Date)(dest)^ = {y, m, d}
	return nil
}

Event :: struct {
	when_: Date `csv:"when"`,
	name:  string,
	until: Maybe(Date),
}

date_hooks :: []csv.Type_Hook{{type = Date, write = date_write, read = date_read}}

@(test)
test_hook_struct_cell :: proc(t: ^testing.T) {
	plan := csv.type_plan_init([]Event, {hooks = date_hooks})
	defer csv.destroy(&plan)
	src := "when,name,until\n2026-10-23,a,\n2027-01-02,\"b, \"\"c\"\"\",2028-03-04\n"
	events: []Event
	testing.expect_value(t, csv.unmarshal(transmute([]byte)src, &events, plan = &plan, allocator = context.temp_allocator), nil)
	if !testing.expect_value(t, len(events), 2) {
		return
	}
	testing.expect_value(t, events[0], Event{when_ = {2026, 10, 23}, name = "a"})
	testing.expect_value(t, events[1], Event{when_ = {2027, 1, 2}, name = `b, "c"`, until = Date{2028, 3, 4}})

	out, err := csv.marshal(events, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), src)
}

// A hook on a type the plan reads itself replaces the plan's reading in every field of that type.
@(test)
test_hook_overrides_scalar :: proc(t: ^testing.T) {
	Flags :: struct {
		a, b: bool,
		n:    int,
	}
	yes_no := []csv.Type_Hook {
		{
			type = bool,
			write = proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
				return csv.marshal_into(out, "yes" if (^bool)(v)^ else "no")
			},
			read = proc(v: csv.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
				switch v.decoded {
				case "yes":
					(^bool)(dest)^ = true
				case "no":
					(^bool)(dest)^ = false
				case:
					return .Wrong_Kind
				}
				return nil
			},
		},
	}
	plan := csv.type_plan_init([]Flags, {hooks = yes_no})
	defer csv.destroy(&plan)
	rows: []Flags
	src := "a,b,n\nyes,no,3\n"
	testing.expect_value(t, csv.unmarshal(transmute([]byte)src, &rows, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, rows[0], Flags{true, false, 3})
	out, _ := csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), src)

	bad := "a,b,n\ntrue,no,3\n"
	err := csv.unmarshal(transmute([]byte)bad, &rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	// The default plan still reads `true`.
	testing.expect_value(t, csv.unmarshal(transmute([]byte)bad, &rows, allocator = context.temp_allocator).?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	ok := "a,b,n\ntrue,false,3\n"
	testing.expect_value(t, csv.unmarshal(transmute([]byte)ok, &rows, allocator = context.temp_allocator), nil)
}

@(test)
test_hook_refusals :: proc(t: ^testing.T) {
	plan := csv.type_plan_init([]Event, {hooks = date_hooks})
	defer csv.destroy(&plan)
	cases := []Refusal {
		{"when\n2026-10-23\nnot a date\n", .Wrong_Kind, 16, "[1].when"},
		{"name,when\nx,2026-13-01\n", .Out_Of_Range, 12, "[0].when"},
		{"when,until\n2026-10-23,2026\n", .Wrong_Kind, 22, "[0].until"},
		// A quoted empty cell is present and the hook reads "". An absent cell is not read.
		{"when\n\"\"\n", .Wrong_Kind, 5, "[0].when"},
	}
	for c in cases {
		events: []Event
		err := csv.unmarshal(transmute([]byte)c.src, &events, plan = &plan, allocator = context.temp_allocator)
		e, refused := err.?
		if !testing.expectf(t, refused, "%q: accepted", c.src) {
			continue
		}
		testing.expectf(t, e.kind == c.kind && e.offset == c.at, "%q: %v at %d, want %v at %d", c.src, e.kind, e.offset, c.kind, c.at)
		testing.expectf(t, path_text(e) == c.path, "%q: path %q, want %q", c.src, path_text(e), c.path)
	}
	events: []Event
	absent := "when,name\n,x\n"
	testing.expect_value(t, csv.unmarshal(transmute([]byte)absent, &events, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, events[0].when_, Date{})

	// A write-only hook cannot be read, and a read-only hook cannot be written.
	write_only := csv.type_plan_init([]Event, {hooks = {{type = Date, write = date_write}}})
	defer csv.destroy(&write_only)
	src := "when\n2026-10-23\n"
	err := csv.unmarshal(transmute([]byte)src, &events, plan = &write_only, allocator = context.temp_allocator)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Unsupported)
	_, merr := csv.marshal(events, plan = &write_only, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(merr), csv.Marshal_Error_Kind.None)
	read_only := csv.type_plan_init([]Event, {hooks = {{type = Date, read = date_read}}})
	defer csv.destroy(&read_only)
	_, merr = csv.marshal(events, plan = &read_only, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(merr), csv.Marshal_Error_Kind.Unsupported)
}

Tagged :: struct {
	text: Raw_Text,
	n:    int,
}

// A type whose hook writes `text`.
Raw_Text :: distinct string

raw_text_plan :: proc(text: string) -> (plan: csv.Type_Plan, rows: []Tagged) {
	hooks := []csv.Type_Hook {
		{
			type = Raw_Text,
			write = proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
				return csv.marshal_into(out, string((^Raw_Text)(v)^))
			},
			read = proc(v: csv.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
				(^Raw_Text)(dest)^ = Raw_Text(v.decoded)
				return nil
			},
		},
	}
	rows = make([]Tagged, 1, context.temp_allocator)
	rows[0] = {Raw_Text(text), 1}
	return csv.type_plan_init([]Tagged, {hooks = hooks}), rows
}

// The text a write hook makes is quoted or escaped as a string is.
@(test)
test_hook_write_quoting :: proc(t: ^testing.T) {
	plan, rows := raw_text_plan("a,b\"c\nd")
	defer csv.destroy(&plan)
	out, err := csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), "text,n\n\"a,b\"\"c\nd\",1\n")
	back: []Tagged
	testing.expect_value(t, csv.unmarshal(out, &back, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, back[0], rows[0])

	rows[0].text = "x\ty\\z\nw"
	out, err = csv.marshal(rows, {dialect = csv.TSV}, &plan, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), "text\tn\nx\\ty\\\\z\\nw\t1\n")
	testing.expect_value(t, csv.unmarshal(out, &back, {dialect = csv.TSV}, &plan, context.temp_allocator), nil)
	testing.expect_value(t, back[0], rows[0])

	// A dialect with no quotes and no escapes cannot spell the newline.
	_, err = csv.marshal(rows, {dialect = {delimiter = ';', quoting = .None}}, &plan, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Unwritable)

	rows[0].text = "\xff"
	_, err = csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Bad_Utf8)

	// An empty text is an empty string, `""`, where cells are quoted.
	rows[0].text = ""
	out, _ = csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "text,n\n\"\",1\n")
}

// A hook's own refusal is `marshal`'s, and nothing is kept.
@(test)
test_hook_write_refusal :: proc(t: ^testing.T) {
	refuse := []csv.Type_Hook {
		{
			type = Date,
			write = proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
				return .Non_Finite if (^Date)(v).month == 0 else date_write(out, v)
			},
		},
	}
	plan := csv.type_plan_init([]Event, {hooks = refuse})
	defer csv.destroy(&plan)
	events := []Event{{when_ = {2026, 1, 1}}, {}}
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect_value(t, marshal_kind(csv.marshal_append(&out, events, plan = &plan)), csv.Marshal_Error_Kind.Non_Finite)
	testing.expect_value(t, len(out), 0)
}

// A write hook writes one cell through `marshal_into`: a number as its spelling, a string quoted as any string.
// None, or a second, is `.Bad_State`.
@(test)
test_hook_writes_one_cell :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Row :: struct {
		d: Date,
	}
	as_number := []csv.Type_Hook{{type = Date, write = proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
		d := (^Date)(v)^
		return csv.marshal_into(out, d.year * 10000 + d.month * 100 + d.day)
	}}}
	plan := csv.type_plan_init([]Row, {hooks = as_number})
	defer csv.destroy(&plan)
	text, err := csv.marshal([]Row{{{2026, 10, 27}}}, plan = &plan, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(text), "d\n20261027\n")

	as_text := []csv.Type_Hook{{type = Date, write = proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
		return csv.marshal_into(out, "a,b")
	}}}
	quoted := csv.type_plan_init([]Row, {hooks = as_text})
	defer csv.destroy(&quoted)
	text, err = csv.marshal([]Row{{}}, plan = &quoted, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(text), "d\n\"a,b\"\n")

	writes := [?]csv.Marshal_Hook{
		proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {return .None},
		proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
			csv.marshal_into(out, 1) or_return
			return csv.marshal_into(out, 2)
		},
	}
	for write in writes {
		bad := csv.type_plan_init([]Row, {hooks = []csv.Type_Hook{{type = Date, write = write}}})
		defer csv.destroy(&bad)
		out := make([dynamic]u8, context.temp_allocator)
		testing.expect_value(t, marshal_kind(csv.marshal_append(&out, []Row{{}}, plan = &bad)), csv.Marshal_Error_Kind.Bad_State)
	}
}

// A type the plan first meets inside a hook: compiling it then appends enough ops, fields and keys to move every
// plan array the writer is walking. The plans are made in the heap allocator, whose frees the address sanitizer
// sees: the test runner's allocator frees nothing.
Hook_Part :: struct {
	f00, f01, f02, f03, f04, f05, f06, f07, f08, f09, f10, f11, f12, f13, f14, f15: int,
}
Hook_Big :: struct {
	a:          [1]int,
	b:          [2]int,
	c:          [3]int,
	d:          [4]int,
	e:          [5]int,
	f:          [6]int,
	g:          [7]int,
	h:          [8]int,
	p, q, r, s: Hook_Part,
}
Hook_Wrapped :: struct {
	n: int,
}

// The hook writes a `Hook_Big`, which is no cell: the plan compiles it, then the write is refused.
@(private = "file")
write_big :: proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
	return csv.marshal_into(out, Hook_Big{})
}

// As `write_big`, with the refusal dropped: the cell is empty and the write goes on.
@(private = "file")
write_big_dropped :: proc(out: csv.Marshal_Out, v: rawptr) -> csv.Marshal_Error_Kind {
	_ = csv.marshal_into(out, Hook_Big{})
	return .None
}

@(private = "file")
Hook_Row :: struct {
	a: int,
	w: Hook_Wrapped,
	b: int,
	c: string,
}

// A hook that compiles a new type moves the plan's arrays under the record loop, which locates the refusal by
// the plan as it is after the hook.
@(test)
test_hook_compile_moves_plan_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rows := []Hook_Row{{1, {2}, 3, "x"}}
	for sort_keys in ([]bool{false, true}) {
		plan := csv.type_plan_init([]Hook_Row, {hooks = []csv.Type_Hook{{type = Hook_Wrapped, write = write_big}}}, runtime.heap_allocator())
		_, err := csv.marshal(rows, {sort_keys = sort_keys}, &plan, context.temp_allocator)
		testing.expect_value(t, csv.render_error(nil, err.?, context.temp_allocator), "Unsupported type at [0].w")
		csv.destroy(&plan)
	}
}

// After such a hook the record loop still reads the rest of the row, and every record after it.
@(test)
test_hook_compile_moves_plan_struct_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rows := []Hook_Row{{1, {2}, 3, "x"}, {5, {6}, 7, "y"}}
	for sort_keys in ([]bool{false, true}) {
		dropped := csv.type_plan_init([]Hook_Row, {hooks = []csv.Type_Hook{{type = Hook_Wrapped, write = write_big_dropped}}}, runtime.heap_allocator())
		out, derr := csv.marshal(rows, {sort_keys = sort_keys}, &dropped, context.temp_allocator)
		testing.expect(t, derr == nil)
		testing.expect_value(t, string(out), "a,b,c,w\n1,3,x,\"\"\n5,7,y,\"\"\n" if sort_keys else "a,w,b,c\n1,\"\",3,x\n5,\"\",7,y\n")
		csv.destroy(&dropped)
	}
}

// The same under list and map rows, whose loops reuse the cell's op from one cell to the next.
@(test)
test_hook_compile_moves_plan_list_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	hooks := []csv.Type_Hook{{type = Hook_Wrapped, write = write_big_dropped}}
	lists := [][]Hook_Wrapped{{{1}, {2}, {3}}, {{4}, {5}, {6}}}
	plan := csv.type_plan_init([][]Hook_Wrapped, {hooks = hooks}, runtime.heap_allocator())
	defer csv.destroy(&plan)
	out, err := csv.marshal(lists, plan = &plan, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(out), "\"\",\"\",\"\"\n\"\",\"\",\"\"\n")

	refused := csv.type_plan_init([][]Hook_Wrapped, {hooks = []csv.Type_Hook{{type = Hook_Wrapped, write = write_big}}}, runtime.heap_allocator())
	defer csv.destroy(&refused)
	_, err = csv.marshal(lists, plan = &refused, allocator = context.temp_allocator)
	testing.expect_value(t, csv.render_error(nil, err.?, context.temp_allocator), "Unsupported type at [0][0]")
}

@(test)
test_hook_compile_moves_plan_map_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	hooks := []csv.Type_Hook{{type = Hook_Wrapped, write = write_big_dropped}}
	row := make(map[string]Hook_Wrapped, context.temp_allocator)
	row["a"], row["b"], row["c"] = {1}, {2}, {3}
	maps := []map[string]Hook_Wrapped{row}
	mplan := csv.type_plan_init([]map[string]Hook_Wrapped, {hooks = hooks}, runtime.heap_allocator())
	defer csv.destroy(&mplan)
	out, err := csv.marshal(maps, plan = &mplan, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(out), "a,b,c\n\"\",\"\",\"\"\n")

	refused := csv.type_plan_init([]map[string]Hook_Wrapped, {hooks = []csv.Type_Hook{{type = Hook_Wrapped, write = write_big}}}, runtime.heap_allocator())
	defer csv.destroy(&refused)
	_, err = csv.marshal(maps, plan = &refused, allocator = context.temp_allocator)
	testing.expect_value(t, csv.render_error(nil, err.?, context.temp_allocator), "Unsupported type at [0].a")
}
