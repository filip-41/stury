package json_tests

import "core:strconv"
import "core:strings"
import "core:testing"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:testkit"

// The value node of a one-value text's root array.
first_value :: proc(t: ^testing.T, doc: ^tape.Document) -> tape.Node_Index {
	testing.expect(t, len(doc.nodes) >= 2)
	return 1
}

// A number reads exact as an integer while it fits `i64` or `u64`, else as the correctly rounded binary64, and as
// `Wide` past binary64's range, and its text is as written.
@(test)
numbers_read_exact_or_rounded :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text: string,
		kind: spell.Number_Kind,
		bits: u64,
	}
	cases := []Case {
		{"0", .Int, 0},
		{"-0", .Int, 0},
		{"-0.0", .Float, 1 << 63},
		{"12345678", .Int, 12345678},
		{"-42", .Int, transmute(u64)i64(-42)},
		{"9223372036854775807", .Int, u64(max(i64))},
		{"9223372036854775808", .Uint, u64(1) << 63},
		{"-9223372036854775808", .Int, u64(1) << 63},
		{"18446744073709551615", .Uint, max(u64)},
		{"18446744073709551616", .Float, transmute(u64)f64(18446744073709551616)},
		{"0.1", .Float, transmute(u64)f64(0.1)},
		{"1.5e-7", .Float, transmute(u64)f64(1.5e-7)},
		{"2.5E+3", .Float, transmute(u64)f64(2500)},
		{"9007199254740993", .Int, 9007199254740993},
		{"9007199254740993.0", .Float, transmute(u64)f64(9007199254740992)},
		{"1.7976931348623157e308", .Float, 0x7FEF_FFFF_FFFF_FFFF},
		{"4.9e-324", .Float, 1},
		{"1e-400", .Float, 0},
		{"1e400", .Wide, 0},
	}
	all := make([dynamic]Case, context.temp_allocator)
	append(&all, ..cases)
	append(&all, Case{strings.concatenate({"1", strings.repeat("0", 400, context.temp_allocator)}, context.temp_allocator), .Wide, 0})
	for c in all {
		doc, err := build(t, strings.concatenate({"[", c.text, "]"}, context.temp_allocator))
		testing.expect_value(t, err, nil)
		num, ok := tape.node_number(&doc, first_value(t, &doc))
		testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "%s: %v %x, want %v %x", c.text, num.kind, num.bits, c.kind, c.bits)
		text, is_text := tape.node_text(&doc, first_value(t, &doc), nil)
		testing.expectf(t, is_text && text == c.text, "%s reads as the text %q", c.text, text)
		tape.destroy(&doc)
	}
}

// A string with no escape reads as its span, and one with escapes decodes into the buffer, short or long, with escapes
// on either side of a 64-byte block's edge.
@(test)
strings_decode_their_escapes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	long := strings.repeat(`ab\n`, 120, context.temp_allocator)
	long_want := strings.repeat("ab\n", 120, context.temp_allocator)
	Case :: struct {
		text, want: string,
	}
	cases := []Case {
		{`""`, ""},
		{`"plain é"`, "plain é"},
		{`"a\"b\\c\/d\be\ff\ng\rh\ti"`, "a\"b\\c/d\be\ff\ng\rh\ti"},
		{`"é€😀\u0000"`, "é€😀\x00"},
		{strings.concatenate({`"`, long, `"`}, context.temp_allocator), long_want},
		{strings.concatenate({`"`, strings.repeat("x", 62, context.temp_allocator), `€`, strings.repeat("y", 300, context.temp_allocator), `"`}, context.temp_allocator), strings.concatenate({strings.repeat("x", 62, context.temp_allocator), "€", strings.repeat("y", 300, context.temp_allocator)}, context.temp_allocator)},
	}
	for c in cases {
		doc, err := build(t, strings.concatenate({"[", c.text, "]"}, context.temp_allocator))
		testing.expect_value(t, err, nil)
		buf := make([]u8, len(c.text), context.temp_allocator)
		s, ok := tape.node_text(&doc, first_value(t, &doc), buf)
		testing.expectf(t, ok && s == c.want, "%q read as %q", c.text, s)
		tape.destroy(&doc)
	}
}

