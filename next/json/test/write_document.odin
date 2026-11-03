package json_tests

import "core:bytes"
import "core:io"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import dsv "../../dsv"
import json ".."
import gen "gen"
import walktest "../../walktest"

// The options each text is written under: compact, pretty at three widths, and with tabs.
WRITE_OPTS :: [?]core.Write_Options {
	{},
	{pretty = true, indent = 2},
	{pretty = true, indent = 4},
	{pretty = true, indent = 0},
	{pretty = true, tab = true},
}

WRITE_TEXTS :: [?]string {
	`null`,
	`-0.0`,
	`"a"`,
	`[]`,
	`{}`,
	`[[],{},[[]],{"a":{}}]`,
	`{"a":1,"b":[true,false,null],"c":{"d":"e","f":[1.5e300,-0,0.1]}}`,
	`  [ 1 , 2 ,
	3 ]  `,
	`{"esc":"a\né\"\\\/😀","A":"k","":""}`,
	`["é","日本語","😀",""]`,
	`[1E400,-1e-400,123456789012345678901234567890,0.000000000000000000001]`,
	`[{"a":[{"a":[{"a":[]}]}]}]`,
}

// Whether `a` and `b` hold the same tree: the same kind, role, subtree size, spelling and source bytes in every row.
same_tree :: proc(t: ^testing.T, a, b: ^core.Document, label: string) -> bool {
	if !testing.expectf(t, len(a.nodes) == len(b.nodes), "%s: %d rows against %d", label, len(a.nodes), len(b.nodes)) {
		return false
	}
	for x, i in a.nodes {
		y := b.nodes[i]
		ok := x.kind == y.kind && x.role == y.role && x.n == y.n && x.spelling == y.spelling
		if x.kind < .Array {
			ok = ok && string(a.src[x.lo:x.lo + u64(x.n)]) == string(b.src[y.lo:y.lo + u64(y.n)])
		}
		if !testing.expectf(t, ok, "%s: row %d differs", label, i) {
			return false
		}
	}
	return true
}

// Checks that compact text holds no whitespace outside a string.
check_layout :: proc(t: ^testing.T, text: []u8, opts: core.Write_Options, label: string) {
	if opts.pretty {
		return
	}
	in_string := false
	for i := 0; i < len(text); i += 1 {
		switch text[i] {
		case '"':
			in_string = !in_string
		case '\\':
			i += 1 if in_string else 0
		case ' ', '\n', '\t', '\r':
			if !testing.expectf(t, in_string, "%s: whitespace in compact text", label) {
				return
			}
		}
	}
}

// Writes `src` read as JSON under every option, reads each text again and compares the trees, writes the read-again
// document once more for the same bytes, and checks `format`, the stream and `core.write` in its own spec against `core.write`.
check_write :: proc(t: ^testing.T, src: []u8) -> bool {
	doc, err := json.build(src, .Json)
	if !testing.expectf(t, err.kind == .None, "build %q: %v", src, err) {
		return false
	}
	defer core.destroy(&doc)
	for opts, k in WRITE_OPTS {
		text, _, werr := core.write(&doc, opts)
		if !testing.expectf(t, werr.kind == .None, "write %q under %d: %v", src, k, werr) {
			return false
		}
		defer delete(text)
		again, rerr := json.build(text, .Json)
		if !testing.expectf(t, rerr.kind == .None, "re-read %q under %d: %v", text, k, rerr) {
			return false
		}
		defer core.destroy(&again)
		if !same_tree(t, &doc, &again, "re-read") {
			return false
		}
		check_layout(t, text, opts, "layout")
		twice, _, terr := core.write(&again, opts)
		defer delete(twice)
		if !testing.expect(t, terr.kind == .None && string(twice) == string(text), "writing a written text changes it") {
			return false
		}
		direct, ferr := json.format(src, .Json, opts)
		defer delete(direct)
		if !testing.expect(t, ferr.kind == .None && string(direct) == string(text), "format differs from core.write") {
			return false
		}
		through, _, cerr := core.write(&doc, opts, json.as(.Json))
		defer delete(through)
		if !testing.expect(t, cerr.kind == .None && string(through) == string(text), "core.write in its own spec differs from core.write") {
			return false
		}
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		_, serr := core.write_stream(bytes.buffer_to_stream(&buf), &doc, opts)
		if !testing.expect(t, serr.kind == .None && string(bytes.buffer_to_bytes(&buf)) == string(text), "the stream differs from core.write") {
			return false
		}
		if !check_subtrees(t, &doc, opts) {
			return false
		}
	}
	return true
}

// Checks that every value node of `doc` writes the text its span formats to.
check_subtrees :: proc(t: ^testing.T, doc: ^core.Document, opts: core.Write_Options) -> bool {
	for x, i in doc.nodes {
		if x.role == .Key {
			continue
		}
		node := core.Node_Index(i)
		text, _, err := core.write(doc, opts, node = node)
		defer delete(text)
		want, _ := json.format(core.span(doc, node), .Json, opts)
		defer delete(want)
		if !testing.expectf(t, err.kind == .None && string(text) == string(want), "node %d of %q writes %q, its span %q", i, doc.src, text, want) {
			return false
		}
	}
	return true
}

