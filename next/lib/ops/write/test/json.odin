package write_tests

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// JSON's writer: every text of the suites and the fixtures, built in each spec, written in each spec and layout, is a
// valid text of the target that reads back as the same values with the comments the target holds, and a write of that
// reading is the same text.

@(private = "file")
FIXTURES_DIR :: #directory + "../../../../../bench/fixtures/"

@(private = "file")
FIXTURES := [?]string{"corpus/canada.json", "corpus/citm_catalog.json", "corpus/twitter.json", "logs.json", "utf8.json", "escape.json", "nested.json"}

@(private = "file")
fixture :: proc(name: string, allocator := context.allocator) -> ([]u8, os.Error) {
	return os.read_entire_file(strings.concatenate({FIXTURES_DIR, name}, context.temp_allocator), allocator)
}

// Appends each fixture's text, which a missing fixture fails.
@(private = "file")
append_fixtures :: proc(t: ^testing.T, texts: ^[dynamic]string) {
	for name in FIXTURES {
		src, err := fixture(name, context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", name, err)
		append(texts, string(src))
	}
}

// Reads `src` by the route under test and again as JSON5 flagged as read with a tolerance, whose write is the walk.
@(private = "file")
build_both_routes :: proc(t: ^testing.T, src: string, k: int, route: json.Spec) -> (fast, walked: json.Document) {
	fast_err, walked_err: json.Error
	fast, fast_err = json.build(transmute([]u8)src, route)
	walked, walked_err = json.build(transmute([]u8)src, .Json5)
	testing.expectf(t, fast_err == nil && walked_err == nil, "text %d: %v %v", k, fast_err, walked_err)
	// A tolerated read takes the walk on every path, which is the model.
	walked.flags += {.Tolerated}
	return
}

// The layouts each text is written in: compact, two spaces, a tab, an odd width.
@(private)
LAYOUTS := [?]write.Options{{}, {indent = 2}, {tab = true}, {indent = 7}, {ascii = true}, {indent = 2, ascii = true}}

@(private)
Tally :: struct {
	texts, writes, refused: int,
}

// Writes the document `src` builds as `from` in every spec and layout and checks each against the laws. A text whose
// write is refused must hold a value the target cannot spell, which only JSON5's non-finite numbers are.
@(private)
round_trips :: proc(t: ^testing.T, src: []u8, from: json.Spec, name: string, tally: ^Tally) {
	doc, err := json.build(src, from)
	if err != nil {
		return
	}
	defer json.destroy(&doc)
	tally.texts += 1
	for to in json.Spec {
		for opts in LAYOUTS {
			tally.writes += 1
			text, dropped, werr := json.write(&doc, to, opts)
			if werr != nil {
				r, refused := werr.(write.Refused)
				num := doc.nodes[r.node] if refused else {}
				ok := refused && r.why == .No_Spelling && from == .Json5 && to != .Json5 && num.kind == .Number
				testing.expectf(t, ok, "%s as %v to %v %v: %v", name, from, to, opts, werr)
				tally.refused += 1
				continue
			}
			defer delete(text)
			what := fmt.tprintf("%s as %v to %v %v", name, from, to, opts)
			holds := json.as(to).facts
			testing.expectf(t, dropped == doc.present - holds, "%s: dropped %v of %v", what, dropped, doc.present)
			if verr := json.validate(text, to); verr != nil {
				testing.expectf(t, false, "%s: %v in %q", what, verr, text)
				continue
			}
			back, berr := json.build(text, to)
			defer json.destroy(&back)
			testing.expect_value(t, berr, nil)
			same := testkit.Same{number_values = from == .Json5 && to != .Json5, facts = holds}
			if !testkit.values_agree(t, &doc, json.ROOT, &back, json.ROOT, same, what) {
				log.infof("%q\nwritten %q", src, text)
				continue
			}
			again, _, aerr := json.write(&back, to, opts)
			defer delete(again)
			testing.expectf(t, aerr == nil && string(again) == string(text), "%s: rewrite %q of %q", what, again, text)
		}
	}
	free_all(context.temp_allocator)
}

@(test)
json_writes_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	tally: Tally
	for f in #load_directory("../../../../json/test/conformance/JSONTestSuite/test_parsing") {
		round_trips(t, f.data, .Json, f.name, &tally)
		round_trips(t, f.data, .Json5, f.name, &tally)
	}
	json5 := [?][]runtime.Load_Directory_File {
		#load_directory("../../../../json/test/conformance/json5-tests/arrays"),
		#load_directory("../../../../json/test/conformance/json5-tests/comments"),
		#load_directory("../../../../json/test/conformance/json5-tests/misc"),
		#load_directory("../../../../json/test/conformance/json5-tests/new-lines"),
		#load_directory("../../../../json/test/conformance/json5-tests/numbers"),
		#load_directory("../../../../json/test/conformance/json5-tests/objects"),
		#load_directory("../../../../json/test/conformance/json5-tests/strings"),
	}
	for dir in json5 {
		for f in dir {
			round_trips(t, f.data, .Json5, f.name, &tally)
			round_trips(t, f.data, .Jsonc, f.name, &tally)
		}
	}
	for src in COMMENTED {
		round_trips(t, transmute([]u8)src, .Jsonc, src, &tally)
		round_trips(t, transmute([]u8)src, .Json5, src, &tally)
	}
	testing.expectf(t, tally.texts > 380, "%d texts", tally.texts)
	for name in FIXTURES {
		if src, err := fixture(name); err == nil {
			round_trips(t, src, .Json, name, &tally)
			delete(src)
		}
	}
	log.infof("%d texts, %d writes, %d refused", tally.texts, tally.writes, tally.refused)
}

