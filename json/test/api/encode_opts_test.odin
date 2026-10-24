package json_tests

// Marshal_Opts past `pretty` (indent, ascii_only, escape_html, trailing_newline) and a plan's enum text on
// every writer, and the writers that stream to an `io.Writer`.

import json "../.."
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
Opt_Color :: enum u8 {Red, Green}

@(private = "file")
Opt_Sparse :: enum i16 {Low = -3, High = 900}

@(private = "file")
Opt_Row :: struct {
	name: string,
	tags: []Opt_Color,
	at:   Opt_Sparse,
}

// `text` with every character `ascii` or `html` asks for written as `\u` escapes, rune by rune.
@(private = "file")
reescape_ref :: proc(text: string, ascii, html: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		switch {
		case html && (r == '<' || r == '>' || r == '&' || r == 0x2028 || r == 0x2029), ascii && r >= 0x80 && r < 0x10000:
			fmt.sbprintf(&b, "\\u%04x", r)
		case ascii && r >= 0x10000:
			c := r - 0x10000
			fmt.sbprintf(&b, "\\u%04x\\u%04x", 0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF))
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// What every writer writes for one value. Its compact text is `doc`.
@(private = "file")
writers_agree :: proc(t: ^testing.T, doc: string, opts: json.Marshal_Opts, want: string, loc := #caller_location) {
	parsed := build_ok(t, doc, loc)
	defer json.destroy(&parsed)
	got, err := json.marshal(&parsed, opts, context.temp_allocator)
	testing.expect_value(t, err, json.Marshal_Error.None, loc = loc)
	testing.expect_value(t, string(got), want, loc = loc)
	sb := strings.builder_make(context.temp_allocator)
	err = json.marshal_to_writer(strings.to_writer(&sb), &parsed, opts, context.temp_allocator)
	testing.expect_value(t, err, json.Marshal_Error.None, loc = loc)
	testing.expect_value(t, strings.to_string(sb), want, loc = loc)
}

// A line indented past 65535 bytes, the widest indent at depth 260, comes out of every writer alike.
@(test)
test_encode_opts_indent_deep :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	depth := 260
	text := nested_arrays(depth)
	parsed := build_ok(t, text)
	defer json.destroy(&parsed)
	opts := json.Marshal_Opts{pretty = true, indent = 255}
	got, err := json.marshal(&parsed, opts, context.temp_allocator)
	testing.expect_value(t, err, json.Marshal_Error.None)
	sb := strings.builder_make(context.temp_allocator)
	err = json.marshal_to_writer(strings.to_writer(&sb), &parsed, opts, context.temp_allocator)
	testing.expect_value(t, err, json.Marshal_Error.None)
	testing.expect(t, string(got) == strings.to_string(sb), "streamed pretty differs")
	innermost := strings.concatenate({"\n", strings.repeat(" ", 255 * (depth - 1), context.temp_allocator), "[]\n"}, context.temp_allocator)
	testing.expect(t, strings.contains(string(got), innermost), "the innermost line is indented 255 spaces per level")
}

@(test)
test_encode_opts_reescape :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := "a<b>&c é \u2028\u2029 😀 \\\"x"
	compact := marshal_text(t, s)
	for ascii in ([]bool{false, true}) {
		for html in ([]bool{false, true}) {
			opts := json.Marshal_Opts{ascii_only = ascii, escape_html = html}
			want := reescape_ref(compact, ascii, html)
			testing.expect_value(t, marshal_text(t, s, opts), want)
			writers_agree(t, compact, opts, want)
		}
	}
	testing.expect_value(t, marshal_text(t, "é😀<", {ascii_only = true, escape_html = true}), `"\u00e9\ud83d\ude00\u003c"`)
	// Keys and map keys are strings too.
	m := make(map[string]int, context.temp_allocator)
	m["<é>"] = 1
	testing.expect_value(t, marshal_text(t, m, {ascii_only = true, escape_html = true}), `{"\u003c\u00e9\u003e":1}`)
}

