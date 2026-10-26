package csv_tests

import "core:strings"
import "core:testing"
import csv "../"

// `query`: a path answered over a built document's field spans, in row order.
@(test)
test_query_answers_document_spans :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n2,bob\n3,cy\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)

	err := csv.query(&doc, ".[].name", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 3)
	names := [?]string{"ada", "bob", "cy"}
	owners := [?]u64{8, 14, 20}
	for a, i in out {
		testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == names[i] && a.owner == owners[i] && a.query == 0,
			"answer %d: %v, want %q at owner %d", i, a, names[i], owners[i])
	}

	// Every row, the record's own span.
	clear(&out)
	err = csv.query(&doc, "[]", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 3)
	records := [?]string{"1,ada", "2,bob", "3,cy"}
	for a, i in out {
		testing.expectf(t, string(src[a.lo:a.hi]) == records[i] && a.owner == owners[i], "record %d: %v", i, a)
	}

	// One row, one cell.
	clear(&out)
	err = csv.query(&doc, ".[1][1]", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "bob")
	testing.expect_value(t, out[0].owner, u64(14))
	clear(&out)
	err = csv.query(&doc, ".[1]", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "2,bob")

	// `limit` counts the answers.
	clear(&out)
	err = csv.query(&doc, "limit(2; .[].name)", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, string(src[out[1].lo:out[1].hi]), "bob")
}

// A path that lands nothing appends nothing: a row or column the document lacks, or a header without the name.
@(test)
test_query_appends_nothing_for_a_miss :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	paths := [?]string{".[9].name", ".[0][9]", ".[].nope"}
	for path in paths {
		clear(&out)
		testing.expect_value(t, csv.query(&doc, path, &out), nil)
		testing.expectf(t, len(out) == 0, "%q appended %d answers", path, len(out))
	}
}

// A ragged row too short for the column answers nothing, and the next row answers.
@(test)
test_query_ragged_row :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1\n2,3\n")
	doc, derr := csv.build(src, {dialect = {ragged = true}})
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, csv.query(&doc, ".[][1]", &out), nil)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "3")
	testing.expect_value(t, out[0].owner, u64(6))
}

@(test)
test_query_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)

	// The path's own fault keeps its byte.
	perr := csv.query(&doc, ".[", &out)
	e, faulted := perr.?
	testing.expect(t, faulted && e.kind == .Bad_Path && e.offset == 1)
	// A shape CSV cannot answer.
	perr = csv.query(&doc, ".[][]", &out)
	e, faulted = perr.?
	testing.expect(t, faulted && e.kind == .Unsupported_Path)
	// A name with no header at all.
	headerless, herr := csv.build(src, {no_header = true})
	defer csv.destroy(&headerless)
	testing.expect_value(t, herr, nil)
	perr = csv.query(&headerless, ".[].name", &out)
	e, faulted = perr.?
	testing.expect(t, faulted && e.kind == .Unsupported_Path)
	// Past the path's step cap.
	long := strings.repeat(".[0]", 33, context.temp_allocator)
	perr = csv.query(&doc, long, &out)
	e, faulted = perr.?
	testing.expect(t, faulted && e.kind == .Over_Capacity)
}

// `query` reads the document's spans, never the text again, and answers the same path the same way twice.
@(test)
test_query_does_not_rescan :: proc(t: ^testing.T) {
	text := "id,name\n1,ada\n2,bob\n"
	src := make([]byte, len(text), context.temp_allocator)
	copy(src, text)
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	// A rescan would read the edited delimiter and lose row 0's second field.
	src[9] = ';'
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, csv.query(&doc, ".[][1]", &out), nil)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "ada")
	testing.expect_value(t, string(src[out[1].lo:out[1].hi]), "bob")
	again: [dynamic]csv.Answer
	defer delete(again)
	testing.expect_value(t, csv.query(&doc, ".[][1]", &again), nil)
	testing.expect_value(t, len(again), len(out))
	for a, i in again {
		testing.expect_value(t, a, out[i])
	}
}

// jq's `[]` is the every-element filter; core's path syntax spells it `.[]`, and the CSV readers take both.
@(test)
test_query_empty_bracket_step :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n2,bob\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, csv.query(&doc, "[]", &out), nil)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "1,ada")
	clear(&out)
	testing.expect_value(t, csv.query(&doc, "limit(1; [])", &out), nil)
	testing.expect_value(t, len(out), 1)
	a, ferr := csv.find(src, "[]")
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, string(src[a.lo:a.hi]), "1,ada")
}

// The same path through `find` and `query` lands on the same span: one streaming reader and one document
// reader, one answer shape.
@(test)
test_find_and_query_agree :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n2,bob\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, csv.query(&doc, ".[].name", &out), nil)
	testing.expect_value(t, len(out), 2)
	first, ferr := csv.find(src, ".[].name")
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, first.lo, out[0].lo)
	testing.expect_value(t, first.hi, out[0].hi)
	testing.expect_value(t, first.owner, out[0].owner)
	// One column of every row, through the streaming multi-answer reader.
	streamed: [dynamic]csv.Answer
	defer delete(streamed)
	testing.expect_value(t, csv.find_column(src, ".[].name", &streamed), nil)
	testing.expect_value(t, len(streamed), len(out))
	for a, i in streamed {
		testing.expect_value(t, a, out[i])
	}
}
