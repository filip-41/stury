// `xml.write` of an XML document, which reads back as the document it was written from, and of a JSON document.
package xml_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import core "../../core"
import write "../../core/write"
import json "../../json"
import xml ".."
import walktest "../../walktest"

// Writes the XML text `src` with `opts`, and returns the text.
@(private = "file")
rewritten :: proc(src: string, opts := core.Write_Options{}, read := xml.Options{}) -> (string, core.Error) {
	doc, err := xml.build(transmute([]u8)src, .Xml, read)
	if err != nil {
		return "", err
	}
	defer xml.destroy(&doc)
	text, _, werr := xml.write(&doc, .Xml, opts, allocator = context.temp_allocator)
	return string(text), werr
}

// Writes the JSON text `src` as XML.
@(private = "file")
from_json :: proc(src: string, opts := core.Write_Options{}) -> (string, int, core.Error) {
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	if err != nil {
		return "", 0, err
	}
	defer json.destroy(&doc)
	text, dropped, werr := xml.write(&doc, .Xml, opts, allocator = context.temp_allocator)
	return string(text), dropped, werr
}

// An XML document keeps its doctype, comments, instructions, attributes, namespace declarations and references as
// written, drops the white space between elements, and pretty output indents only elements with no text.
@(test)
an_xml_document_is_written_as_it_stands :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "<?xml version=\"1.0\"?>\n<!DOCTYPE r [<!ENTITY e \"E\">]>\n<!--c0--><?p0 x?>\n<r a='1&amp;' xmlns:q=\"u\"><!--c1--><q:e b=\"&e;\"/><!--c2-->\n  <n>5 &e; <![CDATA[<]]></n><m>t1<!--m--><b/>  t2</m><c><!--y--></c></r><!--c4-->\n<?p1?>"
	got, err := rewritten(src)
	walktest.expect_nil(t, err)
	testing.expect_value(t, got, "<!DOCTYPE r [<!ENTITY e \"E\">]>\n<!--c0-->\n<?p0 x?>\n<r a='1&amp;' xmlns:q=\"u\"><!--c1--><q:e b=\"&e;\"/><!--c2--><n>5 &e; <![CDATA[<]]></n><m>t1<!--m--><b/>  t2</m><c><!--y--></c></r>\n<!--c4-->\n<?p1?>")
	again, aerr := rewritten(got)
	walktest.expect_nil(t, aerr)
	testing.expect_value(t, again, got)
	pretty, perr := rewritten("<r><a><b>1</b><b>2</b></a><m>x<b/></m></r>", core.PRETTY)
	walktest.expect_nil(t, perr)
	testing.expect_value(t, pretty, "<r>\n  <a>\n    <b>1</b>\n    <b>2</b>\n  </a>\n  <m>x<b/></m>\n</r>")
}

// A JSON document is written with its members as elements, an array as repeated elements, `#text` as text, its text
// escaped and its comments where they stood. What XML cannot spell so that it reads back is refused.
@(test)
a_json_document_is_written_as_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	got, dropped, err := from_json(`// head
{"r": {"a": [1, true], "b": null, "#text": " ", "c": {"d": "<&>\r\"", "#text": "x"}, "é": "é"}}`)
	walktest.expect_nil(t, err)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, got, "<!-- head-->\n<r><a>1</a><a>true</a><b/>&#x20;<c><d>&lt;&amp;&gt;&#xd;\"</d>x</c><é>é</é></r>")
	ascii, _, aerr := from_json(`{"r": "é"}`, {ascii = true})
	walktest.expect_nil(t, aerr)
	testing.expect_value(t, ascii, "<r>&#xe9;</r>")
	back, berr := rewritten(got)
	walktest.expect_nil(t, berr)
	testing.expect_value(t, back, got)
	for refused in ([]string{`[1]`, `{"a": 1, "b": 2}`, `{"a": [1]}`, `{"r": {"a": [[1]]}}`, `{"r": {"a": []}}`, `{"r": {}}`, `{"r": ""}`, `{"r": {"#text": "x"}}`, `{"a:b": 1}`, `{"1a": 1}`, `{"r": "\u0001"}`}) {
		_, _, rerr := from_json(refused)
		e, typed_err := rerr.(core.Typed_Error)
		testing.expectf(t, typed_err && (e.kind == .Unwritable || e.kind == .Unsupported), "%s: %v", refused, rerr)
	}
	_, cut, cerr := from_json("{\"r\": 1 /* a -- b */}")
	walktest.expect_nil(t, cerr)
	testing.expect_value(t, cut, 1)
}