@(test)
write_document_texts :: proc(t: ^testing.T) {
	for text in WRITE_TEXTS {
		if !check_write(t, transmute([]u8)text) {
			return
		}
	}
}

@(test)
write_document_generated :: proc(t: ^testing.T) {
	rand.reset(1)
	for _ in 0 ..< 300 {
		b: [dynamic]u8
		defer delete(b)
		if rand.int_max(2) == 0 {
			gen.text(&b, 1 + rand.int_max(6), .Json)
		} else {
			gen.pretty(&b, 1 + rand.int_max(6), .Json)
		}
		if !check_write(t, b[:]) {
			return
		}
	}
}

// A compact text of a compact source is the source, and a pretty text is exactly the layout of a pretty printer.
@(test)
write_document_layout :: proc(t: ^testing.T) {
	src := `{"a":[1,2,{"b":null}],"c":{},"d":[]}`
	doc, _ := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&doc)
	text, _, _ := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, string(text), src)
	pretty, _, _ := core.write(&doc, core.PRETTY)
	defer delete(pretty)
	want := "{\n  \"a\": [\n    1,\n    2,\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": {},\n  \"d\": []\n}"
	testing.expect_value(t, string(pretty), want)
	tabs, _, _ := core.write(&doc, {pretty = true, tab = true})
	defer delete(tabs)
	testing.expect(t, strings.contains(string(tabs), "\n\t\t\t\"b\""))
	flat, _, _ := core.write(&doc, {pretty = true})
	defer delete(flat)
	testing.expect(t, strings.contains(string(flat), "\n\"c\": {}"))
}

// A number keeps the spelling it was read with, whatever it would print as.
@(test)
write_document_keeps_spelling :: proc(t: ^testing.T) {
	src := `[-0.0,1E5,0.10,1e+2,12345678901234567890123]`
	doc, _ := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&doc)
	text, _, _ := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, string(text), src)
}

// A string that was escaped keeps its escapes, and `ascii` and `escape_html` ask for another spelling of the same text.
@(test)
write_document_string_options :: proc(t: ^testing.T) {
	src := `["a<b>&c","é😀","é\n"]`
	doc, _ := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&doc)
	plain, _, _ := core.write(&doc)
	defer delete(plain)
	testing.expect_value(t, string(plain), src)
	for opts in ([?]core.Write_Options{{ascii = true}, {escape_html = true}, {ascii = true, escape_html = true}, {pretty = true, indent = 2, ascii = true}}) {
		text, _, err := core.write(&doc, opts)
		defer delete(text)
		if !testing.expect_value(t, err.kind, core.Typed_Error_Kind.None) {
			return
		}
		again, rerr := json.build(text, .Json)
		defer core.destroy(&again)
		testing.expect_value(t, rerr.kind, core.Document_Error_Kind.None)
		for x, i in doc.nodes {
			if x.kind != .String {
				continue
			}
			a, _ := core.text_clone(&doc, core.Node_Index(i))
			b, _ := core.text_clone(&again, core.Node_Index(i))
			defer delete(a)
			defer delete(b)
			testing.expect_value(t, b, a)
		}
		for b in text {
			testing.expect(t, !opts.ascii || b < 0x80)
			testing.expect(t, !opts.escape_html || (b != '<' && b != '>' && b != '&'))
		}
	}
}

// `respell_strings` writes a string read from a source as a computed one is written, and leaves the rest as it was read.
@(test)
write_document_respell_strings :: proc(t: ^testing.T) {
	src := `{"\u0061":["\u00e9\/x","\ud83d\ude00","é","\n\"\\",1E2]}`
	doc, _ := json.build(transmute([]u8)string(src), .Json)
	defer core.destroy(&doc)
	kept, _, _ := core.write(&doc)
	defer delete(kept)
	testing.expect_value(t, string(kept), src)
	for opts in ([?]core.Write_Options{{respell_strings = true}, {respell_strings = true, pretty = true, indent = 1}}) {
		text, _, err := core.write(&doc, opts)
		defer delete(text)
		want := `{"a":["é/x","😀","é","\n\"\\",1E2]}`
		if opts.pretty {
			want = "{\n \"a\": [\n  \"é/x\",\n  \"😀\",\n  \"é\",\n  \"\\n\\\"\\\\\",\n  1E2\n ]\n}"
		}
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(text), want)
	}
	jsonc, _ := json.build(transmute([]u8)string(`[/* \/ */ "\/"]`), .Jsonc)
	defer core.destroy(&jsonc)
	text, _, _ := core.write(&jsonc, {respell_strings = true})
	defer delete(text)
	testing.expect_value(t, string(text), `[/* \/ */"/"]`)
}

// A subtree of a delimited target is the array's records, and a key or a node past the document is refused.
@(test)
write_document_nodes :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"n":1,"rows":[{"a":1,"b":"x"},{"a":2}]}`), .Json)
	defer core.destroy(&doc)
	rows, _ := core.member(&doc, core.ROOT, "rows")
	csv, _, err := core.write(&doc, as = dsv.as(.Csv), node = rows)
	defer delete(csv)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(csv), "a,b\n1,x\n2,\n")
	for node in ([?]core.Node_Index{1, core.Node_Index(len(doc.nodes)), core.NO_NODE}) {
		_, _, err = core.write(&doc, node = node)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
	}
	_, _, err = core.write(&doc, as = dsv.as(.Csv), node = 2)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
}

@(test)
write_document_refusals :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`), .Json)
	defer core.destroy(&doc)
	whole, _, werr := core.write(&doc)
	delete(whole)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)

	_, err := json.format(transmute([]u8)string(`[1,`), .Json)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Walk)
	_, err = json.format(transmute([]u8)string("[1, /* c */ "), .Jsonc)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Walk)
	_, err = json.format(transmute([]u8)string(`{a:`), .Json5)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Walk)
}

