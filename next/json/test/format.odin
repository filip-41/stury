package json_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// Every read of a spec, through its handle and its reads table alone, gives what the spec's own call gives.
@(test)
reads_through_each_specs_table_match_its_calls :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		f := json.as(spec)
		r := json.reads(spec)
		text := transmute([]u8)string(`{"a": [1, {"b": 2}], /* c */ "d": 3}` if spec != .Json else `{"a": [1, {"b": 2}], "d": 3}`)
		testing.expect_value(t, r.validate(f, text, {}, context.allocator), nil)
		doc, err := r.build(f, text, {}, context.allocator)
		defer tape.destroy(&doc)
		testing.expect(t, err == nil && len(doc.nodes) == 9 && doc.format == f)
		found, ferr := r.find(f, text, {tape.Name("a"), tape.Index(1), tape.Name("b")}, {}, {}, context.allocator)
		testing.expect(t, ferr == nil && found.outcome == .Found && text[found.lo] == '2')
		d, _ := tape.demand_of([][]tape.Step{{tape.Name("d")}})
		defer tape.destroy(&d)
		part, serr := r.scan(f, text, &d, {}, {}, context.allocator)
		defer tape.destroy(&part)
		at, p, ok := tape.answer(tape.Reader{&part, nil}, 0, 0)
		testing.expect(t, serr == nil && ok && p == .Found && part.src[part.nodes[at].lo] == '3')
		_, bad := r.build(f, transmute([]u8)string("[1,"), {}, context.allocator)
		testing.expect(t, bad != nil)
	}
}

// A container's close end is the byte past its bracket, past the closes of the containers it ends with and the white
// space, commas and comments before them.
@(test)
format_finds_a_close_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		spec:   json.Spec,
		src:    string,
		steps:  []tape.Step,
		closed: string, // the text up to the close end
	}
	cases := []Case{
		{.Json, `[[1], 2]`, {tape.Index(0)}, `[[1]`},
		{.Json, `{"a": [[[]] ] , "b": 1}`, {tape.Name("a")}, `{"a": [[[]] ]`},
		{.Json, `[{"a": "x"} ]`, {tape.Index(0)}, `[{"a": "x"}`},
		{.Json, `[[{}]]`, {tape.Index(0)}, `[[{}]`},
		{.Jsonc, `[[1, /* ] */ // ]
 ], 2]`, {tape.Index(0)}, "[[1, /* ] */ // ]\n ]"},
		{.Json5, `[{a: 'x',}, 1]`, {tape.Index(0)}, `[{a: 'x',}`},
		{.Json, ` [1] `, {}, ` [1]`},
	}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.spec)
		defer tape.destroy(&doc)
		r := tape.Reader{&doc, nil}
		at, p := tape.root(r)
		for step in c.steps {
			#partial switch s in step {
			case tape.Name:
				at, p = tape.member(r, at, string(s))
			case tape.Index:
				at, p = tape.element(r, at, int(s))
			}
		}
		testing.expectf(t, err == nil && p == .Found, "%q: %v %v", c.src, err, p)
		end, ok := doc.format.close_end(&doc, at)
		testing.expectf(t, ok && c.src[:end] == c.closed, "%q: %q", c.src, c.src[:end])
	}
}

