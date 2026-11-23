package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// A text and the fault a read of it gives: its kind, the byte it names and the code of the rule that names the detail.
// A valid text has no kind.
Case :: struct {
	text:   string,
	kind:   tape.Fault_Kind,
	offset: u64,
	rule:   string, // code of the fault's rule, empty for a fault with none
}

// CSV texts and the fault each raises, at the byte the fault's rule names.
@(rodata)
CSV_CASES := []Case {
	{"", nil, 0, ""},
	{"a,b\n1,2\n", nil, 0, ""},
	{"a,b\r\n1,2", nil, 0, ""},
	{"\xef\xbb\xbfa\n", nil, 0, ""},
	{"a\n\n\r\nb\n", nil, 0, ""},
	{"\"a\"\"b\",c\n", nil, 0, ""},
	{"\"a\rb\nc,d\"\n", nil, 0, ""},
	{"a,\"\"\r\n", nil, 0, ""},
	{"a\\,b\n", nil, 0, ""},
	{"a,b\n1\n", .Bad_Width, 5, "too_few_fields"},
	{"a,b\n1,2,3", .Bad_Width, 7, "too_many_fields"},
	{"a\n\nb,c\n", .Bad_Width, 4, "too_many_fields"},
	{"a\"b\n", .Bad_Char, 1, "bare_quote"},
	{"\"a\"b\n", .Bad_Char, 3, "after_quote"},
	{"\"a\" ,b\n", .Bad_Char, 3, "after_quote"},
	{"\"abc", .Truncated, 0, "open_quote"},
	{"a,\"b\nc", .Truncated, 2, "open_quote"},
	{"a,\"b\xc3", .Truncated, 2, "open_quote"},
	{"a,\"b\xff", .Bad_Char, 4, "invalid_utf8"},
	{"a,b\n\"\"\"x\n\"\"\",\"y", .Truncated, 13, "open_quote"},
	{"a\rb\n", .Bad_Char, 1, "lone_cr"},
	{"a\r", .Bad_Char, 1, "lone_cr"},
	{"\"a\"\r", .Bad_Char, 3, "lone_cr"},
	{"a\xff\n", .Bad_Char, 1, "invalid_utf8"},
	{"a\xed\xa0\x80\n", .Bad_Char, 1, "invalid_utf8"},
	{"\"\xc3\"\n", .Bad_Char, 1, "invalid_utf8"},
	{"a\xc3", .Truncated, 2, "cut_utf8"},
	{"\"a\xc3", .Truncated, 0, "open_quote"},
	{"x,\"\xe2\x82", .Truncated, 2, "open_quote"},
	{"a,b\n1\r2,3\n", .Bad_Char, 5, "lone_cr"},
}

// TSV texts and the fault each raises, at the byte the fault's rule names.
@(rodata)
TSV_CASES := []Case {
	{"a\tb\n1\t2\n", nil, 0, ""},
	{"a\\tb\\\\\\n\\r\\0\n", nil, 0, ""},
	{"\"a\tb\n1\t2\n", nil, 0, ""},
	{"a,b\r\n", nil, 0, ""},
	{"a\\xb\n", .Bad_Escape, 1, ""},
	{"a\\", .Bad_Escape, 1, ""},
	{"a\\\n", .Bad_Escape, 1, ""},
	{"a\tb\n1\n", .Bad_Width, 5, "too_few_fields"},
	{"a\rb", .Bad_Char, 1, "lone_cr"},
	{"a\r", .Bad_Char, 1, "lone_cr"},
	{"\\\xff", .Bad_Escape, 0, ""},
	{"a\xf5\n", .Bad_Char, 1, "invalid_utf8"},
	{"a\xf0\x9f\x98", .Truncated, 4, "cut_utf8"},
}

// Whether `err` is the fault `c` names after `shift` bytes, or no error when `c` is a valid text.
fault_is :: proc(err: tape.Error, c: Case, shift: int) -> bool {
	if c.kind == nil {
		return err == nil
	}
	f, faulted := err.(tape.Fault)
	if !faulted || f.at != c.offset + u64(shift) || f.kind != c.kind || f.rules == nil || f.rules.format != "dsv" {
		return false
	}
	return int(f.detail) < len(f.rules.details) && f.rules.details[f.detail].code == c.rule
}

spec_of :: proc(tsv: bool) -> dsv.Spec {
	return .Tsv if tsv else .Csv
}