// A value large enough to flush many times comes out of every streaming writer as the buffered one.
@(test)
test_encode_opts_streams :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rows := make([]Opt_Row, 6000, context.temp_allocator)
	for &row, i in rows {
		// Multibyte text lands across every flush boundary.
		row.name = strings.repeat("é<x😀", i % 7, context.temp_allocator)
		row.tags = {.Red, .Green} if i % 2 == 0 else {}
		row.at = .Low
	}
	Wide :: struct {
		big:  string,
		rows: []Opt_Row,
	}
	v := Wide{big = strings.repeat("ab€", 50_000, context.temp_allocator), rows = rows}
	cases := []struct {
		opts:  json.Marshal_Opts,
		enums: json.Enum_Spelling,
	}{
		{{}, .Name},
		{{pretty = true}, .Name},
		{{pretty = true, indent = 2, trailing_newline = true}, .Name},
		{{ascii_only = true}, .Name},
		{{escape_html = true, pretty = true}, .Name},
		{{trailing_newline = true}, .Int},
	}
	for c in cases {
		plan := json.type_plan_init(Wide, {enums = c.enums}, context.temp_allocator)
		want := marshal_text(t, v, c.opts, &plan)
		sb := strings.builder_make(context.temp_allocator)
		testing.expect_value(t, json.marshal_to_writer(strings.to_writer(&sb), v, c.opts, &plan, context.temp_allocator), json.Marshal_Error.None)
		testing.expectf(t, strings.to_string(sb) == want, "marshal_to_writer %v %v: %d bytes, want %d", c.opts, c.enums, len(sb.buf), len(want))
		// The document writer re-emits the names in the compact text.
		writers_agree(t, marshal_text(t, v), c.opts, marshal_text(t, v, c.opts))
	}
	long := strings.concatenate({`"`, strings.repeat("x", 300_000, context.temp_allocator), `"`}, context.temp_allocator)
	pair := strings.concatenate({"[", long, ",", long, "]"}, context.temp_allocator)
	writers_agree(t, pair, {}, pair)
	spaced := strings.concatenate({"[ ", strings.repeat(`"é" , `, 40_000, context.temp_allocator), "1 ]"}, context.temp_allocator)
	writers_agree(t, spaced, {ascii_only = true}, reescape_ref(strings.concatenate({"[", strings.repeat(`"é",`, 40_000, context.temp_allocator), "1]"}, context.temp_allocator), true, false))
}

// The text without whitespace outside strings, byte by byte.
@(private = "file")
minified_ref :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	in_string, escaped := false, false
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case in_string:
			strings.write_byte(&sb, c)
			in_string = !(c == '"' && !escaped)
			escaped = c == '\\' && !escaped
		case c == ' ' || c == '\n' || c == '\t' || c == '\r':
		case:
			strings.write_byte(&sb, c)
			in_string = c == '"'
		}
	}
	return strings.to_string(sb)
}

// Compact output agrees with the byte-by-byte minifier where long stretches hold no whitespace (copied whole,
// their string mask made up later) and the strings after them hold spaces, an escaped quote and a backslash
// at every offset of a 64-byte block, in a piece or a last piece that ends clean or not, past the writer's
// flush size.
@(test)
test_compact_encode_clean_stretches :: proc(t: ^testing.T) {
	for shift in 0 ..< 130 {
		defer free_all(context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "[ ")
		for _ in 0 ..< 12000 {
			strings.write_string(&sb, `"ab\"c\\",12345,`)
		}
		for _ in 0 ..< shift {
			strings.write_string(&sb, "7,")
		}
		strings.write_string(&sb, ` "x y \" z \\" , "\\\\" ,`)
		for _ in 0 ..< 3000 {
			strings.write_string(&sb, `"z",99,`)
		}
		strings.write_string(&sb, ` "a  b" , {"k": [1, 2] ,"s":"end"},`)
		for _ in 0 ..< shift % 3 {
			strings.write_string(&sb, "8,")
		}
		strings.write_string(&sb, "0]")
		text := strings.to_string(sb)
		writers_agree(t, text, {}, minified_ref(text))
		// The same, ending on a string whose tail holds spaces.
		text = strings.concatenate({text[:len(text) - 1], `, "last   one"]`}, context.temp_allocator)
		writers_agree(t, text, {}, minified_ref(text))
	}
}