// The node readers of a binding: a key's span and escape, a number's form and exact value, and whether a text is
// ASCII.
@(test)
format_node_readers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := transmute([]u8)string(`{"k\u00e9": -12.50e3, "plain": 18446744073709551615, "x": -9223372036854775808, "y": "\u0041b", "z": 1.5}`)
	doc, err := json.build(text)
	defer tape.destroy(&doc)
	testing.expect(t, err == nil)
	r := tape.Reader{&doc, nil}
	span, escaped := tape.key_raw(&doc, 1)
	testing.expect(t, string(span) == `k\u00e9` && escaped)
	span, escaped = tape.key_raw(&doc, 3)
	testing.expect(t, string(span) == "plain" && !escaped)
	form, ok := tape.number_form(&doc, 2)
	testing.expect(t, ok && form.int_digits == 2 && form.frac_digits == 2 && form.exponent && !form.point && form.kind == 0)
	_, ok = tape.number_form(&doc, 1)
	testing.expect(t, !ok)
	big, _ := tape.member(r, tape.ROOT, "plain")
	_, u, unsigned, exact := tape.number_exact(&doc, big)
	testing.expect(t, exact && unsigned && u == max(u64))
	low, _ := tape.member(r, tape.ROOT, "x")
	i, _, signed_unsigned, low_exact := tape.number_exact(&doc, low)
	testing.expect(t, low_exact && !signed_unsigned && i == min(i64))
	half, _ := tape.member(r, tape.ROOT, "z")
	_, _, _, half_exact := tape.number_exact(&doc, half)
	testing.expect(t, !half_exact)
	buf: [16]u8
	ascii, fits := tape.text_is_ascii(&doc, 1, buf[:])
	testing.expect(t, fits && !ascii)
	y, _ := tape.member(r, tape.ROOT, "y")
	ascii, fits = tape.text_is_ascii(&doc, y, buf[:])
	testing.expect(t, fits && ascii)
	ascii, fits = tape.text_is_ascii(&doc, 3, buf[:])
	testing.expect(t, fits && ascii)
}

// The byte past the bracket that closes the container opened at `lo`, found by reading the text as its grammar does:
// strings and comments hold brackets that do not count, and a `//` comment ends at LF or CR, and in JSON5 at U+2028 or
// U+2029.
matching_close :: proc(src: []u8, lo: u64, json5: bool) -> u64 {
	depth := 0
	for i := int(lo); i < len(src); i += 1 {
		switch src[i] {
		case '"', '\'':
			quote := src[i]
			for i += 1; i < len(src) && src[i] != quote; i += 1 {
				i += int(src[i] == '\\')
			}
		case '/':
			if i + 1 < len(src) && src[i + 1] == '*' {
				for i += 2; i + 1 < len(src) && !(src[i] == '*' && src[i + 1] == '/'); i += 1 {
				}
				i += 1
			} else if i + 1 < len(src) && src[i + 1] == '/' {
				for i += 2; i < len(src) && src[i] != '\n' && src[i] != '\r' && !(json5 && i + 2 < len(src) && src[i] == 0xe2 && src[i + 1] == 0x80 && src[i + 2] & 0xfe == 0xa8); i += 1 {
				}
				i -= 1
			}
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
			if depth == 0 {
				return u64(i + 1)
			}
		}
	}
	return u64(len(src))
}

// The close end of every container of a text, the root included, is the byte past its matching bracket, in texts with
// comments that hold brackets, quotes, stars and every line end.
@(test)
format_close_ends_match_brackets :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xc105e)
	check :: proc(t: ^testing.T, src: []u8, spec: json.Spec, name: string, checked: ^int) {
		doc, err := json.build(src, spec)
		defer tape.destroy(&doc)
		if err != nil {
			return
		}
		for node, i in doc.nodes {
			if node.kind < .Array || node.role != .Value {
				continue
			}
			checked^ += 1
			got, ok := doc.format.close_end(&doc, tape.Node_Index(i))
			want := matching_close(src, node.lo, spec == .Json5)
			testing.expectf(t, ok && got == want, "%s %v: container at %d closes at %d, want %d", name, spec, node.lo, got, want)
		}
	}
	checked := 0
	files := corpus_files()
	defer delete(files)
	for file in files {
		check(t, file.data, file.spec, file.name, &checked)
	}
	for f in FLAVORS {
		if f.spec == .Json {
			continue
		}
		for _ in 0 ..< testkit.rounds(150) {
			src := random_text(f)
			check(t, src, f.spec, "generated", &checked)
		}
	}
	testing.expectf(t, checked > 2000, "%d containers", checked)
}

