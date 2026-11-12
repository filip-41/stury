// The YAML writer: every yaml-test-suite document written and read back as the same value, the suite's `out.yaml` texts
// against the writer's, the quoting of computed strings, the layout, comments, tags and anchors, JSON written as YAML
// and read back over generated values, the token write, and the typed write.
package yaml_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import records "../../core/records"
import json_pkg "../../json"
import walktest "../../walktest"
import yaml ".."

PRETTY :: core.Write_Options{pretty = true, indent = 2}

@(private)
written :: proc(doc: ^core.Document, opts := PRETTY) -> (string, core.Error) {
	text, _, err := core.write(doc, opts, yaml.as(.Yaml_1_2), allocator = context.temp_allocator)
	return string(text), err
}

// `src` read as YAML and written as YAML with `opts`.
@(private)
text_of :: proc(src: string, opts := PRETTY) -> string {
	doc, err := build(src)
	if err != nil {
		return "build failed"
	}
	defer core.destroy(&doc)
	text, werr := written(&doc, opts)
	return text if werr == nil else fmt.tprintf("write failed: %v", werr)
}

// The JSON text `src` written as YAML with `opts`.
@(private)
text_of_json :: proc(src: string, opts := PRETTY) -> string {
	doc, err := json_pkg.build(transmute([]u8)src, .Json)
	if err != nil {
		return "build failed"
	}
	defer core.destroy(&doc)
	text, werr := written(&doc, opts)
	return text if werr == nil else fmt.tprintf("write failed: %v", werr)
}

// What is wrong with the documents of the suite case `c` written and read back, or "". Each document of the stream is
// written, read, compared with the one it came from, and written again for the same text. `compared` counts documents.
@(private)
round_trip :: proc(c: Case, compared: ^int) -> string {
	src, _ := read_file(c.dir, "in.yaml")
	if _, is_error := read_file(c.dir, "error"); is_error {
		return ""
	}
	it := records.open(src, yaml.as(.Yaml_1_2), .Concatenated, allocator = context.temp_allocator)
	for {
		rec, more := records.next(&it)
		if !more {
			break
		}
		doc, err := records.build(&it, rec, context.temp_allocator)
		if err != nil {
			continue
		}
		text, werr := written(&doc)
		if werr != nil {
			return fmt.tprintf("the write is %v", werr)
		}
		again, aerr := build(text)
		if aerr != nil {
			return fmt.tprintf("the written text does not read: %v\n%s", aerr, text)
		}
		if !core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&again, core.ROOT}) {
			return fmt.tprintf("the value changed\n%s", text)
		}
		// A comment a read moves to another node settles after one more write.
		second, _ := written(&again)
		if second != text {
			third_doc, terr := build(second)
			if terr != nil {
				return fmt.tprintf("the second text does not read: %v\n%s", terr, second)
			}
			third, _ := written(&third_doc)
			if third != second {
				return fmt.tprintf("the writes do not settle\n%s---\n%s---\n%s", text, second, third)
			}
		}
		core.destroy(&again)
		compared^ += 1
	}
	return ""
}

@(test)
suite_documents_read_back_as_the_same_value :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	list: [dynamic]Case
	cases(&list, SUITE_DIR, "")
	compared, failures := 0, 0
	for c in list {
		if failed := round_trip(c, &compared); failed != "" {
			failures += 1
			fmt.eprintfln("%s: %s", c.name, failed)
		}
	}
	testing.expect(t, compared > 250)
	testing.expectf(t, failures == 0, "%d cases", failures)
}

