package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The document and error of building `src` as `spec`, checked against `validate`'s answer.
build_spec :: proc(t: ^testing.T, src: string, spec: json.Spec) -> (tape.Document, tape.Error) {
	doc, err := json.build(transmute([]u8)src, spec)
	testing.expectf(t, fmt.tprint(json.validate(transmute([]u8)src, spec)) == fmt.tprint(err), "%v: validate and build disagree on %q", spec, src)
	return doc, err
}

// Expects `src` to be refused as `spec` with `kind` at offset `at`, by both `validate` and `build`.
expect_fault :: proc(t: ^testing.T, spec: json.Spec, src: string, kind: tape.Fault_Kind, at: int, loc := #caller_location) {
	doc, err := build_spec(t, src, spec)
	defer tape.destroy(&doc)
	f, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && f.kind == kind && f.at == u64(at), "%v %q: %v, want %v at %d", spec, src, err, kind, at, loc = loc)
}

// Expects `src` to build as `spec` and returns the document.
expect_builds :: proc(t: ^testing.T, spec: json.Spec, src: string, loc := #caller_location) -> tape.Document {
	doc, err := build_spec(t, src, spec)
	testing.expectf(t, err == nil, "%v %q: %v", spec, src, err, loc = loc)
	return doc
}

// The string `body`, in quotes, as the only value of an array and as the only key of an object, with `lead` plain bytes
// before it and `tail` after it. A string short of 32 bytes, one of 32 to 64 and a longer one are read by different
// readers, and a fault inside each is settled by the byte reader. The offset of the string's first byte in each text
// comes with it.
Placed :: struct {
	src:    string,
	at:     int,
	is_key: bool,
}

placed :: proc(body: string, lead, tail: int, quote := `"`) -> [2]Placed {
	pad := proc(n: int) -> string {return strings.repeat("x", n, context.temp_allocator)}
	s := strings.concatenate({quote, pad(lead), body, pad(tail), quote}, context.temp_allocator)
	return {
		{strings.concatenate({"[", s, "]"}, context.temp_allocator), 1 + len(quote) + lead, false},
		{strings.concatenate({"{", s, ":1}"}, context.temp_allocator), 1 + len(quote) + lead, true},
	}
}

// Each lead and tail that puts the fault in another reader's range.
PADS :: [?][2]int{{0, 0}, {0, 3}, {5, 0}, {20, 20}, {0, 70}, {40, 0}, {70, 70}}

// Expects `body`, a string's content, to be refused by every spec in `specs` with `kind` at its byte `at`.
expect_string_fault :: proc(t: ^testing.T, specs: []json.Spec, body: string, kind: tape.Fault_Kind, at: int, loc := #caller_location) {
	for spec in specs {
		for pad in PADS {
			for p in placed(body, pad[0], pad[1]) {
				expect_fault(t, spec, p.src, kind, p.at + at, loc)
			}
		}
	}
}

JSON_SPECS :: []json.Spec{.Json, .Jsonc, .Json5}

