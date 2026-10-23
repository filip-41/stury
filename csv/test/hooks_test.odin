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

date_write :: proc(out: ^[dynamic]u8, v: rawptr) -> csv.Marshal_Error {
	d := (^Date)(v)^
	append(out, fmt.tprintf("%04d-%02d-%02d", d.year, d.month, d.day))
	return .None
}

date_read :: proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
	parts := strings.split(string(text), "-", context.temp_allocator)
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
	defer csv.type_plan_destroy(&plan)
	src := "when,name,until\n2026-10-23,a,\n2027-01-02,\"b, \"\"c\"\"\",2028-03-04\n"
	events: []Event
	testing.expect_value(t, csv.unmarshal(transmute([]byte)src, &events, plan = &plan, allocator = context.temp_allocator), nil)
	if !testing.expect_value(t, len(events), 2) {
		return
	}
	testing.expect_value(t, events[0], Event{when_ = {2026, 10, 23}, name = "a"})
	testing.expect_value(t, events[1], Event{when_ = {2027, 1, 2}, name = `b, "c"`, until = Date{2028, 3, 4}})

	out, err := csv.marshal(events, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
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
			write = proc(out: ^[dynamic]u8, v: rawptr) -> csv.Marshal_Error {
				append(out, "yes" if (^bool)(v)^ else "no")
				return .None
			},
			read = proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
				switch string(text) {
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
	defer csv.type_plan_destroy(&plan)
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
	defer csv.type_plan_destroy(&plan)
	cases := []Refusal {
		{"when\n2026-10-23\nnot a date\n", .Wrong_Kind, 16, "[1].when"},
		{"name,when\nx,2026-13-01\n", .Out_Of_Range, 12, "[0].when"},
		{"when,until\n2026-10-23,2026\n", .Wrong_Kind, 22, "[0].until"},
		// A quoted empty cell is present: the hook reads "", an absent one is not read.
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
	defer csv.type_plan_destroy(&write_only)
	src := "when\n2026-10-23\n"
	err := csv.unmarshal(transmute([]byte)src, &events, plan = &write_only, allocator = context.temp_allocator)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Unsupported)
	_, merr := csv.marshal(events, plan = &write_only, allocator = context.temp_allocator)
	testing.expect_value(t, merr, csv.Marshal_Error.None)
	read_only := csv.type_plan_init([]Event, {hooks = {{type = Date, read = date_read}}})
	defer csv.type_plan_destroy(&read_only)
	_, merr = csv.marshal(events, plan = &read_only, allocator = context.temp_allocator)
	testing.expect_value(t, merr, csv.Marshal_Error.Unsupported)
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
			write = proc(out: ^[dynamic]u8, v: rawptr) -> csv.Marshal_Error {
				append(out, string((^Raw_Text)(v)^))
				return .None
			},
			read = proc(text: []byte, dest: rawptr, allocator: runtime.Allocator) -> Maybe(csv.Unmarshal_Error_Kind) {
				(^Raw_Text)(dest)^ = Raw_Text(string(text))
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
	defer csv.type_plan_destroy(&plan)
	out, err := csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	testing.expect_value(t, string(out), "text,n\n\"a,b\"\"c\nd\",1\n")
	back: []Tagged
	testing.expect_value(t, csv.unmarshal(out, &back, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, back[0], rows[0])

	rows[0].text = "x\ty\\z\nw"
	out, err = csv.marshal(rows, {dialect = csv.TSV}, &plan, context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	testing.expect_value(t, string(out), "text\tn\nx\\ty\\\\z\\nw\t1\n")
	testing.expect_value(t, csv.unmarshal(out, &back, {dialect = csv.TSV}, &plan, context.temp_allocator), nil)
	testing.expect_value(t, back[0], rows[0])

	// A dialect with no quotes and no escapes cannot spell the newline.
	_, err = csv.marshal(rows, {dialect = {delimiter = ';', quoting = .None}}, &plan, context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.Unwritable)

	rows[0].text = "\xff"
	_, err = csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.Bad_Utf8)

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
			write = proc(out: ^[dynamic]u8, v: rawptr) -> csv.Marshal_Error {
				return .Non_Finite if (^Date)(v).month == 0 else date_write(out, v)
			},
		},
	}
	plan := csv.type_plan_init([]Event, {hooks = refuse})
	defer csv.type_plan_destroy(&plan)
	events := []Event{{when_ = {2026, 1, 1}}, {}}
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect_value(t, csv.marshal_append(&out, events, plan = &plan), csv.Marshal_Error.Non_Finite)
	testing.expect_value(t, len(out), 0)
}
