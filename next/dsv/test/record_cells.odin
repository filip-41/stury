package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:testkit"

// A user of the records reads a record's cell by its column's name with `records_find`, and every cell by place with a
// `records_scan` of the path `.[]`, whose k-th answer is the k-th cell. Neither takes a document per record from the
// caller or a loop over the record's members, and a quoted cell reads decoded.

@(private = "file")
ROWS :: "name,qty,note\nbolt,12,\"a,\"\"b\"\"\"\n\"nut\",3,\nwasher,7,x\n"

@(test)
a_records_user_reads_a_cell_by_column_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(ROWS)
	r := dsv.records_open(src)
	out: [8]dsv.Record
	answers: [8]dsv.Span_Answer
	n := dsv.records_find(&r, []dsv.Step{dsv.Name("note")}, out[:], answers[:])
	testing.expect_value(t, n, 3)
	want := [3]string{`a,"b"`, "", "x"}
	buf: [16]u8
	for i in 0 ..< n {
		text, _ := dsv.node_text(dsv.as(.Csv), src, dsv.answer_node(answers[i]), buf[:])
		testing.expectf(t, answers[i].outcome == .Found && text == want[i], "record %d: %v %q", i, answers[i].outcome, text)
	}
	r = dsv.records_open(src)
	n = dsv.records_find(&r, []dsv.Step{dsv.Name("price")}, out[:], answers[:])
	testing.expect_value(t, n, 3)
	testing.expect(t, answers[0].outcome == .Missing)
}

@(test)
a_records_user_reads_a_cell_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(ROWS)
	demand, derr := dsv.demand_of({{dsv.All{}}})
	defer dsv.destroy(&demand)
	testing.expect_value(t, derr, nil)
	r := dsv.records_open(src)
	out: [8]dsv.Record
	docs: [8]dsv.Document
	n := dsv.records_scan(&r, &demand, out[:], docs[:])
	defer for &d in docs[:n] {
		dsv.destroy(&d)
	}
	testing.expect_value(t, n, 3)
	want := [3][3]string{{"bolt", "12", `a,"b"`}, {"nut", "3", ""}, {"washer", "7", "x"}}
	buf: [16]u8
	for i in 0 ..< n {
		for j in 0 ..< 3 {
			at, p, ok := dsv.answer({&docs[i], nil}, 0, j)
			text, _ := dsv.node_text(&docs[i], at, buf[:])
			testing.expectf(t, ok && p == .Found && text == want[i][j], "record %d cell %d: %v %q", i, j, p, text)
		}
		_, _, past := dsv.answer({&docs[i], nil}, 0, 3)
		testing.expect(t, !past)
	}
}

// Under `no_header` a record is an array, and a path of its place names the cell.
@(test)
a_records_user_reads_a_cell_of_a_row_without_a_header_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\nc,d\n")
	r := dsv.records_open(src, .Lines, .Csv, {format = dsv.Dsv_Options{no_header = true}})
	out: [4]dsv.Record
	answers: [4]dsv.Span_Answer
	n := dsv.records_find(&r, []dsv.Step{dsv.Index(1)}, out[:], answers[:])
	testing.expect_value(t, n, 2)
	buf: [4]u8
	want := [2]string{"b", "d"}
	for i in 0 ..< n {
		text, _ := dsv.node_text(dsv.as(.Csv), src, dsv.answer_node(answers[i]), buf[:])
		testing.expectf(t, text == want[i], "record %d: %q", i, text)
	}
}
