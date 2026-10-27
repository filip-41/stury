package csv_tests

import "core:testing"
import csv "../"

@(test)
test_set_values :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,c\n1,2,3\n4,5,6\n")
	expect_set(t, src, ".[0].a", 42, "a,b,c\n42,2,3\n4,5,6\n")
	expect_set(t, src, ".[1][2]", -1.5, "a,b,c\n1,2,3\n4,5,-1.5\n")
	expect_set(t, src, ".[0].b", true, "a,b,c\n1,true,3\n4,5,6\n")
	expect_set(t, src, ".[0].b", "x,y", "a,b,c\n1,\"x,y\",3\n4,5,6\n")
	expect_set(t, src, ".[0].b", "say \"hi\"", "a,b,c\n1,\"say \"\"hi\"\"\",3\n4,5,6\n")
	expect_set(t, src, ".[0].b", "", "a,b,c\n1,\"\",3\n4,5,6\n")
	expect_set(t, src, ".[].c", "z", "a,b,c\n1,2,z\n4,5,z\n")
	expect_set(t, src, ".[].a", Maybe(int)(7), "a,b,c\n7,2,3\n7,5,6\n")
	crlf := transmute([]byte)string("a,b\r\n1,2\r\n")
	expect_set(t, crlf, ".[0].b", "q\r\nr", "a,b\r\n1,\"q\r\nr\"\r\n")
	// A text with no final break keeps none.
	bare := transmute([]byte)string("a,b\n1,2")
	expect_set(t, bare, ".[0].b", 3, "a,b\n1,3")
	// A path cannot name the header's cells by row.
	_, err := csv.set(src, ".[].a", 1, {no_header = true})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unsupported_Path})
}

@(test)
test_set_dialects :: proc(t: ^testing.T) {
	tsv := transmute([]byte)string("a\tb\n1\t2\n")
	expect_set_in(t, csv.TSV, tsv, ".[0].b", "x\ty\nz\\", "a\tb\n1\tx\\ty\\nz\\\\\n")
	semi := transmute([]byte)string("a;b\n1;2\n")
	expect_set_in(t, csv.Dialect{delimiter = ';', quoting = .None}, semi, ".[0].b", "p,q", "a;b\n1;p,q\n")
	_, err := csv.set(semi, ".[0].b", "p;q", {dialect = csv.Dialect{delimiter = ';', quoting = .None}})
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	commented := transmute([]byte)string("# note\na,b\n1,2\n")
	expect_set_in(t, csv.Dialect{comment = '#'}, commented, ".[0].a", "#x", "# note\na,b\n\"#x\",2\n")
	expect_set_in(t, csv.Dialect{comment = '#'}, commented, ".[0].b", "#x", "# note\na,b\n1,#x\n")
	// The text's BOM stays, and a value starting with a BOM does not add a second one.
	bom := transmute([]byte)string("\xEF\xBB\xBFa,b\n1,2\n")
	expect_set(t, bom, ".[0].a", "\xEF\xBB\xBFz", "\xEF\xBB\xBFa,b\n\xEF\xBB\xBFz,2\n")
	out, serr := csv.set(bom, ".[0][0]", "\xEF\xBB\xBFz", {no_header = true})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "\xEF\xBB\xBF\"\xEF\xBB\xBFz\",b\n1,2\n")
	delete(out)
}

// A cell starting with a BOM is data, except at the start of the text.
@(test)
test_edits_with_a_bom_cell :: proc(t: ^testing.T) {
	tsv := transmute([]byte)string("a\tb\n1\t2\n")
	expect_set_in(t, csv.TSV, tsv, ".[0][1]", "\xEF\xBB\xBFy", "a\tb\n1\t\xEF\xBB\xBFy\n")
	expect_set_in(t, csv.TSV, tsv, ".[0].b", "\xEF\xBB\xBFy", "a\tb\n1\t\xEF\xBB\xBFy\n")
	expect_set(t, transmute([]byte)string("a,b\n1,2\n"), ".[0][1]", "\xEF\xBB\xBFy", "a,b\n1,\xEF\xBB\xBFy\n")
	_, err := csv.set(tsv, ".[0][0]", "\xEF\xBB\xBFy", {dialect = csv.TSV, no_header = true})
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	_, err = csv.insert(nil, ".", csv.APPEND, []string{"\xEF\xBB\xBFy"}, {dialect = csv.TSV, no_header = true})
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	out, ierr := csv.insert(tsv, ".", csv.APPEND, []string{"x", "\xEF\xBB\xBFy"}, {dialect = csv.TSV})
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, string(out), "a\tb\n1\t2\nx\t\xEF\xBB\xBFy\n")
	delete(out)
}