// Texts with a comment at every place a read takes one: before a value, a key or a close, between a key and its
// value, on a value's line, in an empty container, before and after the root, as line and block comments.
@(private)
COMMENTED := [?]string{
	"// lead\n{\"a\": 1, // inline a\n /* lead b */ \"b\": [1 /* inline 1 */, 2 // inline 2\n // foot b\n ], \"c\": {} // inline c\n // foot root\n}\n// after",
	"[ /* in empty */ ]",
	"{ // inline open\n}",
	"1 // inline root\n// foot root",
	"/* a */ /* b */ [1, /* c */ /* d */ 2 /* e */ /* f */]",
	"{\"k\" /* between */ : /* colon */ 3}",
	"[1, // x\n2]",
	"[[[]] /* deep */, {\"a\": {\"b\": [/* c */]}}]",
	"[1 /* a // b */, 2 // c /* d\n]",
	"[\"/* not */\", \"// not\"] /* end */",
}

// What a read's tolerances took writes one way on every path, short or long, whatever the white space after it: an
// ill-formed sequence as U+FFFD, NaN and Infinity refused where the target has no spelling for them and written as read
// in JSON5. A JSON5 hex integer of 4096 digits after its sign and `0x` is written.
@(test)
json_writes_tolerated_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pad := strings.repeat(" ", 100, context.temp_allocator)
	x := strings.repeat("x", 80, context.temp_allocator)
	for tail in ([]string{"", pad}) {
		for src in ([]string{"[\"a\xb7\"]", fmt.tprintf("[\"a\xb7%s\", {{\"k\xb7%s\": 1}}]", x, x)}) {
			text := fmt.tprintf("%s%s", src, tail)
			doc, err := json.build(transmute([]u8)text, .Json, {tolerate = {.Invalid_Utf8}})
			defer json.destroy(&doc)
			testing.expect_value(t, err, nil)
			for opts in LAYOUTS {
				out, _, werr := json.write(&doc, .Json, opts)
				defer delete(out)
				testing.expectf(t, werr == nil && json.validate(out) == nil && strings.contains(string(out), "a\\ufffd" if opts.ascii else "a�"), "%q %v: %q %v", text, opts, out, werr)
			}
		}
		for src in ([]string{"[1, NaN, 2]", "[-Infinity]"}) {
			text := fmt.tprintf("%s%s", src, tail)
			doc, err := json.build(transmute([]u8)text, .Json, {tolerate = {.Non_Finite}})
			defer json.destroy(&doc)
			testing.expect_value(t, err, nil)
			for opts in LAYOUTS {
				for to in ([]json.Spec{.Json, .Jsonc}) {
					_, _, werr := json.write(&doc, to, opts)
					r, refused := werr.(write.Refused)
					testing.expectf(t, refused && r.why == .No_Spelling, "%q to %v %v: %v", text, to, opts, werr)
				}
				out, _, werr := json.write(&doc, .Json5, opts)
				defer delete(out)
				back, berr := json.build(out, .Json5)
				defer json.destroy(&back)
				testing.expectf(t, werr == nil && berr == nil && len(back.nodes) == len(doc.nodes), "%q to JSON5 %v: %q %v", text, opts, out, werr)
			}
		}
	}
	hex := fmt.tprintf("-0x%s", strings.repeat("f", 4096, context.temp_allocator))
	doc, _ := json.build(transmute([]u8)hex, .Json5)
	defer json.destroy(&doc)
	out, _, werr := json.write(&doc, .Json)
	defer delete(out)
	testing.expectf(t, werr == nil && len(out) > 4900 && out[0] == '-', "%v %d", werr, len(out))
}

