package csv_tests

import "core:strings"
import "core:testing"
import csv "../"

// `query`: a path answered over a built document's rows, in row order, as over any format's.
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

	clear(&out)
	err = csv.query(&doc, ".[]", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 3)
	records := [?]string{"1,ada", "2,bob", "3,cy"}
	for a, i in out {
		testing.expectf(t, string(src[a.lo:a.hi]) == records[i] && a.owner == 8, "record %d: %v", i, a)
	}

	// A record under a header is an object: an index into it does not apply.
	clear(&out)
	err = csv.query(&doc, ".[1][1]", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], csv.Answer{outcome = .Type_Mismatch, owner = 8, node = csv.NO_NODE})
	clear(&out)
	err = csv.query(&doc, ".[1]", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "2,bob")

	clear(&out)
	err = csv.query(&doc, "limit(2; .[].name)", &out)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, string(src[out[1].lo:out[1].hi]), "bob")
}

// A path naming one row that does not land appends one `.Missing`, owned by the container it missed in; a path
// over every row appends nothing for a header without the name.
@(test)
test_query_answers_a_miss :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	Case :: struct {
		path:  string,
		owner: u64,
	}
	for c in ([]Case{{".[9].name", 8}, {".[0].nope", 8}}) {
		clear(&out)
		testing.expect_value(t, csv.query(&doc, c.path, &out), nil)
		testing.expect_value(t, len(out), 1)
		testing.expect_value(t, out[0], csv.Answer{outcome = .Missing, owner = c.owner, node = csv.NO_NODE})
	}
	clear(&out)
	testing.expect_value(t, csv.query(&doc, ".[].nope", &out), nil)
	testing.expect_value(t, len(out), 0)
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
	testing.expect_value(t, csv.query(&doc, ".[].b", &out), nil)
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

	perr := csv.query(&doc, ".[", &out)
	e, faulted := perr.?
	testing.expect(t, faulted && e.kind == .Bad_Path && e.offset == 1)
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
	testing.expect_value(t, csv.query(&doc, ".[].name", &out), nil)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "ada")
	testing.expect_value(t, string(src[out[1].lo:out[1].hi]), "bob")
	again: [dynamic]csv.Answer
	defer delete(again)
	testing.expect_value(t, csv.query(&doc, ".[].name", &again), nil)
	testing.expect_value(t, len(again), len(out))
	for a, i in again {
		testing.expect_value(t, a, out[i])
	}
}

// core's path syntax starts at the root `.`: a bare bracket step is `.Bad_Path` for `find`, a `Request` and
// `query` alike, whatever follows it, inside `limit(` too.
@(test)
test_bare_bracket_paths_are_refused :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n2,bob\n")
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	for path in ([]string{"[]", "[0]", "[].name", "[0][1]", "limit(1; [])"}) {
		_, ferr := csv.find(src, path)
		testing.expectf(t, ferr != nil && ferr.?.kind == .Bad_Path, "find %q: %v", path, ferr)
		cerr := scan_one(src, path, &out)
		testing.expectf(t, cerr != nil && cerr.?.kind == .Bad_Path, "scan %q: %v", path, cerr)
		perr := csv.query(&doc, path, &out)
		testing.expectf(t, perr != nil && perr.?.kind == .Bad_Path, "query %q: %v", path, perr)
	}
	testing.expect_value(t, len(out), 0)
}

// A text with a header and no record has no row for any path: `query` answers nothing, as `find` does. A
// document built without a header is an array of arrays, where a name does not apply.
@(test)
test_query_on_an_empty_document_is_a_miss :: proc(t: ^testing.T) {
	doc, derr := csv.build(nil)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, csv.query(&doc, ".[].a", &out), nil)
	testing.expect_value(t, len(out), 0)
	a, ferr := csv.find(nil, ".[].a")
	testing.expect_value(t, ferr, nil)
	testing.expect(t, a.outcome == .Missing)
	bare, berr := csv.build(nil, {no_header = true})
	defer csv.destroy(&bare)
	testing.expect_value(t, berr, nil)
	testing.expect_value(t, csv.query(&bare, ".[].a", &out), nil)
	testing.expect_value(t, len(out), 0)
}

// A header name two columns share: `find`, a `Request` and `query` take the last under `.Default`, as JSON's
// readers do. `find` and a `Request` follow an explicit `duplicates`; `.All` reads every column of the name.
@(test)
test_lookups_follow_duplicates :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,a\n1,2\n3,4\n")
	Case :: struct {
		policy: csv.Duplicates,
		first:  string,
		column: string,
	}
	cases := []Case{{.Default, "2", "2 4"}, {.First, "1", "1 3"}, {.Last, "2", "2 4"}, {.All, "1", "1 2 3 4"}}
	for c in cases {
		opts := csv.Read_Opts{duplicates = c.policy}
		a, ferr := csv.find(src, ".[0].a", opts)
		testing.expect_value(t, ferr, nil)
		testing.expect_value(t, string(src[a.lo:a.hi]), c.first)
		out: [dynamic]csv.Answer
		defer delete(out)
		testing.expect_value(t, scan_one(src, ".[].a", &out, opts), nil)
		testing.expect_value(t, cells(src, out[:]), c.column)
	}
	doc, derr := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	answers: [dynamic]csv.Answer
	defer delete(answers)
	testing.expect_value(t, csv.query(&doc, ".[].a", &answers), nil)
	testing.expect_value(t, cells(src, answers[:]), "2 4")
	// `.Refuse` names the repeated header cell, in the error each reader returns.
	refuse := csv.Read_Opts{duplicates = .Refuse}
	_, ferr := csv.find(src, ".[0].a", refuse)
	testing.expect_value(t, ferr, source({kind = .Duplicate_Key, offset = 2}))
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, scan_one(src, ".[].a", &out, refuse), source({kind = .Duplicate_Key, offset = 2}))
	_, rerr := csv.build(src, refuse)
	testing.expect_value(t, rerr, csv.Error{kind = .Duplicate_Key, offset = 2})
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
	testing.expect_value(t, scan_one(src, ".[].name", &streamed), nil)
	testing.expect_value(t, len(streamed), len(out))
	// Only `query` names a cell's row in the document.
	for a, i in streamed {
		want := out[i]
		testing.expect_value(t, want.node, csv.Node(3 * i + 3))
		want.node = csv.NO_NODE
		testing.expect_value(t, a, want)
	}
}

// The answers' cells, joined by spaces.
cells :: proc(src: []byte, answers: []csv.Answer) -> string {
	parts := make([]string, len(answers), context.temp_allocator)
	for a, i in answers {
		parts[i] = string(src[a.lo:a.hi])
	}
	return strings.join(parts, " ", context.temp_allocator)
}