// The byte reader's refusals of a JSON string, each at its own byte.
@(test)
string_faults_are_exact :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for c in 0 ..< 0x20 {
		body := fmt.tprintf("a%cb", c)
		expect_string_fault(t, {.Json, .Jsonc}, body, .Bad_Char, 1)
	}
	expect_string_fault(t, {.Json, .Jsonc}, "\x1f", .Bad_Char, 0)
	expect_string_fault(t, {.Json, .Jsonc}, "ab\x7f\x1f", .Bad_Char, 3)
	Case :: struct {
		body: string,
		kind: tape.Fault_Kind,
		at:   int,
	}
	cases := []Case {
		{`ab\uZZZZ`, .Bad_Escape, 4},
		{`\u12G4`, .Bad_Escape, 4},
		{`\u123`, .Bad_Escape, 5},
		{`\u 123`, .Bad_Escape, 2},
		// A high half needs `\u` and a low half's digits, each refused at the half's backslash.
		{`\ud800`, .Bad_Escape, 0},
		{`\ud800x`, .Bad_Escape, 0},
		{`\ud800\n`, .Bad_Escape, 0},
		{`\ud800\u0041`, .Bad_Escape, 0},
		{`\ud800\u0c00`, .Bad_Escape, 0},
		{`\ud800\uec00`, .Bad_Escape, 0},
		{`\ud800\ud7ff`, .Bad_Escape, 0},
		{`\ud800\ue000`, .Bad_Escape, 0},
		{`\ud800\ud800`, .Bad_Escape, 0},
		{`\ud800\udc0`, .Bad_Escape, 0},
		{`\ud800\udcG0`, .Bad_Escape, 0},
		{`\udbff\udbff`, .Bad_Escape, 0},
		{`\uDBFF\u0041`, .Bad_Escape, 0},
		{`\u0041\ud800`, .Bad_Escape, 6},
		// A low half alone.
		{`\udc00`, .Bad_Escape, 0},
		{`\udfff`, .Bad_Escape, 0},
		{`\uDC00`, .Bad_Escape, 0},
		{`\ud83d\ude00\ude00`, .Bad_Escape, 12},
	}
	for c in cases {
		expect_string_fault(t, {.Json, .Jsonc, .Json5}, c.body, c.kind, c.at)
	}
}

