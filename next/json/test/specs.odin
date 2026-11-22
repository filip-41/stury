package json_tests

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"

// The fault `err` holds, or `.None`.
fault_of :: proc(err: tape.Error) -> (tape.Fault_Kind, u64) {
	if f, ok := err.(tape.Fault); ok {
		return f.kind, f.at
	}
	return .None, 0
}

// JSONC and JSON5 read every text RFC 8259 accepts, with the same nodes.
@(test)
specs_read_every_json_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for f in #load_directory("conformance/JSONTestSuite/test_parsing") {
		if f.name[:2] != "y_" {
			continue
		}
		strict, _ := build(t, string(f.data))
		c, cerr := build(t, string(f.data), spec = .Jsonc)
		f5, ferr := build(t, string(f.data), spec = .Json5)
		testing.expectf(t, cerr == nil && ferr == nil, "%s: %v, %v", f.name, cerr, ferr)
		testing.expectf(t, fmt.tprint(c.nodes) == fmt.tprint(strict.nodes) && fmt.tprint(f5.nodes) == fmt.tprint(strict.nodes), "%s nodes differ", f.name)
		tape.destroy(&strict)
		tape.destroy(&c)
		tape.destroy(&f5)
	}
}

// json5-tests' verdicts: a `.json` or `.json5` text reads as JSON5, and a `.js` or `.txt` text is refused.
@(test)
json5_suite_verdicts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	dirs := [][]runtime.Load_Directory_File {
		#load_directory("conformance/json5-tests/arrays"),
		#load_directory("conformance/json5-tests/comments"),
		#load_directory("conformance/json5-tests/misc"),
		#load_directory("conformance/json5-tests/new-lines"),
		#load_directory("conformance/json5-tests/numbers"),
		#load_directory("conformance/json5-tests/objects"),
		#load_directory("conformance/json5-tests/strings"),
		#load_directory("conformance/json5-tests/todo"),
	}
	count := 0
	for dir in dirs {
		for f in dir {
			reads := strings.has_suffix(f.name, ".json") || strings.has_suffix(f.name, ".json5")
			if !reads && !strings.has_suffix(f.name, ".js") && !strings.has_suffix(f.name, ".txt") {
				continue
			}
			doc, err := build(t, string(f.data), spec = .Json5)
			testing.expectf(t, (err == nil) == reads, "%s: %v", f.name, err)
			tape.destroy(&doc)
			count += 1
		}
	}
	testing.expect(t, count > 100)
}

// A comment's fact kind says where the comment is, and its fact belongs to the node the kind names: a comment before a
// value or a member is that value's, one on the line where a value ends is the value's inline comment, and one before
// a container's close, or past the root's line, is the container's foot.
@(test)
comments_have_kinds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "// head\n{\"a\": 1, // one\n /* b */ \"b\": [2, /* two */ 3,], \"c\" /*k*/ : /*v*/ 4\n // foot\n} // root\n// tail"
	doc, err := build(t, src, spec = .Jsonc)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	Want :: struct {
		text: string,
		node: tape.Node_Index,
		kind: tape.Fact_Kind,
	}
	want := []Want {
		{"// head", 0, .Comment},
		{"// foot", 0, .Comment_Foot},
		{"// root", 0, .Comment_Inline},
		{"// tail", 0, .Comment_Foot},
		{"// one", 2, .Comment_Inline},
		{"/* b */", 4, .Comment},
		{"/* two */", 5, .Comment_Inline},
		{"/*k*/", 8, .Comment},
		{"/*v*/", 8, .Comment},
	}
	testing.expect_value(t, len(doc.facts), len(want))
	for w, i in want[:min(len(want), len(doc.facts))] {
		f := doc.facts[i]
		testing.expectf(t, src[f.lo:][:f.n] == w.text && f.node == w.node && f.kind == w.kind, "fact %d: %v, want %v", i, f, w)
		testing.expect_value(t, f.spelling, u16(2) if w.text[1] == '/' else u16(2) | 2 << 8)
	}
	testing.expect_value(t, doc.present, tape.Facts{.Comment, .Comment_Inline, .Comment_Foot})
	testing.expect_value(t, doc.format.name, "jsonc")
	testing.expect_value(t, doc.format.facts, tape.COMMENTS)
}

// A comment on the line where a container closes is the container's inline comment, and a comment in an empty
// container is its foot.
@(test)
comments_after_containers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:  string,
		node: tape.Node_Index,
		kind: tape.Fact_Kind,
	}
	cases := []Case {
		{"[[1] // c\n]", 1, .Comment_Inline},
		{"[[1], 2 // c\n]", 3, .Comment_Inline},
		{"[[[1]] /* c */, 2]", 1, .Comment_Inline},
		{"[/**/]", 0, .Comment_Foot},
		{"{/**/}", 0, .Comment_Foot},
		{"[1,\n// c\n]", 0, .Comment_Foot},
		{"{\"a\": [] // c\n}", 2, .Comment_Inline},
	}
	for c in cases {
		doc, err := build(t, c.src, spec = .Jsonc)
		testing.expectf(t, err == nil && len(doc.facts) == 1, "%q: %v, %d facts", c.src, err, len(doc.facts))
		if len(doc.facts) == 1 {
			f := doc.facts[0]
			testing.expectf(t, f.node == c.node && f.kind == c.kind, "%q: %v", c.src, f)
		}
		tape.destroy(&doc)
	}
}

