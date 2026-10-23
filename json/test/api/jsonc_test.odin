package json_tests

import json "../.."
import "core:strings"
import "core:testing"

// The JSONC dialect: comments attached to rows as facts, written back by `marshal`, and moved by the edits.

// `facts` lists what is attached to one value, by place, `fact_text` is a comment without its markers. A JSON
// document has none.
@(test)
test_jsonc_comments_attach_to_rows :: proc(t: ^testing.T) {
	src := transmute([]byte)string(`// head
{
  // about a
  "a": /* in a */ 1, // after a
  "b": [
    1, // after 1
    // before 2
    2
    // foot of b
  ],
  // foot of root
} // tail
`)
	doc, err := json.build(src, dialect = .Jsonc)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	Want :: struct {
		row:   int,
		place: json.Fact_Place,
		text:  string,
	}
	wants := []Want{
		{0, .Lead, "// head"},
		{0, .Trail, "// tail"},
		{0, .Foot, "// foot of root"},
		{1, .Lead, "// about a"},
		{1, .Inline, "/* in a */"},
		{1, .Trail, "// after a"},
		{2, .Foot, "// foot of b"},
		{3, .Trail, "// after 1"},
		{4, .Lead, "// before 2"},
	}
	n := 0
	for row in 0 ..< len(doc.rows) {
		for cm in json.facts(&doc, json.Node(row)) {
			if n < len(wants) {
				w := wants[n]
				testing.expect_value(t, int(cm.node), w.row)
				testing.expect_value(t, cm.place, w.place)
				testing.expect_value(t, string(src[cm.lo:cm.hi]), w.text)
				bare := w.text[2:] if w.text[1] == '/' else w.text[2:len(w.text) - 2]
				testing.expect_value(t, json.fact_text(&doc, cm), bare)
			}
			n += 1
		}
	}
	testing.expect_value(t, n, len(wants))

	plain := build_ok(t, `{"a":1}`)
	defer json.destroy(&plain)
	testing.expect_value(t, len(json.facts(&plain, json.child(&plain, json.ROOT, "a"))), 0)
}

@(test)
test_jsonc_marshal_document_keeps_comments :: proc(t: ^testing.T) {
	src := transmute([]byte)string("// head\n{\n  // about a\n  \"a\": /* in a */ 1, // after a\n  \"b\": [1, 2,],\n  \"e\": {\n    // empty\n  },\n} // tail\n")
	doc, err := json.build(src, dialect = .Jsonc)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	pretty, perr := json.marshal(&doc, {pretty = true}, context.temp_allocator)
	testing.expect_value(t, perr, json.Encode_Error.None)
	testing.expect_value(t, string(pretty), "// head\n{\n\t// about a\n\t\"a\": /* in a */ 1, // after a\n\t\"b\": [\n\t\t1,\n\t\t2\n\t],\n\t\"e\": {\n\t\t// empty\n\t}\n} // tail\n")
	compact, cerr := json.marshal(&doc, {}, context.temp_allocator)
	testing.expect_value(t, cerr, json.Encode_Error.None)
	testing.expect_value(t, string(compact), "// head\n{// about a\n\"a\":/* in a */1,// after a\n\"b\":[1,2],\"e\":{// empty\n}}// tail\n")
	// Both read back as the same JSONC document.
	for out in ([]string{string(pretty), string(compact)}) {
		again, aerr := json.build(transmute([]byte)out, dialect = .Jsonc)
		testing.expect(t, aerr == nil, out)
		testing.expect_value(t, len(again.facts), len(doc.facts))
		for cm, i in again.facts {
			if i < len(doc.facts) {
				testing.expect(t, cm.node == doc.facts[i].node && cm.place == doc.facts[i].place, out)
			}
		}
		testing.expect_value(t, len(again.rows), len(doc.rows))
		json.destroy(&again)
	}

	// Two trailing line comments: the second starts its own line, or it would read as part of the first.
	trail := transmute([]byte)string("[] // c\n// d\n")
	tdoc, _ := json.build(trail, dialect = .Jsonc)
	defer json.destroy(&tdoc)
	tout, _ := json.marshal(&tdoc, {pretty = true}, context.temp_allocator)
	testing.expect_value(t, string(tout), "[] // c\n// d\n")
}