// Empty containers among scalars inside `levels` arrays, as many as fill the output more than once.
empty_rows_text :: proc(levels, n: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< levels {
		strings.write_byte(&b, '[')
	}
	for i in 0 ..< n {
		strings.write_string(&b, "[]," if i % 2 == 1 else "1,")
	}
	strings.write_string(&b, `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`)
	for _ in 0 ..< levels {
		strings.write_byte(&b, ']')
	}
	return b.buf[:]
}

// An empty container the rare path opened closes before anything else is written, whatever room the output has after it.
// The tree writer, which `sort_keys` takes, and `format` are the model. A text past the buffer of a stream or the hint of a
// wide indent reaches the rare path at an arbitrary row.
@(test)
empty_container_from_the_rare_path :: proc(t: ^testing.T) {
	Sized :: struct {levels, n: int, opts: core.Write_Options, stream: bool}
	cases := [?]Sized {
		{1, 40_000, {}, true},
		{1, 40_000, core.PRETTY, true},
		{20, 5_000, {pretty = true, indent = 16}, false},
		{40, 5_000, {pretty = true, indent = 16}, false},
	}
	for c in cases {
		text := empty_rows_text(c.levels, c.n)
		doc, err := json.build(text, .Json, {}, false, context.temp_allocator)
		testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
		sorted := c.opts
		sorted.sort_keys = true
		want, _, werr := core.write(&doc, sorted)
		defer delete(want)
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		got: []u8
		if c.stream {
			sink: bytes.Buffer
			defer bytes.buffer_destroy(&sink)
			_, werr = core.write_stream(bytes.buffer_to_stream(&sink), &doc, c.opts)
			got = bytes.buffer_to_bytes(&sink)
			testing.expectf(t, string(got) == string(want), "%v: %d bytes against %d", c, len(got), len(want))
		} else {
			got, _, werr = core.write(&doc, c.opts)
			testing.expectf(t, string(got) == string(want), "%v: %d bytes against %d", c, len(got), len(want))
			delete(got)
		}
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		formatted, ferr := json.format(text, json.Spec.Json, c.opts)
		testing.expect_value(t, ferr.kind, core.Typed_Error_Kind.None)
		testing.expect(t, string(formatted) == string(want))
		delete(formatted)
	}
}

COMMENT_TEXTS :: [?]string {
	`// top
{ // after open
 /* lead */ "a" /* k */ : /* v */ 1, // trail a
 // lead b
 "b": [1, // t1
 2 /* t2 */ , 3 // last
 ] , "c": [] /* c */ , "d": { /* only */ } } // end`,
	"[1 // a\n]\n// after\n/* more */",
	"1\n// after",
	`{ /* e */ }`,
	"[ // x\n]",
	"{\"a\":1 /*t*/ , // t2\n /*f*/ }",
	`/*é😀<&>*/ ["é" /* <a href="x">é😀 */]`,
	"[[1 //\n,2,/**/],{},{\"k\":{/**/}}]//\n",
}

// The comments of a document without their places, in a canonical order.
fact_bodies :: proc(doc: ^core.Document) -> [dynamic]string {
	list: [dynamic]string
	for f in doc.facts {
		append(&list, string(doc.src[f.lo:f.lo + u64(f.n)]))
	}
	slice.sort(list[:])
	return list
}

// Writes `src` read as JSONC under every option and checks that each text reads again as JSONC into the same nodes and the
// same comments, that writing it again changes nothing, and that every entry writes the same text. As JSON the comments
// are dropped and counted.
check_commented :: proc(t: ^testing.T, src: []u8) -> bool {
	doc, err := json.build(src, .Jsonc)
	if !testing.expectf(t, err.kind == .None, "build %q: %v", src, err) {
		return false
	}
	defer core.destroy(&doc)
	bodies := fact_bodies(&doc)
	defer delete(bodies)
	for opts, k in WRITE_OPTS {
		text, _, werr := core.write(&doc, opts)
		if !testing.expectf(t, werr.kind == .None, "write %q under %d: %v", src, k, werr) {
			return false
		}
		defer delete(text)
		again, rerr := json.build(text, .Jsonc)
		if !testing.expectf(t, rerr.kind == .None, "re-read %q under %d: %v", text, k, rerr) {
			return false
		}
		defer core.destroy(&again)
		if !same_tree(t, &doc, &again, "re-read") {
			return false
		}
		got := fact_bodies(&again)
		defer delete(got)
		if !testing.expectf(t, slice.equal(got[:], bodies[:]), "comments of %q under %d became %q", src, k, text) {
			return false
		}
		twice, _, terr := core.write(&again, opts)
		defer delete(twice)
		if !testing.expectf(t, terr.kind == .None && string(twice) == string(text), "writing %q again changes it", text) {
			return false
		}
		direct, ferr := json.format(src, .Jsonc, opts)
		defer delete(direct)
		if !testing.expect(t, ferr.kind == .None && string(direct) == string(text), "format differs from core.write") {
			return false
		}
		through, _, cerr := core.write(&doc, opts, json.as(.Jsonc))
		defer delete(through)
		if !testing.expect(t, cerr.kind == .None && string(through) == string(text), "core.write in its own spec differs from core.write") {
			return false
		}
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		_, serr := core.write_stream(bytes.buffer_to_stream(&buf), &doc, opts)
		if !testing.expect(t, serr.kind == .None && string(bytes.buffer_to_bytes(&buf)) == string(text), "the stream differs from core.write") {
			return false
		}
		plain, dropped, jerr := core.write(&doc, opts, json.as(.Json))
		defer delete(plain)
		if !testing.expect(t, jerr.kind == .None && dropped == len(doc.facts), "write as JSON does not count its dropped comments") {
			return false
		}
		strict, serr2 := json.build(plain, .Json)
		defer core.destroy(&strict)
		if !testing.expectf(t, serr2.kind == .None, "write as JSON of %q is not JSON: %q", src, plain) {
			return false
		}
		if !same_tree(t, &doc, &strict, "strict") {
			return false
		}
		if !check_commented_subtrees(t, &doc, opts) {
			return false
		}
	}
	return true
}