// A text that is only a BOM has no records: a row goes after the BOM, with no break before it.
@(test)
test_insert_into_a_bom_only_text :: proc(t: ^testing.T) {
	bom := transmute([]byte)string("\xEF\xBB\xBF")
	out, err := csv.insert(bom, ".", csv.APPEND, []string{"a", "b"}, {no_header = true})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "\xEF\xBB\xBFa,b\n")
	delete(out)
}

@(test)
test_set_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	Case :: struct {
		path:  string,
		value: any,
		want:  csv.Path_Error,
	}
	cases := []Case {
		{".[1].a", 1, {kind = .Not_Found}},
		{".[0].zz", 1, {kind = .Not_Found}},
		{".[0][5]", 1, {kind = .Not_Found}},
		{".[0]", 1, {kind = .Unsupported_Path}},
		{".[-1].a", 1, {kind = .Unsupported_Path}},
		{".[0].a.b", 1, {kind = .Unsupported_Path}},
		{".[", 1, {kind = .Bad_Path, offset = 1}},
		{".[0].a", nil, {kind = .Encode, encode = .Unsupported}},
		{".[0].a", []int{1}, {kind = .Encode, encode = .Unsupported}},
		{".[0].a", struct{}{}, {kind = .Encode, encode = .Unsupported}},
	}
	for c in cases {
		out, err := csv.set(src, c.path, c.value)
		testing.expectf(t, out == nil && err == c.want, "set %q: %v, want %v", c.path, err, c.want)
		delete(out)
	}
	// A source that is not CSV is refused whole, whatever the path.
	_, err := csv.set(transmute([]byte)string("a,b\n1\n"), ".[0].a", 1)
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 4})
	// One empty field alone reads back as no record.
	one := transmute([]byte)string("a\nx\n")
	_, err = csv.set(one, ".[0].a", "", {dialect = csv.Dialect{quoting = .None}})
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable, offset = 2})
	out, err2 := csv.set(one, ".[0].a", "", {dialect = csv.Dialect{}})
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, string(out), "a\n\"\"\n")
	delete(out)
}

Seat :: struct {
	id:   int,
	name: string,
	ok:   bool,
}

Seat_Named :: struct {
	label: string `csv:"name"`,
	id:    int,
}

@(test)
test_insert_rows :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name,ok\n1,a,true\n2,b,false\n")
	expect_insert(t, src, 0, Seat{3, "c", true}, "id,name,ok\n3,c,true\n1,a,true\n2,b,false\n")
	expect_insert(t, src, 1, Seat{3, "c,d", false}, "id,name,ok\n1,a,true\n3,\"c,d\",false\n2,b,false\n")
	expect_insert(t, src, 2, Seat{3, "c", true}, "id,name,ok\n1,a,true\n2,b,false\n3,c,true\n")
	expect_insert(t, src, csv.APPEND, Seat{3, "c", true}, "id,name,ok\n1,a,true\n2,b,false\n3,c,true\n")
	expect_insert(t, src, csv.APPEND, []string{"3", "c", ""}, "id,name,ok\n1,a,true\n2,b,false\n3,c,\"\"\n")
	// Fields match columns by name, wherever the columns are; a column with no field is empty.
	reordered := transmute([]byte)string("name,x,id\nz,y,1\n")
	expect_insert(t, reordered, csv.APPEND, Seat_Named{"q", 9}, "name,x,id\nz,y,1\nq,,9\n")
	// The new record ends with the first record's line break. A text with no final break gets it before the record.
	crlf := transmute([]byte)string("id,name,ok\r\n1,a,true")
	expect_insert(t, crlf, csv.APPEND, Seat{2, "b", false}, "id,name,ok\r\n1,a,true\r\n2,b,false")
	expect_insert(t, crlf, 0, Seat{2, "b", false}, "id,name,ok\r\n2,b,false\r\n1,a,true")
	only_header := transmute([]byte)string("id,name,ok")
	expect_insert(t, only_header, 0, []string{"1", "a", "true"}, "id,name,ok\n1,a,true")
	headerless := transmute([]byte)string("1,a\n2,b\n")
	out, err := csv.insert(headerless, ".", 1, []string{"9", "z"}, {no_header = true})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "1,a\n9,z\n2,b\n")
	delete(out)
	out, err = csv.insert(nil, ".", csv.APPEND, []string{"9", "z"}, {no_header = true})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "9,z\n")
	delete(out)
}