// A text that ends inside a string or its escape is `Truncated` at its end.
@(test)
string_ends_inside_an_escape :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for text in ([]string{`["\`, `["\u`, `["\u00`, `["\ud800`, `["\ud800\`, `["\ud800\u`, `["\ud800\udc`, `["abc`}) {
		for pad in ([]string{"", strings.repeat("y", 70, context.temp_allocator)}) {
			src := strings.concatenate({text[:2], pad, text[2:]}, context.temp_allocator)
			for spec in JSON_SPECS {
				expect_fault(t, spec, src, .Truncated, len(src))
			}
		}
	}
}

// The escapes JSON allows decode to the text they spell, in a string that any reader may take.
@(test)
string_escapes_decode :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Case :: struct {
		body, want: string,
	}
	cases := []Case {
		{`A`, "A"},
		{`\u0041`, "A"},
		{`\u0141`, "Ł"},
		{`\u00e9\u00E9`, "éé"},
		{`\ud83d\ude00`, "😀"},
		{`\uD834\uDD1E`, "𝄞"},
		{`\udbff\udfff`, "\U0010ffff"},
		{`\ud800\udc00`, "\U00010000"},
		{`\u0000\u001f\u007f`, "\x00\x1f\x7f"},
		{`a\"b\\c\/d\b\f\n\r\t`, "a\"b\\c/d\b\f\n\r\t"},
		{`é\u0141\ud83d\ude00ü`, "éŁ😀ü"},
	}
	buf: [512]u8
	for c in cases {
		for spec in JSON_SPECS {
			for pad in PADS {
				for p in placed(c.body, pad[0], pad[1]) {
					doc := expect_builds(t, spec, p.src)
					defer tape.destroy(&doc)
					node := doc.nodes[1]
					got, ok := tape.node_text(&doc, node, buf[:])
					plain := strings.repeat("x", pad[0], context.temp_allocator)
					tail := strings.repeat("x", pad[1], context.temp_allocator)
					testing.expectf(t, ok && got == strings.concatenate({plain, c.want, tail}, context.temp_allocator), "%v %q: %q", spec, p.src, got)
				}
			}
		}
	}
}

// JSON5 strings hold any byte but CR and LF, and the escapes JSON5 adds.
@(test)
json5_string_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for quote in ([]string{`"`, `'`}) {
		for pad in PADS {
			for body, i in ([]string{"a\rb", "a\nb", "\r", "\n", "ab\r\n"}) {
				at := 0 if len(body) == 1 else (1 if i < 2 else 2)
				if i == 4 {
					at = 2
				}
				for p in placed(body, pad[0], pad[1], quote) {
					expect_fault(t, .Json5, p.src, .Bad_Char, p.at + at)
				}
			}
			for body in ([]string{"a\x00b", "a\x1fb", "a\x7fb", "a\u2028b", "a\u2029b", "a\x0bb"}) {
				for p in placed(body, pad[0], pad[1], quote) {
					doc := expect_builds(t, .Json5, p.src)
					tape.destroy(&doc)
				}
			}
		}
	}
	buf: [512]u8
	Case :: struct {
		src, want: string,
		kind:      tape.Fault_Kind,
		at:        int,
	}
	cases := []Case {
		{src = `['\x41\u0141\'\"\0']`, want = "AŁ'\"\x00"},
		{src = "['a\\\nb']", want = "ab"},
		{src = "['a\\\r\nb']", want = "ab"},
		{src = "['a\\\u2028b']", want = "ab"},
		{src = `["\ud83d\ude00\x7e"]`, want = "😀~"},
		{src = `['\x4']`, kind = .Bad_Escape, at = 5},
		{src = `['\xG1']`, kind = .Bad_Escape, at = 4},
		{src = `['\ud800']`, kind = .Bad_Escape, at = 2},
		{src = `['\udc00']`, kind = .Bad_Escape, at = 2},
		{src = `['\ud800\u0c00']`, kind = .Bad_Escape, at = 2},
		{src = `['\1']`, kind = .Bad_Escape, at = 3},
		{src = `['\u12G4']`, kind = .Bad_Escape, at = 6},
	}
	for c in cases {
		if c.kind != .None {
			expect_fault(t, .Json5, c.src, c.kind, c.at)
			continue
		}
		doc := expect_builds(t, .Json5, c.src)
		defer tape.destroy(&doc)
		got, ok := tape.node_text(&doc, doc.nodes[1], buf[:])
		testing.expectf(t, ok && got == c.want, "%q: %q, want %q", c.src, got, c.want)
	}
}


// The suite's `i_` texts are ones a parser may take or refuse. This pins what each spec does with them: none of a
// refused text's faults differs between JSON, JSONC and JSON5. Lone surrogate escapes and a BOM are decided here, and a
// change of that policy shows as a change of this table.
@(test)
implementation_defined_texts_keep_their_verdict :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Verdict :: struct {
		name: string,
		kind: tape.Fault_Kind, // `.None` for a text that builds
		at:   int,
	}
	want := []Verdict {
		{"i_number_double_huge_neg_exp.json", .None, 0},
		{"i_number_huge_exp.json", .None, 0},
		{"i_number_neg_int_huge_exp.json", .None, 0},
		{"i_number_pos_double_huge_exp.json", .None, 0},
		{"i_number_real_neg_overflow.json", .None, 0},
		{"i_number_real_pos_overflow.json", .None, 0},
		{"i_number_real_underflow.json", .None, 0},
		{"i_number_too_big_neg_int.json", .None, 0},
		{"i_number_too_big_pos_int.json", .None, 0},
		{"i_number_very_big_negative_int.json", .None, 0},
		{"i_object_key_lone_2nd_surrogate.json", .Bad_Escape, 2},
		{"i_string_1st_surrogate_but_2nd_missing.json", .Bad_Escape, 2},
		{"i_string_1st_valid_surrogate_2nd_invalid.json", .Bad_Escape, 2},
		{"i_string_UTF-16LE_with_BOM.json", .Bad_Char, 0},
		{"i_string_UTF-8_invalid_sequence.json", .Bad_Char, 7},
		{"i_string_UTF8_surrogate_U+D800.json", .Bad_Char, 2},
		{"i_string_incomplete_surrogate_and_escape_valid.json", .Bad_Escape, 2},
		{"i_string_incomplete_surrogate_pair.json", .Bad_Escape, 2},
		{"i_string_incomplete_surrogates_escape_valid.json", .Bad_Escape, 2},
		{"i_string_invalid_lonely_surrogate.json", .Bad_Escape, 2},
		{"i_string_invalid_surrogate.json", .Bad_Escape, 2},
		{"i_string_invalid_utf-8.json", .Bad_Char, 2},
		{"i_string_inverted_surrogates_U+1D11E.json", .Bad_Escape, 2},
		{"i_string_iso_latin_1.json", .Bad_Char, 2},
		{"i_string_lone_second_surrogate.json", .Bad_Escape, 2},
		{"i_string_lone_utf8_continuation_byte.json", .Bad_Char, 2},
		{"i_string_not_in_unicode_range.json", .Bad_Char, 2},
		{"i_string_overlong_sequence_2_bytes.json", .Bad_Char, 2},
		{"i_string_overlong_sequence_6_bytes.json", .Bad_Char, 2},
		{"i_string_overlong_sequence_6_bytes_null.json", .Bad_Char, 2},
		{"i_string_truncated-utf-8.json", .Bad_Char, 2},
		{"i_string_utf16BE_no_BOM.json", .Bad_Char, 0},
		{"i_string_utf16LE_no_BOM.json", .Bad_Char, 1},
		{"i_structure_500_nested_arrays.json", .None, 0},
		{"i_structure_UTF-8_BOM_empty_object.json", .None, 0},
	}
	files := #load_directory("conformance/JSONTestSuite/test_parsing")
	seen := 0
	for f in files {
		if f.name[:2] != "i_" {
			continue
		}
		seen += 1
		found := false
		for v in want {
			if v.name != f.name {
				continue
			}
			found = true
			for spec in JSON_SPECS {
				doc, err := build_spec(t, string(f.data), spec)
				if v.kind == .None {
					testing.expectf(t, err == nil, "%s as %v: %v", f.name, spec, err)
				} else {
					fault, faulted := err.(tape.Fault)
					testing.expectf(t, faulted && fault.kind == v.kind && fault.at == u64(v.at), "%s as %v: %v, want %v at %d", f.name, spec, err, v.kind, v.at)
				}
				tape.destroy(&doc)
			}
		}
		testing.expectf(t, found, "%s has no pinned verdict", f.name)
	}
	testing.expect_value(t, seen, len(want))
}

// The unquoted keys JSON5 allows: ECMAScript 5.1 IdentifierNames, which start with a letter, `$`, `_` or an escape of
// one, and go on with marks, digits, connectors and the joiners ZWNJ and ZWJ.
@(test)
json5_identifier_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	accepted := []string {
		"a",
		"$_x9",
		"\xc3\xa9t\xc3\xa9",
		"a\xcc\x81", // U+0301, a mark
		"a\xe2\x80\x8db", // ZWJ
		"a\xe2\x80\x8cb", // ZWNJ
		"a\xd9\xa0", // U+0660, a decimal digit
		"a\xe2\x80\xbf", // U+203F, a connector
		"@u0061b",
		"a@u200db",
		"a@u0301",
		"a@u0661",
		"\xe2\x85\xa0", // U+2160, a letter number
		"\xca\xb0", // U+02B0, a modifier letter
	}
	for spelled in accepted {
		key := fix_escapes(spelled)
		src := strings.concatenate({"{", key, ":1}"}, context.temp_allocator)
		doc := expect_builds(t, .Json5, src)
		testing.expectf(t, len(doc.nodes) == 3 && doc.nodes[1].role == .Key && src[doc.nodes[2].lo:][:doc.nodes[2].n] == "1", "%q: %v", src, doc.nodes)
		tape.destroy(&doc)
	}
	Case :: struct {
		key:  string,
		kind: tape.Fault_Kind,
		at:   int, // in the key
	}
	refused := []Case {
		{"1a", .Bad_Char, 0},
		{"9a", .Bad_Char, 0},
		{"0", .Bad_Char, 0},
		{"\xe2\x80\x8da", .Bad_Char, 0}, // ZWJ
		{"\xe2\x80\x8ca", .Bad_Char, 0}, // ZWNJ
		{"\xcc\x81a", .Bad_Char, 0}, // a mark
		{"\xd9\xa0a", .Bad_Char, 0}, // a decimal digit
		{"\xe2\x80\xbfa", .Bad_Char, 0}, // a connector
		{"@u200da", .Bad_Escape, 0},
		{"@u0301a", .Bad_Escape, 0},
		{"@u0031a", .Bad_Escape, 0},
		{"a@u0020", .Bad_Escape, 1},
		{"a@u00", .Bad_Escape, 5},
		{"a@q", .Bad_Escape, 2},
		{"a-b", .Bad_Char, 1},
		{"a\xe2\x80", .Bad_Char, 1},
	}
	for c in refused {
		key := fix_escapes(c.key)
		src := strings.concatenate({"{", key, ":1}"}, context.temp_allocator)
		expect_fault(t, .Json5, src, c.kind, 1 + c.at)
	}
}

