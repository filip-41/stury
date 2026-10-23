package csv_tests

import "core:mem"
import "core:strings"
import "core:testing"
import csv "../"

@(test)
test_document_columns_and_bounds :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,\"na,me\",id\n1,a,b\n2,c,d\n")
	doc, err := csv.build(src)
	defer csv.document_destroy(&doc)
	testing.expect_value(t, err, nil)
	col, ok := csv.column(&doc, "id")
	testing.expect_value(t, col, 0)
	testing.expect(t, ok)
	col, ok = csv.column(&doc, "na,me")
	testing.expect_value(t, col, 1)
	testing.expect(t, ok)
	_, ok = csv.column(&doc, "missing")
	testing.expect(t, !ok)
	_, ok = csv.get_string(&doc, 2, 0)
	testing.expect(t, !ok)
	_, ok = csv.get_string(&doc, 0, 3)
	testing.expect(t, !ok)
	_, ok = csv.get_string(&doc, -1, 0)
	testing.expect(t, !ok)
	testing.expect_value(t, csv.row_fields(&doc, 5) == nil, true)

	headerless, herr := csv.build(src, header = false)
	defer csv.document_destroy(&headerless)
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, csv.row_count(&headerless), 3)
	_, ok = csv.column(&headerless, "id")
	testing.expect(t, !ok)
	_, ok = csv.get_name(&headerless, 0)
	testing.expect(t, !ok)
}

// A document reads a text in the dialect it is built with: escapes, comment lines, a BOM, and ragged widths.
@(test)
test_document_dialects :: proc(t: ^testing.T) {
	src := transmute([]byte)string("\xEF\xBB\xBFa\tb\n# note\nx\\ty\t\\n\n")
	doc: csv.Document
	err: Maybe(csv.Error)
	doc, err = csv.build(src, TSV_COMMENTS, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, csv.row_count(&doc), 1)
	testing.expect_value(t, csv.column_count(&doc), 2)
	name, _ := csv.get_name(&doc, 0)
	testing.expect_value(t, name, "a")
	cell, _ := csv.get_string(&doc, 0, 0)
	testing.expect_value(t, cell, "x\ty")
	cell, _ = csv.get_string(&doc, 0, 1)
	testing.expect_value(t, cell, "\n")
	// The field is the span as written.
	f, found := csv.get_field(&doc, 0, 0)
	testing.expect(t, found)
	testing.expect_value(t, string(src[f.lo:f.hi]), "x\\ty")
	_, found = csv.get_field(&doc, 0, 2)
	testing.expect(t, !found)

	ragged, rerr := csv.build(transmute([]byte)string("a,b,c\n1\n2,3,4,5\n"), {ragged = true}, allocator = context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(csv.row_fields(&ragged, 0)), 1)
	testing.expect_value(t, len(csv.row_fields(&ragged, 1)), 4)
	testing.expect_value(t, csv.column_count(&ragged), 4)
	_, ok := csv.get_string(&ragged, 0, 1)
	testing.expect(t, !ok)
}

@(test)
test_document_scalars :: proc(t: ^testing.T) {
	src := transmute([]byte)string("i,f,b,s\n42,1.5,true,x\n-7,.5,false,\"1\"\n,,,\n+8,1e3,yes,\n9223372036854775808,1e999,TRUE,\n")
	doc, err := csv.build(src)
	defer csv.document_destroy(&doc)
	testing.expect_value(t, err, nil)
	i, ok := csv.get_int(&doc, 0, 0)
	testing.expect(t, ok && i == 42)
	i, ok = csv.get_int(&doc, 1, 0)
	testing.expect(t, ok && i == -7)
	i, ok = csv.get_int(&doc, 3, 0)
	testing.expect(t, ok && i == 8)
	i, ok = csv.get_int(&doc, 1, 3)
	testing.expect(t, ok && i == 1) // a quoted cell reads as unmarshal reads it
	_, ok = csv.get_int(&doc, 2, 0)
	testing.expect(t, !ok) // an empty cell is absent
	_, ok = csv.get_int(&doc, 4, 0)
	testing.expect(t, !ok) // past i64
	_, ok = csv.get_int(&doc, 0, 1)
	testing.expect(t, !ok) // not an integer
	f, fok := csv.get_float(&doc, 0, 1)
	testing.expect(t, fok && f == 1.5)
	f, fok = csv.get_float(&doc, 1, 1)
	testing.expect(t, fok && f == 0.5)
	f, fok = csv.get_float(&doc, 3, 1)
	testing.expect(t, fok && f == 1000)
	_, fok = csv.get_float(&doc, 4, 1)
	testing.expect(t, !fok)
	_, fok = csv.get_float(&doc, 2, 1)
	testing.expect(t, !fok)
	b, bok := csv.get_bool(&doc, 0, 2)
	testing.expect(t, bok && b)
	b, bok = csv.get_bool(&doc, 1, 2)
	testing.expect(t, bok && !b)
	_, bok = csv.get_bool(&doc, 3, 2)
	testing.expect(t, !bok)
	_, bok = csv.get_bool(&doc, 4, 2)
	testing.expect(t, !bok)
	s, sok := csv.get_string(&doc, 2, 3)
	testing.expect(t, sok && s == "")
}