// JSONC and JSON5 accept a comma before a close, and strict JSON refuses it. No spec accepts a comma with no value
// before it.
@(test)
trailing_commas :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:    string,
		strict: tape.Fault_Kind,
		spec:   tape.Fault_Kind,
		at:     u64, // the spec's fault offset
	}
	cases := []Case {
		{"[1,]", .Bad_Char, .None, 0},
		{"{\"a\":1,}", .Bad_Char, .None, 0},
		{"[1 , ]", .Bad_Char, .None, 0},
		{"[,]", .Bad_Char, .Bad_Char, 1},
		{"[1,,]", .Bad_Char, .Bad_Char, 3},
		{"{,}", .Bad_Char, .Bad_Char, 1},
		{"{\"a\":}", .Bad_Char, .Bad_Char, 5},
		{"1,", .Bad_Char, .Bad_Char, 1},
	}
	for c in cases {
		s, serr := build(t, c.src)
		k, _ := fault_of(serr)
		testing.expectf(t, k == c.strict, "%q as JSON: %v", c.src, serr)
		tape.destroy(&s)
		for spec in ([]int{0, 1}) {
			doc: tape.Document
			err: tape.Error
			if spec == 0 {
				doc, err = build(t, c.src, spec = .Jsonc)
			} else {
				doc, err = build(t, c.src, spec = .Json5)
			}
			kind, at := fault_of(err)
			testing.expectf(t, kind == c.spec && (kind == .None || at == c.at), "%q: %v, want %v at %d", c.src, err, c.spec, c.at)
			tape.destroy(&doc)
		}
	}
}

// Malformed comments, bytes a comment may not hold, and texts that end inside a comment or with no value are refused
// at the byte the case names.
@(test)
comment_faults :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:  string,
		kind: tape.Fault_Kind,
		at:   u64,
	}
	cases := []Case {
		{"/* x", .Truncated, 4},
		{"1 /", .Bad_Char, 2},
		{"[1 /x]", .Bad_Char, 3},
		{"[1, // c", .Truncated, 8},
		{"{\"a\" /x: 1}", .Bad_Char, 5},
		{"[1] /* a */ 2", .Bad_Char, 12},
		{"// \x01\n1", .Bad_Char, 3},
		{"/* \xff */ 1", .Bad_Char, 3},
		{"/* a */\n", .Truncated, 8},
	}
	for c in cases {
		doc, err := build(t, c.src, spec = .Jsonc)
		kind, at := fault_of(err)
		testing.expectf(t, kind == c.kind && at == c.at, "%q: %v, want %v at %d", c.src, err, c.kind, c.at)
		tape.destroy(&doc)
	}
}

// A comment where the records before it taught the walk a member gap is read as a comment: the gap's match stops at
// it, and no gap is learned across it.
@(test)
comments_in_learned_gaps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lasts := []string {
		`{"id":1,/* c */"name":"a"}`,
		`{"id":1,"name":/* c */"a"}`,
		`{"id":1 /* c */,"name":"a"}`,
		`{/* c */"id":1,"name":"a"}`,
		`{"id":1,"name"/* c */:"a"}`,
		"{\"id\":1, // c\n\"name\":\"a\"}",
	}
	for last in lasts {
		for sep in ([]string{",", ",\n"}) {
			text, _ := records(`{"id":1,"name":"a"}`, sep, last, 4)
			doc, err := build(t, text, spec = .Jsonc)
			testing.expectf(t, err == nil && len(doc.facts) == 1, "%q after its records: %v, %d facts", last, err, len(doc.facts))
			expect_key_spans(t, text, &doc)
			tape.destroy(&doc)
			// The same records with the comment in each one.
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "[")
			for i in 0 ..< 12 {
				if i > 0 {
					strings.write_string(&b, sep)
				}
				strings.write_string(&b, last)
			}
			strings.write_string(&b, "]")
			all := strings.to_string(b)
			doc, err = build(t, all, spec = .Jsonc)
			testing.expectf(t, err == nil && len(doc.facts) == 12, "%q in every record: %v, %d facts", last, err, len(doc.facts))
			for f in doc.facts {
				testing.expectf(t, all[f.lo:][:f.n] == "/* c */" || all[f.lo:][:f.n] == "// c", "fact spans %q", all[f.lo:][:f.n])
			}
			tape.destroy(&doc)
		}
	}
}

