package json_tests

import "core:bytes"
import "core:io"
import "core:math/rand"
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
	doc, err := core.build(src, json.as(.Json))
	if !testing.expectf(t, err == nil, "build %q: %v", src, err) {
		return false
	}
	defer core.destroy(&doc)
	for opts, k in WRITE_OPTS {
		text, _, werr := core.write(&doc, opts)
		if !testing.expectf(t, werr == nil, "write %q under %d: %v", src, k, werr) {
			return false
		}
		defer delete(text)
		again, rerr := core.build(text, json.as(.Json))
		if !testing.expectf(t, rerr == nil, "re-read %q under %d: %v", text, k, rerr) {
			return false
		}
		defer core.destroy(&again)
		if !same_tree(t, &doc, &again, "re-read") {
			return false
		}
		check_layout(t, text, opts, "layout")
		twice, _, terr := core.write(&again, opts)
		defer delete(twice)
		if !testing.expect(t, terr == nil && string(twice) == string(text), "writing a written text changes it") {
			return false
		}
		direct, ferr := core.format(src, json.as(.Json), opts)
		defer delete(direct)
		if !testing.expect(t, ferr == nil && string(direct) == string(text), "format differs from core.write") {
			return false
		}
		through, _, cerr := core.write(&doc, opts, json.as(.Json))
		defer delete(through)
		if !testing.expect(t, cerr == nil && string(through) == string(text), "core.write in its own spec differs from core.write") {
			return false
		}
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		_, serr := core.write_stream(bytes.buffer_to_stream(&buf), &doc, opts)
		if !testing.expect(t, serr == nil && string(bytes.buffer_to_bytes(&buf)) == string(text), "the stream differs from core.write") {
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
		want, _ := core.format(core.span(doc, node), json.as(.Json), opts)
		defer delete(want)
		if !testing.expectf(t, err == nil && string(text) == string(want), "node %d of %q writes %q, its span %q", i, doc.src, text, want) {
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
	doc, _ := core.build(transmute([]u8)src, json.as(.Json))
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

// A string that was escaped keeps its escapes, and `ascii`, `escape_del` and `escape_html` ask for another spelling of the same text.
@(test)
write_document_string_options :: proc(t: ^testing.T) {
	src := "[\"a<b>&c\",\"é😀\",\"é\\n\",\"x\x7fy\"]"
	doc, _ := core.build(transmute([]u8)src, json.as(.Json))
	defer core.destroy(&doc)
	plain, _, _ := core.write(&doc)
	defer delete(plain)
	testing.expect_value(t, string(plain), src)
	for opts in ([?]core.Write_Options{{ascii = true}, {escape_html = true}, {escape_del = true}, {ascii = true, escape_html = true}, {pretty = true, indent = 2, ascii = true}}) {
		text, _, err := core.write(&doc, opts)
		defer delete(text)
		if !walktest.expect_nil(t, err) {
			return
		}
		again, rerr := core.build(text, json.as(.Json))
		defer core.destroy(&again)
		walktest.expect_nil(t, rerr)
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
			testing.expect(t, !opts.escape_del || b != 0x7f)
			testing.expect(t, !opts.escape_html || (b != '<' && b != '>' && b != '&'))
		}
	}
}

// `respell_strings` writes a string read from a source as a computed one is written, and leaves the rest as it was read.
@(test)
write_document_respell_strings :: proc(t: ^testing.T) {
	src := `{"\u0061":["\u00e9\/x","\ud83d\ude00","é","\n\"\\",1E2]}`
	doc, _ := core.build(transmute([]u8)string(src), json.as(.Json))
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
		walktest.expect_nil(t, err)
		testing.expect_value(t, string(text), want)
	}
	jsonc, _ := core.build(transmute([]u8)string(`[/* \/ */ "\/"]`), json.as(.Jsonc))
	defer core.destroy(&jsonc)
	text, _, _ := core.write(&jsonc, {respell_strings = true})
	defer delete(text)
	testing.expect_value(t, string(text), `[/* \/ */"/"]`)
}

// A subtree of a delimited target is the array's records, and a key or a node past the document is refused.
@(test)
write_document_nodes :: proc(t: ^testing.T) {
	doc, _ := core.build(transmute([]u8)string(`{"n":1,"rows":[{"a":1,"b":"x"},{"a":2}]}`), json.as(.Json))
	defer core.destroy(&doc)
	rows, _ := core.member(&doc, core.ROOT, "rows")
	csv, _, err := core.write(&doc, as = dsv.as(.Csv), node = rows)
	defer delete(csv)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(csv), "a,b\n1,x\n2,\n")
	for node in ([?]core.Node_Index{1, core.Node_Index(len(doc.nodes)), core.NO_NODE}) {
		_, _, err = core.write(&doc, node = node)
		walktest.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
	}
	_, _, err = core.write(&doc, as = dsv.as(.Csv), node = 2)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unsupported)
}