// Strings as written and respelled only where the target needs it, JSON5 numbers in JSON's spelling, and a key of each kind
// JSON5 writes.
@(test)
json_spells_each_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:  string,
		from: json.Spec,
		to:   json.Spec,
		want: string,
	}
	cases := [?]Case{
		{`"\u00e9\/\u0041\n\u001f\ud83d\ude00\"\\\b\f\r\t\u007f\u2028"`, .Json, .Json, `"\u00e9\/\u0041\n\u001f\ud83d\ude00\"\\\b\f\r\t\u007f\u2028"`},
		{`{"\u0061\u0000":"x"}`, .Json, .Json, `{"\u0061\u0000":"x"}`},
		{`[+1, .5, 5., +.5e3, -.5, 5.e2, 0x1F, -0xff, +0x0, 0xFFFFFFFFFFFFFFFFFF, 1e400]`, .Json5, .Json, `[1,0.5,5.0,0.5e3,-0.5,5.0e2,31,-255,0,4722366482869645213695,1e400]`},
		{`[+1, .5, 0x1F, Infinity, -NaN, 'a"b', "c'd"]`, .Json5, .Json5, `[+1,.5,0x1F,Infinity,-NaN,'a"b',"c'd"]`},
		{`{a: 1, $b_c: 'x', 'q': "y", "\u0041": 2}`, .Json5, .Json, `{"a":1,"$b_c":"x","q":"y","\u0041":2}`},
		{`{a: 1, $b_c: 'x', 'q': "y"}`, .Json5, .Json5, `{a:1,$b_c:'x','q':"y"}`},
		{"'line\\\ncontinued \\x41 \\v \\0'", .Json5, .Json, "\"linecontinued A \\u000b \\u0000\""},
		{"'it\\'s \"q\" \\x0a\\x22 \\a\\n\\u00e9\ttab \\\r\n!'", .Json5, .Json, `"it's \"q\" \n\" a\n\u00e9\ttab !"`},
		{`['\x41é', "\x7e\n", 'é', "\q"]`, .Json5, .Jsonc, `["Aé","~\n","é","q"]`},
		{`['\xe9\xE9']`, .Json5, .Json, `["éé"]`},
		{`["a\né😀", 'b\n']`, .Json5, .Json5, `["a\né😀",'b\n']`},
		{`[1, [2, [3]], {}]`, .Json, .Json, `[1,[2,[3]],{}]`},
		{"  {\n \"a\" : [ true , false , null ] }  ", .Json, .Json, `{"a":[true,false,null]}`},
	}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.from)
		defer json.destroy(&doc)
		testing.expect_value(t, err, nil)
		text, _, werr := json.write(&doc, c.to)
		defer delete(text)
		testing.expectf(t, werr == nil && string(text) == c.want, "%s: %q %v, want %q", c.src, text, werr, c.want)
	}
	refusals := [?]string{"Infinity", "[1, -Infinity]", "{a: NaN}"}
	for src in refusals {
		doc, _ := json.build(transmute([]u8)src, .Json5)
		defer json.destroy(&doc)
		for to in ([]json.Spec{.Json, .Jsonc}) {
			text, _, werr := json.write(&doc, to)
			r, refused := werr.(write.Refused)
			testing.expectf(t, text == nil && refused && r.why == .No_Spelling && doc.nodes[r.node].kind == .Number, "%s to %v: %v", src, to, werr)
		}
	}
}