// JSON5's numbers read as JSON5 means them: hex as an integer, `Infinity` and `NaN` as floats, and a point with no
// digit after it makes a float.
@(test)
json5_numbers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		text: string,
		kind: enum {Int, Float},
		i:    i64,
		f:    f64,
	}
	cases := []Case {
		{"0x1F", .Int, 31, 0},
		{"-0xff", .Int, -255, 0},
		{"+1", .Int, 1, 0},
		{".5", .Float, 0, 0.5},
		{"-.5", .Float, 0, -0.5},
		{"5.", .Float, 0, 5},
		{"5.e2", .Float, 0, 500},
		{"+1.5e1", .Float, 0, 15},
		{"Infinity", .Float, 0, math.inf_f64(1)},
		{"-Infinity", .Float, 0, math.inf_f64(-1)},
		{"0x7FFFFFFFFFFFFFFF", .Int, max(i64), 0},
		{"-0x8000000000000000", .Int, min(i64), 0},
		{"0x10000000000000001", .Float, 0, 18446744073709551616.0},
		{"0x10000000000000801", .Float, 0, 18446744073709555712.0},
		{"0x10000000000000800", .Float, 0, 18446744073709551616.0},
		{"0x100000000000008001", .Float, 0, 295147905179352891392.0},
		// Loose decimals longer than a short buffer, read from the text.
		{fmt.tprintf("+1e%s2", strings.repeat("0", 200, context.temp_allocator)), .Float, 0, 100},
		{fmt.tprintf("-.5%s", strings.repeat("0", 200, context.temp_allocator)), .Float, 0, -0.5},
		{"+1234567890123456789012345.", .Float, 0, 1234567890123456789012345.0},
	}
	for c in cases {
		src := fmt.tprintf("[%s]", c.text)
		doc, err := build(t, src, spec = .Json5)
		testing.expectf(t, err == nil, "%q: %v", src, err)
		if err == nil {
			v, ok := tape.node_number(&doc, doc.nodes[1])
			testing.expect(t, ok)
			switch c.kind {
			case .Int:
				testing.expectf(t, v.kind == .Int && i64(v.bits) == c.i, "%s: %v", c.text, v)
			case .Float:
				testing.expectf(t, v.kind == .Float && transmute(f64)v.bits == c.f, "%s: %v %v", c.text, v, transmute(f64)v.bits)
			}
		}
		tape.destroy(&doc)
	}
	for text in ([]string{"NaN", "+NaN", "-NaN"}) {
		doc, _ := build(t, text, spec = .Json5)
		v, _ := tape.node_number(&doc, doc.nodes[0])
		testing.expectf(t, v.kind == .Float && v.bits == 0x7ff8_0000_0000_0000 | u64(text[0] == '-') << 63, "%s: %v", text, v)
		tape.destroy(&doc)
	}
	for text in ([]string{"-0.", "-0.0", "-.0"}) {
		doc, _ := build(t, text, spec = .Json5)
		v, _ := tape.node_number(&doc, doc.nodes[0])
		testing.expectf(t, v.kind == .Float && v.bits == 1 << 63, "%s: %v", text, v)
		tape.destroy(&doc)
	}
}

// JSON5's strings and keys read with their escapes decoded: `\x`, `\v`, `\0`, an escaped quote of either kind, a
// line continuation, and an escaped character that spells itself. An unquoted key's span is its bare name.
@(test)
json5_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "{unq\\u0061: 'a\\x41\\u00e9\\xe9\\v\\0\\'\\\nb\\q\\\r\nc', $_x: \"d\\\"\\'\", 'k': ''}"
	doc, err := build(t, src, spec = .Json5)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	want := []string{"unqa", "aAéé\v\x00'bqc", "$_x", "d\"'", "k", ""}
	texts: [dynamic]string
	defer delete(texts)
	buf: [256]u8
	for n in doc.nodes {
		if n.kind == .String {
			s, ok := tape.node_text(&doc, n, buf[:])
			testing.expect(t, ok)
			append(&texts, strings.clone(s, context.temp_allocator))
		}
	}
	testing.expect_value(t, len(texts), len(want))
	for w, i in want[:min(len(want), len(texts))] {
		testing.expectf(t, texts[i] == w, "string %d: %q, want %q", i, texts[i], w)
	}
	testing.expect_value(t, doc.nodes[1].spelling & tape.SPELLING_QUOTED, 0)
	testing.expect_value(t, src[doc.nodes[3].lo:][:doc.nodes[3].n], "$_x")
}

// JSON5's own white space and comments read wherever JSON's white space does.
@(test)
json5_white_space :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "\u00a0{\va\u2028:\ufeff1\u3000,\fb\t: // c\u2029 2 /* d */}\u2003"
	doc, err := build(t, src, spec = .Json5)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 5)
	testing.expect_value(t, len(doc.facts), 2)
	_, serr := build(t, src, spec = .Jsonc)
	testing.expect(t, serr != nil)
}