// Checks that every value node of `doc` writes a JSONC text, with at least the comments inside its span, and as JSON
// the text its span writes as JSON.
check_commented_subtrees :: proc(t: ^testing.T, doc: ^core.Document, opts: core.Write_Options) -> bool {
	for x, i in doc.nodes {
		if x.role == .Key {
			continue
		}
		node := core.Node_Index(i)
		text, _, err := core.write(doc, opts, node = node)
		defer delete(text)
		again, rerr := json.build(text, .Jsonc)
		defer core.destroy(&again)
		span, _ := json.build(core.span(doc, node), .Jsonc)
		defer core.destroy(&span)
		if !testing.expectf(t, err.kind == .None && rerr.kind == .None && len(again.facts) >= len(span.facts), "node %d of %q writes %q", i, doc.src, text) {
			return false
		}
		plain, dropped, _ := core.write(doc, opts, json.as(.Json), node)
		defer delete(plain)
		want, _, _ := core.write(&span, opts, json.as(.Json))
		defer delete(want)
		if !testing.expectf(t, string(plain) == string(want) && dropped == len(core.subtree_facts(doc, node)), "node %d of %q writes %q as JSON", i, doc.src, plain) {
			return false
		}
	}
	return true
}

@(test)
write_document_comments :: proc(t: ^testing.T) {
	for text in COMMENT_TEXTS {
		if !check_commented(t, transmute([]u8)text) {
			return
		}
	}
}

@(test)
write_document_comments_generated :: proc(t: ^testing.T) {
	rand.reset(2)
	for _ in 0 ..< 300 {
		b: [dynamic]u8
		defer delete(b)
		gen.text(&b, 1 + rand.int_max(5), .Jsonc)
		if !check_commented(t, b[:]) {
			return
		}
	}
}

// Where a comment goes: before its member, between the key and the value, after the member and its comma, and in a
// container's foot.
@(test)
write_document_comment_layout :: proc(t: ^testing.T) {
	src := `// top
{ /* lead */ "a" /* k */ : 1, // trail
 "b": [2 /* t */] /* u */ /* f */ } // end`
	doc, _ := json.build(transmute([]u8)src, .Jsonc)
	defer core.destroy(&doc)
	compact, _, _ := core.write(&doc)
	defer delete(compact)
	testing.expect_value(t, string(compact), "// top\n{/* lead */\"a\":/* k */1,// trail\n\"b\":[2/* t */]/* u *//* f */}// end\n")
	pretty, _, _ := core.write(&doc, core.PRETTY)
	defer delete(pretty)
	want := "// top\n{\n  /* lead */\n  \"a\": /* k */ 1, // trail\n  \"b\": [\n    2 /* t */\n  ] /* u */ /* f */\n} // end\n"
	testing.expect_value(t, string(pretty), want)
	feet := "[ // x\n 1,\n // foot\n ]"
	foot_doc, _ := json.build(transmute([]u8)feet, .Jsonc)
	defer core.destroy(&foot_doc)
	text, _, _ := core.write(&foot_doc, core.PRETTY)
	defer delete(text)
	testing.expect_value(t, string(text), "[\n  // x\n  1\n  // foot\n]")
}

@(test)
write_document_sort_keys :: proc(t: ^testing.T) {
	src := `{"b":{"z":1,"a":[{"y":0,"x":0}]},"a":2,"é":3,"B":4, "a":5}`
	doc, _ := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&doc)
	text, _, err := core.write(&doc, {sort_keys = true})
	defer delete(text)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `{"B":4,"a":2,"a":5,"b":{"a":[{"x":0,"y":0}],"z":1},"é":3}`)
	direct, ferr := json.format(transmute([]u8)src, .Json, {sort_keys = true})
	defer delete(direct)
	testing.expect_value(t, ferr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(direct), string(text))
	// Keys sort by what they decode to, and a member keeps its comments when it moves.
	commented := "{\"b\":1, // one\n \"\\u0061\":2 /* two */}"
	cdoc, _ := json.build(transmute([]u8)commented, .Jsonc)
	defer core.destroy(&cdoc)
	moved, _, merr := core.write(&cdoc, {sort_keys = true})
	defer delete(moved)
	testing.expect_value(t, merr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(moved), "{\"\\u0061\":2,/* two */\"b\":1// one\n}")
}