// Every read that checks the whole text gives the case's fault, after `shift` empty lines.
expect_reads :: proc(t: ^testing.T, c: Case, src: []u8, shift: int, tsv: bool, opts := dsv.Options{}, loc := #caller_location) -> bool {
	spec := spec_of(tsv)
	got := dsv.validate(src, spec, opts)
	ok := testing.expectf(t, fault_is(got, c, shift), "validate %q shifted %d: %v, want %v %q at %d", c.text, shift, got, c.kind, c.rule, c.offset, loc = loc)
	doc, berr := dsv.build(src, spec, opts)
	tape.destroy(&doc)
	ok &&= testing.expectf(t, fault_is(berr, c, shift), "build %q shifted %d: %v, want %v %q at %d", c.text, shift, berr, c.kind, c.rule, c.offset, loc = loc)
	_, ferr := dsv.find(src, []tape.Step{tape.Index(-1)}, spec, {}, opts)
	ok &&= testing.expectf(t, fault_is(ferr, c, shift), "find %q shifted %d: %v, want %v %q at %d", c.text, shift, ferr, c.kind, c.rule, c.offset, loc = loc)
	return ok
}

@(test)
faults_at_their_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in CSV_CASES {
		expect_reads(t, c, transmute([]u8)c.text, 0, false)
	}
	for c in TSV_CASES {
		expect_reads(t, c, transmute([]u8)c.text, 0, true)
	}
}

// Each case after 0 to 129 empty lines, which are no records. Every quote, CR, escape and UTF-8 sequence of a case
// falls on every byte of a 64-byte block and across the boundary between two, and its fault moves by the same count.
@(test)
faults_at_every_offset :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 130 {
		for tsv in ([]bool{false, true}) {
			for c in (TSV_CASES if tsv else CSV_CASES) {
				clear(&buf)
				for _ in 0 ..< k {
					append(&buf, '\n')
				}
				append(&buf, c.text)
				if !expect_reads(t, c, buf[:], k, tsv) {
					return
				}
			}
		}
	}
}

// A backslash at every byte of a block: each of the five escapes is valid there, and a byte no escape spells faults at
// the backslash. A comment line's backslash opens no escape.
@(test)
escapes_at_every_block_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b: [dynamic]u8
	defer delete(b)
	for k in 0 ..< 128 {
		for escape, valid in ([]u8{'t', 'n', 'r', '0', '\\', 'x', 'T', '\\' ~ 0x20, 0x80}) {
			clear(&b)
			append(&b, "h\n")
			for _ in 0 ..< k {
				append(&b, 'a')
			}
			append(&b, '\\', escape, '\n')
			err := dsv.validate(b[:], .Tsv)
			if valid < 5 {
				testing.expectf(t, err == nil, "backslash at %d escapes %#x: %v", 2 + k, escape, err)
			} else {
				f, bad := err.(tape.Fault)
				testing.expectf(t, bad && f.kind == .Bad_Escape && f.at == u64(2 + k), "backslash at %d escapes %#x: %v", 2 + k, escape, err)
			}
		}
	}
	comment := "h\n#a\\xb\n1\n"
	err := dsv.validate(transmute([]u8)comment, .Tsv, {format = dsv.Dsv_Options{comment = '#'}})
	testing.expectf(t, err == nil, "backslash in a comment line: %v", err)
}

// Each CSV fault reads as a sentence that says what is wrong, at the line and column of the byte its rule names.
@(test)
faults_read_as_sentences :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			text, line: string,
		} {
			{"a,b\n3\n", "2:2: Record has fewer fields than the first record"},
			{"a,b\n1,2,3\n", "2:4: Record has more fields than the first record"},
			{"a,b\n1,\xe9\n", "2:3: Invalid UTF-8 byte 0xE9"},
			{"a,b\n1,2\xc3", "2:5: Unfinished UTF-8 sequence"},
			{"a,b\n1,2\r3,4\n", "2:4: Carriage return not before a line feed"},
			{"a,b\n\"3\"x,4\n", "2:4: Character after a closing quote"},
			{"a,b\nx\"y,4\n", "2:2: Quote inside an unquoted field"},
			{"a,b\n1,\"2\n3,4\n", "2:3: Unfinished quoted field"},
			{"a,a\n1,2\n", "1:3: Duplicate key"},
		}) {
		src := transmute([]u8)c.text
		buf: [96]u8
		line := dsv.error_message(buf[:], dsv.validate(src, .Csv, {dups = .Refuse}), src)
		testing.expectf(t, line == c.line, "%q: %q, want %q", c.text, line, c.line)
	}
}

// A header whose quote the text never closes is the whole text to the pass, so the faults of the text after its first
// line come before the open quote, and no read takes the header for the line the quote opens on.
@(test)
a_header_with_an_unclosed_quote_runs_to_the_text_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("\"b\n\t,x\t,y\n\t z\xa9")
	opts := tape.Options {
		format = tape.Dsv_Options{delimiter = '\t'},
	}
	err := dsv.validate(src, .Csv, opts)
	fault, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && fault.kind == .Bad_Char && fault.at == 13, "validate: %v", err)
	doc, berr := dsv.build(src, .Csv, opts)
	defer dsv.destroy(&doc)
	bfault, bfaulted := berr.(tape.Fault)
	testing.expectf(t, bfaulted && bfault.kind == .Bad_Char && bfault.at == 13, "build: %v", berr)
}
