package csv_tests

import "core:strings"
import "core:mem/virtual"
import "core:testing"
import csv "../"

// `find`: one path, one streaming scan, the first answer, and nothing kept.
@(test)
test_find_answers_cells_and_records :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,\"a,b\"\n2,c\n")
	a, err := csv.find(src, ".[0].name")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "\"a,b\"")
	testing.expect_value(t, a.owner, u64(8))
	testing.expect_value(t, a.query, u32(0))
	a, err = csv.find(src, ".[1][0]")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "2")
	a, err = csv.find(src, ".[1]")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "2,c")
	testing.expect_value(t, a.owner, u64(16))
	// A built path is a path.
	steps := []csv.Step{csv.Index(1), csv.Name("id")}
	a, err = csv.find(src, csv.Path{steps = steps})
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "2")
}

// An every-row path answers its first landing, whatever `limit` the path names.
@(test)
test_find_takes_the_first_answer_of_an_every_row_path :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n2,bob\n3,cy\n")
	a, err := csv.find(src, ".[].name")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "ada")
	testing.expect_value(t, a.owner, u64(8))
	a, err = csv.find(src, "limit(2; .[].name)")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "ada")
	a, err = csv.find(src, ".[][1]")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "ada")
}

// A path that lands nothing is `.Missing`: `NO_OWNER` when no record could hold the answer, the record's first
// byte when one does but lacks the column.
@(test)
test_find_reports_a_miss :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n")
	a, err := csv.find(src, ".[5].name")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Missing)
	testing.expect_value(t, a.owner, csv.NO_OWNER)
	a, err = csv.find(src, ".[0].nope")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Missing)
	testing.expect_value(t, a.owner, csv.NO_OWNER)
	a, err = csv.find(src, ".[0][9]")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Missing)
	testing.expect_value(t, a.owner, u64(8))
}

// A ragged row too short for the column answers nothing, so an every-row path reads on to the next row.
@(test)
test_find_skips_a_ragged_row :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1\n2,3\n")
	a, err := csv.find(src, ".[][1]", {dialect = {ragged = true}})
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "3")
}

// The scan stops at the answer, so a fault after it is not met; a `Request` reads on and reports it.
@(test)
test_find_stops_at_its_answer_and_reports_a_fault :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n3\n")
	a, err := csv.find(src, ".[0].a")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Found)
	testing.expect_value(t, string(src[a.lo:a.hi]), "1")
	a, err = csv.find(src, ".[1].a")
	testing.expect(t, a.outcome == .Missing)
	e, faulted := err.?
	testing.expect(t, faulted && e == source(csv_fault(8, .Field_Count)))
	// A header without the name ends the scan at the header.
	a, err = csv.find(src, ".[0].zz")
	testing.expect_value(t, err, nil)
	testing.expect(t, a.outcome == .Missing)
	testing.expect_value(t, a.owner, csv.NO_OWNER)
	out: [dynamic]csv.Answer
	defer delete(out)
	err = scan_one(src, ".[].a", &out)
	e, faulted = err.?
	testing.expect(t, faulted && e == source(csv_fault(8, .Field_Count)))
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "1")
}

// A path refusal keeps its kind: the path's own fault at its byte, a shape CSV cannot answer as
// `.Unsupported_Path`, as `query` refuses it, and a path past the step cap as `.Over_Capacity`.
@(test)
test_find_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	Case :: struct {
		path: string,
		want: csv.Path_Error_Kind,
	}
	cases := []Case{
		{"", .Bad_Path},
		{".[", .Bad_Path},
		{"first", .Bad_Path},
		{".a", .Unsupported_Path},
		{".[-1].a", .Unsupported_Path},
		{".[0][]", .Unsupported_Path},
		{".[0].a.b", .Unsupported_Path},
	}
	for c in cases {
		_, err := csv.find(src, c.path)
		e, faulted := err.?
		testing.expectf(t, faulted && e.kind == c.want, "find %q: %v, want %v", c.path, err, c.want)
	}
	_, err := csv.find(src, ".[0] | limit(1)")
	e, faulted := err.?
	testing.expect(t, faulted && e.kind == .Bad_Path && e.offset == 5)
	_, err = csv.find(src, ".[0].a", {no_header = true})
	e, faulted = err.?
	testing.expect(t, faulted && e.kind == .Unsupported_Path)
	long := strings.repeat(".[0]", 33, context.temp_allocator)
	_, err = csv.find(src, long)
	e, faulted = err.?
	testing.expect(t, faulted && e.kind == .Over_Capacity)
	_, err = csv.find(src, ".[0].a", {dialect = csv.Dialect{delimiter = '"'}})
	e, faulted = err.?
	testing.expect(t, faulted && e.kind == .Bad_Option)
}