// A container's close end is past its bracket when a `//` comment before it ends at CR, and in JSON5 at U+2028 or
// U+2029, as the walk reads the comment. In JSONC U+2028 ends no comment.
@(test)
format_close_ends_follow_line_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		spec: json.Spec,
		src:  string,
	}{{.Jsonc, "[[1 // a\r], 2]"}, {.Json5, "[[1 // a\r], 2]"}, {.Json5, "[[1 // a\u2028], 2]"}, {.Json5, "[[1 // a\u2029], 2]"}, {.Jsonc, "[[1 // a\u2028]\n], 2]"}}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.spec)
		defer tape.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", c.src, err)
		end, ok := doc.format.close_end(&doc, 1)
		testing.expect(t, ok && end == u64(strings.index(c.src, "], 2]") + 1))
	}
}

// A text written token by token into a sink is the text `write` makes of the document, whatever the layout.
@(test)
tokens_into_a_sink_are_the_text_of_the_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `{"a":[1,2.5,{"b":null}],"c":"x\ny","d":{},"e":[]}`
	doc, err := json.build(transmute([]u8)src)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}, {ascii = true}}) {
		want, _, werr := json.write(&doc, .Json, opts)
		defer delete(want)
		testing.expect(t, werr == nil)
		sink: strings.Builder
		defer strings.builder_destroy(&sink)
		w: json.Writer
		testing.expect(t, json.writer_start(&w, opts, strings.to_writer(&sink)) == nil)
		steps := [?]struct {
			kind: write.Token_Kind,
			text: string,
		}{{.Object, ""}, {.Key, "a"}, {.Array, ""}, {.Number, "1"}, {.Number, "2.5"}, {.Object, ""}, {.Key, "b"}, {.Null, ""}, {.Close, ""}, {.Close, ""}, {.Key, "c"}, {.String, "x\ny"}, {.Key, "d"}, {.Object, ""}, {.Close, ""}, {.Key, "e"}, {.Array, ""}, {.Close, ""}, {.Close, ""}}
		for step in steps {
			testing.expect(t, json.token(&w, step.kind, step.text) == nil)
		}
		_, eerr := json.writer_end(&w)
		testing.expect(t, eerr == nil)
		testing.expectf(t, strings.to_string(sink) == string(want), "%v: %s\nwant %s", opts, strings.to_string(sink), want)
	}
}

// Deep nesting past `ROW_LEVELS` (64) must grow the `write_rows` container stack cleanly across compact, indented,
// tabbed, ASCII, and comment-preserving JSON/JSONC/JSON5 modes, matching sink output byte for byte.
@(test)
perf4_write_rows_deep_nesting_past_stack_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	depth :: 150
	b := strings.builder_make(context.temp_allocator)
	for lvl in 0 ..< depth {
		if lvl % 2 == 0 {
			strings.write_string(&b, `{"k":`)
		} else {
			strings.write_byte(&b, '[')
		}
	}
	strings.write_string(&b, `"leaf"`)
	for lvl := depth - 1; lvl >= 0; lvl -= 1 {
		if lvl % 2 == 0 {
			strings.write_byte(&b, '}')
		} else {
			strings.write_byte(&b, ']')
		}
	}
	src := strings.to_string(b)
	doc, berr := json.build(transmute([]u8)src)
	defer tape.destroy(&doc)
	testing.expect_value(t, berr, nil)

	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		for opts in ([]json.Write_Options{{}, {indent = 2}, {tab = true}, {indent = 2, ascii = true}, {tab = true, ascii = true}}) {
			out, _, werr := json.write(&doc, spec, opts)
			defer delete(out)
			testing.expectf(t, werr == nil, "spec=%v opts=%v err=%v", spec, opts, werr)

			sink: strings.Builder
			defer strings.builder_destroy(&sink)
			_, serr := json.write_to(strings.to_writer(&sink), &doc, spec, opts)
			testing.expectf(t, serr == nil, "sink spec=%v opts=%v err=%v", spec, opts, serr)
			testing.expectf(t, strings.to_string(sink) == string(out), "sink mismatch spec=%v opts=%v", spec, opts)

			round, rerr := json.build(out, spec)
			defer tape.destroy(&round)
			testing.expectf(t, rerr == nil && len(round.nodes) == len(doc.nodes), "roundtrip spec=%v err=%v", spec, rerr)
		}
	}

	// Same deep nesting with comments so `rows_fact_value` and `rows_fact_close` also exercise stack growth past 64.
	bc := strings.builder_make(context.temp_allocator)
	strings.write_string(&bc, "/* lead */\n")
	for lvl in 0 ..< depth {
		if lvl % 2 == 0 {
			strings.write_string(&bc, `{"k":`)
		} else {
			strings.write_byte(&bc, '[')
		}
	}
	strings.write_string(&bc, `"leaf" // inline`)
	strings.write_byte(&bc, '\n')
	for lvl := depth - 1; lvl >= 0; lvl -= 1 {
		if lvl % 2 == 0 {
			strings.write_byte(&bc, '}')
		} else {
			strings.write_byte(&bc, ']')
		}
	}
	csrc := strings.to_string(bc)
	cdoc, cberr := json.build(transmute([]u8)csrc, .Jsonc)
	defer tape.destroy(&cdoc)
	testing.expect_value(t, cberr, nil)
	for opts in ([]json.Write_Options{{}, {indent = 2}, {tab = true}}) {
		cout, cdropped, cwerr := json.write(&cdoc, .Jsonc, opts)
		defer delete(cout)
		testing.expectf(t, cwerr == nil && cdropped == {}, "jsonc deep opts=%v dropped=%v err=%v", opts, cdropped, cwerr)
		cround, crerr := json.build(cout, .Jsonc)
		defer tape.destroy(&cround)
		testing.expectf(t, crerr == nil && len(cround.nodes) == len(cdoc.nodes), "jsonc roundtrip opts=%v err=%v", opts, crerr)
	}
}

