package toml_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// The TOML writer: a document is written as a text that reads back as the same values, a table's own keys before its
// subtables.

@(private = "file")
JSON_TEXTS := [?]string{
	`{"a":1,"b":"x\ny\"\\","c":[1,2.5,"s",[true,false]],"d":{"e":{"f":1},"g":[{"h":1},{"h":2}]},"i":{}}`,
	`{"d":{"x":1},"a":2,"k":[{"p":[{"q":1}]},{"p":[]}],"m":[{"a":1},2]}`,
	`{"odd key":1,"é":2,"":3,"a.b":{"c.d":4},"-":{"_":[]}}`,
	`{"big":9223372036854775807,"neg":-0,"f":1e5,"g":-2.5E-3}`,
	`{}`,
}

@(test)
json_objects_write_as_toml_that_reads_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in JSON_TEXTS {
		doc, err := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expectf(t, err == nil, "%s: %v", src, err)
		for spec in toml.Spec {
			text, _, werr := toml.write(&doc, spec)
			defer delete(text)
			testing.expectf(t, werr == nil, "%d: %v", k, werr)
			testing.expectf(t, toml.validate(text, spec) == nil, "%d: %v\n%s", k, toml.validate(text, spec), text)
			back, berr := toml.build(text, spec)
			defer toml.destroy(&back)
			testing.expectf(t, berr == nil, "%d: %v", k, berr)
			again, _, aerr := toml.write(&back, spec)
			defer delete(again)
			testing.expectf(t, aerr == nil && string(again) == string(text), "%d: a write of the text differs:\n%s\n%s", k, text, again)
			// Back through JSON, the values are the document's.
			as_json, _, jerr := json.write(&back, .Json, {sort_keys = true})
			defer delete(as_json)
			want, _, _ := json.write(&doc, .Json, {sort_keys = true})
			defer delete(want)
			testing.expectf(t, jerr == nil && string(as_json) == string(want), "%d: %s\nwant %s", k, as_json, want)
		}
	}
}

@(test)
known_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, _ := json.build(transmute([]u8)string(`{"d":{"x":1,"y":{"z":"s"}},"a":2,"k":[{"p":1},{"p":2}],"l":[1,[2]]}`))
	defer json.destroy(&doc)
	text, _, err := toml.write(&doc)
	defer delete(text)
	want := "a = 2\nl = [1, [2]]\n\n[d]\nx = 1\n\n[d.y]\nz = \"s\"\n\n[[k]]\np = 1\n\n[[k]]\np = 2\n"
	testing.expectf(t, err == nil && string(text) == want, "%v\n%s", err, text)
}

@(test)
toml_dates_are_kept :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = 1979-05-27T07:32:00Z\nb = 07:32:00\nc = \"1979-05-27\"\n"
	doc, err := toml.build(transmute([]u8)src)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := toml.write(&doc)
	defer delete(text)
	testing.expectf(t, werr == nil && string(text) == src, "%v\n%s", werr, text)
}

