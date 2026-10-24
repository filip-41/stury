package csv_tests

import "core:testing"
import csv "../"

@(test)
test_find_cells :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,\"a,b\"\n2,c\n")
	f, found, err := csv.find(src, ".[0].name")
	testing.expect(t, found && err == nil)
	testing.expect_value(t, string(src[f.lo:f.hi]), "\"a,b\"")
	f, found, err = csv.find(src, ".[1][0]")
	testing.expect(t, found && err == nil)
	testing.expect_value(t, string(src[f.lo:f.hi]), "2")
	_, found, err = csv.find(src, ".[2].name")
	testing.expect(t, !found && err == nil)
	_, found, err = csv.find(src, ".[0].missing")
	testing.expect(t, !found && err == nil)
	_, found, err = csv.find(src, ".[0][2]")
	testing.expect(t, !found && err == nil)
	// A built path is a path.
	steps := []csv.Step{csv.Index(1), csv.Name("id")}
	f, found, err = csv.find(src, csv.Path{steps = steps})
	testing.expect(t, found && err == nil)
	testing.expect_value(t, string(src[f.lo:f.hi]), "2")
}

@(test)
test_find_stops_at_its_record :: proc(t: ^testing.T) {
	// The scan ends at the named record: a fault after it is not met, one before it is.
	src := transmute([]byte)string("a,b\n1,2\n3\n")
	_, found, err := csv.find(src, ".[0].a")
	testing.expect(t, found && err == nil)
	_, found, err = csv.find(src, ".[1].a")
	testing.expect(t, !found)
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 8})
	// A header without the name ends the scan at the header.
	_, found, err = csv.find(src, ".[0].zz")
	testing.expect(t, !found && err == nil)
	out: [dynamic]csv.Field
	defer delete(out)
	testing.expect_value(t, csv.find_column(src, ".[].a", &out), csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 8})
	testing.expect_value(t, len(out), 1)
}

@(test)
test_find_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	Case :: struct {
		path: string,
		want: csv.Path_Error_Kind,
	}
	cases := []Case {
		{"", .Bad_Path},
		{".[", .Bad_Path},
		{"[0].a", .Bad_Path},
		{".[-1].a", .Unsupported_Path},
		{".a", .Unsupported_Path},
		{".[0]", .Unsupported_Path},
		{".[]", .Unsupported_Path},
		{".[].a", .Unsupported_Path},
		{".[0][]", .Unsupported_Path},
		{".[0].a.b", .Unsupported_Path},
		{".[0] | limit(1)", .Bad_Path},
	}
	for c in cases {
		_, found, err := csv.find(src, c.path)
		e, faulted := err.?
		testing.expectf(t, !found && faulted && e.kind == c.want, "find %q: %v %v, want %v", c.path, found, err, c.want)
	}
	// A name needs a header; find_column takes only the whole-column path.
	_, found, err := csv.find(src, ".[0].a", {no_header = true})
	e, _ := err.?
	testing.expect(t, !found && e.kind == .Unsupported_Path)
	out: [dynamic]csv.Field
	defer delete(out)
	e, _ = csv.find_column(src, ".[0].a", &out).?
	testing.expect_value(t, e.kind, csv.Path_Error_Kind.Unsupported_Path)
	_, _, err = csv.find(src, ".[0].a", {dialect = csv.Dialect{delimiter = '"'}})
	e, _ = err.?
	testing.expect_value(t, e.kind, csv.Path_Error_Kind.Bad_Option)
}