// Exercises `doc_span` / `doc_span_held` on `.Held` windowed documents (`records_scan` over pieces), JSON5
// non-finite numbers in `put_number`, ASCII/astral escapes in `put_ascii`, and comment fallbacks in
// `inline_comments` / `put_comment`.
@(test)
perf4_write_held_span_ascii_and_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Single `.Json5` record holding strings, comments, bare keys, astral runes, and non-finite numbers, streamed in pieces so `.Held` is set.
	rec_src := "{bare_key:\"é😀\",'sq':'a\\vb',inf:Infinity,ninf:-Infinity,nan:NaN,num:42} // c1\n"
	p: tape.Pieces
	defer tape.destroy(&p)
	bs := transmute([]u8)rec_src
	step :: 7
	p.last = step >= len(bs)
	demand, derr := tape.demand_of({{tape.Name("bare_key")}, {tape.Name("sq")}, {tape.Name("inf")}, {tape.Name("ninf")}, {tape.Name("nan")}, {tape.Name("num")}})
	defer tape.destroy_demand(&demand)
	testing.expect_value(t, derr, nil)

	r := json.records_open(bs[:min(step, len(bs))], .Lines, .Json5, json.Options{pieces = &p})
	defer tape.destroy_records(&r)
	recs: [4]tape.Record
	docs: [4]tape.Document
	got := 0
	for {
		chunk := json.records_scan(&r, &demand, recs[got:], docs[got:])
		got += chunk
		if !p.more {
			break
		}
		p.from = p.keep
		next_to := min(int(p.at) + step, len(bs))
		p.last = next_to == len(bs)
		werr := tape.records_window(&r, bs[p.from:next_to])
		testing.expect_value(t, werr, nil)
	}
	testing.expectf(t, got == 1 && recs[0].err == nil, "scan got=%d err=%v", got, recs[0].err)
	testing.expect(t, .Held in docs[0].flags, "expected .Held flag on windowed scan document")

	// Writing held doc as `.Json5` keeps non-finite numbers via `doc_span_held`.
	out5, _, w5err := json.write(&docs[0], .Json5, {indent = 2, ascii = true})
	defer delete(out5)
	testing.expect_value(t, w5err, nil)
	s5 := string(out5)
	testing.expectf(t, strings.contains(s5, "Infinity") && strings.contains(s5, "NaN") && strings.contains(s5, `\u00e9\ud83d\ude00`), "unexpected json5 out: %s", s5)

	// Writing the same `.Held` doc as strict `.Json` refuses `Infinity` (`No_Spelling`).
	outj, _, wjerr := json.write(&docs[0], .Json)
	defer delete(outj)
	ref, is_ref := wjerr.(write.Refused)
	testing.expectf(t, is_ref && ref.why == .No_Spelling, "expected No_Spelling refusal on Infinity->Json, got %v", wjerr)

	// Exercise `inline_comments` and `put_comment`: JSONC holds two inline comments where the first contains U+2028
	// (not a line terminator in JSONC); writing to JSON5 drops that first inline comment before emitting the second.
	c5_src := "{/* lead */\n\"a\":1 /* b1 \xe2\x80\xa8 */ /* b2 */ // l */ tail\n, \"b\": /* has */ \"x\\n\\u0001é😀\"\n}"
	c5_doc, c5_err := json.build(transmute([]u8)c5_src, .Jsonc)
	defer tape.destroy(&c5_doc)
	testing.expect_value(t, c5_err, nil)
	c5_out, c5_dropped, c5_werr := json.write(&c5_doc, .Json5, {ascii = true})
	defer delete(c5_out)
	testing.expect_value(t, c5_werr, nil)
	testing.expect(t, .Comment_Inline in c5_dropped, "expected U+2028 block inline comment before second inline comment to be dropped")
	c5_back, c5_berr := json.build(c5_out, .Json5)
	defer tape.destroy(&c5_back)
	testing.expectf(t, c5_berr == nil, "ascii json5 comments did not roundtrip: %v in %s", c5_berr, c5_out)
}