// The layouts: one value or member a line at the indent of its depth, a space after a key's colon, an empty
// container on one line, comments where a read takes them back.
@(test)
json_lays_out_each_layout :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:  string,
		spec: json.Spec,
		opts: write.Options,
		want: string,
	}
	cases := [?]Case{
		{`{"a":[1,2],"b":{},"c":[],"d":{"e":null}}`, .Json, {indent = 2}, "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {},\n  \"c\": [],\n  \"d\": {\n    \"e\": null\n  }\n}"},
		{`[[1]]`, .Json, {tab = true}, "[\n\t[\n\t\t1\n\t]\n]"},
		{`"x"`, .Json, {indent = 4}, `"x"`},
		{"// lead\n[1, // one\n2 /* two */]\n// after", .Jsonc, {indent = 2}, "// lead\n[\n  1, // one\n  2 /* two */\n]\n// after\n"},
		{"// lead\n[1, // one\n2 /* two */]\n// after", .Jsonc, {}, "// lead\n[1,// one\n2/* two */]\n// after\n"},
		{"[1 // foot\n]\n// after", .Jsonc, {indent = 2}, "[\n  1 // foot\n]\n// after\n"},
		{"[ // open\n]", .Jsonc, {}, "[// open\n]"},
		{"[1 // inline\n, 2]", .Jsonc, {}, "[1,// inline\n2]"},
		{"1 // inline\n// foot", .Jsonc, {indent = 2}, "1 // inline\n// foot\n"},
		{"1 // inline\n// foot", .Jsonc, {}, "1// inline\n// foot\n"},
		{"{\"a\":1}// tail", .Jsonc, {indent = 2}, "{\n  \"a\": 1\n} // tail\n"},
		{"{\"a\": /*k*/ 1}", .Jsonc, {}, "{\"a\":/*k*/1}"},
		{"{\"a\" /*k*/ : 1}", .Jsonc, {indent = 2}, "{\n  \"a\": /*k*/ 1\n}"},
		{"{\"a\": // k\n 1}", .Jsonc, {indent = 2}, "{\n  \"a\": /* k*/ 1\n}"},
		{"{\"a\": // k */\n 1}", .Jsonc, {indent = 2}, "{\n  \"a\": // k */\n  1\n}"},
		{"// comment", .Jsonc, {}, ""},
		{"[{\"b\":1,\"a\":{\"d\":2,\"c\":3},\"\\u0061a\":4},{\"y\":[{\"z\":1,\"x\":2}]}]", .Json, {sort_keys = true}, "[{\"a\":{\"c\":3,\"d\":2},\"\\u0061a\":4,\"b\":1},{\"y\":[{\"x\":2,\"z\":1}]}]"},
		{"{\"b\": /* x */ 1, \"a\": 2, // after a\n \"c\": [3]}", .Jsonc, {sort_keys = true, indent = 2}, "{\n  \"a\": 2, // after a\n  \"b\": /* x */ 1,\n  \"c\": [\n    3\n  ]\n}"},
		{"[\"\u00e9\U0001F600\\u0001\\n\", {\"\u043a\": \"x\"}]", .Json, {ascii = true}, "[\"\\u00e9\\ud83d\\ude00\\u0001\\n\",{\"\\u043a\":\"x\"}]"},
		{"// \u00e9\n['\u00e9']", .Json5, {ascii = true, indent = 2}, "// \\u00e9\n[\n  '\\u00e9'\n]"},
		{"[\"a\\n\u00e9\\u00e9\U0001F600\\/\"]", .Json, {ascii = true}, "[\"a\\n\\u00e9\\u00e9\\ud83d\\ude00\\/\"]"},
		{"{\u00e9: '\u00e9\\x41\\'', 'b': \"\\n\"}", .Json5, {ascii = true}, "{\\u00e9:'\\u00e9\\x41\\'','b':\"\\n\"}"},
	}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.spec)
		defer json.destroy(&doc)
		if err != nil {
			testing.expectf(t, c.want == "", "%q: %v", c.src, err)
			continue
		}
		text, _, werr := json.write(&doc, c.spec, c.opts)
		defer delete(text)
		testing.expectf(t, werr == nil && string(text) == c.want, "%q %v: %q %v, want %q", c.src, c.opts, text, werr, c.want)
	}
}

// A write of one value of a document: a subtree as its own text, with its comments, and a key or a node past the
// document refused.
@(test)
json_writes_a_subtree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "{\"a\": [1, /* c */ 2], \"b\": 3}"
	doc, _ := json.build(transmute([]u8)src, .Jsonc)
	defer json.destroy(&doc)
	r := json.Reader{&doc, nil}
	a, _ := json.member(r, json.ROOT, "a")
	text, dropped, err := json.write(&doc, .Jsonc, {node = a})
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "[1,/* c */2]" && dropped == {}, "%q %v %v", text, dropped, err)
	plain, dropped_plain, _ := json.write(&doc, .Json, {node = a})
	defer delete(plain)
	testing.expectf(t, string(plain) == "[1,2]" && dropped_plain == {.Comment_Inline}, "%q %v", plain, dropped_plain)
	for bad in ([]json.Node_Index{1, json.Node_Index(len(doc.nodes))}) {
		_, _, berr := json.write(&doc, .Json, {node = bad})
		testing.expect_value(t, berr, json.Write_Error(tape.Bad_Option{"node"}))
	}
}

