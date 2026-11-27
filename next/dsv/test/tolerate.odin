package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

Tolerated :: struct {
	using c:   Case,
	tsv:       bool,
	no_header: bool,
	tol:       tape.Tolerances,
}

// Texts each tolerance set accepts, and faults no tolerance in the set accepts, which stay the same without it.
@(rodata)
TOLERATED := []Tolerated {
	{{"a,b,c\n1,2\n3\n", nil, 0, ""}, false, false, {.Ragged}},
	{{"a,b\n1", nil, 0, ""}, false, false, {.Ragged}},
	{{"1,2\n3\n4,5,6\n7,8,9,10", nil, 0, ""}, false, true, {.Ragged}},
	{{"a,b\n1,2,3\n", nil, 0, ""}, false, false, {.Ragged}},
	{{"a,b\n1,2,3,4", nil, 0, ""}, false, false, {.Ragged}},
	{{"a,b\n1,2,3\n", .Bad_Width, 7, "too_many_fields"}, false, false, {.Invalid_Utf8, .Bare_Quote}},
	{{"a,b\n1\n", .Bad_Width, 5, "too_few_fields"}, false, false, {.Invalid_Utf8, .Bare_Quote}},
	{{"a\tb\tc\n1\n", nil, 0, ""}, true, false, {.Ragged}},
	{{"a,5\" pipe,b\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"x\"y\"z\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"a\"\"b\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"a\"b,\"c,\"\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"ab\"", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"a\"b,\"c\n", .Truncated, 4, "open_quote"}, false, false, {.Bare_Quote}},
	{{"\"a\"b\n", .Bad_Char, 3, "after_quote"}, false, false, {.Bare_Quote}},
	{{"a\"\rb\n", .Bad_Char, 2, "lone_cr"}, false, false, {.Bare_Quote}},
	{{"a\"b\n", .Bad_Char, 1, "bare_quote"}, false, false, {.Ragged, .Invalid_Utf8}},
	{{"a\xff\n", nil, 0, ""}, false, false, {.Invalid_Utf8}},
	{{"a\xed\xa0\x80,\xc0\xaf\n", nil, 0, ""}, false, false, {.Invalid_Utf8}},
	{{"\"\xc3\",\"x\"\n", nil, 0, ""}, false, false, {.Invalid_Utf8}},
	{{"a\xc3", nil, 0, ""}, false, false, {.Invalid_Utf8}},
	{{"\"a\xc3", .Truncated, 0, "open_quote"}, false, false, {.Invalid_Utf8}},
	{{"a\xf5\n", nil, 0, ""}, true, false, {.Invalid_Utf8}},
	{{"a\xf0\x9f\x98", nil, 0, ""}, true, false, {.Invalid_Utf8}},
	{{"a\\xb\n", .Bad_Escape, 1, ""}, true, false, {.Invalid_Utf8, .Ragged, .Bare_Quote}},
	{{"a\xff\n", .Bad_Char, 1, "invalid_utf8"}, false, false, {.Ragged, .Bare_Quote}},
	{{"a,b\n\xff,x\"y\n1\n", nil, 0, ""}, false, false, {.Invalid_Utf8, .Lone_Surrogate, .Ragged, .Bare_Quote}},
	{{"a\xff\n", .Bad_Char, 1, "invalid_utf8"}, false, false, {.Lone_Surrogate}},
	{{"a\t\"b\n1\n", .Bad_Width, 6, "too_few_fields"}, true, false, {.Bare_Quote}},
}

// Texts with `#` comment lines. `.Invalid_Utf8` is for cells, so an ill-formed sequence in a comment line is still a
// fault.
@(rodata)
COMMENTED := []Tolerated {
	{{"a,b\n# ok\n1,\xff\n", nil, 0, ""}, false, false, {.Invalid_Utf8}},
	{{"a,b\n# x\xffy\n1,2\n", .Bad_Char, 7, "invalid_utf8"}, false, false, {.Invalid_Utf8}},
	{{"a,\xff\n# \xff\n", .Bad_Char, 6, "invalid_utf8"}, false, false, {.Invalid_Utf8}},
	{{"a\n#\xf0\x9f\x98\n", .Bad_Char, 3, "invalid_utf8"}, false, false, {.Invalid_Utf8}},
	{{"a,b\n1,2\n# x\xe2\x82", .Truncated, 13, "cut_utf8"}, false, false, {.Invalid_Utf8}},
	{{"a\tb\n# \xc3(\n", .Bad_Char, 6, "invalid_utf8"}, true, false, {.Invalid_Utf8}},
	{{"a\"b,c\n#x\n1,2\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"a,b\nx\"y,1\n#c\n2,3\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	// A tolerated bare quote opens no quoted cell, so the line after it still starts a comment.
	{{"y\"\n#,\"\n", nil, 0, ""}, false, false, {.Bare_Quote}},
	{{"a,b\n1,x\"\n#\"\n2,3\n", nil, 0, ""}, false, false, {.Bare_Quote}},
}

// Each tolerance after 0 to 129 empty lines, so what it accepts falls on every byte of a block. A text the set accepts
// is clean with it, faulty without it, and its build is flagged `.Tolerated`. A text it does not accept keeps the kind
// and offset it has without the set.
@(test)
tolerances :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [dynamic]u8
	defer delete(buf)
	for k in 0 ..< 130 {
		for commented in ([]bool{false, true}) {
			comment := u8('#') if commented else 0
			for c in (COMMENTED if commented else TOLERATED) {
				clear(&buf)
				for _ in 0 ..< k {
					append(&buf, '\n')
				}
				append(&buf, c.text)
				strict := dsv.Options{format = dsv.Dsv_Options{no_header = c.no_header, comment = comment}}
				opts := strict
				opts.tolerate = c.tol
				if !expect_reads(t, c, buf[:], k, c.tsv, opts) {
					return
				}
				if c.kind == nil {
					testing.expectf(t, dsv.validate(buf[:], spec_of(c.tsv), strict) != nil, "%q: a strict read takes it", c.text)
					doc, _ := dsv.build(buf[:], spec_of(c.tsv), opts)
					testing.expectf(t, .Tolerated in doc.flags, "%q: the build is not flagged tolerated", c.text)
					tape.destroy(&doc)
				}
			}
		}
	}
}