@(private = "file")
JSONC_CONFIG :: `{
  // the name
  "name": "stury", // short
  "depth": 4,
  /* lead of tags */
  "tags": [
    "a", // first
    "b"
    // end of tags
  ]
}
`

// Each comment edit reads back where it was put.
@(test)
test_jsonc_comment_edits :: proc(t: ^testing.T) {
	src := transmute([]byte)string(JSONC_CONFIG)
	Case :: struct {
		path:  string,
		place: json.Fact_Place,
		text:  string,
	}
	cases := []Case{
		{".depth", .Lead, "// how deep"},
		{".depth", .Inline, "/* levels */"},
		{".depth", .Trail, "// trail"},
		{".tags", .Foot, "/* foot */"},
		{".", .Lead, "// top"},
		{".", .Foot, "// last"},
		{".tags[1]", .Trail, "/* b */"},
	}
	for c in cases {
		out, err := json.edit_comment(src, c.path, c.place, c.text, .Insert, context.temp_allocator)
		testing.expect_value(t, err, nil)
		doc, berr := json.build(out, context.temp_allocator, dialect = .Jsonc)
		testing.expect(t, berr == nil, string(out))
		hit := false
		for cm in doc.facts {
			hit ||= cm.place == c.place && string(out[cm.lo:cm.hi]) == c.text
		}
		testing.expect(t, hit, string(out))
	}

	_, err := json.edit_comment(src, ".name", .Trail, "// two", .Insert, context.temp_allocator)
	edit_err(t, err, .Unplaceable)
	_, err = json.edit_comment(src, ".depth", .Foot, "// x", .Insert, context.temp_allocator)
	edit_err(t, err, .Unplaceable)
	_, err = json.edit_comment(src, ".depth", .Lead, "/* open", .Insert, context.temp_allocator)
	edit_err(t, err, .Bad_Comment)

	out: []byte
	out, err = json.edit_comment(src, ".name", .Trail, "/* shorter */", .Set, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.has_prefix(string(out), "{\n  // the name\n  \"name\": \"stury\", /* shorter */\n  \"depth\""), string(out))
	_, err = json.edit_comment(src, ".depth", .Trail, "// x", .Set, context.temp_allocator)
	edit_err(t, err, .Not_Found)

	out, err = json.edit_comment(src, ".name", .Lead, "", .Remove, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out[:30]), "{\n  \"name\": \"stury\", // short\n")
	out, err = json.edit_comment(src, ".tags[]", .Trail, "", .Remove, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, json.validate(out, .Jsonc) == nil)
	testing.expect(t, strings.has_suffix(string(out), "\"a\",\n    \"b\"\n    // end of tags\n  ]\n}\n"), string(out))
}