// A partial document's container written whole would lose what the read did not keep, so it is refused, and a value
// the read kept whole is written.
@(test)
json_refuses_a_partial_container :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a": [1, 2], "b": {"c": 3}}`)
	paths := [][]tape.Step{{tape.Name("b")}}
	demand, _ := tape.demand_of(paths)
	defer tape.destroy(&demand)
	doc, err := json.scan(src, &demand)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	_, _, werr := json.write(&doc)
	r, refused := werr.(write.Refused)
	testing.expectf(t, refused && r.why == .Partial, "%v", werr)
	b, _, _ := json.answer({&doc, nil}, 0, 0)
	text, _, berr := json.write(&doc, .Json, {node = b})
	defer delete(text)
	testing.expectf(t, berr == nil && string(text) == `{"c":3}`, "%q %v", text, berr)
	// A partial container inside a value written whole is refused where the rows reach it, with blanks after the text
	// so that the rows copy its tokens.
	deep := transmute([]u8)string(`{"a": {"b": {"x": 1, "y": 2}}}` + "                                                                ")
	deep_demand, _ := tape.demand_of([][]tape.Step{{tape.Name("a"), tape.Name("b"), tape.Name("x")}})
	defer tape.destroy(&deep_demand)
	deep_doc, derr := json.scan(deep, &deep_demand)
	defer json.destroy(&deep_doc)
	testing.expect_value(t, derr, nil)
	// The nodes: the root, key `a`, its object, key `b`, its object, which lacks `y`.
	a := json.Node_Index(2)
	for opts in ([?]json.Write_Options{{node = a}, {node = a, indent = 2}}) {
		inner, _, ierr := json.write(&deep_doc, .Json, opts)
		defer delete(inner)
		r, refused = ierr.(write.Refused)
		testing.expectf(t, refused && r.why == .Partial && r.node == 4, "%v: %q %v", opts, inner, ierr)
	}
	// A text cut inside its root: the containers the cut left open are refused, a value closed before it is written,
	// and a cut scalar root is refused at the root.
	Cut :: struct {
		src:  string,
		node: json.Node_Index,
		want: string,
	}
	cuts := [?]Cut{{`[1, 2, 3`, 0, ""}, {`{"a": {"b": 1}, "c": [true, nul`, 2, `{"b":1}`}, {`{"a": {"b": 1}, "c": [true, nul`, 6, ""}, {`12`, 0, ""}}
	for c in cuts {
		p := tape.Pieces{so_far = true, allocator = context.allocator}
		cut, cerr := json.build(transmute([]u8)string(c.src), .Json, {pieces = &p})
		defer json.destroy(&cut)
		defer tape.destroy(&p)
		testing.expectf(t, cerr == nil && .Cut in cut.flags, "%q: %v", c.src, cerr)
		out, _, oerr := json.write(&cut, .Json, {node = c.node})
		defer delete(out)
		why, was_refused := oerr.(write.Refused)
		ok := string(out) == c.want && oerr == nil if c.want != "" else was_refused && why.why == .Partial && why.node == c.node
		testing.expectf(t, ok, "%q at %d: %q %v", c.src, c.node, out, oerr)
	}
}

// A sink takes the text a buffer write gives, in pieces of the sink's buffer, and a sink that fails is the error.
@(test)
json_writes_to_a_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	for i in 0 ..< 20000 {
		fmt.sbprintf(&b, "%s{{\"k%d\": [%d, \"%s\"]}}", "[" if i == 0 else ",", i, i * 7, "x\\ny")
	}
	strings.write_byte(&b, ']')
	doc, _ := json.build(b.buf[:])
	defer json.destroy(&doc)
	want, _, _ := json.write(&doc, .Json, {indent = 2})
	defer delete(want)
	sink: bytes.Buffer
	defer bytes.buffer_destroy(&sink)
	_, err := json.write_to(bytes.buffer_to_stream(&sink), &doc, .Json, {indent = 2})
	testing.expect_value(t, err, nil)
	testing.expect(t, string(bytes.buffer_to_bytes(&sink)) == string(want))
	failing := io.Stream {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			if mode == .Query {
				return io.query_utility({.Write, .Query})
			}
			return 0, .Unexpected_EOF
		},
	}
	_, ferr := json.write_to(failing, &doc)
	testing.expect_value(t, ferr, json.Write_Error(io.Error.Unexpected_EOF))
	// A sink with no procedure is refused before any buffer is taken, and one that says it took more than it was
	// given is an error.
	_, zerr := json.write_to({}, &doc)
	testing.expect_value(t, zerr, json.Write_Error(tape.Bad_Option{"sink"}))
	_, dzerr := dsv.write_to({}, &doc)
	testing.expect_value(t, dzerr, dsv.Write_Error(tape.Bad_Option{"sink"}))
	boasting := io.Stream {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			if mode == .Query {
				return io.query_utility({.Write, .Query})
			}
			return i64(len(p)) + 1, nil
		},
	}
	_, berr := json.write_to(boasting, &doc)
	testing.expect_value(t, berr, json.Write_Error(io.Error.Invalid_Write))
	// A write that fails drops no fact, whether its sink fails or a value is refused.
	commented, _ := json.build(transmute([]u8)string("// c\n[1, /* d */ 2]"), .Jsonc)
	defer json.destroy(&commented)
	sunk, serr := json.write_to(failing, &commented)
	testing.expectf(t, serr != nil && sunk == {}, "failing sink: %v %v", sunk, serr)
	refused, _ := json.build(transmute([]u8)string("// c\n[NaN, /* d */ 2]"), .Json5)
	defer json.destroy(&refused)
	text, kept, rerr := json.write(&refused, .Json)
	testing.expectf(t, rerr != nil && text == nil && kept == {}, "refused value: %v %v", kept, rerr)
}