@(test)
write_document_refusals :: proc(t: ^testing.T) {
	doc, _ := core.build(transmute([]u8)string(`{"a":1}`), json.as(.Json))
	defer core.destroy(&doc)
	whole, _, werr := core.write(&doc)
	delete(whole)
	walktest.expect_nil(t, werr)

	_, err := core.format(transmute([]u8)string(`[1,`), json.as(.Json))
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Walk)
	_, err = core.format(transmute([]u8)string("[1, /* c */ "), json.as(.Jsonc))
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Walk)
	_, err = core.format(transmute([]u8)string(`{a:`), json.as(.Json5))
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Walk)
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
		doc, err := core.build(text, json.as(.Json, {}), .Last, context.temp_allocator)
		walktest.expect_nil(t, err)
		sorted := c.opts
		sorted.sort_keys = true
		want, _, werr := core.write(&doc, sorted)
		defer delete(want)
		walktest.expect_nil(t, werr)
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
		walktest.expect_nil(t, werr)
		formatted, ferr := core.format(text, json.as(.Json), c.opts)
		walktest.expect_nil(t, ferr)
		testing.expect(t, string(formatted) == string(want))
		delete(formatted)
	}
}

// Where a comment goes: before its member, between the key and the value, after the member and its comma, and in a
// container's foot.
@(test)
write_document_comment_layout :: proc(t: ^testing.T) {
	src := `// top
{ /* lead */ "a" /* k */ : 1, // trail
 "b": [2 /* t */] /* u */ /* f */ } // end`
	doc, _ := core.build(transmute([]u8)src, json.as(.Jsonc))
	defer core.destroy(&doc)
	compact, _, _ := core.write(&doc)
	defer delete(compact)
	testing.expect_value(t, string(compact), "// top\n{/* lead */\"a\":/* k */1,// trail\n\"b\":[2/* t */]/* u *//* f */}// end\n")
	pretty, _, _ := core.write(&doc, core.PRETTY)
	defer delete(pretty)
	want := "// top\n{\n  /* lead */\n  \"a\": /* k */ 1, // trail\n  \"b\": [\n    2 /* t */\n  ] /* u */ /* f */\n} // end\n"
	testing.expect_value(t, string(pretty), want)
	feet := "[ // x\n 1,\n // foot\n ]"
	foot_doc, _ := core.build(transmute([]u8)feet, json.as(.Jsonc))
	defer core.destroy(&foot_doc)
	text, _, _ := core.write(&foot_doc, core.PRETTY)
	defer delete(text)
	testing.expect_value(t, string(text), "[\n  // x\n  1\n  // foot\n]")
	// Compact text ends a value's line before a comment that is not the value's inline comment.
	lines := "[1, /* i */\n /* head */ 2 /* i */\n /* foot */]\n/* root foot */"
	lines_doc, _ := core.build(transmute([]u8)lines, json.as(.Jsonc))
	defer core.destroy(&lines_doc)
	broken, _, _ := core.write(&lines_doc)
	defer delete(broken)
	testing.expect_value(t, string(broken), "[1,/* i */\n/* head */2/* i */\n/* foot */]\n/* root foot */")
}