// Every object of a text written under `sort_keys` has its decoded keys in byte order and the same rows.
@(test)
write_document_sort_keys_generated :: proc(t: ^testing.T) {
	rand.reset(3)
	for _ in 0 ..< 300 {
		b: [dynamic]u8
		defer delete(b)
		gen.text(&b, 1 + rand.int_max(5), .Json)
		doc, _ := json.build(b[:], .Json)
		defer core.destroy(&doc)
		text, _, err := core.write(&doc, {sort_keys = true})
		defer delete(text)
		if !testing.expect_value(t, err.kind, core.Typed_Error_Kind.None) {
			return
		}
		again, rerr := json.build(text, .Json)
		defer core.destroy(&again)
		if !testing.expect_value(t, rerr.kind, core.Document_Error_Kind.None) || !testing.expect_value(t, len(again.nodes), len(doc.nodes)) {
			return
		}
		for n, i in again.nodes {
			if n.kind != .Map {
				continue
			}
			prev := ""
			it := core.pairs(&again, core.Node_Index(i))
			for key, _ in core.pair_next(&it) {
				name, _ := core.text_clone(&again, key)
				defer delete(name)
				if !testing.expectf(t, prev <= name, "keys %q, %q out of order in %q", prev, name, text) {
					return
				}
				prev = strings.clone(name, context.temp_allocator)
			}
		}
		sorted_again, _, _ := core.write(&again, {sort_keys = true})
		defer delete(sorted_again)
		if !testing.expect(t, string(sorted_again) == string(text), "sorting a sorted text changes it") {
			return
		}
	}
}

JSON5_TEXTS :: [?][2]string {
	{`{a:1,'b':+.5,"c":5.,d:0x1F,e:-0xff,f:[.5e3,-.0,+1],g:'it\'s'}`, `{"a":1,"b":0.5,"c":5,"d":31,"e":-255,"f":[0.5e3,-0.0,1],"g":"it's"}`},
	{"{ // c\n a: 0xFFFFFFFFFFFFFFFFFFFFFFFF, $_x: 'a\\\nb' }", `{"a":79228162514264337593543950335,"$_x":"ab"}`},
	{`[0x0,"\u00e9",'\x41\0']`, `[0,"é","A\u0000"]`},
	{`/* c */ 1e5 // d`, `1e5`},
}

@(test)
write_document_json5 :: proc(t: ^testing.T) {
	for pair in JSON5_TEXTS {
		doc, err := json.build(transmute([]u8)pair[0], .Json5)
		if !testing.expectf(t, err.kind == .None, "build %q: %v", pair[0], err) {
			return
		}
		defer core.destroy(&doc)
		text, dropped, werr := core.write(&doc, as = json.as(.Json))
		defer delete(text)
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(text), pair[1])
		testing.expect_value(t, dropped, len(doc.facts))
		own, kept, oerr := core.write(&doc)
		defer delete(own)
		testing.expect_value(t, oerr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, kept, 0)
		direct, ferr := json.format(transmute([]u8)pair[0], .Json5)
		defer delete(direct)
		testing.expect_value(t, ferr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(direct), string(own))
	}
	for src in ([?]string{`[Infinity]`, `{a:-Infinity}`, `[NaN]`, `[1,+NaN]`}) {
		doc, _ := json.build(transmute([]u8)src, .Json5)
		defer core.destroy(&doc)
		_, _, err := core.write(&doc, as = json.as(.Json))
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.Non_Finite)
	}
}

// A JSON5 text written as JSON reads again as the same values, and as JSON5 it is written as it was authored.
@(test)
write_document_json5_generated :: proc(t: ^testing.T) {
	rand.reset(4)
	for _ in 0 ..< 400 {
		b: [dynamic]u8
		defer delete(b)
		gen.text(&b, 1 + rand.int_max(5), .Json5)
		doc, err := json.build(b[:], .Json5)
		if !testing.expectf(t, err.kind == .None, "build %q: %v", b[:], err) {
			return
		}
		defer core.destroy(&doc)
		for opts, k in WRITE_OPTS {
			text, _, werr := core.write(&doc, opts, json.as(.Json))
			defer delete(text)
			if werr.kind == .Non_Finite {
				continue
			}
			if !testing.expectf(t, werr.kind == .None, "write %q under %d: %v", b[:], k, werr) {
				return
			}
			again, rerr := json.build(text, .Json)
			defer core.destroy(&again)
			if !testing.expectf(t, rerr.kind == .None, "%q is not JSON: %v", text, rerr) || !testing.expect_value(t, len(again.nodes), len(doc.nodes)) {
				return
			}
			for n, i in doc.nodes {
				m := again.nodes[i]
				if !testing.expectf(t, n.kind == m.kind && n.role == m.role && (n.n == m.n || n.kind < .Array), "row %d differs in %q", i, text) {
					return
				}
				if n.kind == .Number {
					x, y := core.number(&doc, core.Node_Index(i)), core.number(&again, core.Node_Index(i))
					if !testing.expectf(t, x == y, "number %d is %v, written %v: %q", i, x, y, text) {
						return
					}
				} else if n.kind == .String {
					x, _ := core.text_clone(&doc, core.Node_Index(i))
					y, _ := core.text_clone(&again, core.Node_Index(i))
					defer delete(x)
					defer delete(y)
					if !testing.expectf(t, x == y, "string %d is %q, written %q", i, x, y) {
						return
					}
				}
			}
		}
		own, _, oerr := core.write(&doc, as = json.as(.Json5))
		defer delete(own)
		if !testing.expect_value(t, oerr.kind, core.Typed_Error_Kind.None) {
			return
		}
		back, berr := json.build(own, .Json5)
		defer core.destroy(&back)
		if !testing.expectf(t, berr.kind == .None, "%q is not JSON5: %v", own, berr) || !same_tree(t, &doc, &back, "json5") {
			return
		}
	}
}