// Every allocation a write makes may be refused: the write returns the refusal and keeps no block.
@(test)
json_write_refusals_free_all :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Run :: struct {
		doc:  ^json.Document,
		spec: json.Spec,
		opts: write.Options,
	}
	src := fmt.tprintf("// c\n[{{\"a\\u0041\": [1, \"\\u00e9\", {{\"x\": %s1%s}}]}} /* d */]", strings.repeat("[", 100, context.temp_allocator), strings.repeat("]", 100, context.temp_allocator))
	doc, err := json.build(transmute([]u8)string(src), .Jsonc)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	for spec in json.Spec {
		run := Run{&doc, spec, {indent = 2}}
		s := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
				r := (^Run)(data)
				text, _, werr := json.write(r.doc, r.spec, r.opts, a)
				if werr == nil {
					delete(text, a)
				} else {
					_ = werr.(runtime.Allocator_Error)
				}
			}, &run)
		testing.expectf(t, s.bad == 0 && s.refused > 1, "%v: %v", spec, s)
	}
}

// A strict JSON text's compact write over its bytes is the walk's, which a JSON5 read of the same text takes: escapes
// respelled across every cut of a segment, blanks in and out of strings, and spaced and unspaced stretches.
@(test)
json_dense_writes_as_the_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xde45e)
	// The escapes spell a backslash as `~`.
	ESCAPES := []string{`~u00e9`, `~ud83d~ude00`, `~/`, `~u0041`, `~"`, `~~`, `~u001f`, `~u001F`, `~n`, `~u0022`, `~u005c`, `~u2028`, `~u00C9`, `~uD83D~uDE00`, `~u07ff`, `~u0800`, `~uFFFF`, `~u007f`, `~u0000`, `~b`, `~t`, `~~~"`, `x`, ` `}
	texts: [dynamic]string
	defer delete(texts)
	append_fixtures(t, &texts)
	for _ in 0 ..< testkit.rounds(60) {
		b := strings.builder_make(context.temp_allocator)
		spaced := rand.int_max(3)
		strings.write_byte(&b, '[')
		for i in 0 ..< 200 + rand.int_max(400) {
			if i > 0 {
				strings.write_string(&b, ", " if spaced == 0 || spaced == 1 && rand.int_max(8) == 0 else ",")
			}
			strings.write_string(&b, `{"k":"`)
			for _ in 0 ..< rand.int_max(12) {
				for c in transmute([]u8)rand.choice(ESCAPES) {
					strings.write_byte(&b, '\\' if c == '~' else c)
				}
			}
			strings.write_string(&b, `","n":[1,true,null]}`)
		}
		strings.write_byte(&b, ']')
		append(&texts, strings.to_string(b))
	}
	for src, k in texts {
		strict, walked := build_both_routes(t, src, k, .Json)
		defer json.destroy(&strict)
		defer json.destroy(&walked)
		dense, _, derr := json.write(&strict, .Json)
		defer delete(dense)
		want, _, err := json.write(&walked, .Json)
		defer delete(want)
		testing.expectf(t, derr == nil && err == nil && string(dense) == string(want), "text %d: %v %v %d %d", k, derr, err, len(dense), len(want))
	}
}

// The write of a JSON, JSONC or JSON5 document by its rows is the walk's, which a read flagged as tolerant takes, in every
// layout, into a buffer and a sink, whole and for a subtree: tokens past the rows' longest, escapes spelled again in
// keys and values, nesting past the rows' stack and their deepest line, comments the target drops.
@(test)
json_rows_write_as_the_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5085)
	long := strings.repeat("x\\n", 200, context.temp_allocator)
	texts: [dynamic]string
	defer delete(texts)
	append(&texts, fmt.tprintf("%s{{\"%s\": \"%s\", \"k\\u0041\": [\"\\/\", {{}}, []]}}%s", strings.repeat("[", 1500, context.temp_allocator), long, long, strings.repeat("]", 1500, context.temp_allocator)))
	append(&texts, fmt.tprintf("[\"%s\", \"\\u00e9%s\", %s, {{\"a\": [1, // c\n2]}}]", long, long, strings.repeat("1", 300, context.temp_allocator)))
	append(&texts, fmt.tprintf("%s1%s", strings.repeat("[/* a */", 1500, context.temp_allocator), strings.repeat("] // b\n", 1500, context.temp_allocator)))
	append_fixtures(t, &texts)
	for _ in 0 ..< testkit.rounds(100) {
		b := strings.builder_make(context.temp_allocator)
		random_value(&b, 0)
		append(&texts, strings.to_string(b))
	}
	for odds in ([?]int{1, 3, 20, 400}) {
		for _ in 0 ..< testkit.rounds(4) {
			append(&texts, records_text(300 if odds > 3 else 40, odds, false))
		}
	}
	// The JSON5 texts follow the JSONC ones, and are read as JSON5, whose rows are its own.
	json5_from := len(texts)
	for odds in ([?]int{1, 3, 20, 400}) {
		for _ in 0 ..< testkit.rounds(6) {
			append(&texts, records_text(150 if odds > 3 else 30, odds, true))
		}
	}
	for src, k in texts {
		rows, walked := build_both_routes(t, src, k, .Jsonc if k < json5_from else .Json5)
		defer json.destroy(&rows)
		defer json.destroy(&walked)
		node := json.ROOT if len(rows.nodes) < 3 else json.Node_Index(len(rows.nodes) / 3)
		for node > 0 && rows.nodes[node].role != .Value {
			node -= 1
		}
		// JSON5 texts hold numbers JSON and JSONC cannot spell.
		for spec in ([]json.Spec{.Json, .Jsonc, .Json5} if k < json5_from else {.Json5}) {
			for opts in LAYOUTS {
				for at in ([]json.Node_Index{json.ROOT, node}) {
					o := opts
					o.node = at
					got, gdropped, gerr := json.write(&rows, spec, o)
					defer delete(got)
					want, dropped, err := json.write(&walked, spec, o)
					defer delete(want)
					testing.expectf(t, gerr == nil && err == nil && string(got) == string(want) && gdropped == dropped, "text %d as %v %v: %v %v rows %q, walk %q", k, spec, o, gerr, err, got[:min(len(got), 400)], want[:min(len(want), 400)])
					sunk, serr := sink_text(&rows, spec, o)
					defer delete(sunk)
					testing.expectf(t, serr == nil && string(sunk) == string(want), "text %d as %v %v to a sink: %v", k, spec, o, serr)
				}
			}
		}
	}
}