@(test)
test_insert_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,a\n")
	Case :: struct {
		at:   int,
		row:  any,
		want: csv.Path_Error,
	}
	cases := []Case {
		{-1, []string{"1", "a"}, {kind = .Unplaceable}},
		{2, []string{"1", "a"}, {kind = .Unplaceable}},
		{0, []string{"1"}, {kind = .Bad_Row, offset = 1}},
		{0, []string{"1", "a", "b"}, {kind = .Bad_Row, offset = 3}},
		{0, Seat{}, {kind = .Bad_Row, offset = 2}}, // `ok` names no column
		{0, 5, {kind = .Encode, encode = .Unsupported}},
		{0, nil, {kind = .Encode, encode = .Unsupported}},
	}
	for c in cases {
		out, err := csv.insert(src, ".", c.at, c.row)
		testing.expectf(t, err == c.want, "insert %d %v: %v, want %v", c.at, c.row, err, c.want)
		delete(out)
	}
	// The path names the records, which have no names.
	_, err := csv.insert(src, ".[0]", 0, []string{"1", "a"})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unsupported_Path})
	_, err = csv.insert(src, ".", "id", []string{"1", "a"})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable})
	// A header is needed to place a row, but not to be found by one.
	_, err = csv.insert(nil, ".", 0, []string{"a"})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable})
	// Ragged texts take rows of any width.
	out, rerr := csv.insert(src, ".", 0, []string{"1"}, {dialect = csv.Dialect{ragged = true}})
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "id,name\n1\n1,a\n")
	delete(out)
	// A comment line cannot be a record: a first cell starting with the comment byte is quoted, escaped or refused.
	out, rerr = csv.insert(src, ".", 0, []string{"#x", "a"}, {dialect = csv.Dialect{comment = '#'}})
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "id,name\n\"#x\",a\n1,a\n")
	delete(out)
	_, rerr = csv.insert(src, ".", 0, []string{"#x", "a"}, {dialect = csv.Dialect{quoting = .None, comment = '#'}})
	testing.expect_value(t, rerr, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	// A bad source is refused with the scan's location.
	_, rerr = csv.insert(transmute([]byte)string("a,b\n1\n"), ".", 0, []string{"1", "2"})
	testing.expect_value(t, rerr, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 4})
}

@(test)
test_remove_rows_and_columns :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,c\n1,2,3\n4,5,6\n")
	expect_remove(t, src, ".[0]", "a,b,c\n4,5,6\n")
	expect_remove(t, src, ".[1]", "a,b,c\n1,2,3\n")
	expect_remove(t, src, ".[].a", "b,c\n2,3\n5,6\n")
	expect_remove(t, src, ".[].b", "a,c\n1,3\n4,6\n")
	expect_remove(t, src, ".[].c", "a,b\n1,2\n4,5\n")
	expect_remove(t, src, ".[][1]", "a,c\n1,3\n4,6\n")
	// Removing the last record in a text with no final break: the record before it becomes the end, with its break.
	bare := transmute([]byte)string("a,b\n1,2\n3,4")
	expect_remove(t, bare, ".[1]", "a,b\n1,2\n")
	expect_remove(t, bare, ".[0]", "a,b\n3,4")
	crlf := transmute([]byte)string("a,b\r\n1,2\r\n3,4\r\n")
	expect_remove(t, crlf, ".[0]", "a,b\r\n3,4\r\n")
	expect_remove(t, crlf, ".[].b", "a\r\n1\r\n3\r\n")
	quoted := transmute([]byte)string("a,\"b,c\",d\n1,\"2\n3\",4\n")
	expect_remove(t, quoted, ".[0]", "a,\"b,c\",d\n")
	expect_remove(t, quoted, ".[].a", "\"b,c\",d\n\"2\n3\",4\n")
	// Comment lines stay where they were.
	commented := transmute([]byte)string("# top\na,b\n# mid\n1,2\n# low\n3,4\n")
	out, err := csv.remove(commented, ".[0]", {dialect = csv.Dialect{comment = '#'}})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "# top\na,b\n# mid\n# low\n3,4\n")
	delete(out)
}

