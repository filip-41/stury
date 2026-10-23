package csv_tests

import "core:io"
import "core:strings"
import "core:testing"
import csv "../"

@(test)
test_marshal_append :: proc(t: ^testing.T) {
	rows := []Strict{{1, "a"}, {2, "b,c"}}
	want, _ := csv.marshal(rows, allocator = context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "prefix:")
	testing.expect_value(t, csv.marshal_append(&out, rows), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), strings.concatenate({"prefix:", string(want)}, context.temp_allocator))

	// A refusal leaves `out` as it was, whatever the failed call had written.
	before := strings.clone(string(out[:]), context.temp_allocator)
	bad := []Strict{{1, "a"}, {2, "\xff"}}
	testing.expect_value(t, csv.marshal_append(&out, bad), csv.Marshal_Error.Bad_Utf8)
	testing.expect_value(t, string(out[:]), before)
	testing.expect_value(t, csv.marshal_append(&out, rows, {dialect = {delimiter = '"'}}), csv.Marshal_Error.Bad_Option)
	testing.expect_value(t, string(out[:]), before)
}

// A BOM opening the output is quoted only when the output opens with it.
@(test)
test_marshal_append_bom :: proc(t: ^testing.T) {
	Cell :: struct {
		s: string,
	}
	rows := []Cell{{"\xEF\xBB\xBFa"}}
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect_value(t, csv.marshal_append(&out, rows, {no_header = true}), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "\"\xEF\xBB\xBFa\"\n")
	clear(&out)
	append(&out, "x\n")
	testing.expect_value(t, csv.marshal_append(&out, rows, {no_header = true}), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "x\n\xEF\xBB\xBFa\n")
}

Wide_Row :: struct {
	name: string,
	id:   int,
	note: string,
}

fail_writer :: proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	return 0, .Unexpected_EOF if mode == .Write else .Empty
}

@(test)
test_marshal_to_writer :: proc(t: ^testing.T) {
	rows := make([]Wide_Row, 8000, context.temp_allocator)
	for &r, k in rows {
		r = {"name, with comma" if k % 7 == 0 else "plain", k, "" if k % 3 == 0 else "q\"uote"}
	}
	// Rows opening with a BOM, one of which opens each chunk the stream writes.
	for &r, k in rows {
		if k % 2 == 0 {
			r.name = "\xEF\xBB\xBFbom"
		}
	}
	for opts in ([]csv.Marshal_Opts{{}, {no_header = true, crlf = true}, {dialect = csv.TSV}}) {
		want, werr := csv.marshal(rows, opts, allocator = context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		err := csv.marshal_to_writer(strings.to_writer(&b), rows, opts, allocator = context.temp_allocator)
		testing.expect_value(t, err, werr)
		if werr == .None {
			testing.expectf(t, strings.to_string(b) == string(want), "%v: streamed %d bytes, marshal %d", opts, len(b.buf), len(want))
		}
	}
	// An empty input still writes its header.
	b := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, csv.marshal_to_writer(strings.to_writer(&b), []Strict{}), csv.Marshal_Error.None)
	testing.expect_value(t, strings.to_string(b), "id,name\n")

	failing := io.Writer {
		procedure = fail_writer,
	}
	testing.expect_value(t, csv.marshal_to_writer(failing, rows, allocator = context.temp_allocator), csv.Marshal_Error.Write_Failed)
	testing.expect_value(t, csv.marshal_to_writer(failing, []Strict{{1, "\xff"}}, allocator = context.temp_allocator), csv.Marshal_Error.Bad_Utf8)
}

@(test)
test_write_record :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	cells := []Maybe(string){"a", nil, "", "x,y", "q\"r", "l\nm"}
	testing.expect_value(t, csv.write_record(&out, cells), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "a,,\"\",\"x,y\",\"q\"\"r\",\"l\nm\"\n")
	clear(&out)
	testing.expect_value(t, csv.write_record(&out, cells, csv.TSV), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "a\t\t\tx,y\tq\"r\tl\\nm\n")
	clear(&out)
	testing.expect_value(t, csv.write_record(&out, cells[:2], crlf = true), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "a,\r\n")

	// What it writes reads back as the cells: a nil cell and an empty one are told apart in CSV.
	clear(&out)
	testing.expect_value(t, csv.write_record(&out, cells), csv.Marshal_Error.None)
	rs := csv.records(out[:], allocator = context.temp_allocator)
	rec, _ := csv.next_record(&rs)
	testing.expect_value(t, len(rec.fields), len(cells))
	testing.expect_value(t, rec.fields[1].lo, rec.fields[1].hi)
	testing.expect_value(t, rec.fields[2].hi - rec.fields[2].lo, 2)
}