// Replaces `@` with a backslash in a test's text, which an editor's escape handling would otherwise rewrite.
fix_escapes :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "@", "\\", context.temp_allocator)
	return out
}

// A JSON5 number has no digit after a leading zero, whatever that digit is.
@(test)
json5_leading_zero :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for spec in JSON_SPECS {
		for sign in ([]string{"", "-"}) {
			for d in '0' ..= '9' {
				src := fmt.tprintf("[%s0%c]", sign, d)
				expect_fault(t, spec, src, .Bad_Number, 2 + len(sign))
			}
			for d in ([]string{"0.5", "0e1", "0"}) {
				doc := expect_builds(t, spec, fmt.tprintf("[%s%s]", sign, d))
				tape.destroy(&doc)
			}
		}
	}
	for d in '0' ..= '9' {
		expect_fault(t, .Json5, fmt.tprintf("{{a:+0%c}}", d), .Bad_Number, 5)
	}
}

// Records with unquoted keys never teach the walk a member gap and run its misses out, and the gaps of quoted records
// before them are not matched against them. A broken record is refused where it breaks, and a key that differs from
// the records' or is wider reads.
@(test)
unquoted_keys_among_repeated_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Case :: struct {
		last: string,
		kind: tape.Fault_Kind, // `.None` for a record that reads
		at:   int,
	}
	record :: `{abc:1,def:"x"}`
	cases := []Case {
		{`{abc:1,def:"x"}`, .None, 0},
		{`{abc:1,defg:"x"}`, .None, 0},
		{`{abcdefghijklmnopqrstuvwxyz0123456789:1,d:"x"}`, .None, 0},
		{`{$:1,_:"x"}`, .None, 0},
		{`{abc :1 , def : "x"}`, .None, 0},
		{`{abc:1 def:"x"}`, .Bad_Char, 7},
		{`{abc:1,,def:"x"}`, .Bad_Char, 7},
		{`{abc 1,def:"x"}`, .Bad_Char, 5},
		{`{abc:1,def "x"}`, .Bad_Char, 11},
		{`{abc:1,def:}`, .Bad_Char, 11},
		{`{abc:1,1def:"x"}`, .Bad_Char, 7},
		{"{abc:1,de\x01f:\"x\"}", .Bad_Char, 9},
	}
	quoted := `{"abc":1,"def":"x"}`
	for lead in ([]int{0, 5}) {
		for sep in ([]string{",", ",\n"}) {
			for c in cases {
				text, at := records(record, sep, c.last, 3000)
				prefix := ""
				if lead > 0 {
					prefix = strings.join({strings.repeat(strings.concatenate({quoted, sep}, context.temp_allocator), lead, context.temp_allocator)}, "", context.temp_allocator)
				}
				text = strings.concatenate({text[:1], prefix, text[1:]}, context.temp_allocator)
				doc, err := build_spec(t, text, .Json5)
				if c.kind == .None {
					testing.expectf(t, err == nil, "%q: %v", c.last, err)
				} else {
					f, faulted := err.(tape.Fault)
					testing.expectf(t, faulted && f.kind == c.kind && f.at == u64(at + len(prefix) + c.at), "%q: %v, want %v at %d", c.last, err, c.kind, at + len(prefix) + c.at)
				}
				tape.destroy(&doc)
			}
		}
	}
	text, _ := records(record, ",", record, 3000)
	doc := expect_builds(t, .Json5, text)
	defer tape.destroy(&doc)
	for node in doc.nodes {
		if node.role == .Key {
			word := text[node.lo:][:node.n]
			testing.expectf(t, word == "abc" || word == "def", "key %q", word)
		}
	}
}

