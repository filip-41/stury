// Tests that hold two formats' packages. They live apart so that no format's own suite imports the other format.
package core_test

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:slice"
import "core:strings"
import "core:testing"
import core ".."
import compose "../compose"
import typed "../typed"
import write "../write"
import dsv "../../dsv"
import json "../../json"
import walktest "../../walktest"

// A commit to JSON refuses a delimited document before it splices, since a table is another format family.
@(test)
json_commit_refuses_table :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a\n1\n")
	doc, err := core.build(src, dsv.as(.Csv))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	out, _, cerr := compose.commit(&list, json.as(.Json))
	walktest.expect_kind(t, cerr, core.Document_Error_Kind.Bad_Spec)
	testing.expect(t, out == nil)
}

// `format` reads and writes back in the handle's format, a table as a table and a text as JSON.
@(test)
format_serves_every_format :: proc(t: ^testing.T) {
	table, terr := core.format(transmute([]u8)string("a,b\n1,\"x\"\n"), dsv.as(.Csv))
	defer delete(table)
	walktest.expect_nil(t, terr)
	testing.expect_value(t, string(table), "a,b\n1,x\n")
	text, jerr := core.format(transmute([]u8)string(`{a: [1,],}`), json.as(.Json5), core.PRETTY)
	defer delete(text)
	walktest.expect_nil(t, jerr)
	_, none := core.format(transmute([]u8)string(`1`), core.As{})
	walktest.expect_kind(t, none, core.Typed_Error_Kind.Unsupported)
}

// A pointer writes a name with `~` and `/` escaped, an index in digits, and a step with no one place as `-`.
@(test)
write_pointer_escapes_names_and_indexes :: proc(t: ^testing.T) {
	steps := []core.Step{core.Name("a/b"), core.Name("c~d"), core.Index(12), core.All{}}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, core.write_pointer(strings.to_writer(&b), steps), io.Error.None)
	testing.expect_value(t, strings.to_string(b), "/a~1b/c~0d/12/-")
	strings.builder_reset(&b)
	testing.expect_value(t, core.write_pointer(strings.to_writer(&b), nil), io.Error.None)
	testing.expect_value(t, strings.to_string(b), "")
}

// The zero `Duplicates` is the format's policy, which both formats read as `.Last`.
@(test)
default_duplicates_read_as_last :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, core.Duplicates{}, core.Duplicates.Default)
	S :: struct {
		a: i32,
	}
	by_default, by_last: S
	src := transmute([]u8)string(`{"a":1,"a":2}`)
	e := json.unmarshal(src, json.Spec.Json, &by_default, read = {}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	e = json.unmarshal(src, json.Spec.Json, &by_last, read = {dups = .Last}, opts = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, e)
	testing.expect_value(t, by_default.a, 2)
	testing.expect_value(t, by_last, by_default)
	csv := transmute([]u8)string("a,a\n1,2\n")
	d1, d2: S
	e = dsv.unmarshal(csv, dsv.Spec.Csv, &d1, read = {}, opts = {}, allocator = context.temp_allocator)
	e2 := dsv.unmarshal(csv, dsv.Spec.Csv, &d2, read = {dups = .Last}, opts = {}, allocator = context.temp_allocator)
	testing.expect_value(t, e == nil, e2 == nil)
	testing.expect_value(t, d1, d2)
}

// An error entry holds its kind, its bytes, its record and its paths, and no more than a cache line.
@(test)
error_entry_layout :: proc(t: ^testing.T) {
	testing.expect(t, size_of(core.Error_Entry) <= 128)
}

@(private = "file")
build_as :: proc(src: []u8, spec: any) -> (core.Document, core.Error) {
	return core.build(src, spec.(core.As))
}

// One edit list over a record, run on a JSON array of objects and on a CSV table, writes each format's own text.
@(test)
value_edits_write_each_formats_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rows := []struct {
		src, want: string,
		as:        core.As,
	}{
		{`[{"a":1,"b":2}]`, `[{"a":"x y","b":5}]`, json.as(.Json)},
		{"a,b\n1,2\n", "a,b\nx y,5\n", dsv.as(.Csv)},
		{"a\tb\n1\t2\n", "a\tb\nx y\t5\n", dsv.as(.Tsv)},
	}
	for row in rows {
		walktest.check(t, row.src, row.want, build_as, row.as, proc(list: ^core.Edit_List) -> core.Error {
			record, _ := core.child_at(list.doc, core.ROOT, 0)
			write.set_member(list, record, "a", "x y") or_return
			return write.set_member(list, record, "b", 5)
		})
	}
}

