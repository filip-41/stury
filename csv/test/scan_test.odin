package csv_tests

import "core:fmt"
import "core:testing"
import "core:unicode/utf8"
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
		for shift in 1 ..= 70 {
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

// The scanner against a byte-at-a-time reading of the same rules, in each dialect, over generated CSV and
// mutations of it, judged strictly or structurally, with and without a field cap.
@(test)
test_scan_against_reference :: proc(t: ^testing.T) {
	dialects := []csv.Dialect {
		{},
		csv.TSV,
		{delimiter = ';', quoting = .None},
		{comment = '#'},
		{ragged = true},
		{delimiter = '\t', quoting = .None, escapes = .Backslash, comment = '#', ragged = true},
	}
	seed := u64(0x9E3779B97F4A7C15)
	for d in dialects {
		for iter in 0 ..< 12000 {
			src := generate(&seed, d, context.temp_allocator)
			strictness := csv.Strictness.Strict if next(&seed) % 4 != 0 else .Structural
			limits := csv.Limits{max_fields = 1 + int(next(&seed) % 4) if next(&seed) % 4 == 0 else 0}
			want_recs, want_err := reference(src, d, strictness == .Strict, limits.max_fields)
			got := csv.validate(src, d, strictness, limits)
			recs, err := collect(src, d, strictness, limits)
			if !testing.expectf(t, got == want_err && err == want_err, "%v case %d %q (%v, %v): validate %v, records %v, want %v", d, iter, src, strictness, limits, got, err, want_err) {
				return
			}
			if !testing.expectf(t, len(recs) == len(want_recs), "%v case %d %q: %d records, want %d", d, iter, src, len(recs), len(want_recs)) {
				return
			}
			for r, i in recs {
				if !testing.expectf(t, r.at == want_recs[i].at && fmt.tprint(r.fields) == fmt.tprint(want_recs[i].fields), "%v case %d %q: record %d %v, want %v", d, iter, src, i, r, want_recs[i]) {
					return
				}
			}
			free_all(context.temp_allocator)
		}
	}
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

@(private = "file")
next :: proc(s: ^u64) -> u64 {
	s^ ~= s^ << 13
	s^ ~= s^ >> 7
	s^ ~= s^ << 17
	return s^
}

// CSV in dialect `d`: fields of text, quoted text or escapes the dialect reads, holding delimiters, quotes,
// line breaks and UTF-8, LF or CRLF breaks, blank and comment lines, a BOM, one width unless `d` is ragged, and
// then, half the time, a few bytes inserted, deleted or replaced.
generate :: proc(s: ^u64, d: csv.Dialect, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	delim := d.delimiter if d.delimiter != 0 else ','
	if next(s) % 8 == 0 {
		append(&out, "\xEF\xBB\xBF")
	}
	width := 1 + int(next(s) % 4)
	rows := int(next(s) % 12)
	crlf := next(s) % 2 == 0
	plain := []string{"", "a", "bc", "1234567890", "é", "日本", "😀x", "lorem ipsum dolor sit amet"}
	quoted := []string{`""`, `"a,b"`, `"x""y"`, "\"l1\nl2\"", "\"c\r\nd\"", `""""`, "\"é,ü\"", `"long field with ""quotes"" and, commas, that runs on past a block edge........"`}
	unquoted := []string{`a"b`, `"`, `""x`, "x#y", "tab\\tbed", `\\`, "a\\nb\\r", "nul\\0byte", `a long field with \\t escapes and "quotes" that runs on past a block edge........`}
	for row in 0 ..< rows {
		if d.comment != 0 && next(s) % 6 == 0 {
			append(&out, d.comment)
			append(&out, " a comment, \"with\" \\x; and \t tabs é \r lone cr")
			append(&out, "\r\n" if crlf else "\n")
		}
		cols := 1 + int(next(s) % 4) if d.ragged else width
		for col in 0 ..< cols {
			if col > 0 {
				append(&out, delim)
			}
			k := next(s)
			switch {
			case k % 3 != 0:
				append(&out, plain[k % 8])
			case d.quoting == .Quotes:
				append(&out, quoted[(k >> 8) % 8])
			case:
				append(&out, unquoted[(k >> 8) % u64(len(unquoted))])
			}
		}
		if row + 1 < rows || next(s) % 2 == 0 {
			append(&out, "\r\n" if crlf else "\n")
		}
		if next(s) % 10 == 0 {
			append(&out, "\n")
		}
	}
	if next(s) % 2 == 0 && len(out) > 0 {
		alphabet := []byte{'a', delim, '"', '\n', '\r', '\\', 't', '0', '#', 0xC3, 0xA9, 0xFF, 0xE2, 0x82, ' '}
		for _ in 0 ..< 1 + int(next(s) % 3) {
			at := int(next(s) % u64(len(out)))
			b := alphabet[next(s) % u64(len(alphabet))]
			switch next(s) % 3 {
			case 0:
				inject_at(&out, at, b)
			case 1:
				ordered_remove(&out, at)
			case 2:
				out[at] = b
			}
			if len(out) == 0 {
				break
			}
		}
	}
	return out[:]
}

// A byte-at-a-time reading of the rules `csv.validate` documents for dialect `d`, judging UTF-8 when `strict`
// and capping a record at `max_fields` (0 for none): the records it yields and its fault.
@(private = "file")
reference :: proc(src: []byte, d: csv.Dialect, strict: bool, max_fields: int) -> (recs: [dynamic]csv.Record, err: Maybe(csv.Error)) {
	recs.allocator = context.temp_allocator
	State :: enum {Start, Plain, Quoted, Closed}
	delim := d.delimiter if d.delimiter != 0 else ','
	quotes, escapes := d.quoting == .Quotes, d.escapes == .Backslash
	cap := max_fields if max_fields > 0 else max(int)
	fields := make([dynamic]csv.Field, context.temp_allocator)
	n := len(src)
	i := 3 if n >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
	state := State.Start
	line, comment := true, false
	field_lo, rec_lo, width := i, i, 0
	close_field :: proc(fields: ^[dynamic]csv.Field, lo, hi, rec_lo, cap: int) -> Maybe(csv.Error) {
		if len(fields) == cap {
			return csv.Error{offset = u64(rec_lo), kind = .Limit_Fields}
		}
		append(fields, csv.Field{u64(lo), u64(hi)})
		return nil
	}
	end_record :: proc(recs: ^[dynamic]csv.Record, fields: ^[dynamic]csv.Field, src: []byte, rec_lo, end: int, width: ^int, d: csv.Dialect) -> Maybe(csv.Error) {
		defer clear(fields)
		if len(fields) == 1 && (end == rec_lo || end == rec_lo + 1 && src[rec_lo] == '\r' || d.comment != 0 && src[rec_lo] == d.comment) {
			return nil
		}
		if width^ == 0 {
			width^ = len(fields)
		} else if len(fields) != width^ && !d.ragged {
			return csv.Error{offset = u64(rec_lo), kind = .Field_Count}
		}
		f := make([]csv.Field, len(fields), context.temp_allocator)
		copy(f, fields[:])
		append(recs, csv.Record{fields = f, at = u64(rec_lo)})
		return nil
	}
	for i < n {
		c := src[i]
		if c >= 0x80 {
			if state == .Closed {
				return recs, csv.Error{offset = u64(i), kind = .Bad_Char}
			}
			size := 1
			if strict {
				r: rune
				r, size = utf8.decode_rune(src[i:])
				if r == utf8.RUNE_ERROR && size == 1 {
					if !utf8.full_rune(src[i:]) {
						return recs, csv.Error{offset = u64(n), kind = .Truncated}
					}
					return recs, csv.Error{offset = u64(i), kind = .Bad_Char}
				}
			}
			if state == .Start {
				state = .Plain
			}
			line = false
			i += size
			continue
		}
		if state == .Quoted {
			if c == '"' {
				state = .Closed
			}
			i += 1
			continue
		}
		if !comment && c == '\r' && (i + 1 >= n || src[i + 1] != '\n') {
			return recs, csv.Error{offset = u64(i), kind = .Bad_Char}
		}
		if comment && c != '\n' {
			i += 1
			continue
		}
		at_line := line
		line = false
		switch {
		case c == delim:
			close_field(&fields, field_lo, i, rec_lo, cap) or_return
			field_lo = i + 1
			state = .Start
		case c == '\n' || c == '\r':
			// A comment line's text up to its LF is one field.
			comment = false
			hi := i
			if c == '\r' {
				i += 1
			}
			close_field(&fields, field_lo, hi, rec_lo, cap) or_return
			end_record(&recs, &fields, src, rec_lo, i, &width, d) or_return
			field_lo, rec_lo = i + 1, i + 1
			state, line = .Start, true
		case at_line && d.comment != 0 && c == d.comment:
			comment = true
		case c == '"' && quotes:
			if state == .Plain {
				return recs, csv.Error{offset = u64(i), kind = .Bad_Char}
			}
			state = .Quoted
		case c == '\\' && escapes:
			if i + 1 >= n || !(src[i + 1] == 't' || src[i + 1] == 'n' || src[i + 1] == 'r' || src[i + 1] == '0' || src[i + 1] == '\\') {
				return recs, csv.Error{offset = u64(i), kind = .Bad_Escape}
			}
			state = .Plain
			i += 1
		case:
			if state == .Closed {
				return recs, csv.Error{offset = u64(i), kind = .Bad_Char}
			}
			state = .Plain
		}
		i += 1
	}
	if state == .Quoted {
		return recs, csv.Error{offset = u64(n), kind = .Truncated}
	}
	if rec_lo < n {
		close_field(&fields, field_lo, n, rec_lo, cap) or_return
		end_record(&recs, &fields, src, rec_lo, n, &width, d) or_return
	}
	return recs, nil
}