@(test)
write_document_sort_keys :: proc(t: ^testing.T) {
	src := `{"b":{"z":1,"a":[{"y":0,"x":0}]},"a":2,"é":3,"B":4, "a":5}`
	doc, _ := core.build(transmute([]u8)src, json.as(.Json))
	defer core.destroy(&doc)
	text, _, err := core.write(&doc, {sort_keys = true})
	defer delete(text)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), `{"B":4,"a":2,"a":5,"b":{"a":[{"x":0,"y":0}],"z":1},"é":3}`)
	direct, ferr := core.format(transmute([]u8)src, json.as(.Json), {sort_keys = true})
	defer delete(direct)
	walktest.expect_nil(t, ferr)
	testing.expect_value(t, string(direct), string(text))
	// Keys sort by what they decode to, and a member keeps its comments when it moves.
	commented := "{\"b\":1, // one\n \"\\u0061\":2 /* two */}"
	cdoc, _ := core.build(transmute([]u8)commented, json.as(.Jsonc))
	defer core.destroy(&cdoc)
	moved, _, merr := core.write(&cdoc, {sort_keys = true})
	defer delete(moved)
	walktest.expect_nil(t, merr)
	testing.expect_value(t, string(moved), "{\"\\u0061\":2,/* two */\"b\":1// one\n}")
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
		doc, err := core.build(transmute([]u8)pair[0], json.as(.Json5))
		if !testing.expectf(t, err == nil, "build %q: %v", pair[0], err) {
			return
		}
		defer core.destroy(&doc)
		text, dropped, werr := core.write(&doc, as = json.as(.Json))
		defer delete(text)
		walktest.expect_nil(t, werr)
		testing.expect_value(t, string(text), pair[1])
		testing.expect_value(t, dropped, len(doc.facts))
		own, kept, oerr := core.write(&doc)
		defer delete(own)
		walktest.expect_nil(t, oerr)
		testing.expect_value(t, kept, 0)
		direct, ferr := core.format(transmute([]u8)pair[0], json.as(.Json5))
		defer delete(direct)
		walktest.expect_nil(t, ferr)
		testing.expect_value(t, string(direct), string(own))
	}
	for src in ([?]string{`[Infinity]`, `{a:-Infinity}`, `[NaN]`, `[1,+NaN]`}) {
		doc, _ := core.build(transmute([]u8)src, json.as(.Json5))
		defer core.destroy(&doc)
		_, _, err := core.write(&doc, as = json.as(.Json))
		walktest.expect_kind(t, err, core.Typed_Error_Kind.Non_Finite)
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
		doc, err := core.build(b[:], json.as(.Json5))
		if !testing.expectf(t, err == nil, "build %q: %v", b[:], err) {
			return
		}
		defer core.destroy(&doc)
		for opts, k in WRITE_OPTS {
			text, _, werr := core.write(&doc, opts, json.as(.Json))
			defer delete(text)
			if walktest.typed_kind(werr) == .Non_Finite {
				continue
			}
			if !testing.expectf(t, werr == nil, "write %q under %d: %v", b[:], k, werr) {
				return
			}
			again, rerr := core.build(text, json.as(.Json))
			defer core.destroy(&again)
			if !testing.expectf(t, rerr == nil, "%q is not JSON: %v", text, rerr) || !testing.expect_value(t, len(again.nodes), len(doc.nodes)) {
				return
			}
			for n, i in doc.nodes {
				m := again.nodes[i]
				if !testing.expectf(t, n.kind == m.kind && n.role == m.role && (n.n == m.n || n.kind < .Array), "row %d differs in %q", i, text) {
					return
				}
				if n.kind == .Number {
					x, x_ok := core.number(&doc, core.Node_Index(i))
					y, y_ok := core.number(&again, core.Node_Index(i))
					if !testing.expectf(t, x_ok && y_ok && x == y, "number %d is %v, written %v: %q", i, x, y, text) {
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
		if !walktest.expect_nil(t, oerr) {
			return
		}
		back, berr := core.build(own, json.as(.Json5))
		defer core.destroy(&back)
		if !testing.expectf(t, berr == nil, "%q is not JSON5: %v", own, berr) || !same_tree(t, &doc, &back, "json5") {
			return
		}
	}
}

// A delimited text with a header is an array of records, its comment lines dropped and counted.
@(test)
write_document_shared_keys :: proc(t: ^testing.T) {
	doc, err := core.build(transmute([]u8)string("x,y\n# note\n1,a\n2.5,\"b c\"\n"), dsv.as(.Csv, {comment = '#'}))
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, err) {
		return
	}
	text, _, werr := core.write(&doc, as = json.as(.Json))
	defer delete(text)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), `[{"x":"1","y":"a"},{"x":"2.5","y":"b c"}]`)
	pretty, _, perr := core.write(&doc, core.PRETTY, json.as(.Jsonc))
	defer delete(pretty)
	walktest.expect_nil(t, perr)
	again, aerr := core.build(pretty, json.as(.Json))
	defer core.destroy(&again)
	walktest.expect_nil(t, aerr)
	dropping, dropped, _ := core.write(&doc, as = json.as(.Json))
	delete(dropping)
	testing.expect_value(t, dropped, len(doc.facts))
	testing.expect(t, dropped > 0)
	sorted, _, serr := core.write(&doc, {sort_keys = true}, json.as(.Json))
	defer delete(sorted)
	walktest.expect_nil(t, serr)
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
		if !walktest.expect_nil(t, perr) {
			return
		}
		steps[i] = path
	}
	defer for &p in steps {
		core.path_destroy(&p)
	}
	doc, err := json.scan(transmute([]u8)src, .Json, steps[:])
	if !walktest.expect_nil(t, err) {
		return
	}
	defer core.destroy(&doc)
	text, _, kerr := json.write(&doc, .Json)
	defer delete(text)
	walktest.expect_nil(t, kerr)
	testing.expect_value(t, string(text), `{"a":[2,{"k":[4]}],"b":{"d":2}}`)
}

