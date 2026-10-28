package csv_tests

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import csv "../"

// A refusal's kind, `.None` for none.
@(private)
marshal_kind :: proc(err: Maybe(csv.Marshal_Error)) -> csv.Marshal_Error_Kind {
	if e, bad := err.?; bad {
		return e.kind
	}
	return .None
}

@(test)
test_marshal_text :: proc(t: ^testing.T) {
	rows := []Strict{{1, "plain"}, {-2, "a,b"}, {3, `q"d`}, {4, "line\nbreak"}, {5, ""}}
	out, err := csv.marshal(rows, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
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
			if !testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None) {
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
	if !testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None) {
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

// An f16 is written in its own width's shortest digits and read back rounded once from the decimal: a midpoint
// ties to even, a decimal past it rounds up, and one past the widest finite f16's rounding is out of range.
@(test)
test_marshal_f16_round_trip :: proc(t: ^testing.T) {
	Half :: struct {
		h: f16,
	}
	rows := []Half{{0.1}, {-65504}, {6.104e-5}, {5.96e-8}, {-0.0}, {1}}
	out, err := csv.marshal(rows, allocator = context.temp_allocator)
	if !testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None) {
		return
	}
	back: []Half
	testing.expect_value(t, read(t, string(out), &back), nil)
	if !testing.expect_value(t, len(back), len(rows)) {
		return
	}
	for r, k in rows {
		testing.expectf(t, transmute(u16)back[k].h == transmute(u16)r.h, "row %d: %v, want %v (from %q)", k, back[k].h, r.h, string(out))
	}
	cases := []struct {
		text: string,
		want: f16,
	}{{"1.00048828125", 1}, {"1.000488281250001", 1.0009765625}, {"+.5", 0.5}, {"65519", 65504}}
	for c in cases {
		testing.expect_value(t, read(t, fmt.tprintf("h\n%s\n", c.text), &back), nil)
		testing.expectf(t, len(back) == 1 && back[0].h == c.want, "%s: %v, want %v", c.text, back, c.want)
	}
	testing.expect_value(t, read(t, "h\n65520\n", &back).?.kind, csv.Unmarshal_Error_Kind.Out_Of_Range)
}

@(test)
test_marshal_enum_ints :: proc(t: ^testing.T) {
	plan := csv.type_plan_init([]Row, {enums = .Int})
	defer csv.destroy(&plan)
	rows := []Row{{color = .Blue}}
	out, err := csv.marshal(rows, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	back: []Row
	testing.expect_value(t, csv.unmarshal(out, &back, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, back[0].color, Color.Blue)
	// A value no member has is refused as the names are, and as `unmarshal` refuses it.
	_, err = csv.marshal([]Row{{color = Color(3)}}, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Not_A_Member)
}

// A cell is never omitted, so a tag's `omitempty` is refused in both directions.
@(test)
test_omitempty_refused :: proc(t: ^testing.T) {
	Tagged :: struct {
		id: int `csv:"id,omitempty"`,
	}
	_, err := csv.marshal([]Tagged{{1}}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Bad_Tag)
	rows: []Tagged
	testing.expect_value(t, read(t, "id\n1\n", &rows).?.kind, csv.Unmarshal_Error_Kind.Bad_Tag)
}

// A refusal names the record by its index in the input and the field by its name; `write_record`'s names the cell.
@(test)
test_marshal_refusal_path :: proc(t: ^testing.T) {
	Cell :: struct {
		id:    int,
		score: f64 `csv:"points"`,
	}
	_, err := csv.marshal([]Cell{{1, 2}, {2, math.nan_f64()}}, allocator = context.temp_allocator)
	testing.expect_value(t, csv.render_error(nil, err.?, context.temp_allocator), "Number has no finite value at [1].points")
	b := strings.builder_make(context.temp_allocator)
	rows := make([]Cell, 600, context.temp_allocator)
	rows[555].score = math.inf_f64(1)
	werr := csv.marshal_to_writer(strings.to_writer(&b), rows, allocator = context.temp_allocator)
	testing.expect_value(t, csv.render_error(nil, werr.?, context.temp_allocator), "Number has no finite value at [555].points")
	out: [dynamic]u8
	defer delete(out)
	rerr := csv.write_record(&out, {"a", "\xff"})
	testing.expect_value(t, csv.render_error(nil, rerr.?, context.temp_allocator), "Invalid UTF-8 at [1]")
}

@(test)
test_marshal_refusals :: proc(t: ^testing.T) {
	expect_refused :: proc(t: ^testing.T, rows: []Row, want: csv.Marshal_Error_Kind, loc := #caller_location) {
		out, err := csv.marshal(rows, allocator = context.temp_allocator)
		testing.expect_value(t, marshal_kind(err), want, loc)
		testing.expect(t, out == nil, loc = loc)
	}
	expect_refused(t, {{score = math.nan_f64()}}, .Non_Finite)
	expect_refused(t, {{ratio = math.inf_f32(1)}}, .Non_Finite)
	expect_refused(t, {{color = Color(3)}}, .Not_A_Member)
	expect_refused(t, {{name = "\xff"}}, .Bad_Utf8)
	expect_refused(t, {{r = 0xd800}}, .Bad_Utf8)
	_, err := csv.marshal([]Strict{}, {dialect = {delimiter = '"'}})
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Bad_Option)
	_, err = csv.marshal([]Nested{{}}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Unsupported)
	// A `Maybe` of a pointer-like cell stores no tag, so it is not one cell, as `unmarshal` refuses it.
	Bare :: struct {
		c: Maybe(cstring),
		n: int,
	}
	_, err = csv.marshal([]Bare{{"x", 7}}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Unsupported)
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
		testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.Unwritable, loc)
		testing.expect(t, out == nil, loc = loc)
	}
	expect_unwritable(t, []Note{{"x"}, {nil}}, {})
	expect_unwritable(t, []Note{{nil}}, {no_header = true, crlf = true})
	expect_unwritable(t, []Name{{""}}, {dialect = {quoting = .None}})
	expect_unwritable(t, []None{{}}, {no_header = true})
	// An empty string is `""` where cells are quoted, which reads back present.
	out, err := csv.marshal([]Name{{""}, {"x"}}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), "name\n\"\"\nx\n")
	b: [dynamic]u8
	defer delete(b)
	testing.expect_value(t, marshal_kind(csv.marshal_append(&b, []Note{{nil}})), csv.Marshal_Error_Kind.Unwritable)
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
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
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
		testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
		back: []Nums
		testing.expectf(t, read(t, string(out), &back, {dialect = {delimiter = d}}) == nil && len(back) == 2 && back[0] == nums[0] && back[1] == nums[1], "%q: %q read %v", d, string(out), back)
	}

	Wide :: struct {
		b: Big,
	}
	plan := csv.type_plan_init([]Wide, {enums = .Int})
	defer csv.destroy(&plan)
	out, err = csv.marshal([]Wide{{.Y}}, plan = &plan, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "b\n18446744073709551615\n")
	wide: []Wide
	testing.expect_value(t, csv.unmarshal(out, &wide, plan = &plan, allocator = context.temp_allocator), nil)
	testing.expect_value(t, wide[0].b, Big.Y)
}