// CR is JSON whitespace, so a line comment ends at CR, LF or CRLF alike, and the comment's span stops
// before the break.
@(test)
test_jsonc_line_comment_ends_at_cr :: proc(t: ^testing.T) {
	Trail :: struct {
		src: string,
		at:  u64,
	}
	for c in ([]Trail{{"1 // c\r2", 7}, {"1 // c\n2", 7}, {"1 // c\r\n2", 8}}) {
		src := transmute([]byte)c.src
		testing.expect_value(t, json.validate(src, .Jsonc), json.Error{offset = c.at, kind = .Trailing})
		doc, err := json.build(src, dialect = .Jsonc)
		testing.expect_value(t, err, json.Error{offset = c.at, kind = .Trailing})
		json.destroy(&doc)
	}

	for brk in ([]string{"\r", "\n", "\r\n"}) {
		src_text, _ := strings.replace_all("{|// head|\"a\": 1 // note|}|", "|", brk, context.temp_allocator)
		src := transmute([]byte)src_text
		doc, err := json.build(src, dialect = .Jsonc)
		defer json.destroy(&doc)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(doc.rows), 2)
		lead := json.facts(&doc, 1)
		testing.expect_value(t, len(lead), 2)
		if len(lead) == 2 {
			testing.expect_value(t, lead[0].place, json.Fact_Place.Lead)
			testing.expect_value(t, string(src[lead[0].lo:lead[0].hi]), "// head")
			testing.expect_value(t, lead[1].place, json.Fact_Place.Trail)
			testing.expect_value(t, string(src[lead[1].lo:lead[1].hi]), "// note")
		}

		// Removing the lead comment takes its line and one whole break with it.
		out, eerr := json.edit_comment(src, ".a", .Lead, "", .Remove, context.temp_allocator)
		testing.expect_value(t, eerr, nil)
		want, _ := strings.replace_all("{|\"a\": 1 // note|}|", "|", brk, context.temp_allocator)
		testing.expect_value(t, string(out), want)

		// An entry on the line after a line comment goes with its own line and break.
		two, _ := strings.replace_all("{|\"a\": 1, // x|\"b\": 2|}", "|", brk, context.temp_allocator)
		out, eerr = json.remove(transmute([]byte)two, ".b", context.temp_allocator, .Jsonc)
		testing.expect_value(t, eerr, nil)
		want, _ = strings.replace_all("{|\"a\": 1, // x|}", "|", brk, context.temp_allocator)
		testing.expect_value(t, string(out), want)
	}
}

// A comment whose append is refused is `.Out_Of_Memory`, never a valid result with the comment missing,
// the one after the root is appended last, by the finishing skip.
@(test)
test_jsonc_refused_comment_is_out_of_memory :: proc(t: ^testing.T) {
	src := raw("1 // c")
	budget := Budget{backing = context.allocator}
	facts := make([dynamic]json.Fact, budget_allocator(&budget))
	testing.expect_value(t, json.validate(src, .Jsonc, facts = &facts), json.Error{kind = .Out_Of_Memory})
	delete(facts)

	sweep := Budget_Sweep{limit = 100}
	for b, k in next_budget(&sweep) {
		doc, err := json.build(src, budget_allocator(b), dialect = .Jsonc)
		json.destroy(&doc)
		if !b.refused {
			testing.expect_value(t, err, nil)
			continue
		}
		testing.expectf(t, err == json.Error{kind = .Out_Of_Memory}, "allocation %d: %v", k, err)
	}
	expect_swept(t, &sweep)
}

// A comment's bytes are checked as a string's raw bytes: wire UTF-8, and no control byte but a tab, and CR and
// LF where they end a line comment or sit in a block comment. Each refusal is the string's, at the same byte.
@(test)
test_jsonc_comment_bytes_judged_as_string_bytes :: proc(t: ^testing.T) {
	// Padding before the body, and room after it, put it in a 16-byte window of the comment's run.
	pads := []string{"", "0123456789abcdef0", "* / *0123456789abcdef* /"}
	for body in ([]string{"a\xffb", "a\x00b", "a\x01b", "a\x1fb", "\xc3", "\xed\xa0\x80", "\xc0\xaf", "\xf4\x90\x80\x80", "\xe2\x82"}) {
		for room in ([]string{"", "                    "}) {
			str := strings.concatenate({"\"", body, room}, context.temp_allocator)
			want, _ := json.validate(raw(str)).?
			testing.expectf(t, want.kind == .Bad_Char || want.kind == .Truncated, "%q: %v", str, want)
			for open in ([]string{"1 //", "1 /*"}) {
				for pad in pads {
					src := strings.concatenate({open, pad, body, room}, context.temp_allocator)
					e, bad := json.validate(raw(src), .Jsonc).?
					at := want.offset + u64(len(open) + len(pad) - 1) if want.kind == .Bad_Char else u64(len(src))
					testing.expectf(t, bad && e.kind == want.kind && e.offset == at, "%q: %v, string %v", src, e, want)
					doc, berr := json.build(raw(src), dialect = .Jsonc)
					testing.expectf(t, berr == e, "%q: build %v, validate %v", src, berr, e)
					json.destroy(&doc)
				}
			}
		}
	}
	for src in ([]string{"1 // tab\there é \x7f\n", "1 /* a\r\nb\tc é 𝄞 */", "1 // a\r", "1 // é", "1 /* 0123456789abcdef é * / 0123456789abcdef \t\r\n**/                  ", "1 // 0123456789abcdef é \t 0123456789abcdef\r\n                  "}) {
		testing.expectf(t, json.validate(raw(src), .Jsonc) == nil, "%q", src)
	}
}

