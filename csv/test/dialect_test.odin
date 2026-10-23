package csv_tests

import "core:strings"
import "core:testing"
import csv "../"

UNQUOTED :: csv.Dialect{delimiter = ';', quoting = .None}
COMMENTS :: csv.Dialect{comment = '#'}
TSV_COMMENTS :: csv.Dialect{delimiter = '\t', quoting = .None, escapes = .Backslash, comment = '#'}

@(test)
test_dialect_cases :: proc(t: ^testing.T) {
	check_cases(t, []Case {
		{"a\\tb\tc\\\\d\\n\n", .None, 0, csv.TSV},
		{"\"a\"b\t\"\n", .None, 0, csv.TSV},
		{"a\tb\r\nc\td\r\n", .None, 0, csv.TSV},
		{"a\\0b\t\\0\n", .None, 0, csv.TSV},
		{"a\\1", .Bad_Escape, 1, csv.TSV},
		{"a\\x", .Bad_Escape, 1, csv.TSV},
		{"a\\", .Bad_Escape, 1, csv.TSV},
		{"a\\\tb", .Bad_Escape, 1, csv.TSV},
		{"a\\\nb", .Bad_Escape, 1, csv.TSV},
		{"a\\\r\n", .Bad_Escape, 1, csv.TSV},
		{"a\\\"", .Bad_Escape, 1, csv.TSV},
		{"\\\\\\", .Bad_Escape, 2, csv.TSV},
		{"a\rb", .Bad_Char, 1, csv.TSV},
		{"a\tb\nc\n", .Field_Count, 4, csv.TSV},
		{"a\"b;\"\n", .None, 0, UNQUOTED},
		{"a\\;b\n", .None, 0, UNQUOTED},
		{"\"a;b\"\nc\n", .Field_Count, 6, UNQUOTED},
		{"#x,y,z\na,b\n", .None, 0, COMMENTS},
		{"a,b\n#c\nd,e\n", .None, 0, COMMENTS},
		{"a,b\n#\"\nd,e\n", .None, 0, COMMENTS},
		{"a,b\n#c\r\n", .None, 0, COMMENTS},
		{"a,b\n#c", .None, 0, COMMENTS},
		{"a,b\nc#,d\n", .None, 0, COMMENTS},
		{"a,b\n\"#\",d\n", .None, 0, COMMENTS},
		{"a,b\n\"x\n#y\",d\n", .None, 0, COMMENTS},
		{"a,b\n#c\rd\n", .None, 0, COMMENTS},
		{"a,b\n#c\r\rd\r\n1,2\n", .None, 0, COMMENTS},
		{"a,b\n#c\r", .None, 0, COMMENTS},
		{"a,b\n#c\r1,2\n", .None, 0, COMMENTS},
		{"a,b\n1,2\r#c\n", .Bad_Char, 7, COMMENTS},
		{"a,b\n#\xFF\n", .Bad_Char, 5, COMMENTS},
		{"a,b\n #c\n", .Field_Count, 4, COMMENTS},
		{"#\\x\na\n", .None, 0, TSV_COMMENTS},
		{"a\n\\#\n", .Bad_Escape, 2, TSV_COMMENTS},
		{"a,b\nc\nd,e,f\n", .None, 0, {ragged = true}},
		{"a,b\nc\n\"d\n", .Truncated, 9, {ragged = true}},
	})
}

@(test)
test_dialect_options :: proc(t: ^testing.T) {
	Text :: struct {
		s: string,
	}
	src := transmute([]byte)string("a\n")
	refused := []csv.Dialect {
		{comment = '"'},
		{comment = '\r'},
		{comment = '\n'},
		{comment = ','},
		{comment = 0x80},
		{delimiter = ';', comment = ';'},
		{escapes = .Backslash},
		{quoting = .None, escapes = .Backslash, delimiter = '\\'},
		{quoting = .None, escapes = .Backslash, delimiter = 't'},
		{quoting = .None, escapes = .Backslash, delimiter = '0'},
		{delimiter = '\t', quoting = .None, escapes = .Backslash, comment = '\\'},
	}
	for d in refused {
		testing.expectf(t, csv.validate(src, d) == csv.Error{kind = .Bad_Option}, "%v: validate accepted", d)
		_, rerr := collect(src, d)
		testing.expectf(t, rerr == csv.Error{kind = .Bad_Option}, "%v: records %v", d, rerr)
		rows: []Text
		uerr := csv.unmarshal(src, &rows, {dialect = d}, allocator = context.temp_allocator)
		expect_check_agrees(t, src, []Text, {dialect = d}, uerr)
		testing.expectf(t, uerr != nil && uerr.?.kind == .Bad_Option, "%v: unmarshal %v", d, uerr)
		_, merr := csv.marshal([]Text{{"a"}}, {dialect = d}, allocator = context.temp_allocator)
		testing.expectf(t, merr == .Bad_Option, "%v: marshal %v", d, merr)
	}
	accepted := []csv.Dialect{csv.TSV, {quoting = .None, comment = '"'}, {comment = '#', ragged = true}, {quoting = .None, escapes = .Backslash, comment = '\t'}}
	for d in accepted {
		testing.expectf(t, csv.validate(src, d) == nil, "%v: validate refused", d)
	}
	testing.expect_value(t, csv.validate(src, limits = {max_fields = -1}), csv.Error{kind = .Bad_Option})
}

