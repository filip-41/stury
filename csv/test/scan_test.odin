package csv_tests

import "core:testing"
import csv "../"

Case :: struct {
	src:     string,
	kind:    csv.Error_Kind,
	at:      u64, // the fault's offset, when `kind` is not `.None`
	dialect: csv.Dialect,
}

@(test)
test_validate_cases :: proc(t: ^testing.T) {
	cases := []Case {
		{"", .None, 0, {}},
		{"a", .None, 0, {}},
		{"a,b\nc,d\n", .None, 0, {}},
		{"a,b\r\nc,d\r\n", .None, 0, {}},
		{"a,b\nc,d", .None, 0, {}},
		{"\xEF\xBB\xBFa,b\n", .None, 0, {}},
		{"a,b\n\n\r\nc,d\n", .None, 0, {}},
		{`"a,b","c""d"` + "\n" + `"e` + "\r\n" + `f",g` + "\n", .None, 0, {}},
		{`""`, .None, 0, {}},
		{`"",""""`, .None, 0, {}},
		{",\n,\n", .None, 0, {}},
		{"é,ü\n", .None, 0, {}},
		{`a,"b"x`, .Bad_Char, 5, {}},
		{`a,"b`, .Truncated, 4, {}},
		{`b"c`, .Bad_Char, 1, {}},
		{`a,b"`, .Bad_Char, 3, {}},
		{`"a" ,b`, .Bad_Char, 3, {}},
		{"a\rb", .Bad_Char, 1, {}},
		{"a\r", .Bad_Char, 1, {}},
		{"a,b\nc\n", .Field_Count, 4, {}},
		{"a\nb,c\n", .Field_Count, 2, {}},
		{"a,b\nc,d,e", .Field_Count, 4, {}},
		{"a\xFFb", .Bad_Char, 1, {}},
		{"a\xC3", .Truncated, 2, {}},
		{"a\xE2\x82", .Truncated, 3, {}},
		{"a\xE2\x28\xA1", .Bad_Char, 1, {}},
		{"\xED\xA0\x80", .Bad_Char, 0, {}},
		{"\xC0\xAF", .Bad_Char, 0, {}},
		{"a\xEF\xBB\xBF", .None, 0, {}},
	}
	check_cases(t, cases)
}

// Each case as written and with blank lines in front, which move every construct across the block edges.
check_cases :: proc(t: ^testing.T, cases: []Case) {
	for c in cases {
		check(t, transmute([]byte)c.src, c, 0)
		for shift in ([]int{1, 2, 63, 64, 65}) {
			if len(c.src) >= 3 && c.src[:3] == "\xEF\xBB\xBF" {
				break
			}
			buf := make([]byte, shift + len(c.src), context.temp_allocator)
			for i in 0 ..< shift {
				buf[i] = '\n'
			}
			copy(buf[shift:], c.src)
			check(t, buf, c, u64(shift))
		}
	}
}

@(private = "file")
check :: proc(t: ^testing.T, src: []byte, c: Case, shift: u64) {
	got := csv.validate(src, c.dialect)
	want: Maybe(csv.Error)
	if c.kind != .None {
		want = csv.Error{offset = c.at + shift, kind = c.kind}
	}
	testing.expectf(t, got == want, "%q (shift %d): validate %v, want %v", c.src, shift, got, want)
	_, rerr := collect(src, c.dialect)
	testing.expectf(t, rerr == want, "%q (shift %d): records %v, want %v", c.src, shift, rerr, want)
}

@(test)
test_bad_delimiter :: proc(t: ^testing.T) {
	for d in ([]byte{'"', '\r', '\n', 0x80}) {
		testing.expect_value(t, csv.validate(transmute([]byte)string("a"), {delimiter = d}), csv.Error{kind = .Bad_Option})
	}
	testing.expect_value(t, csv.validate(transmute([]byte)string("a;b\nc;d"), {delimiter = ';'}), nil)
}

@(test)
test_field_text :: proc(t: ^testing.T) {
	src := transmute([]byte)string("\xEF\xBB\xBFa,\"b,\"\"c\"\"\"\r\n\n\"x\ny\",\r\n")
	recs, err := collect(src, {})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(recs), 2)
	want := [][]string{{"a", `b,"c"`}, {"x\ny", ""}}
	for r, i in recs {
		testing.expect_value(t, len(r.fields), 2)
		for f, k in r.fields {
			text, escaped, aerr := csv.field_text(src, f)
			testing.expect_value(t, aerr, nil)
			testing.expect_value(t, string(text), want[i][k])
			if escaped {
				delete(text)
			}
		}
	}
	testing.expect_value(t, recs[0].at, 3)
	testing.expect_value(t, recs[1].at, 17)
}

// Every record of `src`, its fields copied, and the iterator's fault.
collect :: proc(src: []byte, dialect: csv.Dialect, strictness := csv.Strictness.Strict, limits := csv.Limits{}) -> (out: [dynamic]csv.Record, err: Maybe(csv.Error)) {
	out.allocator = context.temp_allocator
	it := csv.records(src, dialect, strictness, limits)
	defer csv.records_destroy(&it)
	for r in csv.next_record(&it) {
		append(&out, csv.Record{fields = clone(r.fields), at = r.at})
	}
	return out, it.err
}

@(private = "file")
clone :: proc(f: []csv.Field) -> []csv.Field {
	c := make([]csv.Field, len(f), context.temp_allocator)
	copy(c, f)
	return c
}