@(test)
test_document_refusals :: proc(t: ^testing.T) {
	_, err := csv.build(transmute([]byte)string("a,b\n1\n"))
	testing.expect_value(t, err, csv.Error{kind = .Field_Count, offset = 4})
	_, err = csv.build(nil, csv.Dialect{delimiter = '"'})
	testing.expect_value(t, err, csv.Error{kind = .Bad_Option})
	_, err = csv.build(transmute([]byte)string("a,b\n1,2\n"), limits = {max_fields = 1})
	testing.expect_value(t, err, csv.Error{kind = .Limit_Fields})
	// A document of nothing is a document with no rows.
	doc, eerr := csv.build(nil)
	testing.expect_value(t, eerr, nil)
	testing.expect_value(t, csv.row_count(&doc), 0)
	csv.document_destroy(&doc)
}

@(test)
test_document_lazy_judges_strings :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\nok,\xFF\n")
	doc, err := csv.build(src, strictness = .Lazy)
	defer csv.document_destroy(&doc)
	testing.expect_value(t, err, nil)
	s, ok := csv.get_string(&doc, 0, 0)
	testing.expect(t, ok && s == "ok")
	_, ok = csv.get_string(&doc, 0, 1)
	testing.expect(t, !ok)
	_, strict := csv.build(src)
	testing.expect_value(t, strict, csv.Error{kind = .Bad_Char, offset = 7})
}

// The reserve for the rest of the text is a guess: a first row far shorter than the rest, in a heap too small to
// hold the guess, must not fail the build.
@(test)
test_document_build_without_room_for_the_guess :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "a\nb\n")
	for _ in 0 ..< 40 {
		strings.write_string(&b, "cccccccccccccccccccc\n")
	}
	src := transmute([]byte)strings.to_string(b)
	space := make([]byte, 4096, context.temp_allocator)
	arena: mem.Arena
	mem.arena_init(&arena, space)
	doc, err := csv.build(src, allocator = mem.arena_allocator(&arena))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, csv.row_count(&doc), 41)
}

// A decoded text is decoded once: a second read returns the same string, for a name and for a cell of a
// regular and of a ragged document.
@(test)
test_document_decoded_once :: proc(t: ^testing.T) {
	for ragged in ([]bool{false, true}) {
		doc, err := csv.build(transmute([]byte)string("\"a\"\"b\",c\nx,\"y\"\"\"\n\"\"\"z\",w\n"), {ragged = ragged})
		defer csv.document_destroy(&doc)
		testing.expect_value(t, err, nil)
		name, _ := csv.get_name(&doc, 0)
		again, _ := csv.get_name(&doc, 0)
		testing.expect_value(t, name, "a\"b")
		testing.expect_value(t, raw_data(again), raw_data(name))
		cell, _ := csv.get_string(&doc, 0, 1)
		testing.expect_value(t, cell, "y\"")
		cell, _ = csv.get_string(&doc, 1, 0)
		testing.expect_value(t, cell, "\"z")
		again, _ = csv.get_string(&doc, 1, 0)
		testing.expect_value(t, raw_data(again), raw_data(cell))
		cell, _ = csv.get_string(&doc, 1, 1)
		testing.expect_value(t, cell, "w")
	}
}