@(test)
test_dialect_field_text :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a\\tb\tc\\\\d\\n\\r\t\"q\"\n")
	recs, err := collect(src, csv.TSV)
	if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(recs), 1) {
		return
	}
	want := []string{"a\tb", "c\\d\n\r", `"q"`}
	for f, k in recs[0].fields {
		text, _, aerr := csv.field_text(src, f, csv.TSV, context.temp_allocator)
		testing.expect_value(t, aerr, nil)
		testing.expect_value(t, string(text), want[k])
		raw, escaped, _ := csv.field_text(src, f, {delimiter = '\t', quoting = .None})
		testing.expect(t, !escaped)
		testing.expect_value(t, string(raw), string(src[f.lo:f.hi]))
	}
}

@(test)
test_max_fields :: proc(t: ^testing.T) {
	Limit_Case :: struct {
		src:     string,
		dialect: csv.Dialect,
		max:     int,
		want:    Maybe(csv.Error),
	}
	cases := []Limit_Case {
		{"a,b\nc,d\n", {}, 2, nil},
		{"a,b,c\n", {}, 2, csv.Error{0, .Limit_Fields}},
		{"a,b\nc,d,e\n", {}, 2, csv.Error{4, .Limit_Fields}},
		{"a\nb,c,d\n", {ragged = true}, 2, csv.Error{2, .Limit_Fields}},
		{"a,b,c,\"d", {}, 2, csv.Error{0, .Limit_Fields}},
		{"a,b\n#c,d,e\n", COMMENTS, 2, nil},
		{strings.repeat("f,", 19, context.temp_allocator), {}, 20, nil},
		{strings.repeat("f,", 20, context.temp_allocator), {}, 20, csv.Error{0, .Limit_Fields}},
		// Later rows wider than the first, up to the cap and then one past it: a document checks each
		// record's own field count.
		{strings.repeat("a,b,c\n", 200, context.temp_allocator), {}, 3, nil},
		{strings.concatenate({strings.repeat("a,b,c\n", 200, context.temp_allocator), "a,b,c,d\n"}, context.temp_allocator), {ragged = true}, 3, csv.Error{1200, .Limit_Fields}},
	}
	for c in cases {
		src := transmute([]byte)c.src
		got := csv.validate(src, c.dialect, limits = {max_fields = c.max})
		testing.expectf(t, got == c.want, "%q: validate %v, want %v", c.src, got, c.want)
		_, rerr := collect(src, c.dialect, limits = {max_fields = c.max})
		testing.expectf(t, rerr == c.want, "%q: records %v, want %v", c.src, rerr, c.want)
		doc, derr := csv.build(src, c.dialect, header = false, limits = {max_fields = c.max})
		testing.expectf(t, derr == c.want, "%q: build %v, want %v", c.src, derr, c.want)
		csv.document_destroy(&doc)
	}
	Text :: struct {
		a: string,
	}
	rows: []Text
	err := read(t, "a\nx,y,z\n", &rows, {dialect = {ragged = true}, limits = {max_fields = 2}})
	e, refused := err.?
	testing.expect(t, refused && e.kind == .Syntax && e.syntax == .Limit_Fields && e.offset == 2 && path_text(e) == "[0]")
}