// A partial document is written as the target spec says, as the same nodes of a full build are.
@(test)
write_document_kept_as_target :: proc(t: ^testing.T) {
	src := transmute([]u8)string("[{id:0x1F,v:Infinity,'s':'q'},2]")
	path, perr := core.parse_path(".[0]")
	defer core.path_destroy(&path)
	if !walktest.expect_nil(t, perr) {
		return
	}
	doc, err := json.scan(src, .Json5, path)
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, err) {
		return
	}
	full, ferr := core.build(src, json.as(.Json5))
	defer core.destroy(&full)
	walktest.expect_nil(t, ferr)
	answer := doc.answers[0].node
	for target in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		kept, _, kerr := core.write(&doc, as = json.as(target), node = answer)
		defer delete(kept)
		whole, _, werr := core.write(&full, as = json.as(target), node = 1)
		defer delete(whole)
		testing.expectf(t, walktest.typed_kind(kerr) == walktest.typed_kind(werr) && walktest.at_of(kerr) == walktest.at_of(werr) && string(kept) == string(whole), "%v: %q %v, full %q %v", target, kept, kerr, whole, werr)
	}
	own, _, oerr := json.write(&doc, .Json5)
	defer delete(own)
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, string(own), "[{id:0x1F,v:Infinity,'s':'q'}]")
}

// A JSONC line comment holding U+2028 or U+2029, which end a JSON5 line comment, is written as JSON5 with them spelled
// ` ` and ` `, so the text past them stays in the comment.
@(test)
write_document_line_separators_as_json5 :: proc(t: ^testing.T) {
	src := "[1 // a , 2 b\n]"
	doc, err := core.build(transmute([]u8)src, json.as(.Jsonc))
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, err) {
		return
	}
	text, _, werr := core.write(&doc, as = json.as(.Json5))
	defer delete(text)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), "[1// a\\u2028, 2\\u2029b\n]")
	again, rerr := core.build(text, json.as(.Json5))
	defer core.destroy(&again)
	walktest.expect_nil(t, rerr)
	testing.expect_value(t, len(again.nodes), len(doc.nodes))
	testing.expect_value(t, len(again.facts), 1)
	kept, _, kerr := core.write(&doc, as = json.as(.Jsonc))
	defer delete(kept)
	walktest.expect_nil(t, kerr)
	testing.expect_value(t, string(kept), "[1// a , 2 b\n]")
}