// `sort_keys` with `jq_spelling` writes the bytes `stury -S` prints, newline and all (`-c` and the default pretty layout, `--jsonc` for
// a JSONC text): nested, escaped, repeated and non-ASCII keys in byte order, an empty object, and comments with
// their members.
@(test)
test_encode_opts_sort_keys_matches_cli :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src, compact, pretty: string,
		dialect:              json.Dialect,
	}
	cases := []Case {
		{
			src     = `{"b":{"z":1,"y":[{"q":1,"p":2}]},"a":null,"bc":3,"ba":4,"é":1,"e":2,"A":0,"d":1,"d":2,"\/x":"\/","k":{}}`,
			compact = `{"/x":"/","A":0,"a":null,"b":{"y":[{"p":2,"q":1}],"z":1},"ba":4,"bc":3,"d":2,"e":2,"k":{},"é":1}`,
			pretty  = "{\n  \"/x\": \"/\",\n  \"A\": 0,\n  \"a\": null,\n  \"b\": {\n    \"y\": [\n      {\n        \"p\": 2,\n        \"q\": 1\n      }\n    ],\n    \"z\": 1\n  },\n  \"ba\": 4,\n  \"bc\": 3,\n  \"d\": 2,\n  \"e\": 2,\n  \"k\": {},\n  \"é\": 1\n}",
		},
		{
			src     = "// h\n{\n  // zc\n  \"z\": 1, // tz\n  /* ib */ \"a\": /* in */ 2,\n  \"m\": {\"y\":1, // ty\n  \"x\":2 /* tx */\n  // foot\n  }\n} // end\n",
			compact = "// h\n{/* ib */\"a\":/* in */2,\"m\":{\"x\":2,/* tx */\"y\":1// ty\n// foot\n},// zc\n\"z\":1// tz\n}// end",
			pretty  = "// h\n{\n  /* ib */\n  \"a\": /* in */ 2,\n  \"m\": {\n    \"x\": 2, /* tx */\n    \"y\": 1 // ty\n    // foot\n  },\n  // zc\n  \"z\": 1 // tz\n} // end",
			dialect = .Jsonc,
		},
	}
	for c in cases {
		doc, err := json.build(transmute([]byte)c.src, {dialect = c.dialect})
		defer json.destroy(&doc)
		testing.expect(t, err == nil)
		for pretty in ([2]bool{false, true}) {
			got, merr := json.marshal(&doc, {jq_spelling = true, sort_keys = true, pretty = pretty, indent = 2, trailing_newline = true}, context.temp_allocator)
			testing.expect_value(t, merr, json.Marshal_Error.None)
			testing.expect_value(t, string(got), strings.concatenate({c.pretty if pretty else c.compact, "\n"}, context.temp_allocator))
		}
	}
	// Without `jq_spelling`, text is as authored and repeated keys keep their source order.
	doc, _ := json.build(transmute([]byte)string(`{"b":1,"a":"\/","b":2}`))
	defer json.destroy(&doc)
	got, _ := json.marshal(&doc, {sort_keys = true}, context.temp_allocator)
	testing.expect_value(t, string(got), `{"a":"\/","b":1,"b":2}`)
}

// On objects already in key order, `sort_keys` alone writes the default writer's bytes, whatever the other options.
@(test)
test_encode_opts_sort_keys_alone_changes_only_the_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src:     string,
		dialect: json.Dialect,
	}
	cases := []Case {
		{src = `{"a":[1E2,-0.50,{},[]],"b":"\/<é> ","c":{"x":true,"y":null}}`},
		{src = "{ \"a\" : [ 1 , 2 ] ,\n \"b\":{ } }"},
		{src = "// h\n{\n  /* ib */ \"a\": /* in */ 2, // ta\n  \"m\": {\"x\":2 /* tx */\n  // foot\n  },\n} // end\n", dialect = .Jsonc},
	}
	opts := []json.Marshal_Opts {
		{},
		{pretty = true},
		{pretty = true, indent = 2, trailing_newline = true},
		{ascii_only = true, escape_html = true},
	}
	for c in cases {
		doc, err := json.build(transmute([]byte)c.src, {dialect = c.dialect})
		defer json.destroy(&doc)
		testing.expect(t, err == nil)
		for o in opts {
			want, werr := json.marshal(&doc, o, context.temp_allocator)
			sorted := o
			sorted.sort_keys = true
			got, gerr := json.marshal(&doc, sorted, context.temp_allocator)
			testing.expectf(t, werr == .None && gerr == .None && string(got) == string(want), "%q %v: got %q, want %q", c.src, o, got, want)
		}
	}
}