@(test)
test_remove_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	Case :: struct {
		path: string,
		want: csv.Path_Error,
	}
	cases := []Case {
		{".[1]", {kind = .Not_Found}},
		{".[].zz", {kind = .Not_Found}},
		{".[][3]", {kind = .Not_Found}},
		{".[0].a", {kind = .Unsupported_Path}},
		{".[0][1]", {kind = .Unsupported_Path}},
		{".[]", {kind = .Unsupported_Path}},
		{".[-1]", {kind = .Unsupported_Path}},
		{".[", {kind = .Bad_Path, offset = 1}},
	}
	for c in cases {
		out, err := csv.remove(src, c.path)
		testing.expectf(t, out == nil && err == c.want, "remove %q: %v, want %v", c.path, err, c.want)
	}
	// The only column cannot go: no record would be left.
	_, err := csv.remove(transmute([]byte)string("a\n1\n"), ".[].a")
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable, offset = 0})
	// A second column starting with the comment byte would make its record a comment.
	_, err = csv.remove(transmute([]byte)string("a,b\n1,#2\n"), ".[].a", {dialect = csv.Dialect{comment = '#'}})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable, offset = 4})
	// A removal that would put a BOM at the front is refused.
	_, err = csv.remove(transmute([]byte)string("a,\xEF\xBB\xBFb\n"), ".[].a")
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable})
	_, err = csv.remove(transmute([]byte)string("a,b\n1\n"), ".[0]")
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 4})
}

@(test)
test_edits_in_ragged_texts :: proc(t: ^testing.T) {
	d := csv.Dialect{ragged = true}
	src := transmute([]byte)string("a,b,c\n1\n2,3\n4,5,6\n")
	expect_set_in(t, d, src, ".[].c", "z", "a,b,c\n1\n2,3\n4,5,z\n")
	expect_set_in(t, d, src, ".[1].b", 9, "a,b,c\n1\n2,9\n4,5,6\n")
	_, err := csv.set(src, ".[0].b", 9, {dialect = d})
	testing.expect_value(t, err, csv.Path_Error{kind = .Not_Found})
	// A removal skips a record too short for the column.
	out, rerr := csv.remove(src, ".[].b", {dialect = d})
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "a,c\n1\n2\n4,6\n")
	delete(out)
	out, rerr = csv.remove(src, ".[].c", {dialect = d})
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "a,b\n1\n2,3\n4,5\n")
	delete(out)
	expect_remove_in(t, d, src, ".[1]", "a,b,c\n1\n4,5,6\n")
}

// `set` and `remove` resolve a header name by `opts.duplicates`, and refuse the repeat under `.Default`, as JSON's
// edits do.
@(test)
test_edits_follow_duplicate_columns :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,a\n1,2,3\n4,5,6\n")
	_, err := csv.set(src, ".[0].a", 9)
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Duplicate_Key, offset = 4})
	_, err = csv.remove(src, ".[].a")
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Duplicate_Key, offset = 4})
	out, serr := csv.set(src, ".[0].a", 9, {duplicates = .First})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b,a\n9,2,3\n4,5,6\n")
	delete(out)
	out, serr = csv.set(src, ".[0].a", 9, {duplicates = .Last})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b,a\n1,2,9\n4,5,6\n")
	delete(out)
	// `.All` edits every column of the name.
	out, serr = csv.set(src, ".[0].a", 9, {duplicates = .All})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b,a\n9,2,9\n4,5,6\n")
	delete(out)
	out, serr = csv.remove(src, ".[].a", {duplicates = .All})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "b\n2\n5\n")
	delete(out)
	out, serr = csv.set(src, ".[].a", 0, {duplicates = .All})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b,a\n0,2,0\n0,5,0\n")
	delete(out)
	out, serr = csv.remove(src, ".[].a", {duplicates = .First})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "b,a\n2,3\n5,6\n")
	delete(out)
	out, serr = csv.remove(src, ".[].a", {duplicates = .Last})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b\n1,2\n4,5\n")
	delete(out)
	// An index path names no column name, so no duplicate is read.
	out, serr = csv.set(src, ".[0][1]", 9)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b,a\n1,9,3\n4,5,6\n")
	delete(out)
}