// A record whose member gap differs from the records before it by one byte anywhere is refused at that byte, however
// long the gap is and whichever part of the compare reads the byte: `,"key":` for keys of 0 to 64 bytes, and the same
// with a line break, an indent of 0 to 60 bytes and a space after the colon, in the first slot of an object and in the
// one after a value. Only a key that closes within 32 bytes teaches the walk its gap, so the long gaps are indents.
@(test)
a_gap_differing_in_any_byte_is_refused_there :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Shape :: struct {
		indent, length: int, // indent -1 for a gap with no white space
	}
	shapes := make([dynamic]Shape, context.temp_allocator)
	for length in 0 ..= 64 {
		append(&shapes, Shape{-1, length})
	}
	for indent in 0 ..= 60 {
		for length in ([]int{1, 31, 32, 33}) {
			append(&shapes, Shape{indent, length})
		}
	}
	for spec in ([]json.Spec{.Json, .Jsonc}) {
		for shape in shapes {
			length, indent := shape.length, shape.indent
			pretty := indent >= 0
			key := strings.repeat("k", length, context.temp_allocator)
			spaces := strings.repeat(" ", max(indent, 0), context.temp_allocator)
			// A record with its first key long, then one with its second key long.
			for long_first in ([]bool{false, true}) {
				k1, k2 := "a", key
				if long_first {
					k1, k2 = key, "b"
				}
				first, rest: string
				if pretty {
					first = fmt.tprintf("\n%s\"%s\": ", spaces, k1)
					rest = fmt.tprintf(",\n%s\"%s\": ", spaces, k2)
				} else {
					first = fmt.tprintf("\"%s\":", k1)
					rest = fmt.tprintf(",\"%s\":", k2)
				}
				tail := "\n}" if pretty else "}"
				record := strings.concatenate({"{", first, "1", rest, "2", tail}, context.temp_allocator)
				gaps := [2]struct {
					lo, n: int,
				}{{1, len(first)}, {1 + len(first) + 1, len(rest)}}
				for gap in gaps {
					for j in 0 ..< gap.n {
						broken := strings.concatenate({record[:gap.lo + j], "\x01", record[gap.lo + j + 1:]}, context.temp_allocator)
						text, at := records(record, ",", broken, 4)
						doc, err := build_spec(t, text, spec)
						f, faulted := err.(tape.Fault)
						testing.expectf(
							t,
							faulted && f.kind == .Bad_Char && f.at == u64(at + gap.lo + j),
							"%v key %d bytes, indent %d, byte %d of a %d byte gap broken: %v, want Bad_Char at %d",
							spec,
							length,
							indent,
							j,
							gap.n,
							err,
							at + gap.lo + j,
						)
						tape.destroy(&doc)
					}
				}
				text, _ := records(record, ",", record, 4)
				doc := expect_builds(t, spec, text)
				expect_key_spans(t, text, &doc)
				tape.destroy(&doc)
			}
		}
	}
}