// A JSONC document with no comment is written as JSON, and `format` removes its trailing comma.
@(test)
write_document_jsonc_without_comments :: proc(t: ^testing.T) {
	src := `[1, 2,]`
	doc, err := core.build(transmute([]u8)src, json.as(.Jsonc))
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, err) {
		return
	}
	text, _, werr := core.write(&doc)
	defer delete(text)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), `[1,2]`)
	direct, ferr := core.format(transmute([]u8)src, json.as(.Jsonc))
	defer delete(direct)
	walktest.expect_nil(t, ferr)
	testing.expect_value(t, string(direct), `[1,2]`)
}

// A document of another format is written through its own text, number and kind: an empty cell is null.
@(test)
write_document_from_delimited_text :: proc(t: ^testing.T) {
	doc, err := core.build(transmute([]u8)string("1,a\n2.5,\"b c\"\n"), dsv.as(.Csv, {no_header = true}))
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, err) {
		return
	}
	text, _, werr := core.write(&doc, as = json.as(.Json))
	defer delete(text)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), `[["1","a"],["2.5","b c"]]`)
	own, _, cerr := core.write(&doc)
	defer delete(own)
	walktest.expect_nil(t, cerr)
	testing.expect_value(t, string(own), "1,a\n2.5,b c\n")
	headed, herr := core.build(transmute([]u8)string("x,y,z\n1,2,\n"), dsv.as(.Csv))
	defer core.destroy(&headed)
	walktest.expect_nil(t, herr)
	records, _, rerr := core.write(&headed, as = json.as(.Json))
	defer delete(records)
	walktest.expect_nil(t, rerr)
	testing.expect_value(t, string(records), `[{"x":"1","y":"2","z":null}]`)
}

