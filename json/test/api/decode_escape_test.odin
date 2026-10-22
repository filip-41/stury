package json_tests

import json "../.."
import "core:testing"

// Structural framing accepts these documents. Escape grammar is not its job.
// The decode door is what refuses a token the scan did not validate.
@(test)
test_decode_span_refuses_malformed_escapes :: proc(t: ^testing.T) {
	zz := transmute([]byte)string(`["\uZZZZ"]`)
	testing.expect(t, json.validate(zz, .Json, .Structural) == nil, `structural accepts ["\uZZZZ"]`)
	_, _, ok := json.decode_span(zz, 1, u64(len(zz) - 1), .String, context.temp_allocator)
	testing.expect(t, !ok, `decode_span refuses ["\uZZZZ"]`)

	// Fewer than four bytes before the closing quote.
	trunc := transmute([]byte)string(`["\u12"]`)
	_, _, ok = json.decode_span(trunc, 1, u64(len(trunc) - 1), .String, context.temp_allocator)
	testing.expect(t, !ok, `decode_span refuses ["\u12"]`)

	// The token is the whole buffer: a short `\u` must not read past src.
	root := transmute([]byte)string(`"\u12"`)
	_, _, ok = json.decode_span(root, 0, u64(len(root)), .String, context.temp_allocator)
	testing.expect(t, !ok, `decode_span refuses "\u12"`)

	bad := transmute([]byte)string(`["\x"]`)
	testing.expect(t, json.validate(bad, .Json, .Structural) == nil, `structural accepts ["\x"]`)
	_, _, ok = json.decode_span(bad, 1, u64(len(bad) - 1), .String, context.temp_allocator)
	testing.expect(t, !ok, `decode_span refuses ["\x"]`)

	// Its bytes are checked as a strict scan checks a string's: a raw control byte or bytes that are not UTF-8
	// refuse, escaped or not, DEL and multi-byte UTF-8 read.
	for s in ([]string{"\"a\tb\"", "\"\\n\t\"", "\"\xff\"", "\"\xc3\"", "\"\xed\xa0\x80\"", "\"\\u0041\xc0\x80\"", "\"\x00\""}) {
		src := transmute([]byte)s
		testing.expectf(t, json.validate(src) != nil, "%q: validate accepts", s)
		d, _, s_ok := json.decode_span(src, 0, u64(len(src)), .String, context.temp_allocator)
		testing.expectf(t, !s_ok, "%q: decode_span %q", s, d)
	}
	for s in ([]string{"\"\x7f\"", "\"é\"", "\"\\té\"", "\"\xf0\x9f\x98\x80\""}) {
		src := transmute([]byte)s
		testing.expectf(t, json.validate(src) == nil, "%q: validate refuses", s)
		_, _, s_ok := json.decode_span(src, 0, u64(len(src)), .String, context.temp_allocator)
		testing.expectf(t, s_ok, "%q: decode_span refuses", s)
	}
}

// The short-integer and plain-run shortcuts decide nothing the full arms would decide otherwise: their edges
// (sign, 18 and 19 digits, a stop byte inside or past an 8-byte run) land as before.
@(test)
test_decode_span_shortcut_edges :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Num :: struct {
		tok:  string,
		want: json.Decoded,
		ok:   bool,
	}
	for c in ([]Num{
		{"0", i64(0), true},
		{"-7", i64(-7), true},
		{"123456789012345678", i64(123456789012345678), true},
		{"-123456789012345678", i64(-123456789012345678), true},
		{"9223372036854775807", i64(9223372036854775807), true},
		{"-9223372036854775808", i64(-9223372036854775808), true},
		{"9223372036854775808", u64(9223372036854775808), true},
		{"-", nil, false},
		{"", nil, false},
		{"1a", nil, false},
		// A leading zero is an integer part's only digit: these are two tokens, not one.
		{"01", nil, false},
		{"-01", nil, false},
		{"00", nil, false},
		{"0123456789012345678901", nil, false},
		{"00.5", nil, false},
		{"-00e1", nil, false},
	}) {
		d, _, ok := json.decode_span(transmute([]byte)c.tok, 0, u64(len(c.tok)), .Number)
		testing.expectf(t, ok == c.ok && d == c.want, "%q: %v %v, want %v %v", c.tok, d, ok, c.want, c.ok)
	}
	neg_zero, _, nz_ok := json.decode_span(transmute([]byte)string("-0"), 0, 2, .Number)
	_, is_int := neg_zero.(i64)
	testing.expect(t, nz_ok && !is_int, "-0 is not an i64")

	Str :: struct {
		tok: string,
		ok:  bool,
	}
	for c in ([]Str{
		{`"abcdefghijklmnop"`, true},
		{"\"abcdefgh\tij\"", false},
		{"\"abcdefgh\"ij\"", false},
		{"\"abcdefgh\xffij\"", false},
		{"\"abcdefg\x1f\"", false},
		{`"abcdefgh\nij"`, true},
		{"\"abcdefghé\"", true},
		{"\"abcdefgh\x7f\"", true},
	}) {
		_, _, ok := json.decode_span(transmute([]byte)c.tok, 0, u64(len(c.tok)), .String, context.temp_allocator)
		testing.expectf(t, ok == c.ok, "%q: ok %v, want %v", c.tok, ok, c.ok)
	}
}