// An edit judges its source as `records` reads it under `opts`, so `.Lazy` accepts a UTF-8 fault in a cell the
// edit leaves alone, and `limits` are the caller's.
@(test)
test_edits_judge_source_as_records :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\nok,\xFF\n")
	_, err := csv.set(src, ".[0].a", 7)
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Bad_Char, offset = 7})
	out, serr := csv.set(src, ".[0].a", 7, {strictness = .Lazy})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b\n7,\xFF\n")
	delete(out)
	out, serr = csv.insert(src, ".", csv.APPEND, []string{"x", "y"}, {strictness = .Lazy})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b\nok,\xFF\nx,y\n")
	delete(out)
	out, serr = csv.remove(src, ".[0]", {strictness = .Lazy})
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "a,b\n")
	delete(out)
	// A cap the caller set is judged as `records` judges it.
	_, serr = csv.set(src, ".[0].a", 7, {limits = {max_fields = 1}})
	testing.expect_value(t, serr, csv.Path_Error{kind = .Bad_Source, syntax = .Limit_Fields, offset = 0})
}

@(test)
test_splice :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	edits := []csv.Edit{{lo = 4, hi = 5, bytes = transmute([]byte)string("10")}, {lo = 6, hi = 7, bytes = transmute([]byte)string("\"x\"")}}
	out, err := csv.splice(src, edits)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "a,b\n10,\"x\"\n")
	delete(out)
	out, err = csv.splice(src, nil)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), string(src))
	delete(out)
	bad := [][]csv.Edit {
		{{lo = 5, hi = 4}},
		{{lo = 0, hi = 99}},
		{{lo = 4, hi = 6}, {lo = 5, hi = 7}},
		{{lo = 6, hi = 7}, {lo = 4, hi = 5}},
	}
	for e in bad {
		_, err = csv.splice(src, e)
		testing.expectf(t, err == csv.Path_Error{kind = .Bad_Edit}, "%v: %v", e, err)
	}
	// An edit that leaves a text that is not CSV is refused, with the fault located in the result.
	_, err = csv.splice(src, []csv.Edit{{lo = 4, hi = 5, bytes = transmute([]byte)string("1,9")}})
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Result, syntax = .Field_Count, offset = 4})
	_, err = csv.splice(src, []csv.Edit{{lo = 0, hi = 0}}, {dialect = csv.Dialect{delimiter = '"'}})
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Option})
}

// `set` of `src` at `path` to `value`, in the default dialect, is `want`.
expect_set :: proc(t: ^testing.T, src: []byte, path: string, value: any, want: string, loc := #caller_location) {
	expect_set_in(t, csv.Dialect{}, src, path, value, want, loc)
}

expect_set_in :: proc(t: ^testing.T, d: csv.Dialect, src: []byte, path: string, value: any, want: string, loc := #caller_location) {
	out, err := csv.set(src, path, value, {dialect = d})
	testing.expectf(t, err == nil && string(out) == want, "set %s of %q: %q %v, want %q", path, src, out, err, want, loc = loc)
	delete(out)
}

expect_insert :: proc(t: ^testing.T, src: []byte, at: int, row: any, want: string, loc := #caller_location) {
	out, err := csv.insert(src, ".", at, row)
	testing.expectf(t, err == nil && string(out) == want, "insert %d into %q: %q %v, want %q", at, src, out, err, want, loc = loc)
	delete(out)
}

expect_remove :: proc(t: ^testing.T, src: []byte, path: string, want: string, loc := #caller_location) {
	expect_remove_in(t, csv.Dialect{}, src, path, want, loc)
}

expect_remove_in :: proc(t: ^testing.T, d: csv.Dialect, src: []byte, path: string, want: string, loc := #caller_location) {
	out, err := csv.remove(src, path, {dialect = d})
	testing.expectf(t, err == nil && string(out) == want, "remove %s of %q: %q %v, want %q", path, src, out, err, want, loc = loc)
	delete(out)
}