@(test)
test_strictness :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,\xFF\n")
	testing.expect_value(t, csv.validate(src), csv.Error{2, .Bad_Char})
	testing.expect_value(t, csv.validate(src, strictness = .Structural), nil)
	testing.expect_value(t, csv.validate(src, strictness = .Lazy), nil)
	recs, err := collect(src, {}, .Structural)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(recs), 1)
	// The structure is judged whatever the strictness.
	testing.expect_value(t, csv.validate(transmute([]byte)string("a\xFF\"b"), strictness = .Structural), csv.Error{2, .Bad_Char})
	testing.expect_value(t, csv.validate(transmute([]byte)string("\"a\"\xFF"), strictness = .Structural), csv.Error{3, .Bad_Char})
	testing.expect_value(t, csv.validate(transmute([]byte)string("a\\\xFF"), csv.TSV, .Structural), csv.Error{1, .Bad_Escape})
}

// `.Lazy` judges the UTF-8 of the header and of the cells a field reads, and of no other byte.
@(test)
test_unmarshal_lazy :: proc(t: ^testing.T) {
	Lazy_Case :: struct {
		src:        string,
		strictness: csv.Strictness,
		dialect:    csv.Dialect,
		kind:       csv.Error_Kind, // `.None` when accepted
		at:         u64,
		path:       string,
	}
	Text :: struct {
		a: string,
	}
	// Rows whose ignored column holds a UTF-8 fault, over several blocks, then a fault in the column that is read.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "a,b\n")
	for _ in 0 ..< 6 {
		strings.write_string(&b, "x,\xFF")
		strings.write_string(&b, strings.repeat("y", 70, context.temp_allocator))
		strings.write_string(&b, "\n")
	}
	far := u64(strings.builder_len(b))
	strings.write_string(&b, "\xFE,z\n")
	cases := []Lazy_Case {
		{"a,b\nx,\xFF\n", .Lazy, {}, .None, 0, ""},
		{"a,b\nx,\xFF\n", .Structural, {}, .None, 0, ""},
		{"a,b\nx,\xFF\n", .Strict, {}, .Bad_Char, 6, "[0]"},
		{"a,b\n\xFF,x\n", .Lazy, {}, .Bad_Char, 4, "[0]"},
		{"a,\xFF\n", .Lazy, {}, .Bad_Char, 2, ""},
		{"a,b\nx,\xFF\n\xFE,y\n", .Lazy, {}, .Bad_Char, 8, "[1]"},
		{"a,b\nx,\xC3", .Lazy, {}, .None, 0, ""},
		{"a,b\nx,\xC3", .Strict, {}, .Truncated, 7, "[0]"},
		{"a\n#\xFF\nx\n", .Lazy, COMMENTS, .None, 0, ""},
		{"a\n#\xFF\nx\n", .Strict, COMMENTS, .Bad_Char, 3, "[0]"},
		{"a\tb\nx\t\xFF\n", .Lazy, csv.TSV, .None, 0, ""},
		{strings.to_string(b), .Lazy, {}, .Bad_Char, far, "[6]"},
	}
	for c in cases {
		rows: []Text
		err := read(t, c.src, &rows, {dialect = c.dialect, strictness = c.strictness})
		e, refused := err.?
		if c.kind == .None {
			testing.expectf(t, !refused && len(rows) > 0 && rows[0].a == "x", "%q %v: %v, rows %v", c.src, c.strictness, err, rows)
			continue
		}
		testing.expectf(t, refused && e.kind == .Syntax && e.syntax == c.kind && e.offset == c.at && path_text(e) == c.path, "%q %v: %v (path %q), want %v at %d %q", c.src, c.strictness, err, path_text(e), c.kind, c.at, c.path)
	}
}

@(test)
test_unmarshal_ragged :: proc(t: ^testing.T) {
	Pair :: struct {
		a, b: string,
	}
	rows: []Pair
	src := "a,b\n1\n2,3,4\n"
	testing.expect_value(t, read(t, src, &rows, {dialect = {ragged = true}}), nil)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0], Pair{"1", ""})
	testing.expect_value(t, rows[1], Pair{"2", "3"})
	e, refused := read(t, src, &rows, {dialect = {ragged = true}, unknown_fields = .Refuse}).?
	testing.expect(t, refused && e.kind == .Unknown_Field && e.offset == 10 && path_text(e) == "[1]")
	Required :: struct {
		a: string,
		b: string `csv:",required"`,
	}
	req: []Required
	e, refused = read(t, "a,b\n1\n", &req, {dialect = {ragged = true}}).?
	testing.expect(t, refused && e.kind == .Missing_Field && e.offset == 5 && path_text(e) == "[0].b")
}