// A map of the pairs `kv`, from the temp allocator.
@(private)
pairs :: proc(kv: ..[2]string) -> map[string]string {
	m := make(map[string]string, context.temp_allocator)
	for p in kv {
		m[p[0]] = p[1]
	}
	return m
}

// A list row is one record, its elements the cells, with no header; a map row's header is every record's keys,
// sorted, and a key a record lacks is an empty cell. Each reads back equal.
@(test)
test_marshal_cell_rows :: proc(t: ^testing.T) {
	lists := [][]string{{"a", "b"}, {"1", ""}, {`x"y`, "c,d"}}
	out, err := csv.marshal(lists, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), "a,b\n1,\"\"\n\"x\"\"y\",\"c,d\"\n")
	back: [][]string
	testing.expect(t, csv.unmarshal(out, &back, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, fmt.tprint(back), fmt.tprint(lists))
	out, err = csv.marshal([][]Maybe(string){{"a", nil}}, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "a,\n")

	maps := []map[string]string{pairs({"b", "2"}, {"a", "1"}), pairs({"c", "3"})}
	out, err = csv.marshal(maps, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), "a,b,c\n1,2,\n,,3\n")
	read_maps: []map[string]string
	testing.expect(t, csv.unmarshal(out, &read_maps, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, len(read_maps), 2)
	testing.expect_value(t, len(read_maps[0]), 2)
	testing.expect_value(t, read_maps[0]["b"], "2")
	testing.expect_value(t, fmt.tprint(read_maps[1]), fmt.tprint(maps[1]))
	out, err = csv.marshal(maps, {no_header = true}, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "1,2,\n,,3\n")
	out, err = csv.marshal([]map[string]string{pairs({"a", ""})}, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "a\n\"\"\n")
	out, err = csv.marshal([]map[string]string{}, allocator = context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
	testing.expect_value(t, len(out), 0)

	// Streamed in chunks, the header is written once.
	many := make([]map[string]int, 600, context.temp_allocator)
	for &m, i in many {
		m = make(map[string]int, context.temp_allocator)
		m["n"] = i
	}
	whole, _ := csv.marshal(many, allocator = context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, csv.marshal_to_writer(strings.to_writer(&b), many, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, strings.to_string(b), string(whole))
}

// What a list or map row cannot write: a cell type `unmarshal` cannot read, a map entry whose cell is empty
// (read back as no entry), a blank line, and a value refused in a cell, at `[record][cell]` or `[record].key`.
@(test)
test_marshal_cell_rows_refused :: proc(t: ^testing.T) {
	expect_refused :: proc(t: ^testing.T, rows: $T, opts: csv.Marshal_Opts, kind: csv.Marshal_Error_Kind, path: string, loc := #caller_location) {
		out, err := csv.marshal(rows, opts, allocator = context.temp_allocator)
		testing.expect_value(t, marshal_kind(err), kind, loc)
		testing.expect(t, out == nil, loc = loc)
		if path != "" {
			msg := csv.render_error(nil, err.?, context.temp_allocator)
			testing.expectf(t, strings.has_suffix(msg, path), "%q does not end in %q", msg, path, loc = loc)
		}
	}
	expect_refused(t, [][][]int{{{1}}}, {}, .Unsupported, "")
	by_int := make(map[int]string, context.temp_allocator)
	by_int[1] = "a"
	expect_refused(t, []map[int]string{by_int}, {}, .Unsupported, "")
	expect_refused(t, []map[string]string{pairs({"a", ""})}, {dialect = {quoting = .None}}, .Unwritable, "at [0].a")
	nil_entry := make(map[string]Maybe(string), context.temp_allocator)
	nil_entry["a"] = nil
	expect_refused(t, []map[string]Maybe(string){nil_entry}, {}, .Unwritable, "at [0].a")
	expect_refused(t, [][]string{{"a"}, {}}, {}, .Unwritable, "at [1]")
	expect_refused(t, [][]string{{""}}, {dialect = {quoting = .None}}, .Unwritable, "at [0]")
	expect_refused(t, []map[string]string{{}}, {}, .Unwritable, "at [0]")
	expect_refused(t, [][]f64{{1, math.inf_f64(1)}}, {}, .Non_Finite, "at [0][1]")
}
