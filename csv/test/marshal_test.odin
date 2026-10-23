package csv_tests

import "core:math"
import "core:testing"
import csv "../"

@(test)
test_marshal_text :: proc(t: ^testing.T) {
	rows := []Strict{{1, "plain"}, {-2, "a,b"}, {3, `q"d`}, {4, "line\nbreak"}, {5, ""}}
	out, err := csv.marshal(rows, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	testing.expect_value(t, string(out), "id,name\n1,plain\n-2,\"a,b\"\n3,\"q\"\"d\"\n4,\"line\nbreak\"\n5,\"\"\n")
	out, err = csv.marshal(rows[:1], {dialect = {delimiter = ';'}, no_header = true, crlf = true}, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "1;plain\r\n")
}

// Every length up to past four 16-byte windows reads back, plain and with a quote at each window's edge.
@(test)
test_marshal_text_lengths :: proc(t: ^testing.T) {
	alphabet := "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
	for n in 0 ..< len(alphabet) {
		for quote in ([]int{-1, 0, 15, 16, 31, n - 1}) {
			b := make([]byte, n, context.temp_allocator)
			copy(b, alphabet[:n])
			if quote >= 0 && quote < n {
				b[quote] = '"'
			}
			rows := []Strict{{n, string(b)}}
			out, err := csv.marshal(rows, allocator = context.temp_allocator)
			if !testing.expect_value(t, err, csv.Marshal_Error.None) {
				return
			}
			back: []Strict
			testing.expect_value(t, read(t, string(out), &back), nil)
			if testing.expect_value(t, len(back), 1) {
				testing.expectf(t, back[0] == rows[0], "%q read back as %q from %q", rows[0].name, back[0].name, string(out))
			}
		}
	}
}

@(test)
test_marshal_round_trip :: proc(t: ^testing.T) {
	rows := []Row {
		{id = 1, small = -128, name = `Ann "A", jr`, ok = true, score = 0.1, ratio = 0.1, color = .Blue, r = 'é', big = max(u128)},
		{id = min(i64), small = 127, name = "", score = 1e300, ratio = 3.4e38, note = 5, r = '"'},
		{score = -2.5e-310, ratio = math.F32_MIN, name = "x\r\ny"},
	}
	out, err := csv.marshal(rows, allocator = context.temp_allocator)
	if !testing.expect_value(t, err, csv.Marshal_Error.None) {
		return
	}
	back: []Row
	testing.expect_value(t, read(t, string(out), &back), nil)
	if !testing.expect_value(t, len(back), len(rows)) {
		return
	}
	for r, k in rows {
		testing.expectf(t, back[k] == r, "row %d: %v, want %v (from %q)", k, back[k], r, string(out))
	}
}

@(test)
test_marshal_enum_ints :: proc(t: ^testing.T) {
	plan := csv.type_plan_init([]Row, {enums = .Int})
	defer csv.type_plan_destroy(&plan)
	rows := []Row{{color = .Blue}}
	out, err := csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	back: []Row
	testing.expect_value(t, csv.unmarshal(out, &back, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, back[0].color, Color.Blue)
}

@(test)
test_marshal_refusals :: proc(t: ^testing.T) {
	expect_refused :: proc(t: ^testing.T, rows: []Row, want: csv.Marshal_Error, loc := #caller_location) {
		out, err := csv.marshal(rows, allocator = context.temp_allocator)
		testing.expect_value(t, err, want, loc)
		testing.expect(t, out == nil, loc = loc)
	}
	expect_refused(t, {{score = math.nan_f64()}}, .Non_Finite)
	expect_refused(t, {{ratio = math.inf_f32(1)}}, .Non_Finite)
	expect_refused(t, {{color = Color(3)}}, .Not_A_Member)
	expect_refused(t, {{name = "\xff"}}, .Bad_Utf8)
	expect_refused(t, {{r = 0xd800}}, .Bad_Utf8)
	_, err := csv.marshal([]Strict{}, {dialect = {delimiter = '"'}})
	testing.expect_value(t, err, csv.Marshal_Error.Bad_Option)
	_, err = csv.marshal([]Nested{{}}, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.Unsupported)
}

// A record that would be a blank line reads back as no record, so `marshal` refuses it as `write_record` does.
@(test)
test_marshal_refuses_blank_line :: proc(t: ^testing.T) {
	Note :: struct {
		note: Maybe(string),
	}
	Name :: struct {
		name: string,
	}
	None :: struct {}
	expect_unwritable :: proc(t: ^testing.T, rows: $T/[]$E, opts: csv.Marshal_Opts, loc := #caller_location) {
		out, err := csv.marshal(rows, opts, allocator = context.temp_allocator)
		testing.expect_value(t, err, csv.Marshal_Error.Unwritable, loc)
		testing.expect(t, out == nil, loc = loc)
	}
	expect_unwritable(t, []Note{{"x"}, {nil}}, {})
	expect_unwritable(t, []Note{{nil}}, {no_header = true, crlf = true})
	expect_unwritable(t, []Name{{""}}, {dialect = {quoting = .None}})
	expect_unwritable(t, []None{{}}, {no_header = true})
	// An empty string is `""` where cells are quoted, which reads back present.
	out, err := csv.marshal([]Name{{""}, {"x"}}, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	testing.expect_value(t, string(out), "name\n\"\"\nx\n")
	b: [dynamic]u8
	defer delete(b)
	testing.expect_value(t, csv.marshal_append(&b, []Note{{nil}}), csv.Marshal_Error.Unwritable)
	testing.expect_value(t, len(b), 0)
}

Big :: enum u64 {
	X = 0,
	Y = max(u64),
}

// Text `unmarshal` would misread unless `marshal` quotes it: a BOM opening the output, numbers holding the
// delimiter, and u64 enum members past max(i64) spelled as integers.
@(test)
test_marshal_reads_back :: proc(t: ^testing.T) {
	Cell :: struct {
		s: string,
	}
	out, err := csv.marshal([]Cell{{"\xEF\xBB\xBFabc"}}, {no_header = true}, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	cells: []Cell
	testing.expect_value(t, read(t, string(out), &cells, {no_header = true}), nil)
	testing.expect_value(t, cells[0].s, "\xEF\xBB\xBFabc")

	Nums :: struct {
		a: int,
		b: f64,
	}
	for d in ([]byte{'5', '-', '.', 'e', '+'}) {
		nums := []Nums{{15, -1.5}, {-25, 1e30}}
		out, err = csv.marshal(nums, {dialect = {delimiter = d}}, allocator = context.temp_allocator)
		testing.expect_value(t, err, csv.Marshal_Error.None)
		back: []Nums
		testing.expectf(t, read(t, string(out), &back, {dialect = {delimiter = d}}) == nil && len(back) == 2 && back[0] == nums[0] && back[1] == nums[1], "%q: %q read %v", d, string(out), back)
	}

	Wide :: struct {
		b: Big,
	}
	plan := csv.type_plan_init([]Wide, {enums = .Int})
	defer csv.type_plan_destroy(&plan)
	out, err = csv.marshal([]Wide{{.Y}}, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "b\n18446744073709551615\n")
	wide: []Wide
	testing.expect_value(t, csv.unmarshal(out, &wide, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, wide[0].b, Big.Y)
}