// A key reads as a string does, and a buffer shorter than an escaped string's span is refused.
@(test)
keys_and_short_buffers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := build(t, `{"kéy": "v\n", "n": 1}`)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	buf: [16]u8
	key, ok := tape.node_text(&doc, 1, buf[:])
	testing.expectf(t, ok && key == "kéy", "key %q", key)
	_, fits := tape.node_text(&doc, 2, buf[:2])
	testing.expect(t, !fits)
	_, is_number := tape.node_number(&doc, 0)
	testing.expect(t, !is_number)
}

// Escaped strings decode identically at 16/32/64/256-byte boundaries, across all UTF-8 `\u` widths, and with tight
// buffers and sources.
@(test)
strings_decode_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text, want: string,
	}
	cases := []Case {
		{`"a\nb"`, "a\nb"},
		{`"\"\"\\\\\n\t\u0041\u0042"`, "\"\"\\\\\n\tAB"},
		{`"\u0000\u0041\u007f\u0080\u00e9\u07ff\u0800\u20ac\uffff\ud83d\ude00\uD800\uDC00\uDBFF\uDFFF"`, "\x00A\x7f\u0080é\u07ff\u0800€\uffff😀\U00010000\U0010ffff"},
	}
	for c in cases {
		doc, err := build(t, c.text)
		testing.expect_value(t, err, nil)
		buf := make([]u8, doc.nodes[0].n, context.temp_allocator)
		s, ok := tape.node_text(&doc, 0, buf)
		testing.expectf(t, ok && s == c.want, "%q read as %q, want %q", c.text, s, c.want)
		tape.destroy(&doc)
	}
	for off in ([]int{0, 14, 15, 16, 31, 63, 255}) {
		src := strings.concatenate({`"`, strings.repeat("a", off, context.temp_allocator), `\n`, "tail", `"`}, context.temp_allocator)
		want := strings.concatenate({strings.repeat("a", off, context.temp_allocator), "\n", "tail"}, context.temp_allocator)
		doc, err := build(t, src)
		testing.expect_value(t, err, nil)
		buf := make([]u8, doc.nodes[0].n, context.temp_allocator)
		s, ok := tape.node_text(&doc, 0, buf)
		testing.expectf(t, ok && s == want, "off %d failed", off)
		tape.destroy(&doc)
	}
}

// Fractions, integers, and Clinger/Eisel-Lemire boundaries decode accurately in both tight root inputs and arrays.
@(test)
numbers_decode_boundaries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pad := strings.repeat(" ", 44, context.temp_allocator)
	floats := []string {
		"0.5", "-0.0", "1.2", "12.345", "123456.7", "1.234567",
		"12.34567890123", "123456789.012345",
		"900719925474099.1", "900719925474099.2", "900719925474099.3",
		"-123.4567890123456", "-0.0000000000000000", "12345678901234567.8", "123456789012345678.9", "1234567890123456789.1",
		"5.1814081e-74", "8.37e+272",
	}
	for s in floats {
		want_f, want_ok := strconv.parse_f64(s)
		testing.expect(t, want_ok)
		want_bits := transmute(u64)want_f
		wraps := []string {
			s,
			strings.concatenate({"[", s, "]"}, context.temp_allocator),
			strings.concatenate({pad, s}, context.temp_allocator),
			strings.concatenate({pad, s, "        "}, context.temp_allocator),
		}
		for wrap in wraps {
			doc, err := build(t, wrap)
			testing.expect_value(t, err, nil)
			node := first_value(t, &doc) if wrap[0] == '[' else tape.ROOT
			num, ok := tape.node_number(&doc, node)
			testing.expectf(t, ok && num.kind == .Float && num.bits == want_bits, "%q: %v %x, want Float %x", wrap, num.kind, num.bits, want_bits)
			tape.destroy(&doc)
		}
	}
	Int_Case :: struct {
		text: string,
		kind: spell.Number_Kind,
		bits: u64,
	}
	ints := []Int_Case {
		{"7", .Int, 7},
		{"12345678", .Int, 12345678},
		{"123456789", .Int, 123456789},
		{"1234567890123456", .Int, 1234567890123456},
		{"12345678901234567", .Int, 12345678901234567},
		{"1234567890123456789", .Int, 1234567890123456789},
		{"10000000000000000000", .Uint, 10000000000000000000},
		{"123456789012345678901234567890", .Float, transmute(u64)f64(123456789012345678901234567890.0)},
	}
	for c in ints {
		wraps := []string {
			c.text,
			strings.concatenate({"[", c.text, "]"}, context.temp_allocator),
			strings.concatenate({pad, c.text}, context.temp_allocator),
			strings.concatenate({pad, c.text, "        "}, context.temp_allocator),
		}
		for wrap in wraps {
			doc, err := build(t, wrap)
			testing.expect_value(t, err, nil)
			node := first_value(t, &doc) if wrap[0] == '[' else tape.ROOT
			num, ok := tape.node_number(&doc, node)
			testing.expectf(t, ok && num.kind == c.kind && num.bits == c.bits, "%q: %v %x, want %v %x", wrap, num.kind, num.bits, c.kind, c.bits)
			tape.destroy(&doc)
		}
	}
}