// With `trailing_newline`, a compact line comment that ends the output already ended the line.
@(test)
test_jsonc_marshal_trailing_newline_after_line_comment :: proc(t: ^testing.T) {
	Case :: struct {
		src:    string,
		pretty: bool,
		want:   string,
	}
	for c in ([]Case{{"[1] // trail\n", false, "[1]// trail\n"}, {"[1] // trail\n", true, "[\n\t1\n] // trail\n"}, {"[1] /* t */", false, "[1]/* t */\n"}}) {
		doc, err := json.build(raw(c.src), dialect = .Jsonc)
		defer json.destroy(&doc)
		testing.expect_value(t, err, nil)
		out, merr := json.marshal(&doc, {pretty = c.pretty, trailing_newline = true}, context.temp_allocator)
		testing.expect_value(t, merr, json.Encode_Error.None)
		testing.expect_value(t, string(out), c.want)
	}
}

// Where no comment sits in the separators an edit touches, a JSONC edit lays them out as the JSON edit does,
// a comment in the way keeps the entry between extents, owners unchanged (`/*a*/` trails `1`, on its line).
@(test)
test_jsonc_edits_lay_out_as_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src, path: string,
		at:        int, // the insert position, or REMOVE
		want:      string,
	}
	REMOVE :: -2
	run :: proc(c: Case, d: json.Dialect) -> ([]byte, Maybe(json.Path_Error)) {
		if c.at == REMOVE {
			return json.remove(raw(c.src), c.path, context.temp_allocator, d)
		}
		return json.insert(raw(c.src), c.path, c.at, 9, context.temp_allocator, d)
	}
	plain := []Case{
		{"[1 , 2]", ".", 1, "[1 , 9 , 2]"},
		{"[1 , 2]", ".", 0, "[9 , 1 , 2]"},
		{"[1 , 2]", ".", json.APPEND, "[1 , 2 , 9]"},
		{"[ 1 ]", ".", json.APPEND, "[ 1, 9 ]"},
		{"[]", ".", json.APPEND, "[9]"},
		{"[1 , 2]", ".[1]", REMOVE, "[1]"},
		{"[1\n,\n2\n]", ".[1]", REMOVE, "[1\n]"},
		{"[1 , 2]", ".[0]", REMOVE, "[2]"},
		{"{\"a\":1, \"b\":2, \"c\":3}", ".b", REMOVE, "{\"a\":1, \"c\":3}"},
	}
	for c in plain {
		for d in ([]json.Dialect{.Json, .Jsonc}) {
			out, err := run(c, d)
			testing.expectf(t, err == nil && string(out) == c.want, "%v %q %s %d: %q %v, want %q", d, c.src, c.path, c.at, out, err, c.want)
		}
	}
	obj, oerr := json.insert(raw("{\"a\" : 1 ,\n \"b\" : 2}"), ".", "c", 3, context.temp_allocator, .Jsonc)
	testing.expect_value(t, oerr, nil)
	testing.expect_value(t, string(obj), "{\"a\" : 1 ,\n \"b\" : 2 ,\n \"c\" : 3}")

	commented := []Case{
		{"[1, 2,]", ".", json.APPEND, "[1, 2, 9,]"},
		{"[1, /*a*/ 2]", ".", 1, "[1, /*a*/ 9, 2]"},
		{"[1, 2 // x\n]", ".", json.APPEND, "[1, 2, // x\n 9\n]"},
		{"[1 /*t*/, 2]", ".[1]", REMOVE, "[1 /*t*/]"},
		{"[1, /*l*/ 2]", ".[1]", REMOVE, "[1, /*l*/ ]"},
	}
	for c in commented {
		out, err := run(c, .Jsonc)
		testing.expectf(t, err == nil && json.validate(out, .Jsonc) == nil, "%q %s %d: %q %v", c.src, c.path, c.at, out, err)
		testing.expectf(t, string(out) == c.want, "%q %s %d: %q, want %q", c.src, c.path, c.at, out, c.want)
	}
}