// Verifies `write_as`'s pre-Tree `dense_route` fast bypass and non-bypass edge cases (partial, cut, sub-node, key node).
@(test)
perf4_write_dense_bypass_and_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := `{"a":[1,2,3],"b":{"nested":"val"},"c":"plain"}`
	doc, err := json.build(transmute([]u8)src)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)

	// Dense fast path matches compact text exactly.
	compact, dropped, cerr := json.write(&doc, .Json)
	defer delete(compact)
	testing.expectf(t, cerr == nil && dropped == {} && string(compact) == src, "dense bypass mismatch: %s %v", compact, cerr)

	// Key node (`opts.node = 1`) must return `Bad_Option{"node"}`.
	bad_out, _, bad_err := json.write(&doc, .Json, {node = 1})
	defer delete(bad_out)
	bo, is_bo := bad_err.(tape.Bad_Option)
	testing.expectf(t, is_bo && bo.option == "node", "expected Bad_Option node, got %v", bad_err)

	// Sub-node (`opts.node = 2`, the `[1,2,3]` array) writes only that subtree cleanly.
	sub_out, _, sub_err := json.write(&doc, .Json, {node = 2})
	defer delete(sub_out)
	testing.expectf(t, sub_err == nil && string(sub_out) == "[1,2,3]", "sub-node mismatch: %s %v", sub_out, sub_err)

	// `.Cut` partial read must return `Refused{0, .Partial}` via `write_as` / `write_walked`.
	cut_p := tape.Pieces{so_far = true, allocator = context.allocator}
	defer tape.destroy(&cut_p)
	cut_src := `{"a":[1,2`
	cut_doc, cut_err := json.build(transmute([]u8)cut_src, .Json, {pieces = &cut_p})
	defer tape.destroy(&cut_doc)
	testing.expect_value(t, cut_err, nil)
	testing.expect(t, .Cut in cut_doc.flags, "expected .Cut flag")
	cout, _, cwerr := json.write(&cut_doc, .Json)
	defer delete(cout)
	cref, is_cref := cwerr.(write.Refused)
	testing.expectf(t, is_cref && cref.why == .Partial, "expected Partial refusal on .Cut doc, got %v", cwerr)
}