// `limit` ends the walk at its last answer: the record after it is not read, so its fault is not met.
@(test)
test_scan_stops_at_its_limit :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a\n1\n2\"x\n")
	out: [dynamic]csv.Answer
	defer delete(out)
	testing.expect_value(t, scan_one(src, "limit(1; .[].a)", &out), nil)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "1")
	// Without the limit the walk reads on and meets the fault, after the answers before it.
	clear(&out)
	testing.expect_value(t, scan_one(src, ".[].a", &out), source({kind = .Bad_Char, offset = 5}))
	testing.expect_value(t, len(out), 1)
	clear(&out)
	good := transmute([]byte)string("a\n1\n2\n")
	testing.expect_value(t, scan_one(good, "limit(5; .[].a)", &out), nil)
	testing.expect_value(t, len(out), 2)
}

// The `.Bad_Source` a path procedure reports for the scan's fault `e`.
source :: proc(e: csv.Error) -> csv.Path_Error {
	return {kind = .Bad_Source, syntax = e.kind, detail = e.detail, offset = e.offset}
}

// One path through a `Request`, its answers appended to `out`.
scan_one :: proc(src: []byte, path: csv.Path_Spec, out: ^[dynamic]csv.Answer, opts := csv.Read_Opts{}) -> Maybe(csv.Path_Error) {
	req: csv.Request
	defer csv.destroy(&req)
	csv.request_init(&req, path, opts = opts) or_return
	err := csv.scan(src, &req)
	append(out, ..req.answers[:])
	return err
}

// Many paths in one pass: each path's answers in row order, a row path's miss among them, and the walk ends after
// the last row any path names.
@(test)
test_request_answers_many_paths_in_one_pass :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,ada\n2,bob\n3\"x\n")
	req: csv.Request
	defer csv.destroy(&req)
	testing.expect_value(t, csv.request_init(&req, ".[1].name", "limit(2; .[].id)", ".[0][5]", ".[0]"), nil)
	testing.expect_value(t, csv.scan(src, &req), nil)
	want := []string{"bob", "1 2", "", "1,ada"}
	for w, q in want {
		got, err := csv.answers(&req, q)
		testing.expect_value(t, err, nil)
		testing.expectf(t, cells(src, got) == w, "path %d: %q, want %q", q, cells(src, got), w)
	}
	miss, _ := csv.answers(&req, 2)
	testing.expect_value(t, miss[0], csv.Answer{outcome = .Missing, owner = 8, query = 2, node = csv.NO_NODE})
	// A rescan with a path over every row meets the fault after the answers before it.
	testing.expect_value(t, csv.request_init(&req, ".[].id", ".[0].name"), nil)
	testing.expect_value(t, csv.scan(src, &req), source({kind = .Bad_Char, offset = 21}))
	testing.expect_value(t, len(req.answers), 3)
	testing.expect_value(t, csv.scan(src, &csv.Request{}), csv.Path_Error{kind = .Bad_Option})
	// The answers live in the request's allocator, so a rescan with another context allocator answers again.
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	areq: csv.Request
	testing.expect_value(t, csv.request_init(&areq, ".[0].id", allocator = virtual.arena_allocator(&arena)), nil)
	testing.expect_value(t, csv.scan(src, &areq), nil)
	testing.expect_value(t, csv.scan(src, &areq), nil)
	testing.expect_value(t, len(areq.answers), 1)
}

// The engine of each path: one pass over the records for every path `scan` takes, and none for the rest.
@(test)
test_route_of_names_columns_or_unsupported :: proc(t: ^testing.T) {
	paths := []csv.Path{{steps = {csv.Any{}, csv.Name("a")}}, {steps = {csv.Name("a")}}}
	r, err := csv.route_of(nil, paths, 0)
	testing.expect(t, err == nil && r.class == .Direct && r.why == "Columns")
	r, err = csv.route_of(nil, paths, 1)
	testing.expect(t, err == nil && r.class == .Fallback && r.why == "Unsupported_Path")
	r, err = csv.route_of(nil, paths, 0, {no_header = true})
	testing.expect(t, err == nil && r.class == .Fallback)
	_, err = csv.route_of(nil, paths, 2)
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Option})
}