// A `Raw` is checked by the dialect it is written into: an edit of a JSONC text takes one holding comments or a
// trailing comma, a JSON edit refuses it, and so does a comment that would swallow what follows it.
@(test)
test_jsonc_raw_is_judged_as_jsonc :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	R :: struct {
		r: json.Raw,
	}
	r: R
	testing.expect_value(t, json.unmarshal(raw(`{"r":[1, /*c*/ 2,]}`), &r, {dialect = .Jsonc}, nil, context.temp_allocator), nil)
	testing.expect_value(t, string(r.r), `[1, /*c*/ 2,]`)
	out, err := json.set(raw(`{"x": /*k*/ 0}`), ".x", r.r, context.temp_allocator, dialect = .Jsonc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), `{"x": /*k*/ [1, /*c*/ 2,]}`)
	out, err = json.insert(raw(`[0]`), ".", 0, json.Raw("[1,]"), context.temp_allocator, .Jsonc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), `[[1,],0]`)

	_, err = json.set(raw(`{"x":0}`), ".x", r.r, context.temp_allocator)
	testing.expect_value(t, edit_err(t, err, .Encode).encode, json.Encode_Error.Bad_Raw)
	for swallows in ([]json.Raw{"1 // c", "1 /* c */"}) {
		_, err = json.set(raw(`[0, 1]`), ".[0]", swallows, context.temp_allocator, dialect = .Jsonc)
		testing.expect_value(t, edit_err(t, err, .Encode).encode, json.Encode_Error.Bad_Raw)
	}
}

// A slash that opens no comment (the last byte, or followed by neither `/` nor `*`) is `.Bad_Char` at the slash.
@(test)
test_jsonc_lone_slash_is_bad_char :: proc(t: ^testing.T) {
	for c in ([]struct {
		src: string,
		at:  u64,
	}{{"1/", 1}, {"1/2", 1}, {"/", 0}}) {
		e, bad := json.validate(raw(c.src), .Jsonc).?
		testing.expectf(t, bad && e.kind == .Bad_Char && e.offset == c.at, "%q: %v", c.src, e)
	}
}

// A trailing comma stays one when a comment sits between it and the closer.
@(test)
test_jsonc_trailing_comma_behind_a_comment :: proc(t: ^testing.T) {
	for src in ([]string{"[1, /*c*/]", `{ "a": 1, /*c*/ }`, "[1, // c\n]"}) {
		testing.expectf(t, json.validate(raw(src), .Jsonc) == nil, "%q", src)
	}
}

// A refused allocation anywhere in attaching comments to a document nested past MAX_DEPTH (where the attach
// stack grows) is `.Out_Of_Memory`, and the allocations granted are all given back.
@(test)
test_jsonc_refused_attach_stack_is_out_of_memory :: proc(t: ^testing.T) {
	n := json.MAX_DEPTH + 2
	src := nested_arrays(n, "/*c*/")
	limits := json.Limits{max_depth = 5000}
	sweep := Budget_Sweep{limit = 200}
	for b, k in next_budget(&sweep) {
		doc, err := json.build(raw(src), budget_allocator(b), limits, .Jsonc)
		json.destroy(&doc)
		if !b.refused {
			testing.expect_value(t, err, nil)
			continue
		}
		testing.expectf(t, err == json.Error{kind = .Out_Of_Memory}, "allocation %d: %v", k, err)
	}
	expect_swept(t, &sweep)
}