// A document read with `infer` writes a cell as the null, boolean or number it reads as, and every other cell stays a string, so the
// text is JSON whatever the cells hold.
@(test)
write_document_infers_cells :: proc(t: ^testing.T) {
	src := "a,b,c,d,e,f,g,h\n1,-2.50e3,true,false,,x,\"7\",0\n01,+1,.5,1.,0x1,NaN,-, 1\n"
	doc, err := core.build(transmute([]u8)src, dsv.as(.Csv, {infer = true}))
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, err) {
		return
	}
	text, _, werr := core.write(&doc, {}, json.as(.Json))
	defer delete(text)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(text), `[{"a":1,"b":-2.50e3,"c":true,"d":false,"e":null,"f":"x","g":"7","h":0},` +
		`{"a":"01","b":"+1","c":".5","d":"1.","e":"0x1","f":"NaN","g":"-","h":" 1"}]`)
	again, aerr := core.build(text, json.as(.Json))
	defer core.destroy(&again)
	walktest.expect_nil(t, aerr)
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
	// The sizes around the one a small text is copied up to.
	for n in 1000 ..< 1030 {
		append(&texts, strings.concatenate({`["`, strings.repeat("a", n, context.temp_allocator), `"]`}, context.temp_allocator))
	}
	for n in 0 ..< 200 {
		append(&texts, strings.concatenate({`["`, strings.repeat("a", n, context.temp_allocator), `"]`}, context.temp_allocator))
		append(&texts, strings.concatenate({"[", strings.repeat("1,", n, context.temp_allocator), "1]"}, context.temp_allocator))
		append(&texts, strings.concatenate({"[", strings.repeat(" ", n, context.temp_allocator), "1", strings.repeat(" ", n, context.temp_allocator), "]"}, context.temp_allocator))
	}
	for text in texts {
		src := walktest.fence_copy(&fence, transmute([]u8)text)
		doc, err := core.build(src, json.as(.Json))
		if !walktest.expect_nil(t, err) {
			return
		}
		for opts in WRITE_OPTS {
			direct, ferr := core.format(src, json.as(.Json), opts, context.temp_allocator)
			walktest.expect_nil(t, ferr)
			written, _, werr := core.write(&doc, opts, allocator = context.temp_allocator)
			walktest.expect_nil(t, werr)
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
		doc, err := core.build(transmute([]u8)c[0], json.as(.Json, read))
		if !walktest.expect_nil(t, err) {
			continue
		}
		defer core.destroy(&doc)
		for opts in ([?]core.Write_Options{{}, {sort_keys = true}}) {
			text, _, werr := core.write(&doc, opts, allocator = context.temp_allocator)
			walktest.expect_nil(t, werr)
			testing.expect_value(t, string(text), c[1])
			_, bad := walktest.fault_of(json.validate(text, .Json)).?
			testing.expect(t, !bad)
		}
		direct, ferr := core.format(transmute([]u8)c[0], json.as(.Json, read), {}, context.temp_allocator)
		walktest.expect_nil(t, ferr)
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
	doc, err := core.build(transmute([]u8)src, json.as(.Json, {tolerate = {.Invalid_Utf8}}))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	text, _, werr := core.write(&doc, {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, werr)
	testing.expect(t, string(text) == want)
	pretty, _, perr := core.write(&doc, {pretty = true, indent = 2}, allocator = context.temp_allocator)
	walktest.expect_nil(t, perr)
	again, aerr := core.format(pretty, json.as(.Json), {}, context.temp_allocator)
	walktest.expect_nil(t, aerr)
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
		doc, err := core.build(transmute([]u8)src, json.as(.Jsonc))
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		dropped, serr := core.write_stream(io.Stream{procedure = refusing_stream}, &doc, {}, json.as(.Json))
		walktest.expect_kind(t, serr, core.Typed_Error_Kind.Write_Failed)
		testing.expect_value(t, walktest.typed_of(serr).cause, io.Error.Permission_Denied)
		testing.expect_value(t, dropped, 0)
	}
}

// A string with `ascii`, `escape_del` or `escape_html` is copied from the source when it holds no byte they respell and written by
// `put_string` otherwise. The tree writer, which `sort_keys` takes, is the model.
@(test)
spelling_options_in_the_row_walk :: proc(t: ^testing.T) {
	PIECES := [?]string{"a", "plain text", "0123456789abcdef", "é", "日", "😀", "<", ">", "&", " ", `\n`, `é`, `\"`, `\/`, " ", "\x7f"}
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
		doc, err := core.build(transmute([]u8)strings.to_string(b), json.as(.Json))
		defer core.destroy(&doc)
		if !testing.expectf(t, err == nil, "build %q: %v", strings.to_string(b), err) {
			return
		}
		for opts in ([?]core.Write_Options {
				{ascii = true},
				{escape_html = true},
				{escape_del = true},
				{escape_del = true, escape_html = true},
				{ascii = true, escape_html = true, pretty = true, indent = 2},
				{escape_html = true, pretty = true, indent = 1},
			}) {
			got, _, gerr := core.write(&doc, opts)
			defer delete(got)
			model := opts
			model.sort_keys = true
			want, _, werr := core.write(&doc, model)
			defer delete(want)
			if !testing.expectf(t, gerr == nil && werr == nil && string(got) == string(want), "%q under %v: %q, the tree writer %q", strings.to_string(b), opts, got, want) {
				return
			}
		}
	}
}

// A text with a comment, read under a raised `max_depth`, is written back at its full depth.
@(test)
write_document_deep_comment :: proc(t: ^testing.T) {
	src := strings.concatenate({strings.repeat("[", 5000, context.temp_allocator), "/* c */0", strings.repeat("]", 5000, context.temp_allocator)}, context.temp_allocator)
	text, err := core.format(transmute([]u8)src, json.as(.Jsonc, {max_depth = 5000}), {}, context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(text), src)
}
