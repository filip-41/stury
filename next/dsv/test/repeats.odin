package dsv_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// A table built from a header that repeats a name reads as the JSON object of the same keys built under the same
// policy: what its length counts, the order and values of its listing, and the cell each name reads, under every read
// policy.

@(private = "file")
Row_Reads :: struct {
	length:  int,
	listing: string,
	members: string,
}

// What the reads of the row at `row` of `doc` answer, as text, under read policy `dups`.
@(private = "file")
row_reads :: proc(doc: ^tape.Document, row: tape.Node_Index, names: []string, dups: tape.Duplicates) -> (got: Row_Reads) {
	r := tape.Reader{doc = doc}
	buf: [64]u8
	got.length, _, _ = tape.length(r, row, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	c, _, _ := tape.children(r, row, context.temp_allocator)
	for {
		key, value, p := tape.next_child(r, &c, dups)
		if p != .Found {
			break
		}
		named, _ := testkit.member_key(doc, c, key)
		k, _ := tape.node_text(doc, named, buf[:])
		fmt.sbprintf(&b, "%s=", k)
		v, _ := tape.node_text(doc, value, buf[:])
		fmt.sbprintf(&b, "%s;", v)
	}
	got.listing = strings.to_string(b)
	m := strings.builder_make(context.temp_allocator)
	for name in names {
		cell, p := tape.member(r, row, name, dups)
		text := ""
		if p == .Found {
			text, _ = tape.node_text(doc, cell, buf[:])
		}
		fmt.sbprintf(&m, "%s:%v:%s;", name, p, text)
	}
	got.members = strings.to_string(m)
	return
}

@(test)
tables_with_a_repeated_name_read_as_json_objects_do :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	headers := [][]string{{"a", "b", "a"}, {"a", "a"}, {"a", "b", "a", "b", "c"}, {"x", "a", "b", "a", "a"}, {"a", "b", "c"},
		{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "d", "h", "d"}}
	names := []string{"a", "b", "c", "d", "e", "h", "j", "x", "none"}
	build_policies := []tape.Duplicates{.Default, .Last, .First, .All, .Group}
	read_policies := []tape.Duplicates{.Default, .Last, .First, .All, .Group}
	for header in headers {
		csv := strings.builder_make(context.temp_allocator)
		object := strings.builder_make(context.temp_allocator)
		strings.write_string(&object, "[{")
		for name, i in header {
			sep := "," if i > 0 else ""
			fmt.sbprintf(&csv, "%s%s", sep, name)
			fmt.sbprintf(&object, "%s\"%s\":\"%d\"", sep, name, i + 1)
		}
		strings.write_string(&object, "}]")
		strings.write_byte(&csv, '\n')
		for i in 0 ..< len(header) {
			fmt.sbprintf(&csv, "%s%d", "," if i > 0 else "", i + 1)
		}
		strings.write_byte(&csv, '\n')
		for build_dups in build_policies {
			opts := tape.Options {
				dups = build_dups,
			}
			table, terr := dsv.build(transmute([]u8)strings.to_string(csv), .Csv, opts)
			defer dsv.destroy(&table)
			tree, jerr := json.build(transmute([]u8)strings.to_string(object), .Json, opts)
			defer json.destroy(&tree)
			if !testing.expectf(t, terr == nil && jerr == nil, "%v %v: %v, %v", header, build_dups, terr, jerr) {
				continue
			}
			trow, _ := tape.element({doc = &table}, tape.ROOT, 0)
			jrow, _ := tape.element({doc = &tree}, tape.ROOT, 0)
			for read in read_policies {
				want := row_reads(&tree, jrow, names, read)
				got := row_reads(&table, trow, names, read)
				testing.expectf(t, got == want, "header %v built %v read %v:\n table %v\n json  %v", header, build_dups, read, got, want)
			}
		}
	}
}