// A delimited text with a header is an array of records, its comment lines dropped and counted.
@(test)
write_document_shared_keys :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("x,y\n# note\n1,a\n2.5,\"b c\"\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
		return
	}
	text, _, werr := core.write(&doc, as = json.as(.Json))
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `[{"x":"1","y":"a"},{"x":"2.5","y":"b c"}]`)
	pretty, _, perr := core.write(&doc, core.PRETTY, json.as(.Jsonc))
	defer delete(pretty)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None)
	again, aerr := json.build(pretty, .Json)
	defer core.destroy(&again)
	testing.expect_value(t, aerr.kind, core.Document_Error_Kind.None)
	dropping, dropped, _ := core.write(&doc, as = json.as(.Json))
	delete(dropping)
	testing.expect_value(t, dropped, len(doc.facts))
	testing.expect(t, dropped > 0)
	sorted, _, serr := core.write(&doc, {sort_keys = true}, json.as(.Json))
	defer delete(sorted)
	testing.expect_value(t, serr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(sorted), `[{"x":"1","y":"a"},{"x":"2.5","y":"b c"}]`)
}

// A partial document is written with only the members and elements its read kept.
@(test)
write_document_kept :: proc(t: ^testing.T) {
	src := `{"a":[1,2,3,{"k":[4,5]}],"b":{"c":1,"d":2},"e":null}`
	paths := [?]string{`.a[1]`, `.a[3].k[0]`, `.b.d`}
	steps: [3]core.Path
	for p, i in paths {
		path, perr := core.parse_path(p)
		if !testing.expect_value(t, perr.kind, core.Path_Error_Kind.None) {
			return
		}
		steps[i] = path
	}
	defer for &p in steps {
		core.path_destroy(&p)
	}
	doc, err := json.scan(transmute([]u8)src, .Json, steps[:])
	if !testing.expect_value(t, err.kind, core.Path_Error_Kind.None) {
		return
	}
	defer core.destroy(&doc)
	text, _, kerr := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, kerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `{"a":[2,{"k":[4]}],"b":{"d":2}}`)
}

// A JSONC document with no comment is written as JSON, and `format` removes its trailing comma.
@(test)
write_document_jsonc_without_comments :: proc(t: ^testing.T) {
	src := `[1, 2,]`
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	defer core.destroy(&doc)
	if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
		return
	}
	text, _, werr := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `[1,2]`)
	direct, ferr := json.format(transmute([]u8)src, .Jsonc)
	defer delete(direct)
	testing.expect_value(t, ferr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(direct), `[1,2]`)
}

// A document of another format is written through its own text, number and resolve.
@(test)
write_document_from_delimited_text :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("1,a\n2.5,\"b c\"\n"), .Csv, {no_header = true})
	defer core.destroy(&doc)
	if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
		return
	}
	text, _, werr := core.write(&doc, as = json.as(.Json))
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `[["1","a"],["2.5","b c"]]`)
	own, _, cerr := core.write(&doc)
	defer delete(own)
	testing.expect_value(t, cerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(own), "1,a\n2.5,b c\n")
	headed, herr := dsv.build(transmute([]u8)string("x,y\n1,2\n"), .Csv)
	defer core.destroy(&headed)
	testing.expect_value(t, herr.kind, core.Document_Error_Kind.None)
	records, _, rerr := core.write(&headed, as = json.as(.Json))
	defer delete(records)
	testing.expect_value(t, rerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(records), `[{"x":"1","y":"2"}]`)
}

// A document read with `infer` writes a cell as the null, boolean or number it reads as, and every other cell stays a string, so the
// text is JSON whatever the cells hold.
@(test)
write_document_infers_cells :: proc(t: ^testing.T) {
	src := "a,b,c,d,e,f,g,h\n1,-2.50e3,true,false,,x,\"7\",0\n01,+1,.5,1.,0x1,NaN,-, 1\n"
	doc, err := dsv.build(transmute([]u8)src, .Csv, {infer = true})
	defer core.destroy(&doc)
	if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
		return
	}
	text, _, werr := core.write(&doc, {}, json.as(.Json))
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), `[{"a":1,"b":-2.50e3,"c":true,"d":false,"e":null,"f":"x","g":"7","h":0},` +
		`{"a":"01","b":"+1","c":".5","d":"1.","e":"0x1","f":"NaN","g":"-","h":" 1"}]`)
	again, aerr := json.build(text, .Json)
	defer core.destroy(&again)
	testing.expect_value(t, aerr.kind, core.Document_Error_Kind.None)
}