// The suite's `out.yaml` is the canonical text of a case. Its value is the value of the writer's text.
@(test)
suite_out_yaml_is_the_value_the_writer_keeps :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	list: [dynamic]Case
	cases(&list, SUITE_DIR, "")
	checked, failures := 0, 0
	for c in list {
		out, has_out := read_file(c.dir, "out.yaml")
		src, _ := read_file(c.dir, "in.yaml")
		if !has_out {
			continue
		}
		want, werr := build(string(out))
		doc, derr := build(string(src))
		if werr != nil || derr != nil {
			continue
		}
		text, err := written(&doc)
		got, gerr := build(text)
		checked += 1
		if err != nil || gerr != nil || !core.equal(core.Node_Ref{&want, core.ROOT}, core.Node_Ref{&got, core.ROOT}) {
			failures += 1
			fmt.eprintfln("%s: out.yaml and the written text differ\n%s", c.name, text)
		}
	}
	testing.expect(t, checked > 50)
	testing.expectf(t, failures == 0, "%d cases", failures)
}

// A string the 1.1 schema or the core one reads as another type is quoted, so every reader keeps it a string.
@(test)
strings_other_readers_would_retype_are_quoted :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	words := [?]string{"yes", "no", "on", "off", "y", "n", "Yes", "NO", "~", "null", "Null", "true", "False", "0123", "0o17", "0x1F", "1_000", "1e3", ".inf", "-.inf", ".NaN", "+1", "12:30:45", "2001-12-14", "=", "<<", "", " lead", "trail ", "a: b", "a #b", "- a", "? a", "&a", "*a", "!a", "%a", "@a", "`a", "{a", "[a", "a,b", "'a", "\"a", "|", ">", "#a", "---", "...", "a\tb", "a\nb", "é", "\x01"}
	for w in words {
		doc: core.Document
		src := fmt.tprintf("[%s]", json_quote(w))
		built, err := json_pkg.build(transmute([]u8)src, .Json)
		if err != nil {
			continue
		}
		doc = built
		text, werr := written(&doc)
		testing.expectf(t, werr == nil, "%q: the write is %v", w, werr)
		for style in ([?]core.Write_Options{PRETTY, {pretty = false}}) {
			out, _ := written(&doc, style)
			again, aerr := build(out)
			if !testing.expectf(t, aerr == nil, "%q: %q does not read", w, out) {
				continue
			}
			item, _ := core.child_at(&again, core.ROOT, 0)
			got, _ := core.text_clone(&again, item, context.temp_allocator)
			testing.expectf(t, core.kind(&again, item) == .String && got == w, "%q read back as %q (%v)", w, got, core.kind(&again, item))
		}
		_ = text
	}
}

@(private)
json_quote :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\t':
			strings.write_string(&b, "\\t")
		case 0 ..< 0x20:
			fmt.sbprintf(&b, "\\u%04x", c)
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

@(test)
block_layout_indents_by_the_option :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	got := text_of_json(`{"a":1,"b":[1,{"c":2,"d":[]},[3,4]],"e":{},"f":"x y"}`)
	testing.expect_value(t, got, "a: 1\nb:\n  - 1\n  - c: 2\n    d: []\n  - - 3\n    - 4\ne: {}\nf: x y\n")
	four := text_of_json(`{"a":[1,{"b":2}]}`, core.Write_Options{pretty = true, indent = 4})
	testing.expect_value(t, four, "a:\n    - 1\n    - b: 2\n")
	flow := text_of_json(`{"a":1,"b":[1,"x y",null,true],"c":{}}`, core.Write_Options{})
	testing.expect_value(t, flow, `{a: 1, b: [1, x y, null, true], c: {}}`)
}

@(test)
multi_line_strings_are_literal_blocks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	got := text_of_json(`{"a":"x\ny\n","b":"x\ny","c":"x\n\n","d":"  x\ny"}`)
	again, err := build(got)
	walktest.expect_nil(t, err)
	for pair in ([?][2]string{{"a", "x\ny\n"}, {"b", "x\ny"}, {"c", "x\n\n"}, {"d", "  x\ny"}}) {
		i, _ := core.member(&again, core.ROOT, pair[0])
		have, _ := core.text_clone(&again, i, context.temp_allocator)
		testing.expectf(t, have == pair[1], "%s is %q in %q", pair[0], have, got)
	}
	testing.expect(t, strings.contains(got, "|"))
}