// The value of an XML document, a repeated name an array, is written as one element per item and an array of text runs
// as the runs, and reads back as that value, each name's elements and runs together.
@(test)
a_grouped_value_is_written_as_its_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, err := xml.build(transmute([]u8)string(`<r>a<b>1</b>c<b>2</b></r>`), .Xml)
	walktest.expect_nil(t, err)
	defer xml.destroy(&doc)
	value, _, verr := core.write(&doc, {}, json.as(.Json), allocator = context.temp_allocator)
	walktest.expect_nil(t, verr)
	testing.expect_value(t, string(value), `{"r":{"#text":["a","c"],"b":["1","2"]}}`)
	got, _, gerr := from_json(string(value))
	walktest.expect_nil(t, gerr)
	testing.expect_value(t, got, "<r>ac<b>1</b><b>2</b></r>")
	back, berr := xml.build(transmute([]u8)got, .Xml)
	walktest.expect_nil(t, berr)
	defer xml.destroy(&back)
	again, _, aerr := core.write(&back, {}, json.as(.Json), allocator = context.temp_allocator)
	walktest.expect_nil(t, aerr)
	testing.expect_value(t, string(again), `{"r":{"#text":"ac","b":["1","2"]}}`)
	_, _, rerr := from_json(`{"r": {"#text": [], "b": 1}}`)
	e, refused := rerr.(core.Typed_Error)
	testing.expect(t, refused && e.kind == .Unwritable)
}

// The token write is the element write of `write` and refuses what it refuses.
@(test)
token_write_writes_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for pretty in ([]bool{false, true}) {
		w: write.Tokens
		testing.expect_value(t, xml.tokens_init(&w, .Xml, core.PRETTY if pretty else {}, context.temp_allocator), core.Typed_Error_Kind.None)
		write.open_object(&w)
		write.key(&w, "r")
		write.open_object(&w)
		write.key(&w, "a")
		write.open_array(&w)
		write.value_int(&w, 1)
		write.value_bool(&w, true)
		write.close(&w)
		write.key(&w, "b")
		write.value_null(&w)
		write.key(&w, "c")
		write.value_string(&w, "<&>")
		write.key(&w, "d")
		write.value_float(&w, 1.5)
		write.close(&w)
		write.close(&w)
		bytes, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		want := "<r>\n  <a>1</a>\n  <a>true</a>\n  <b/>\n  <c>&lt;&amp;&gt;</c>\n  <d>1.5</d>\n</r>" if pretty else "<r><a>1</a><a>true</a><b/><c>&lt;&amp;&gt;</c><d>1.5</d></r>"
		testing.expect_value(t, string(bytes), want)
	}
	refused := [?]struct {
		calls: proc(w: ^write.Tokens),
		kind:  core.Typed_Error_Kind,
	} {
		{proc(w: ^write.Tokens) {write.value_int(w, 1)}, .Unsupported},
		{proc(w: ^write.Tokens) {write.open_object(w); write.key(w, "r"); write.open_object(w); write.close(w); write.close(w)}, .Unwritable},
		{proc(w: ^write.Tokens) {write.open_object(w); write.key(w, "r"); write.open_array(w); write.close(w); write.close(w)}, .Unwritable},
		{proc(w: ^write.Tokens) {write.open_object(w); write.key(w, "1a"); write.value_int(w, 1); write.close(w)}, .Unwritable},
		{proc(w: ^write.Tokens) {write.open_object(w); write.key(w, "r"); write.value_string(w, "\x01"); write.close(w)}, .Unwritable},
	}
	for c in refused {
		w: write.Tokens
		xml.tokens_init(&w, .Xml, allocator = context.temp_allocator)
		c.calls(&w)
		_, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, c.kind)
	}
}

// Every valid document of the W3C suite that the walk reads is written so that it reads back as the document it was
// written from, and a second write writes the first's text.
@(test)
conformance_documents_read_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !os.exists(strings.concatenate({SUITE_DIR, "files"}, context.temp_allocator)) {
		testing.fail_now(t, "the suite is not fetched: run python3 xml/test/conformance/fetch.py")
	}
	rest := CASES
	written, failures := 0, 0
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, "\t", context.temp_allocator)
		kind, path, entities := fields[0], fields[1], fields[2]
		if kind != "valid" && kind != "invalid" {
			continue
		}
		src, rerr := os.read_entire_file_from_path(strings.concatenate({SUITE_DIR, "files/", path}, context.temp_allocator), context.temp_allocator)
		if rerr != nil {
			continue
		}
		opts: xml.Options
		if entities != "none" {
			opts.tolerate = {.Unread_Entity}
		}
		want, built := canonical_text(src, opts)
		if !built {
			continue
		}
		text, err := rewritten(string(src), read = opts)
		if err != nil {
			failures += 1
			fmt.eprintfln("%s: %v", path, err)
			continue
		}
		got, back := canonical_text(transmute([]u8)text, opts)
		again, _ := rewritten(text, read = opts)
		if !back || got != want || again != text {
			failures += 1
			fmt.eprintfln("%s: reads back as %q, want %q", path, got, want)
		}
		written += 1
	}
	testing.expect(t, written > 100)
	testing.expectf(t, failures == 0, "%d documents", failures)
}
