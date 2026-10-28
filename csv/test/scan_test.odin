package csv_tests

import "core:strings"
import "core:testing"
import csv "../"

Case :: struct {
	src:     string,
	kind:    Maybe(csv.Error_Kind), // nil when accepted
	at:      u64, // the fault's offset
	dialect: csv.Dialect,
}

@(test)
test_validate_cases :: proc(t: ^testing.T) {
	cases := []Case {
		{"", nil, 0, {}},
		{"a", nil, 0, {}},
		{"a,b\nc,d\n", nil, 0, {}},
		{"a,b\r\nc,d\r\n", nil, 0, {}},
		{"a,b\nc,d", nil, 0, {}},
		{"\xEF\xBB\xBFa,b\n", nil, 0, {}},
		{"a,b\n\n\r\nc,d\n", nil, 0, {}},
		{`"a,b","c""d"` + "\n" + `"e` + "\r\n" + `f",g` + "\n", nil, 0, {}},
		{`""`, nil, 0, {}},
		{`"",""""`, nil, 0, {}},
		{",\n,\n", nil, 0, {}},
		{"é,ü\n", nil, 0, {}},
		{`a,"b"x`, .Bad_Char, 5, {}},
		{`a,"b`, .Truncated, 4, {}},
		{`b"c`, .Bad_Char, 1, {}},
		{`a,b"`, .Bad_Char, 3, {}},
		{`"a" ,b`, .Bad_Char, 3, {}},
		{"a\rb", .Bad_Char, 1, {}},
		{"a\r", .Bad_Char, 1, {}},
		{"a,b\nc\n", .Bad_Structure, 4, {}},
		{"a\nb,c\n", .Bad_Structure, 2, {}},
		{"a,b\nc,d,e", .Bad_Structure, 4, {}},
		{"a\xFFb", .Bad_Char, 1, {}},
		{"a\xC3", .Truncated, 2, {}},
		{"a\xE2\x82", .Truncated, 3, {}},
		{"a\xE2\x28\xA1", .Bad_Char, 1, {}},
		{"\xED\xA0\x80", .Bad_Char, 0, {}},
		{"\xC0\xAF", .Bad_Char, 0, {}},
		{"a\xEF\xBB\xBF", nil, 0, {}},
	}
	check_cases(t, cases)
}

// Each case as written and with blank lines in front, which shift every construct across the block edges.
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

// The error of CSV fault `f` at `offset`.
csv_fault :: proc(offset: u64, f: csv.Fault) -> csv.Error {
	return {offset = offset, kind = .Bad_Structure if f == .Field_Count else .Limit_Format, detail = u8(f)}
}

// A case's error: `.Bad_Structure` is a validate's only structure fault, `Fault.Field_Count`.
case_error :: proc(c: Case, shift: u64) -> csv.Error {
	if c.kind.? == .Bad_Structure {
		return csv_fault(c.at + shift, .Field_Count)
	}
	return {offset = c.at + shift, kind = c.kind.?}
}

@(private = "file")
check :: proc(t: ^testing.T, src: []byte, c: Case, shift: u64) {
	got := csv.validate(src, {dialect = c.dialect})
	want: Maybe(csv.Error)
	if c.kind != nil {
		want = case_error(c, shift)
	}
	testing.expectf(t, got == want, "%q (shift %d): validate %v, want %v", c.src, shift, got, want)
	_, rerr := collect(src, c.dialect)
	testing.expectf(t, rerr == want, "%q (shift %d): records %v, want %v", c.src, shift, rerr, want)
}

@(test)
test_bad_delimiter :: proc(t: ^testing.T) {
	for d in ([]byte{'"', '\r', '\n', 0x80}) {
		testing.expect_value(t, csv.validate(transmute([]byte)string("a"), {dialect = {delimiter = d}}), csv.Error{kind = .Bad_Option})
	}
	testing.expect_value(t, csv.validate(transmute([]byte)string("a;b\nc;d"), {dialect = {delimiter = ';'}}), nil)
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
		for _, k in r.fields {
			text, escaped, aerr := csv.field_text(r, k)
			testing.expect_value(t, aerr, nil)
			testing.expect_value(t, text, want[i][k])
			if escaped {
				delete(text)
			}
		}
	}
	testing.expect_value(t, recs[0].at, 3)
	testing.expect_value(t, recs[1].at, 17)
}

// Cells longer than one 16-byte window, with `""` and escapes before and across window edges, and a short last
// cell at the input's end, decode as a byte-at-a-time reader does.
@(test)
test_field_text_long :: proc(t: ^testing.T) {
	Long_Case :: struct {
		dialect:   csv.Dialect,
		src, want: string,
	}
	cases := []Long_Case{
		{{}, "\"0123456789abcde\"\"f0123456789abcdef\"\"\"\"x\",\"\"\"\"", "0123456789abcde\"f0123456789abcdef\"\"x|\""},
		{{}, "\"\"\"0123456789abcdef0123456789abcdef\",a\"", ""},
		{{}, "\"0123456789abcdef0123456789abcdef\"\"\",\"a\"\"\"", "0123456789abcdef0123456789abcdef\"|a\""},
		{csv.TSV, "0123456789abcde\\tf0123456789abcdef\\\\\\n\t\\0", "0123456789abcde\tf0123456789abcdef\\\n|\x00"},
		{csv.TSV, "0123456789abcdef0123456789abcdef\\r\tplain", "0123456789abcdef0123456789abcdef\r|plain"},
	}
	for c in cases {
		src := transmute([]byte)c.src
		recs, err := collect(src, c.dialect)
		if c.want == "" {
			testing.expect(t, err != nil)
			continue
		}
		if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(recs), 1) {
			continue
		}
		got: [dynamic]string
		got.allocator = context.temp_allocator
		for _, k in recs[0].fields {
			text, _, aerr := csv.field_text(recs[0], k, context.temp_allocator)
			testing.expect_value(t, aerr, nil)
			append(&got, text)
		}
		testing.expect_value(t, strings.join(got[:], "|", context.temp_allocator), c.want)
	}
}

// Every record of `src`, its fields copied, and the iterator's fault.
collect :: proc(src: []byte, dialect: csv.Dialect, strictness := csv.Strictness.Strict, limits := csv.Limits{}) -> (out: [dynamic]csv.Record, err: Maybe(csv.Error)) {
	out.allocator = context.temp_allocator
	it := csv.records(src, {dialect = dialect, strictness = strictness, limits = limits})
	defer csv.destroy(&it)
	for r in csv.next_record(&it) {
		append(&out, csv.Record{fields = clone(r.fields), at = r.at, src = r.src, dialect = r.dialect})
	}
	return out, it.err
}

@(private = "file")
clone :: proc(f: []csv.Field) -> []csv.Field {
	c := make([]csv.Field, len(f), context.temp_allocator)
	copy(c, f)
	return c
}