@(test)
comments_tags_and_anchors_are_written_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	src := "# head\na: &x 1 # inline\nb: *x\nc: !!str 5\nd: !local\n  - e\n"
	got := text_of(src)
	for part in ([?]string{"# head", "&x 1", "# inline", "*x", "!!str 5", "!local"}) {
		testing.expectf(t, strings.contains(got, part), "%q is not in %q", part, got)
	}
	doc, _ := build(src)
	again, err := build(got)
	walktest.expect_nil(t, err)
	testing.expect(t, core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&again, core.ROOT}))
	i, _ := core.member(&again, core.ROOT, "c")
	testing.expect_value(t, core.kind(&again, i), core.Kind.String)
}

@(test)
a_stream_is_written_with_document_starts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	it := records.open(transmute([]u8)string("a: 1\n---\n- b\n---\nc\n"), yaml.as(.Yaml_1_2), .Concatenated, allocator = context.temp_allocator)
	count := 0
	for rec in records.next(&it) {
		doc, _ := records.build(&it, rec, context.temp_allocator)
		text, err := written(&doc)
		walktest.expect_nil(t, err)
		again, aerr := build(text)
		walktest.expect_nil(t, aerr)
		testing.expect(t, core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&again, core.ROOT}))
		count += 1
	}
	testing.expect_value(t, count, 3)
}

// A JSON value written as YAML and read back is the value, in block and flow style, ascii or not, sorted or not.
@(test)
json_written_as_yaml_reads_back_as_json :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	state := rand.create(20261108)
	gen := rand.default_random_generator(&state)
	context.random_generator = gen
	styles := [?]core.Write_Options{PRETTY, {pretty = true, indent = 4}, {pretty = false}, {pretty = true, indent = 2, ascii = true}, {pretty = true, indent = 2, sort_keys = true}}
	for _ in 0 ..< 300 {
		b: strings.Builder
		strings.builder_init(&b)
		random_value(&b, 4)
		src := strings.to_string(b)
		doc, err := json_pkg.build(transmute([]u8)src, .Json)
		if err != nil {
			continue
		}
		for style in styles {
			text, werr := written(&doc, style)
			if !testing.expectf(t, werr == nil, "%s: the write is %v", src, werr) {
				continue
			}
			again, aerr := build(text)
			if !testing.expectf(t, aerr == nil, "%s: %q does not read: %v", src, text, aerr) {
				continue
			}
			if !style.sort_keys {
				testing.expectf(t, core.equal(core.Node_Ref{&doc, core.ROOT}, core.Node_Ref{&again, core.ROOT}), "%s changed:\n%s", src, text)
			}
		}
	}
}

@(private)
random_value :: proc(b: ^strings.Builder, depth: int) {
	pick := rand.int_max(depth > 0 ? 8 : 5)
	switch pick {
	case 0:
		strings.write_string(b, "null")
	case 1:
		strings.write_string(b, "true" if rand.int_max(2) == 0 else "false")
	case 2:
		fmt.sbprintf(b, "%d", rand.int_max(2000) - 1000)
	case 3:
		fmt.sbprintf(b, "%v", f64(rand.int_max(100000)) / 64)
	case 4:
		pool := [?]string{"", "x", "yes", "no", "null", "0123", "a b", " a", "a ", "a: b", "# c", "x\ny", "é", "tab\t", "-", "?", "1e3", ".inf", "12:30", "=", "a\"b", "a'b", "line\n", "\u2028"}
		strings.write_string(b, json_quote(rand.choice(pool[:])))
	case 5, 6:
		strings.write_byte(b, '[')
		for i in 0 ..< rand.int_max(4) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			random_value(b, depth - 1)
		}
		strings.write_byte(b, ']')
	case:
		strings.write_byte(b, '{')
		for i in 0 ..< rand.int_max(4) {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			pool := [?]string{"a", "b", "yes", "k k", "", "0", "x:y", "null", "é", "- a"}
			strings.write_string(b, json_quote(fmt.tprintf("%s%d", rand.choice(pool[:]), i)))
			strings.write_byte(b, ':')
			random_value(b, depth - 1)
		}
		strings.write_byte(b, '}')
	}
}