// A string literal and a string variable give the same bytes, and the text of a value is spelled only as `typed.Raw`.
@(test)
string_literal_and_variable_edit_alike :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := `{"a":1}`
	as := json.as(.Json)
	spelled := [3]string{`{"a":"[1]"}`, `{"a":"[1]"}`, `{"a":[1]}`}
	for i in 0 ..< 3 {
		doc, err := core.build(transmute([]u8)src, as)
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		text := "[1]"
		switch i {
		case 0:
			write.set_member(&list, core.ROOT, "a", "[1]")
		case 1:
			write.set_member(&list, core.ROOT, "a", text)
		case 2:
			write.set_member(&list, core.ROOT, "a", typed.Raw(text))
		}
		out, _, cerr := compose.commit(&list)
		defer delete(out)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(out), spelled[i])
	}
}

// A toy format over JSONC's: a property is spelled `/*!body*/` before its node, and every node reads the style "toy".
toy_prefix :: proc(doc: ^core.Document, role: core.Role, body: []u8, text: ^[dynamic]u8) -> bool {
	append(text, "/*!")
	append(text, ..body)
	append(text, "*/")
	return true
}

toy_fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Name) -> (core.Fact_Value, bool) {
	return {text = "toy"}, name == .Style
}

// A property fact set through a format that spells one is written just before its node, once, and one removed or
// replaced goes with its spelling. A spelling-borne fact is read through `Readers.fact`, a span fact over it.
@(test)
property_fact_is_written_before_its_node :: proc(t: ^testing.T) {
	doc, err := core.build(transmute([]u8)string(`{"a": 1, "b": 2}`), json.as(.Jsonc))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	edit := core.services_of(doc.as).edit^
	edit.prefix = toy_prefix
	readers := doc.readers^
	readers.fact = toy_fact
	doc.readers = &readers

	a, _ := core.member(&doc, core.ROOT, "a")
	b, _ := core.member(&doc, core.ROOT, "b")
	style, held := core.fact_value(&doc, a, .Style)
	testing.expect(t, held && style.text == "toy")
	_, tagged := core.fact_value(&doc, a, .Tag)
	testing.expect(t, !tagged)

	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	list.edit = &edit
	walktest.expect_nil(t, core.set_fact(&list, a, .Tag, "t"))
	walktest.expect_nil(t, core.set_fact(&list, b, .Anchor, "x"))
	walktest.expect_nil(t, core.set_fact(&list, b, .Tag, "y"))
	out, dropped, cerr := compose.commit(&list)
	defer delete(out)
	walktest.expect_nil(t, cerr)
	testing.expect_value(t, dropped, 0)
	testing.expect_value(t, string(out), `{"a": /*!t*/ 1, "b": /*!x*/ /*!y*/ 2}`)
}

// A property body is one non-empty line.
@(test)
property_fact_body_is_one_line :: proc(t: ^testing.T) {
	doc, _ := json.build(transmute([]u8)string(`{"a": 1}`), .Json)
	defer core.destroy(&doc)
	a, _ := core.member(&doc, core.ROOT, "a")
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	walktest.expect_kind(t, core.set_fact(&list, a, .Tag, ""), core.Document_Error_Kind.Bad_Fact)
	walktest.expect_kind(t, core.set_fact(&list, a, .Tag, "x\ny"), core.Document_Error_Kind.Bad_Fact)
}

// A toy token spelling whose start writes the site it was given.
toy_start :: proc(t: ^write.Tokens, as: core.As) -> core.Typed_Error_Kind {
	write.put_text(t.out, fmt.tprintf("%d,%v,%v:", t.site.column, t.site.flow, t.site.member))
	return .None
}

toy_value :: proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
	write.put_text(t.out, "v")
	return .None
}