// Without a header in a ragged text, column k reads field k whatever the first record's width.
@(test)
test_unmarshal_ragged_without_header :: proc(t: ^testing.T) {
	Row :: struct {
		x, y: string,
		z:    Maybe(string),
	}
	opts := csv.Unmarshal_Opts{dialect = {ragged = true}, no_header = true}
	rows: []Row
	testing.expect_value(t, read(t, "a\nb,c,d\ne,f\n", &rows, opts), nil)
	if !testing.expect_value(t, len(rows), 3) {
		return
	}
	testing.expect_value(t, rows[0], Row{"a", "", nil})
	testing.expect_value(t, rows[1], Row{"b", "c", "d"})
	testing.expect_value(t, rows[2], Row{"e", "f", nil})

	opts.unknown_fields = .Refuse
	rows = nil
	testing.expect_value(t, read(t, "a\nb,c,d\n", &rows, opts), nil)
	e, refused := read(t, "a\nb,c,d,e\n", &rows, opts).?
	testing.expect(t, refused && e.kind == .Unknown_Field && e.offset == 8 && path_text(e) == "[1]")
}

@(test)
test_dialect_marshal_spelling :: proc(t: ^testing.T) {
	Line :: struct {
		name: string,
		n:    int,
		note: Maybe(string),
	}
	rows := []Line{{"a\tb", 1, "x"}, {"x\ny\r", -2, nil}, {"back\\slash", 3, `q"d`}, {"", 4, "#c"}, {"#hash", 5, nil}}
	out, err := csv.marshal(rows, {dialect = csv.TSV}, allocator = context.temp_allocator)
	testing.expect_value(t, err, csv.Marshal_Error.None)
	testing.expect_value(t, string(out), "name\tn\tnote\na\\tb\t1\tx\nx\\ny\\r\t-2\t\nback\\\\slash\t3\tq\"d\n\t4\t#c\n#hash\t5\t\n")
	out, _ = csv.marshal([]Line{{"#hash", 1, nil}}, {dialect = COMMENTS, no_header = true}, allocator = context.temp_allocator)
	testing.expect_value(t, string(out), "\"#hash\",1,\n")
}

@(test)
test_marshal_unwritable :: proc(t: ^testing.T) {
	Text :: struct {
		s: string,
	}
	Two :: struct {
		a, b: string,
	}
	Opt :: struct {
		s: Maybe(string),
	}
	Num :: struct {
		x: f64,
	}
	expect_out :: proc(t: ^testing.T, rows: []$T, d: csv.Dialect, want: string, want_err := csv.Marshal_Error.None, loc := #caller_location) {
		out, err := csv.marshal(rows, {dialect = d, no_header = true}, allocator = context.temp_allocator)
		testing.expect_value(t, err, want_err, loc)
		testing.expect_value(t, string(out), want, loc)
	}
	plain := csv.Dialect{quoting = .None}
	expect_out(t, []Text{{"a,b"}}, plain, "", .Unwritable)
	expect_out(t, []Text{{"x\ny"}}, plain, "", .Unwritable)
	expect_out(t, []Text{{"x\ry"}}, csv.TSV, "x\\ry\n")
	expect_out(t, []Text{{"a\"b\\c"}}, plain, "a\"b\\c\n")
	expect_out(t, []Text{{"a,b"}}, csv.TSV, "a,b\n")
	expect_out(t, []Text{{"a;b"}}, {delimiter = ';', quoting = .None, escapes = .Backslash}, "", .Unwritable)
	expect_out(t, []Text{{"#x"}}, {quoting = .None, comment = '#'}, "", .Unwritable)
	expect_out(t, []Text{{"#x"}}, TSV_COMMENTS, "", .Unwritable)
	expect_out(t, []Two{{"x", "#y"}}, {quoting = .None, comment = '#'}, "x,#y\n")
	expect_out(t, []Text{{"\tx"}}, {quoting = .None, escapes = .Backslash, comment = '\t'}, "\\tx\n")
	expect_out(t, []Text{{"\xEF\xBB\xBFabc"}}, plain, "", .Unwritable)
	expect_out(t, []Opt{{""}}, plain, "", .Unwritable)
	expect_out(t, []Opt{{""}}, {}, "\"\"\n")
	expect_out(t, []Opt{{nil}}, plain, "", .Unwritable)
	expect_out(t, []Num{{1.5}}, {delimiter = '.', quoting = .None}, "", .Unwritable)
}