@(test)
typed_values_are_marshalled_as_yaml :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	Inner :: struct {
		on:   bool,
		tags: []string,
	}
	Config :: struct {
		name:  string,
		port:  int,
		ratio: f64,
		yes:   string,
		inner: Inner,
		none:  Maybe(int),
	}
	value := Config{name = "web", port = 80, ratio = 0.5, yes = "no", inner = {on = true, tags = {"a", "b c"}}}
	text, err := yaml.marshal(value, write = PRETTY)
	walktest.expect_nil(t, err)
	got := string(text)
	testing.expect_value(t, got, "name: web\nport: 80\nratio: 0.5\n'yes': 'no'\ninner:\n  'on': true\n  tags:\n    - a\n    - b c\nnone: null\n")
	compact, cerr := yaml.marshal(value, write = core.Write_Options{})
	walktest.expect_nil(t, cerr)
	testing.expect_value(t, string(compact), `{name: web, port: 80, ratio: 0.5, 'yes': 'no', inner: {'on': true, tags: [a, b c]}, none: null}`)
}

@(test)
byte_strings_are_marshalled_as_binary_and_read_back :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	Blob :: struct {
		name: string,
		data: typed.Bytes,
		none: typed.Bytes,
	}
	value := Blob{name = "x", data = typed.Bytes([]u8{'a', 'b', 'c', 0, 0xff}), none = typed.Bytes([]u8{})}
	for layout in ([?]core.Write_Options{PRETTY, {}}) {
		text, err := yaml.marshal(value, write = layout)
		walktest.expect_nil(t, err)
		testing.expect(t, strings.contains(string(text), "!!binary YWJjAP8="), string(text))
		testing.expect(t, strings.contains(string(text), `!!binary ""`), string(text))
		back: Blob
		walktest.expect_nil(t, yaml.unmarshal(text, .Yaml_1_2, &back))
		testing.expect_value(t, string(cast([]u8)back.data), "abc\x00\xff")
		testing.expect_value(t, len(back.none), 0)
	}
}

@(test)
token_write_lays_out_the_calls :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	testing.expect_value(t, write.tokens_init(&w, yaml.as(.Yaml_1_2), PRETTY, allocator = context.temp_allocator), core.Typed_Error_Kind.None)
	write.open_object(&w)
	write.key(&w, "on")
	write.value_string(&w, "yes")
	write.key(&w, "list")
	write.open_array(&w)
	write.value_int(&w, 1)
	write.value_float(&w, 1.5)
	write.value_null(&w)
	write.close(&w)
	write.close(&w)
	bytes, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(bytes), "'on': 'yes'\nlist:\n  - 1\n  - 1.5\n  - null\n")

	flat: write.Tokens
	write.tokens_init(&flat, yaml.as(.Yaml_1_2), allocator = context.temp_allocator)
	write.open_array(&flat)
	write.value_string(&flat, "a b")
	write.value_bool(&flat, true)
	write.close(&flat)
	bytes, err = write.tokens_finish(&flat)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(bytes), "[a b, true]")
}

@(test)
token_write_nests_blocks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	w: write.Tokens
	write.tokens_init(&w, yaml.as(.Yaml_1_2), PRETTY, allocator = context.temp_allocator)
	write.open_array(&w)
	write.open_array(&w)
	write.value_int(&w, 1)
	write.value_int(&w, 2)
	write.close(&w)
	write.open_object(&w)
	write.key(&w, "a")
	write.open_object(&w)
	write.close(&w)
	write.key(&w, "b")
	write.value_string(&w, "x\ny")
	write.key(&w, "c")
	write.open_array(&w)
	write.close(&w)
	write.close(&w)
	write.close(&w)
	bytes, err := write.tokens_finish(&w)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(bytes), "- - 1\n  - 2\n- a: {}\n  b: |-\n    x\n    y\n  c: []\n")
}