@(test)
values_with_no_toml_spelling_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src in ([?]string{`{"a":123456789012345678901234567890}`, `{"a":18446744073709551615}`, `{"a":null}`, `[1]`, `{"a":{"b":[null]}}`, `"s"`}) {
		doc, _ := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		_, _, err := toml.write(&doc)
		refused, ok := err.(toml.Refused)
		testing.expectf(t, ok && refused.why == .No_Spelling, "%s: %v", src, err)
	}
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`))
	defer json.destroy(&doc)
	_, _, err := toml.write(&doc, .Toml_1_0, {ascii = true})
	testing.expect(t, err != nil)
	_ = tape.ROOT
	_ = testkit.deadline
}

// The writer takes the text of a number read from TOML as a TOML number, with no second check of it: signs, underscores,
// exponents, a leading `+`, the bases and the infinite and not-a-number floats are written as the reader's values say.
@(test)
toml_numbers_write_as_the_reader_read_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = 1\nb = +1\nc = -17\nd = 1_000\ne = 1e3\nf = 1E+3\ng = 6.626e-34\nh = 1_0.5_5\ni = +inf\nj = -inf\nk = nan\nl = +nan\n" +
		"m = 0xDEAD_BEEF\nn = 0o755\no = 0b1010\np = -0.0\nq = +0\nr = 1e400\ns = -9223372036854775808\nu = 5e+22\n"
	want := "a = 1\nb = 1\nc = -17\nd = 1000\ne = 1e3\nf = 1E+3\ng = 6.626e-34\nh = 10.55\ni = inf\nj = -inf\nk = nan\nl = nan\n" +
		"m = 0xdeadbeef\nn = 0o755\no = 0b1010\np = -0.0\nq = 0\nr = 1e400\ns = -9223372036854775808\nu = 5e+22\n"
	doc, err := toml.build(transmute([]u8)src, .Toml_1_0)
	defer toml.destroy(&doc)
	testing.expectf(t, err == nil, "%v", err)
	text, _, werr := toml.write(&doc)
	defer delete(text)
	testing.expectf(t, werr == nil && string(text) == want, "%v\n%s", werr, text)
	back, berr := toml.build(text, .Toml_1_0)
	defer toml.destroy(&back)
	testing.expectf(t, berr == nil, "%v", berr)
	again, _, rerr := toml.write(&back)
	defer delete(again)
	testing.expectf(t, rerr == nil && string(again) == want, "%v\n%s", rerr, again)
}

@(test)
toml_write_partial_dups_v11_utf8_and_deep_dotted :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Partial documents from `toml.scan` are refused with `.Partial`.
	demand, _ := tape.demand_of([][]tape.Step{{tape.Name("a")}})
	defer tape.destroy(&demand)
	part, perr := toml.scan(transmute([]u8)string("a = 1\nb = 2\n"), &demand)
	defer toml.destroy(&part)
	testing.expect(t, perr == nil)
	_, _, pwerr := toml.write(&part)
	pr, pok := pwerr.(toml.Refused)
	testing.expectf(t, pok && pr.why == .Partial, "partial root: %v", pwerr)

	demand2, _ := tape.demand_of([][]tape.Step{{tape.Name("arr"), tape.Index(0)}})
	defer tape.destroy(&demand2)
	part2, perr2 := toml.scan(transmute([]u8)string("arr = [1, 2, 3]\n"), &demand2)
	defer toml.destroy(&part2)
	testing.expect(t, perr2 == nil)
	_, _, pwerr2 := toml.write(&part2)
	pr2, pok2 := pwerr2.(toml.Refused)
	testing.expectf(t, pok2 && pr2.why == .Partial, "partial array: %v", pwerr2)

	// 2. Duplicate keys from non-TOML docs (e.g. JSON built with `dups = .All`) are refused.
	dup_doc, derr := json.build(transmute([]u8)string(`{"a":1,"a":2}`), .Json, {dups = .All})
	defer json.destroy(&dup_doc)
	testing.expect(t, derr == nil)
	for sort in ([?]bool{false, true}) {
		_, _, dwerr := toml.write(&dup_doc, .Toml_1_0, {sort_keys = sort})
		dr, dok := dwerr.(toml.Refused)
		testing.expectf(t, dok && dr.why == .No_Spelling, "dup sort=%v: %v", sort, dwerr)
	}

	// 3. TOML 1.1 no-seconds times/datetimes gain `:00` when written as TOML 1.0.
	v11_src := "t = 07:32\nld = 1979-05-27T07:32\nod1 = 1979-05-27T07:32Z\nod2 = 1979-05-27 07:32+02:00\nd = 1979-05-27\n"
	v11_doc, v11_err := toml.build(transmute([]u8)v11_src, .Toml_1_1)
	defer toml.destroy(&v11_doc)
	testing.expectf(t, v11_err == nil, "v11 build: %v", v11_err)
	as_10, _, w10_err := toml.write(&v11_doc, .Toml_1_0)
	defer delete(as_10)
	want_10 := "t = 07:32:00\nld = 1979-05-27T07:32:00\nod1 = 1979-05-27T07:32:00Z\nod2 = 1979-05-27 07:32:00+02:00\nd = 1979-05-27\n"
	testing.expectf(t, w10_err == nil && string(as_10) == want_10, "v11->v10: %v\n%s", w10_err, as_10)
	testing.expectf(t, toml.validate(as_10, .Toml_1_0) == nil, "validate v10: %v", toml.validate(as_10, .Toml_1_0))

	// 4. `Comment_Foot` on an inline table in TOML 1.1 written as TOML 1.0 (not broken) is reported in `dropped`.
	foot_src := "t = {\n  a = 1,\n  # foot\n}\n"
	foot_doc, foot_err := toml.build(transmute([]u8)foot_src, .Toml_1_1)
	defer toml.destroy(&foot_doc)
	testing.expectf(t, foot_err == nil, "foot build: %v", foot_err)
	foot_out, foot_dropped, foot_werr := toml.write(&foot_doc, .Toml_1_0)
	defer delete(foot_out)
	testing.expectf(t, foot_werr == nil && .Comment_Foot in foot_dropped, "foot dropped: %v %v %q", foot_werr, foot_dropped, foot_out)

	// 5. Invalid UTF-8 in a comment is dropped cleanly, and invalid UTF-8 in a literal string falls back to basic string.
	cmt_buf := transmute([]u8)strings.clone("// bad X comment\n{\"a\": 1}")
	defer delete(cmt_buf)
	bad_cmt, berr := json.build(cmt_buf, .Jsonc)
	defer json.destroy(&bad_cmt)
	testing.expect(t, berr == nil)
	cmt_buf[7] = 0xff
	bad_out, bad_dropped, bwerr := toml.write(&bad_cmt, .Toml_1_0)
	defer delete(bad_out)
	testing.expectf(t, bwerr == nil && .Comment in bad_dropped && toml.validate(bad_out, .Toml_1_0) == nil, "bad utf8 comment: %v %v %q", bwerr, bad_dropped, bad_out)

	lit_buf := transmute([]u8)strings.clone("a = 'badX'\n")
	defer delete(lit_buf)
	lit_doc, lerr := toml.build(lit_buf, .Toml_1_0)
	defer toml.destroy(&lit_doc)
	testing.expect(t, lerr == nil)
	lit_buf[8] = 0xff
	lit_out, _, lwerr := toml.write(&lit_doc, .Toml_1_0)
	defer delete(lit_out)
	testing.expectf(t, lwerr == nil && toml.validate(lit_out, .Toml_1_0) == nil && string(lit_out) == "a = \"bad\ufffd\"\n", "bad utf8 literal: %v %q", lwerr, lit_out)

	// 6. Deep dotted keys (10,000+ levels) write iteratively without native stack overflow.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	DEPTH :: 10_000
	for i in 0 ..< DEPTH {
		if i > 0 {
			strings.write_byte(&b, '.')
		}
		strings.write_byte(&b, 'a')
	}
	strings.write_string(&b, " = 1\n")
	deep_src := transmute([]u8)strings.to_string(b)
	deep_doc, deep_err := toml.build(deep_src, .Toml_1_0, {budget = {depth = DEPTH + 16}})
	defer toml.destroy(&deep_doc)
	testing.expectf(t, deep_err == nil, "deep build: %v", deep_err)
	deep_out, _, deep_werr := toml.write(&deep_doc, .Toml_1_0)
	defer delete(deep_out)
	testing.expectf(t, deep_werr == nil && string(deep_out) == string(deep_src), "deep write: %v len=%d", deep_werr, len(deep_out))
}

@(test)
toml_is_v1s_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string(`{"a":1,"b":"x\ny","c":[1,2.5],"d":{"e":true},"f":[{"g":1},{"g":2}]}`))
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := toml.write(&doc)
	defer delete(text)
	want := "a = 1\nb = \"x\\ny\"\nc = [1, 2.5]\n\n[d]\ne = true\n\n[[f]]\ng = 1\n\n[[f]]\ng = 2\n"
	testing.expectf(t, werr == nil && string(text) == want, "%v\n%s", werr, text)
}

@(test)
a_header_under_dotted_keys_is_written_as_a_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "[fruit]\napple.color = \"red\"\n\n[fruit.apple.texture]\nsmooth = true\n\n[[fruit.apple.seeds]]\nsize = 2\n"
	doc, err := toml.build(transmute([]u8)src, .Toml_1_1)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := toml.write(&doc, .Toml_1_1)
	defer delete(text)
	testing.expectf(t, werr == nil && string(text) == src, "%v\n%s", werr, text)
}

@(test)
a_table_in_braces_keeps_its_comments_in_toml_1_1 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = {# lead\n\tb = 1, # one\n\tc = 2,\n\t# foot\n}\n"
	doc, err := toml.build(transmute([]u8)src, .Toml_1_1)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	text, dropped, werr := toml.write(&doc, .Toml_1_1)
	defer delete(text)
	testing.expectf(t, werr == nil && dropped & tape.COMMENTS == {} && string(text) == "a = {\n# lead\nb = 1, # one\nc = 2,\n# foot\n}\n", "%v %v\n%s", werr, dropped, text)
	// A text of 1.0 cannot break a table in braces, so its comments are reported.
	text10, dropped10, werr10 := toml.write(&doc, .Toml_1_0)
	defer delete(text10)
	testing.expectf(t, werr10 == nil && dropped10 & tape.COMMENTS != {} && string(text10) == "a = {b = 1, c = 2}\n", "%v %v\n%s", werr10, dropped10, text10)
}

@(private = "file")
FACT_TEXTS := [?]string{
	"# head\n\na = 1 # one\nb = 0xFF\nc = 1.0\nd = 'lit'\ne = \"\"\"\nml\nx\"\"\"\nf = '''\nmlit\n'''\ng = 1979-05-27T07:32:00Z\n# lead t\n[t] # on t\nx = [1, 2] # xs\n# foot t\n\n[t.u]\ny = {p = 1, q = 2}\n\n[[arr]]\nk = 1\n\n# second\n[[arr]]\nk = 2\n",
	"a.b = 1\na.c = 2\n\"quoted key\" = 3\n'lit key' = 4\n[x.y.z]\nv = true\n",
	"[t]\nx = 1\n# end of t\n\n[u]\ny = 1\n# file end\n",
	"i = inf\nn = nan\nm = -inf\no = 0o17\nb = 0b101\n",
}

// A description of the facts of `doc`: each node's style and tag names and each fact's kind and text.
describe :: proc(doc: ^tape.Document, unordered := false) -> string {
	b: strings.Builder
	lines := make([dynamic]string, context.temp_allocator)
	for _, i in doc.nodes {
		at := tape.Node_Index(i)
		style, _ := tape.fact_name(doc, at, .Style)
		tag, _ := tape.fact_name(doc, at, .Tag)
		line: strings.Builder
		strings.builder_init(&line, context.temp_allocator)
		fmt.sbprintf(&line, "%d %q %q", 0 if unordered else i, style, tag)
		for f in tape.facts_of(doc, at) {
			fmt.sbprintf(&line, " %v:%q", f.kind, string(tape.span_bytes(doc, f.lo, f.n)))
		}
		append(&lines, strings.to_string(line))
	}
	if unordered {
		slice.sort(lines[:])
	}
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(test)
toml_facts_are_written_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in FACT_TEXTS {
		doc, err := toml.build(transmute([]u8)src)
		defer toml.destroy(&doc)
		testing.expectf(t, err == nil, "%d: %v", k, err)
		text, dropped, werr := toml.write(&doc)
		defer delete(text)
		testing.expectf(t, werr == nil && dropped == {}, "%d: %v %v\n%s", k, werr, dropped, text)
		back, berr := toml.build(text)
		defer toml.destroy(&back)
		testing.expectf(t, berr == nil, "%d: %v\n%s", k, berr, text)
		want, got := describe(&doc), describe(&back)
		defer delete(want)
		defer delete(got)
		testing.expectf(t, want == got, "%d: facts differ\n%s\nwant\n%s\ngot\n%s", k, text, want, got)
	}
}

@(test)
comments_of_other_formats_are_written :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string("// head\n{\n// lead a\n\"a\": 1, // tail a\n\"b\": {\"c\": 2}\n}\n"), .Jsonc)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	text, dropped, werr := toml.write(&doc)
	defer delete(text)
	want := "# head\n\n# lead a\na = 1 # tail a\n\n[b]\nc = 2\n"
	testing.expectf(t, werr == nil && dropped == {} && string(text) == want, "%v %v\n%s", werr, dropped, text)
}

@(test)
indent_and_sorted_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, _ := json.build(transmute([]u8)string(`{"b":1,"a":{"z":1,"y":{"q":[{"k":1}]}},"c":{"w":2,"v":3}}`))
	defer json.destroy(&doc)
	text, _, err := toml.write(&doc, .Toml_1_0, {indent = 2, sort_keys = true})
	defer delete(text)
	want := "b = 1\n\n[a]\n  z = 1\n\n  [a.y]\n\n    [[a.y.q]]\n      k = 1\n\n[c]\n  v = 3\n  w = 2\n"
	testing.expectf(t, err == nil && string(text) == want, "%v\n%s", err, text)
	back, berr := toml.build(text)
	defer toml.destroy(&back)
	testing.expect(t, berr == nil)
}

@(test)
suite_texts_write_and_read_back_with_their_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	written := 0
	for dir in SUITE {
		if !strings.has_prefix(dir.prefix, "valid/") {
			continue
		}
		for file in dir.files {
			if !strings.has_suffix(file.name, ".toml") {
				continue
			}
			doc, err := toml.build(file.data, .Toml_1_1)
			defer toml.destroy(&doc)
			if err != nil {
				continue
			}
			text, _, werr := toml.write(&doc, .Toml_1_1)
			defer delete(text)
			if werr != nil {
				// A TOML text holds no null, but a value past 64 bits or a key that is a container is refused too.
				continue
			}
			written += 1
			// Known gaps: a comment inside an inline table, and tables a header made under a table of dotted keys, are not
			// written as they were.
			back, berr := toml.build(text, .Toml_1_1)
			defer toml.destroy(&back)
			testing.expectf(t, berr == nil, "%s%s: %v\n%s", dir.prefix, file.name, berr, text)
			want, got := describe(&doc, true), describe(&back, true)
			defer delete(want)
			defer delete(got)
			testing.expectf(t, berr == nil && want == got, "%s%s: facts differ\n%s\nwant\n%s\ngot\n%s", dir.prefix, file.name, text, want, got)
		}
	}
	testing.expect(t, written > 100)
}