// A seeded xorshift generator of number texts.
Number_Gen :: struct {
	state: u64,
}

// A value below `n` from `g`.
gen_below :: proc(g: ^Number_Gen, n: int) -> int {
	g.state ~= g.state << 13
	g.state ~= g.state >> 7
	g.state ~= g.state << 17
	return int(g.state % u64(n))
}

// A JSON number of up to 21 integer and 21 fraction digits, with an exponent one time in five.
gen_number :: proc(g: ^Number_Gen, b: ^strings.Builder) {
	if gen_below(g, 4) == 0 {
		strings.write_byte(b, '-')
	}
	int_digits := 1 + gen_below(g, 21)
	if int_digits == 1 && gen_below(g, 3) == 0 {
		strings.write_byte(b, '0')
	} else {
		strings.write_byte(b, u8('1' + gen_below(g, 9)))
		for _ in 1 ..< int_digits {
			strings.write_byte(b, u8('0' + gen_below(g, 10)))
		}
	}
	if gen_below(g, 3) != 0 {
		strings.write_byte(b, '.')
		for _ in 0 ..= gen_below(g, 21) {
			strings.write_byte(b, u8('0' + gen_below(g, 10)))
		}
	}
	if gen_below(g, 5) == 0 {
		strings.write_byte(b, 'e' if gen_below(g, 2) == 0 else 'E')
		if sign := gen_below(g, 3); sign != 0 {
			strings.write_byte(b, '+' if sign == 1 else '-')
		}
		for _ in 0 ..= gen_below(g, 3) {
			strings.write_byte(b, u8('0' + gen_below(g, 10)))
		}
	}
}

// The value `strconv` reads from the JSON number `s`, as the readers report it.
strconv_number :: proc(s: string) -> spell.Number {
	if !strings.contains_any(s, ".eE") {
		if v, ok := strconv.parse_i64_of_base(s, 10); ok {
			return {u64(v), .Int}
		}
		if v, ok := strconv.parse_u64_of_base(s, 10); ok && s[0] != '-' {
			return {v, .Uint}
		}
	}
	f, _ := strconv.parse_f64(s)
	if bits := transmute(u64)f; bits & (0x7FF << 52) != 0x7FF << 52 {
		return {bits, .Float}
	}
	return {0, .Wide}
}

// Every number reads as `strconv` reads it: in compact and pretty arrays, and alone at every offset near the start and
// end of a text.
@(test)
numbers_read_as_strconv_reads_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	g := Number_Gen{0x9E37_79B9_7F4A_7C15}
	for sep in ([]string{",", ",\n  "}) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for i in 0 ..< 4000 {
			if i > 0 {
				strings.write_string(&b, sep)
			}
			gen_number(&g, &b)
		}
		strings.write_byte(&b, ']')
		text := strings.to_string(b)
		doc, err := build(t, text)
		testing.expect_value(t, err, nil)
		for node, i in doc.nodes[1:] {
			s := text[node.lo:][:node.n]
			num, ok := tape.node_number(&doc, tape.Node_Index(i + 1))
			want := strconv_number(s)
			testing.expectf(t, ok && num == want, "%s: %v %x, want %v %x", s, num.kind, num.bits, want.kind, want.bits)
		}
		tape.destroy(&doc)
	}
	for _ in 0 ..< 3000 {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< gen_below(&g, 64) {
			strings.write_byte(&b, ' ')
		}
		lo := strings.builder_len(b)
		gen_number(&g, &b)
		s := strings.to_string(b)[lo:]
		for _ in 0 ..< gen_below(&g, 10) {
			strings.write_byte(&b, ' ')
		}
		doc, err := build(t, strings.to_string(b))
		testing.expect_value(t, err, nil)
		num, ok := tape.node_number(&doc, 0)
		want := strconv_number(s)
		testing.expectf(t, ok && num == want, "%q at %d: %v %x, want %v %x", s, lo, num.kind, num.bits, want.kind, want.bits)
		tape.destroy(&doc)
	}
}