// A document built under a raised `max_depth` is written, compact and pretty, past the depth the stack holds in line.
@(test)
write_document_deep :: proc(t: ^testing.T) {
	depth := core.MAX_DEPTH + 40
	b: strings.Builder
	defer strings.builder_destroy(&b)
	for _ in 0 ..< depth {
		strings.write_byte(&b, '[')
	}
	strings.write_string(&b, `"leaf"`)
	for _ in 0 ..< depth {
		strings.write_byte(&b, ']')
	}
	src := transmute([]u8)strings.to_string(b)
	doc, err := json.build(src, .Json, {max_depth = u32(depth + 1)})
	defer core.destroy(&doc)
	if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
		return
	}
	text, _, werr := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), string(src))
	pretty, _, perr := core.write(&doc, core.PRETTY)
	defer delete(pretty)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None)
	again, aerr := json.build(pretty, .Json, {max_depth = u32(depth + 1)})
	defer core.destroy(&again)
	testing.expect_value(t, aerr.kind, core.Document_Error_Kind.None)
	same_tree(t, &doc, &again, "deep")
}

// A long key and a long string past one reservation are copied whole.
@(test)
write_document_long_tokens :: proc(t: ^testing.T) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"`)
	for _ in 0 ..< 10000 {
		strings.write_string(&b, "k")
	}
	strings.write_string(&b, `":["`)
	for _ in 0 ..< 70000 {
		strings.write_string(&b, "v")
	}
	strings.write_string(&b, `",1]}`)
	check_write(t, transmute([]u8)strings.to_string(b))
}

// A token within a block copy of the source's end is written whole at every length, as a value and as a key.
@(test)
write_document_near_the_end :: proc(t: ^testing.T) {
	for n in 0 ..< 70 {
		x := strings.repeat("x", n, context.temp_allocator)
		digits := strings.repeat("7", n + 1, context.temp_allocator)
		for parts in ([?][3]string{{`[1,{"k":"`, x, `"}]`}, {`{"`, x, `":[]}`}, {`{"a":{"k":`, digits, `}}`}}) {
			parts := parts
			text := strings.concatenate(parts[:], context.temp_allocator)
			if !check_write(t, transmute([]u8)text) {
				return
			}
		}
	}
}

// A text past the stream's buffer is written through each refill.
@(test)
write_document_refills :: proc(t: ^testing.T) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "[")
	for _ in 0 ..< 20000 {
		strings.write_string(&b, `{"id":1,"tags":[[[[[[[["a","b"]]]]]]]],"on":true},`)
	}
	strings.write_string(&b, "null]")
	check_write(t, transmute([]u8)strings.to_string(b))
}

// A text that ends at an unmapped page is written whole, by the row walk, the dense route and `format`: no read passes
// its last byte.
@(test)
writes_stop_at_the_end_of_a_page :: proc(t: ^testing.T) {
	fence := walktest.fence_init()
	defer walktest.unfence(&fence)
	texts: [dynamic]string
	defer delete(texts)
	for text in WRITE_TEXTS {
		append(&texts, text)
	}
	for n in 0 ..< 200 {
		append(&texts, strings.concatenate({`["`, strings.repeat("a", n, context.temp_allocator), `"]`}, context.temp_allocator))
		append(&texts, strings.concatenate({"[", strings.repeat("1,", n, context.temp_allocator), "1]"}, context.temp_allocator))
		append(&texts, strings.concatenate({"[", strings.repeat(" ", n, context.temp_allocator), "1", strings.repeat(" ", n, context.temp_allocator), "]"}, context.temp_allocator))
	}
	for text in texts {
		src := walktest.fence_copy(&fence, transmute([]u8)text)
		doc, err := json.build(src, .Json)
		if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
			return
		}
		for opts in WRITE_OPTS {
			direct, ferr := json.format(src, .Json, opts, {}, context.temp_allocator)
			testing.expect_value(t, ferr.kind, core.Typed_Error_Kind.None)
			written, _, werr := core.write(&doc, opts, allocator = context.temp_allocator)
			testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
			testing.expect_value(t, string(written), string(direct))
		}
		core.destroy(&doc)
	}
}