// A subtree write drops the kinds of facts inside the subtree, not those of the whole document.
@(test)
json_subtree_drops_its_own_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string("[1 /* a */, [2], [3 // b\n]]"), .Jsonc)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	plain, with_comment: json.Node_Index
	for n, i in doc.nodes {
		if n.kind == .Array && i > 0 {
			if plain == 0 {
				plain = json.Node_Index(i)
			} else {
				with_comment = json.Node_Index(i)
			}
		}
	}
	for at, want in ([]json.Node_Index{plain, with_comment, json.ROOT}) {
		out, dropped, werr := json.write(&doc, .Json, {node = at})
		defer delete(out)
		testing.expectf(t, werr == nil && (dropped == {}) == (want == 0), "node %d: %q %v %v", at, out, dropped, werr)
	}
}

// A block comment that holds U+2028 reads as several lines in JSON5, so it is dropped there, and the comment after it
// on its line stays an inline one.
@(test)
json5_drops_a_block_comment_with_a_line_separator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string("[1 /* a b */ // c\n, 2]"), .Jsonc)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	for opts in LAYOUTS {
		out, dropped, werr := json.write(&doc, .Json5, opts)
		defer delete(out)
		back, berr := json.build(out, .Json5)
		defer json.destroy(&back)
		testing.expectf(t, werr == nil && berr == nil && dropped != {} && len(back.facts) == 1 && back.facts[0].kind == .Comment_Inline, "%v: %q %v %v", opts, out, werr, berr)
	}
}

// Random documents of every kind, deep and wide, with every escape and number form, read back from every layout.
@(test)
json_random_documents_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x3717e)
	tally: Tally
	for _ in 0 ..< testkit.rounds(300) {
		b := strings.builder_make(context.temp_allocator)
		random_value(&b, 0)
		round_trips(t, b.buf[:], .Json5, "random", &tally)
		round_trips(t, b.buf[:], .Jsonc, "random", &tally)
	}
}

// A comment or a line end, one gap in `odds`, else nothing.
@(private = "file")
gap :: proc(b: ^strings.Builder, odds: int) {
	if rand.int_max(odds) == 0 {
		strings.write_string(b, rand.choice([]string{" /* c */ ", " // c\n", "\n", "/* a\nb */", " /* é */"}))
	}
}

