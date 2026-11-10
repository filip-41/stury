// Tests that hold two formats' packages. They live apart so that no format's own suite imports the other format.
package core_test

import "core:io"
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
