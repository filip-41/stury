package csv_tests

import "core:fmt"
import "core:testing"
import csv "../"

@(test)
test_find_against_document :: proc(t: ^testing.T) {
	ds := MODEL_DIALECTS
	seed := u64(0x9E3779B97F4A7C15)
	for d in ds {
		for _ in 0 ..< 300 {
			grid, src := model_text(&seed, d)
			doc, _ := csv.build(src, d, allocator = context.temp_allocator)
			rows := csv.row_count(&doc)
			for r in 0 ..< rows + 1 {
				for c in 0 ..< csv.column_count(&doc) + 1 {
					want, in_doc := csv.get_field(&doc, r, c)
					by_index := fmt.tprintf(".[%d][%d]", r, c)
					got, found, err := csv.find(src, by_index, d)
					if !testing.expectf(t, err == nil && found == in_doc && (!found || got == want), "%v %q %s: %v %v %v, want %v %v", d, src, by_index, got, found, err, want, in_doc) {
						return
					}
					if c < len(grid[0]) {
						by_name := fmt.tprintf(".[%d].c%d", r, c)
						got, found, err = csv.find(src, by_name, d)
						if !testing.expectf(t, err == nil && found == in_doc && (!found || got == want), "%v %q %s: %v %v %v, want %v %v", d, src, by_name, got, found, err, want, in_doc) {
							return
						}
					}
				}
			}
			for c in 0 ..< len(grid[0]) {
				out: [dynamic]csv.Field
				out.allocator = context.temp_allocator
				err := csv.find_column(src, fmt.tprintf(".[].c%d", c), &out, d, allocator = context.temp_allocator)
				testing.expectf(t, err == nil, "%v %q: column %d: %v", d, src, c, err)
				n := 0
				for r in 0 ..< rows {
					if want, ok := csv.get_field(&doc, r, c); ok {
						if !testing.expectf(t, n < len(out) && out[n] == want, "%v %q: column %d row %d", d, src, c, r) {
							return
						}
						n += 1
					}
				}
				testing.expectf(t, n == len(out), "%v %q: column %d holds %d fields, want %d", d, src, c, len(out), n)
			}
			// Without a header the first record is row 0.
			recs, _ := collect(src, d)
			for rec, r in recs {
				got, found, err := csv.find(src, fmt.tprintf(".[%d][0]", r), d, header = false)
				if !testing.expectf(t, err == nil && found && got == rec.fields[0], "%v %q: headerless row %d: %v %v %v", d, src, r, got, found, err) {
					return
				}
			}
			free_all(context.temp_allocator)
		}
	}
}

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
	_, found, err := csv.find(src, ".[0].a", header = false)
	e, _ := err.?
	testing.expect(t, !found && e.kind == .Unsupported_Path)
	out: [dynamic]csv.Field
	defer delete(out)
	e, _ = csv.find_column(src, ".[0].a", &out).?
	testing.expect_value(t, e.kind, csv.Path_Error_Kind.Unsupported_Path)
	_, _, err = csv.find(src, ".[0].a", csv.Dialect{delimiter = '"'})
	e, _ = err.?
	testing.expect_value(t, e.kind, csv.Path_Error_Kind.Bad_Option)
}