// An array of `records` objects of scalars and containers with a gap in `odds` at every place a comment may stand, so a
// run of rows meets facts in every place and in every depth. With `json5` its keys are bare, single or double quoted, its
// numbers take every JSON5 form, its strings are single quoted or continue a line, and commas trail.
@(private = "file")
records_text :: proc(records, odds: int, json5: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for r in 0 ..< records {
		gap(&b, odds)
		if r > 0 {
			strings.write_byte(&b, ',')
			gap(&b, odds)
		}
		strings.write_byte(&b, '{')
		for m in 0 ..< 1 + rand.int_max(6) {
			if m > 0 {
				strings.write_byte(&b, ',')
			}
			gap(&b, odds)
			switch rand.int_max(3) if json5 else 2 {
			case 0:
				fmt.sbprintf(&b, "k%d", m)
			case 1:
				fmt.sbprintf(&b, `'k%d\x41é'`, m)
			case:
				fmt.sbprintf(&b, `"k%dA"`, m)
			}
			gap(&b, odds)
			strings.write_byte(&b, ':')
			gap(&b, odds)
			switch rand.int_max(8) if json5 else 5 {
			case 0:
				strings.write_string(&b, rand.choice([]string{"0x1F", "+1", ".5", "5.", "Infinity", "-Infinity", "NaN", "1e3", "-0", "12"}) if json5 else `[1, "a\n", [], [[2]], {"x": null}, {}]`)
			case 1:
				strings.write_string(&b, `[1, 'a\'b', [], {k: null,},]` if json5 else `{"p": [true, false], "q": {"r": "s"}}`)
			case 2:
				strings.write_string(&b, `{p: [true, false,], 'q': {r: "s"}}` if json5 else `[]`)
			case 3:
				strings.write_string(&b, "'single \\\n continued é \\x7f'" if json5 else `"string with é and \/"`)
			case 4:
				strings.write_string(&b, rand.choice([]string{"null", "true", "false"}) if json5 else `"string with é and \/"`)
			case:
				strings.write_string(&b, `"string with é and \/ é"`)
			}
			gap(&b, odds)
		}
		if json5 && rand.int_max(3) == 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '}')
		gap(&b, odds)
	}
	if json5 && records > 0 {
		strings.write_byte(&b, ',')
	}
	strings.write_byte(&b, ']')
	gap(&b, odds)
	return strings.to_string(b)
}

@(private = "file")
random_value :: proc(b: ^strings.Builder, depth: int) {
	if rand.int_max(4) == 0 {
		strings.write_string(b, rand.choice([]string{" /* c */ ", " // c\n", "\n"}))
	}
	switch rand.int_max(9 if depth < 6 else 6) {
	case 0:
		strings.write_string(b, rand.choice([]string{"null", "true", "false"}))
	case 1:
		strings.write_string(b, rand.choice([]string{"0", "-0", "12", "-3.25", "1e400", "4.5E-3", "18446744073709551616", "123456789012345678901234567890", "0.1", "-0.0"}))
	case 2, 3, 4, 5:
		random_string(b)
	case 6, 7:
		strings.write_byte(b, '[')
		for i in 0 ..< rand.int_max(5) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			random_value(b, depth + 1)
		}
		strings.write_byte(b, ']')
	case 8:
		strings.write_byte(b, '{')
		for i in 0 ..< rand.int_max(5) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			random_string(b)
			strings.write_byte(b, ':')
			random_value(b, depth + 1)
		}
		strings.write_byte(b, '}')
	}
}

// Random JSON5 strings and bare keys, in either quote, with every escape JSON5 has and the bytes JSON cannot hold raw,
// read back from every target and layout.
@(test)
json5_random_strings_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5712)
	pieces := [?]string{
		"a", " ", "é", "😀", " ", "\t", "\x01", "\x7f", `\x41`, `\x00`, `\x1F`, `\xe9`, `\x22`, `\x5c`, `\0`, `\v`, `\b`, `\f`, `\'`, `\"`,
		"\\\u2028", "\\\u2029", `\😀`, "é\\é", `\\`, `\/`, `\a`, `\$`, `\é`, `\u` + `00e9`, `\u` + `0041`, `\u` + `d83d\u` + `de00`, `\u` + `2028`, "\\\n", "\\\r\n", "\\ ", `\n`, `\t`,
	}
	tally: Tally
	for _ in 0 ..< testkit.rounds(150) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '{')
		for m in 0 ..< 1 + rand.int_max(6) {
			if m > 0 {
				strings.write_byte(&b, ',')
			}
			if rand.int_max(3) == 0 {
				fmt.sbprintf(&b, "k%d%s", m, rand.choice([]string{"", "é", "𝒜"}))
			} else {
				fmt.sbprintf(&b, "'k%d%s'", m, rand.choice(pieces[:]) if rand.int_max(2) == 0 else "")
			}
			strings.write_byte(&b, ':')
			quote := rand.choice([]string{"'", `"`})
			strings.write_string(&b, quote)
			for _ in 0 ..< rand.int_max(8) {
				piece := rand.choice(pieces[:])
				// A raw quote of the string's own kind is a break.
				if strings.contains(piece, quote) && !strings.has_prefix(piece, `\`) {
					piece = "a"
				}
				strings.write_string(&b, piece)
			}
			strings.write_string(&b, quote)
		}
		strings.write_byte(&b, '}')
		round_trips(t, b.buf[:], .Json5, "json5 strings", &tally)
	}
	testing.expect(t, tally.texts > 50)
}

@(private = "file")
random_string :: proc(b: ^strings.Builder) {
	strings.write_byte(b, '"')
	for _ in 0 ..< rand.int_max(12) {
		strings.write_string(b, rand.choice([]string{"a", "é", "😀", "\\n", "\\\"", "\\\\", "\\/", "\\u0000", "\\u001F", "\\u00e9", "\\ud83d\\ude00", "\\u2028", "\\t", "/*", "*/", "//", " ", "\x7f"}))
	}
	strings.write_byte(b, '"')
}