// A lone surrogate half encodes no scalar: `.Bad_Escape` at its backslash from every validating entry, and no
// decode, the pair is one character. The command line refuses the same inputs at the same byte.
@(test)
test_lone_surrogates_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src: string,
		at:  int, // the backslash refused, or -1 for a document that reads
	}
	cases := [?]Case{
		{`"\uD800"`, 1},
		{`"\uDC00"`, 1},
		{`"\uD800x"`, 1},
		{`"\uD800A"`, 1},
		{`"\uD800\u0041"`, 1},
		{`"\uD800\uD800\uDC00"`, 1},
		{`"\uDC00\uD800"`, 1},
		{`["a\uDFFF"]`, 3},
		{`{"\uDBFF":1}`, 2},
		{`"\uD83D\uDE00"`, -1},
		{`"\udbff\udfff"`, -1},
	}
	for c in cases {
		src := transmute([]byte)c.src
		want: Maybe(json.Error)
		if c.at >= 0 {
			want = json.Error{kind = .Bad_Escape, offset = u64(c.at)}
		}
		testing.expectf(t, json.validate(src) == want, "%s: validate %v, want %v", c.src, json.validate(src), want)
		doc, berr := json.build(src, context.temp_allocator)
		testing.expectf(t, berr == want, "%s: build %v, want %v", c.src, berr, want)
		v: any
		uerr, refused := json.unmarshal(src, &v, {}, nil, context.temp_allocator).?
		testing.expectf(t, refused == (c.at >= 0) && (!refused || uerr.syntax == .Bad_Escape && uerr.offset == u64(c.at)), "%s: unmarshal %v", c.src, uerr)
		if c.src[0] != '"' {
			continue
		}
		d, _, ok := json.decode_span(src, 0, u64(len(src)), .String, context.temp_allocator)
		testing.expectf(t, ok == (c.at < 0), "%s: decode_span %v %v", c.src, d, ok)
		if c.at < 0 {
			s, _ := json.get_string(&doc, json.ROOT)
			testing.expectf(t, s == d.(string) && len(s) == 4, "%s: build %q, decode_span %q", c.src, s, d)
		}
	}
	// `.Structural` checks no escape, and the decode is what refuses there.
	lone := raw(`["\uDC00"]`)
	testing.expect_value(t, json.validate(lone, strictness = .Structural), nil)
	_, _, ok := json.decode_span(lone, 1, u64(len(lone) - 1), .String, context.temp_allocator)
	testing.expect(t, !ok, `decode_span refuses ["\uDC00"]`)
	// A path scan checks the values it passes over, so a lone half outside every answer is refused too.
	unread := raw(`{"a":"\uD800","v":1}`)
	req: json.Request({.Path})
	defer json.destroy(&req)
	testing.expect_value(t, json.request_init(&req, ".v"), nil)
	lone_at: json.Scan_Error = json.Error{kind = .Bad_Escape, offset = 6}
	testing.expect_value(t, json.scan(unread, &req), lone_at)
	// An input cut inside the low half is truncated, not refused.
	testing.expect_value(t, json.validate(raw(`"\uD800\uDC`)), json.Error{kind = .Truncated, offset = 11})
}

// An escaped string's buffer refused by the allocator is `ok = false`, nothing decoded.
@(test)
test_decode_span_refused_allocator :: proc(t: ^testing.T) {
	src := raw(`"a\nb"`)
	budget := Budget{backing = context.allocator}
	d, _, ok := json.decode_span(src, 0, u64(len(src)), .String, budget_allocator(&budget))
	testing.expect(t, !ok && d == nil, "a refused buffer decodes nothing")
}