@(test)
test_write_record_unwritable :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "kept\n")
	// A blank line reads back as no record: no cells, one nil cell, and one empty cell where none is quoted.
	testing.expect_value(t, csv.write_record(&out, nil), csv.Marshal_Error.Unwritable)
	testing.expect_value(t, csv.write_record(&out, {nil}), csv.Marshal_Error.Unwritable)
	testing.expect_value(t, csv.write_record(&out, {""}, csv.TSV), csv.Marshal_Error.Unwritable)
	testing.expect_value(t, string(out[:]), "kept\n")
	testing.expect_value(t, csv.write_record(&out, {""}), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "kept\n\"\"\n")
	testing.expect_value(t, csv.write_record(&out, {nil, nil}, csv.TSV), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "kept\n\"\"\n\t\n")
	testing.expect_value(t, csv.write_record(&out, {"a"}, {delimiter = '"'}), csv.Marshal_Error.Bad_Option)
	testing.expect_value(t, csv.write_record(&out, {"\xff"}), csv.Marshal_Error.Bad_Utf8)
	testing.expect_value(t, string(out[:]), "kept\n\"\"\n\t\n")

	// A first cell opening with the comment byte is quoted, and where no cell is quoted the record is refused.
	clear(&out)
	testing.expect_value(t, csv.write_record(&out, {"#x", "y"}, {comment = '#'}), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "\"#x\",y\n")
	testing.expect_value(t, csv.write_record(&out, {"#x"}, {quoting = .None, comment = '#'}), csv.Marshal_Error.Unwritable)
}

// Under `Escapes.Backslash` a NUL is written as `\0` and read back as the NUL, where other dialects write it raw.
@(test)
test_backslash_escapes_nul :: proc(t: ^testing.T) {
	Cell :: struct {
		s: string,
	}
	long := "0123456789abcdefghij\x00k"
	rows := []Cell{{"a\x00b"}, {"\x00"}, {long}}
	out, err := csv.marshal(rows, {dialect = csv.TSV}, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	testing.expect_value(t, string(out), "s\na\\0b\n\\0\n0123456789abcdefghij\\0k\n")
	back: []Cell
	testing.expect_value(t, csv.unmarshal(out, &back, {dialect = csv.TSV}, allocator = context.temp_allocator), nil)
	testing.expect_value(t, len(back), 3)
	testing.expect_value(t, back[0].s, "a\x00b")
	testing.expect_value(t, back[1].s, "\x00")
	testing.expect_value(t, back[2].s, long)
	raw, rerr := csv.marshal(rows[:1], {dialect = {delimiter = ';', quoting = .None}}, allocator = context.temp_allocator)
	testing.expect_value(t, rerr, csv.Marshal_Error.None)
	testing.expect_value(t, string(raw), "s\na\x00b\n")
	cells := make([dynamic]u8, context.temp_allocator)
	testing.expect_value(t, csv.write_record(&cells, {"a\x00b", nil}, csv.TSV), csv.Marshal_Error.None)
	testing.expect_value(t, string(cells[:]), "a\\0b\t\n")
	text, escaped, aerr := csv.field_text(cells[:], {0, 4}, csv.TSV, context.temp_allocator)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, escaped, true)
	testing.expect_value(t, string(text), "a\x00b")
	set, serr := csv.set(transmute([]byte)string("s\nx\n"), ".[0].s", "p\x00q", csv.TSV, allocator = context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(set), "s\np\\0q\n")
}

// A BOM opens the output only at its start: `at_start` says whether an empty `out` is it.
@(test)
test_write_record_bom :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	bom := "\xEF\xBB\xBFa"
	testing.expect_value(t, csv.write_record(&out, {bom}), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "\"\xEF\xBB\xBFa\"\n")
	clear(&out)
	testing.expect_value(t, csv.write_record(&out, {bom}, at_start = false), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "\xEF\xBB\xBFa\n")
	clear(&out)
	testing.expect_value(t, csv.write_record(&out, {bom}, csv.TSV), csv.Marshal_Error.Unwritable)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, csv.write_record(&out, {bom}, csv.TSV, at_start = false), csv.Marshal_Error.None)
	testing.expect_value(t, string(out[:]), "\xEF\xBB\xBFa\n")
}