// The token writer hands its start the place the text will stand, and a whole text has the zero site.
@(test)
token_writer_start_reads_the_site :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	toy := write.Token_Spelling {
		start = toy_start,
		value = toy_value,
	}
	sites := [2]core.Site{{}, {column = 6, flow = true, member = true}}
	wants := [2]string{"0,false,false:v", "6,true,true:v"}
	for site, i in sites {
		w: write.Tokens
		testing.expect_value(t, write.tokens_init(&w, core.As{}, allocator = context.temp_allocator, spell = &toy, site = site), core.Typed_Error_Kind.None)
		testing.expect_value(t, write.value_null(&w), core.Typed_Error_Kind.None)
		out, err := write.tokens_finish(&w)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(out), wants[i])
	}
}

// A toy relocation: a node moved to another place is written between angle brackets with its column, and an array
// has no spelling anywhere else.
toy_relocate :: proc(doc: ^core.Document, node: core.Node_Index, site: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	if core.kind(doc, node) == .Array {
		return nil, false
	}
	text := fmt.tprintf("<%s@%d>", core.span(doc, node), site.column)
	return slice.clone(transmute([]u8)text, allocator), site.placed
}

// A value an edit takes from its document is written with the bytes the format gives the node at its new place, and
// keeps its own in a format with no `relocate`.
@(test)
moved_node_takes_the_formats_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc, err := core.build(transmute([]u8)string("{\"a\": 1,\n  \"b\": [2]}"), json.as(.Json))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	edit := core.services_of(doc.as).edit^
	edit.relocate = toy_relocate
	a, _ := core.member(&doc, core.ROOT, "a")
	b, _ := core.member(&doc, core.ROOT, "b")
	wants := [2]string{"{\"a\": 1,\n  \"b\": 1}", "{\"a\": 1,\n  \"b\": <1@7>}"}
	for want, i in wants {
		list := core.edit_list_init(&doc)
		defer core.edit_list_destroy(&list)
		if i == 1 {
			list.edit = &edit
		}
		walktest.expect_nil(t, core.set_value(&list, b, core.Node_Ref{&doc, a}))
		if i == 1 {
			walktest.expect_kind(t, core.set_value(&list, a, core.Node_Ref{&doc, b}), core.Document_Error_Kind.Bad_Value)
			testing.expect_value(t, string(list.edits[0].text), "<1@7>")
			continue
		}
		out, _, cerr := compose.commit(&list)
		defer delete(out)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(out), want)
	}
}

// A toy commit: the source, then each edit's text after a bar, in the order recorded.
toy_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	b := make([dynamic]u8, allocator)
	append(&b, ..list.doc.src)
	for e in list.edits {
		append(&b, '|')
		append(&b, ..e.text)
	}
	return b[:], 0, {}
}

// A format that commits its own edits is handed the list as it was recorded, and a value spelled for it keeps the
// list's base layout, where a format `core/compose` commits takes the layout and the indent its site shows.
@(test)
format_commit_takes_the_list_as_recorded :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "{\n    \"a\": [\n        1\n    ]\n}"
	doc, err := core.build(transmute([]u8)src, json.as(.Json))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	held, herr := core.build(transmute([]u8)string(`[2,3]`), json.as(.Json))
	defer core.destroy(&held)
	walktest.expect_nil(t, herr)
	edit := core.services_of(doc.as).edit^
	edit.commit = toy_commit
	a, _ := core.member(&doc, core.ROOT, "a")
	wants := [2]string{"[\n        2,\n        3\n    ]", "[\n  2,\n  3\n]"}
	for want, i in wants {
		list := core.edit_list_init(&doc, context.temp_allocator)
		list.write = core.PRETTY
		if i == 1 {
			list.edit = &edit
		}
		walktest.expect_nil(t, core.set_value(&list, a, core.Node_Ref{&held, core.ROOT}))
		testing.expect_value(t, string(list.edits[0].text), want)
		out, _, cerr := compose.commit(&list, allocator = context.temp_allocator)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(out), "{\n    \"a\": [\n        2,\n        3\n    ]\n}" if i == 0 else fmt.tprintf("%s|%s", src, want))
	}
}