// A tolerated lone surrogate half reads as U+FFFD, and every route writes what the read decodes, which reads strictly.
@(test)
lone_surrogates_write_as_they_read :: proc(t: ^testing.T) {
	long := strings.repeat("a", 300, context.temp_allocator)
	FFFD :: "\xEF\xBF\xBD"
	cases := [?][2]string {
		{`"\ud800"`, `"` + FFFD + `"`},
		{`["\udc00",1]`, `["` + FFFD + `",1]`},
		{`["\ud83dx"]`, `["` + FFFD + `x"]`},
		{`{"\ud800":"\ud83d\ude00"}`, `{"` + FFFD + `":"\ud83d\ude00"}`},
		{`[1,1,1,1,1,1,1,1,1,1,1,1,1,"\ud800",1,1,1,1,1,1,1,1,1,1,1,1,1]`, `[1,1,1,1,1,1,1,1,1,1,1,1,1,"` + FFFD + `",1,1,1,1,1,1,1,1,1,1,1,1,1]`},
		{strings.concatenate({`["`, long, `\ud800"]`}, context.temp_allocator), strings.concatenate({`["`, long, FFFD, `"]`}, context.temp_allocator)},
	}
	read := json.Options{tolerate = {.Lone_Surrogate}}
	for c in cases {
		doc, err := json.build(transmute([]u8)c[0], .Json, read)
		if !testing.expect_value(t, err.kind, core.Document_Error_Kind.None) {
			continue
		}
		defer core.destroy(&doc)
		for opts in ([?]core.Write_Options{{}, {sort_keys = true}}) {
			text, _, werr := core.write(&doc, opts, allocator = context.temp_allocator)
			testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
			testing.expect_value(t, string(text), c[1])
			_, bad := json.validate(text, .Json).?
			testing.expect(t, !bad)
		}
		direct, ferr := json.format(transmute([]u8)c[0], .Json, {}, read, context.temp_allocator)
		testing.expect_value(t, ferr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(direct), c[1])
	}
}

// Strings a tolerance read go through the row walk's rare path as they are spelled again, past a chunk of rows and in
// keys too.
@(test)
tolerated_strings_through_the_row_walk :: proc(t: ^testing.T) {
	FFFD :: "\xEF\xBF\xBD"
	src := strings.concatenate({"[", strings.repeat("\"a\xff\",{\"k\xff\":\"b\"},1,", 3000, context.temp_allocator), "0]"}, context.temp_allocator)
	want := strings.concatenate({"[", strings.repeat(`"a` + FFFD + `",{"k` + FFFD + `":"b"},1,`, 3000, context.temp_allocator), "0]"}, context.temp_allocator)
	doc, err := json.build(transmute([]u8)src, .Json, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	text, _, werr := core.write(&doc, {}, allocator = context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect(t, string(text) == want)
	pretty, _, perr := core.write(&doc, {pretty = true, indent = 2}, allocator = context.temp_allocator)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None)
	again, aerr := json.format(pretty, .Json, {}, {}, context.temp_allocator)
	testing.expect_value(t, aerr.kind, core.Typed_Error_Kind.None)
	testing.expect(t, string(again) == want)
}

@(private)
refusing_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	return 0, .Permission_Denied if mode == .Write else .Unknown
}

// A stream that fails reports the write's end through the tree writer and the row walk, and a failed write counts no drop.
@(test)
document_write_to_a_failing_stream :: proc(t: ^testing.T) {
	for src in ([?]string{`[1,2]`, "[1, /* c */ 2]"}) {
		doc, err := json.build(transmute([]u8)src, .Jsonc)
		defer core.destroy(&doc)
		testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
		dropped, serr := core.write_stream(io.Stream{procedure = refusing_stream}, &doc, {}, json.as(.Json))
		testing.expect_value(t, serr.kind, core.Typed_Error_Kind.Write_Failed)
		testing.expect_value(t, serr.cause, io.Error.Permission_Denied)
		testing.expect_value(t, dropped, 0)
	}
}

// A string with `ascii` or `escape_html` is copied from the source when it holds no byte they respell and written by
// `put_string` otherwise. The tree writer, which `sort_keys` takes, is the model.
@(test)
spelling_options_in_the_row_walk :: proc(t: ^testing.T) {
	PIECES := [?]string{"a", "plain text", "0123456789abcdef", "é", "日", "😀", "<", ">", "&", " ", `\n`, `é`, `\"`, `\/`, " "}
	rand.reset(5)
	for _ in 0 ..< 300 {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		strings.write_byte(&b, '[')
		for item in 0 ..< 1 + rand.int_max(4) {
			strings.write_string(&b, ",{" if item > 0 else "{")
			for key in "abc" {
				strings.write_byte(&b, '"')
				strings.write_rune(&b, key)
				for _ in 0 ..< rand.int_max(3) {
					strings.write_string(&b, rand.choice(PIECES[:]))
				}
				strings.write_string(&b, `":"`)
				for _ in 0 ..< rand.int_max(24) {
					strings.write_string(&b, rand.choice(PIECES[:]))
				}
				strings.write_string(&b, `"`)
				if key != 'c' {
					strings.write_byte(&b, ',')
				}
			}
			strings.write_byte(&b, '}')
		}
		strings.write_byte(&b, ']')
		doc, err := json.build(transmute([]u8)strings.to_string(b), .Json)
		defer core.destroy(&doc)
		if !testing.expectf(t, err.kind == .None, "build %q: %v", strings.to_string(b), err) {
			return
		}
		for opts in ([?]core.Write_Options {
				{ascii = true},
				{escape_html = true},
				{ascii = true, escape_html = true, pretty = true, indent = 2},
				{escape_html = true, pretty = true, indent = 1},
			}) {
			got, _, gerr := core.write(&doc, opts)
			defer delete(got)
			model := opts
			model.sort_keys = true
			want, _, werr := core.write(&doc, model)
			defer delete(want)
			if !testing.expectf(t, gerr.kind == .None && werr.kind == .None && string(got) == string(want), "%q under %v: %q, the tree writer %q", strings.to_string(b), opts, got, want) {
				return
			}
		}
	}
}
