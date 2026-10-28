package csv_tests

import "core:mem"
import "core:strings"
import "core:testing"
import csv "../"

// The cell of `record` (an element of the root) under `name`, or element `name` of a headerless record.
@(private = "file")
cell :: proc(doc: ^csv.Document, record: int, name: union {
		string,
		int,
	}) -> (kind: csv.Kind, text: string) {
	r := csv.child(doc, csv.ROOT, record)
	n: csv.Node
	switch v in name {
	case string:
		n = csv.child(doc, r, v)
	case int:
		n = csv.child(doc, r, v)
	}
	kind, _ = csv.kind(doc, n)
	text, _ = csv.get_string(doc, n)
	return
}

// With a header, a text is an array of objects keyed by the header's names; without, an array of arrays.
@(test)
test_document_shape :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,\"na,me\",x\n1,,\"\"\n2,\"c\"\"d\",e\n")
	doc, err := csv.build(src)
	defer csv.destroy(&doc)
	testing.expect_value(t, err, nil)
	k, _ := csv.kind(&doc, csv.ROOT)
	testing.expect_value(t, k, csv.Kind.Array)
	testing.expect_value(t, csv.child_count(&doc, csv.ROOT), 2)
	r := csv.child(&doc, csv.ROOT, 1)
	k, _ = csv.kind(&doc, r)
	testing.expect_value(t, k, csv.Kind.Object)
	testing.expect_value(t, string(csv.get_raw(&doc, r)), "2,\"c\"\"d\",e")
	keys: [dynamic]string
	defer delete(keys)
	it := csv.members(&doc, r)
	for key in csv.members(&it) {
		append(&keys, key)
	}
	testing.expect_value(t, strings.join(keys[:], "|", context.temp_allocator), "id|na,me|x")
	// An empty cell is null; a quoted `""` is the empty string.
	k, _ = cell(&doc, 0, "na,me")
	testing.expect_value(t, k, csv.Kind.Null)
	s: string
	k, s = cell(&doc, 0, "x")
	testing.expect(t, k == .String && s == "")
	_, s = cell(&doc, 1, "na,me")
	testing.expect_value(t, s, "c\"d")
	testing.expect_value(t, csv.child(&doc, r, "missing"), csv.NO_NODE)

	headerless, herr := csv.build(src, {no_header = true})
	defer csv.destroy(&headerless)
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, csv.child_count(&headerless, csv.ROOT), 3)
	k, _ = csv.kind(&headerless, csv.child(&headerless, csv.ROOT, 0))
	testing.expect_value(t, k, csv.Kind.Array)
	_, s = cell(&headerless, 0, 1)
	testing.expect_value(t, s, "na,me")
	_, ok := csv.get_key(&headerless, csv.child(&headerless, csv.child(&headerless, csv.ROOT, 0), 0))
	testing.expect(t, !ok)
}

// A quoted cell's `""` is decoded wherever it falls against the scanner's 64-byte blocks: in the cell's last
// block, in a block before it, or in the block the header ends in.
@(test)
test_document_doubled_quotes :: proc(t: ^testing.T) {
	for head in 0 ..< 140 {
		for tail in ([]int{0, 3, 70}) {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "a,\"b\"\"\"\n1,\"")
			for _ in 0 ..< head {
				strings.write_byte(&b, 'y')
			}
			strings.write_string(&b, "\"\"")
			for _ in 0 ..< tail {
				strings.write_byte(&b, 'z')
			}
			strings.write_string(&b, "\"\n2,\"")
			for _ in 0 ..< head + tail {
				strings.write_byte(&b, 'w')
			}
			strings.write_string(&b, "\"\n")
			doc, err := csv.build(transmute([]byte)strings.to_string(b), {}, context.temp_allocator)
			testing.expect_value(t, err, nil)
			_, s := cell(&doc, 0, "b\"")
			testing.expect_value(t, len(s), head + tail + 1)
			testing.expect_value(t, s[head], '"')
			_, s = cell(&doc, 1, "b\"")
			testing.expect_value(t, len(s), head + tail)
		}
		// A backslash escape at each offset, the next one 17 bytes on, in the window after.
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "a\n")
		for _ in 0 ..< head {
			strings.write_byte(&b, 'y')
		}
		strings.write_string(&b, "\\tzzzzzzzzzzzzzzzzz\\\\z\n")
		doc, err := csv.build(transmute([]byte)strings.to_string(b), {dialect = TSV_COMMENTS}, context.temp_allocator)
		testing.expect_value(t, err, nil)
		_, s := cell(&doc, 0, "a")
		testing.expect_value(t, len(s), head + 20)
		testing.expect_value(t, s[head], '\t')
		testing.expect_value(t, s[head + 18], '\\')
	}
}

// A document reads a text in the dialect it is built with: escapes, comment lines, a BOM, and ragged widths.
@(test)
test_document_dialects :: proc(t: ^testing.T) {
	src := transmute([]byte)string("\xEF\xBB\xBFa\\tb\tb\n# note\nx\\ty\t\\n\n")
	doc, err := csv.build(src, {dialect = TSV_COMMENTS}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, csv.child_count(&doc, csv.ROOT), 1)
	_, s := cell(&doc, 0, "a\tb")
	testing.expect_value(t, s, "x\ty")
	_, s = cell(&doc, 0, "b")
	testing.expect_value(t, s, "\n")
	// A cell's span is the field as written.
	r := csv.child(&doc, csv.ROOT, 0)
	testing.expect_value(t, string(csv.get_raw(&doc, csv.child(&doc, r, 0))), "x\\ty")

	ragged, rerr := csv.build(transmute([]byte)string("1\n2,3,4,5\n"), {dialect = {ragged = true}, no_header = true}, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, csv.child_count(&ragged, csv.child(&ragged, csv.ROOT, 0)), 1)
	testing.expect_value(t, csv.child_count(&ragged, csv.child(&ragged, csv.ROOT, 1)), 4)
	// Under a header, a short record lacks the members of its missing columns; a long one has no names for its
	// last cells.
	short, serr := csv.build(transmute([]byte)string("a,b,c\n1\n"), {dialect = {ragged = true}}, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, csv.child_count(&short, csv.child(&short, csv.ROOT, 0)), 1)
	_, lerr := csv.build(transmute([]byte)string("a,b\n1,2,3\n"), {dialect = {ragged = true}}, context.temp_allocator)
	testing.expect_value(t, lerr, csv_fault(4, .Field_Count))
}

@(test)
test_document_refusals :: proc(t: ^testing.T) {
	_, err := csv.build(transmute([]byte)string("a,b\n1\n"))
	testing.expect_value(t, err, csv_fault(4, .Field_Count))
	_, err = csv.build(nil, {dialect = csv.Dialect{delimiter = '"'}})
	testing.expect_value(t, err, csv.Error{kind = .Bad_Option})
	_, err = csv.build(transmute([]byte)string("a,b\n1,2\n"), {limits = {max_fields = 1}})
	testing.expect_value(t, err, csv_fault(0, .Too_Many_Fields))
	// A document of nothing is an empty array.
	doc, eerr := csv.build(nil)
	testing.expect_value(t, eerr, nil)
	testing.expect_value(t, csv.child_count(&doc, csv.ROOT), 0)
	csv.destroy(&doc)
}

// A document is built `.Strict`: every value of it is read.
@(test)
test_document_is_strict :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\nok,\xFF\n")
	_, err := csv.build(src, {strictness = .Lazy})
	testing.expect_value(t, err, csv.Error{kind = .Bad_Char, offset = 7})
}

// A header name two columns share is two members under `.Default`, `.Last` and `.All`, and `child` by key reads the
// last, as JSON's documents do; `.First` keeps the first column's member only; `.Refuse` refuses the name.
@(test)
test_document_duplicate_columns :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,\"na,me\",id\n1,a,b\n")
	for d in ([]csv.Duplicates{.Default, .Last, .All}) {
		doc, err := csv.build(src, {duplicates = d})
		testing.expect_value(t, err, nil)
		testing.expect_value(t, doc.distinct_keys, false)
		testing.expect_value(t, csv.child_count(&doc, csv.child(&doc, csv.ROOT, 0)), 3)
		_, s := cell(&doc, 0, "id")
		testing.expect_value(t, s, "b")
		csv.destroy(&doc)
	}
	first, ferr := csv.build(src, {duplicates = .First})
	defer csv.destroy(&first)
	testing.expect_value(t, ferr, nil)
	testing.expect(t, first.distinct_keys)
	r := csv.child(&first, csv.ROOT, 0)
	testing.expect_value(t, csv.child_count(&first, r), 2)
	_, s := cell(&first, 0, "id")
	testing.expect_value(t, s, "1")
	_, s = cell(&first, 0, "na,me")
	testing.expect_value(t, s, "a")
	_, err := csv.build(src, {duplicates = .Refuse})
	testing.expect_value(t, err, csv.Error{kind = .Duplicate_Key, offset = 11})
}

// The reserve for the rest of the text is an estimate. A first row far shorter than the rest, in a heap too
// small for the estimate, must not fail the build.
@(test)
test_document_build_without_room_for_the_guess :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "a\nb\n")
	for _ in 0 ..< 40 {
		strings.write_string(&b, "cccccccccccccccccccc\n")
	}
	src := transmute([]byte)strings.to_string(b)
	space := make([]byte, 12 << 10, context.temp_allocator)
	arena: mem.Arena
	mem.arena_init(&arena, space)
	doc, err := csv.build(src, allocator = mem.arena_allocator(&arena))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, csv.child_count(&doc, csv.ROOT), 41)
}

// A built document decodes every cell and name while it is built: a read returns the same string each time and
// writes nothing.
@(test)
test_document_reads_do_not_write :: proc(t: ^testing.T) {
	doc, err := csv.build(transmute([]byte)string("\"a\"\"b\",c\nx,\"y\"\"\"\n\"\"\"z\",w\n"))
	defer csv.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect(t, doc.decoded)
	r := csv.child(&doc, csv.ROOT, 1)
	name, _ := csv.get_key(&doc, csv.child(&doc, r, 0))
	again, _ := csv.get_key(&doc, csv.child(&doc, r, 0))
	testing.expect_value(t, name, "a\"b")
	testing.expect_value(t, raw_data(again), raw_data(name))
	_, s := cell(&doc, 1, "a\"b")
	testing.expect_value(t, s, "\"z")
	_, again = cell(&doc, 1, "a\"b")
	testing.expect_value(t, raw_data(again), raw_data(s))
	_, s = cell(&doc, 0, "c")
	testing.expect_value(t, s, "y\"")
}

// `header_of` reads a header record's names; `record_document` keys a later record by them, as `build` keys
// each record of a text.
@(test)
test_record_document :: proc(t: ^testing.T) {
	text := "\"a\"\"b\",c,c\n1,,\"x\"\"y\"\n"
	src := make([]byte, len(text), context.temp_allocator)
	copy(src, text)
	it := csv.records(src)
	defer csv.destroy(&it)
	head, _ := csv.next_record(&it)
	h, herr := csv.header_of(head)
	defer csv.destroy(&h)
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, strings.join(h.names, "|", context.temp_allocator), "a\"b|c|c")
	testing.expect(t, !h.distinct_keys)
	_, rerr := csv.header_of(head, .Refuse)
	testing.expect_value(t, rerr, csv.Error{kind = .Duplicate_Key, offset = 9})
	first, ferr := csv.header_of(head, .First)
	defer csv.destroy(&first)
	testing.expect_value(t, ferr, nil)
	testing.expect(t, first.distinct_keys)
	testing.expect_value(t, strings.join(first.names, "|", context.temp_allocator), "a\"b|c")
	rec, _ := csv.next_record(&it)
	doc, err := csv.record_document(rec, &h)
	defer csv.destroy(&doc)
	testing.expect_value(t, err, nil)
	// The document copies what it reads: it outlives the record's source.
	mem.zero_slice(src)
	k, _ := csv.kind(&doc, csv.ROOT)
	testing.expect_value(t, k, csv.Kind.Object)
	testing.expect_value(t, csv.child_count(&doc, csv.ROOT), 3)
	s, _ := csv.get_string(&doc, csv.child(&doc, csv.ROOT, "a\"b"))
	testing.expect_value(t, s, "1")
	s, _ = csv.get_string(&doc, csv.child(&doc, csv.ROOT, "c"))
	testing.expect_value(t, s, "x\"y")
	k, _ = csv.kind(&doc, csv.child(&doc, csv.ROOT, 1))
	testing.expect_value(t, k, csv.Kind.Null)
	testing.expect_value(t, string(csv.get_raw(&doc, csv.ROOT)), "1,,\"x\"\"y\"")

}

// `header_pick` keeps the named columns in column order, a repeated name at its last column; a record document
// of it holds only those cells.
@(test)
test_header_pick :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,a,c\n1,2,3,4\n")
	it := csv.records(src)
	defer csv.destroy(&it)
	head, _ := csv.next_record(&it)
	h, _ := csv.header_of(head)
	defer csv.destroy(&h)
	picked, err := csv.header_pick(&h, {"c", "a", "nope"})
	defer csv.destroy(&picked)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.join(picked.names, "|", context.temp_allocator), "a|c")
	rec, _ := csv.next_record(&it)
	doc, derr := csv.record_document(rec, &picked)
	defer csv.destroy(&doc)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, csv.child_count(&doc, csv.ROOT), 2)
	s, _ := csv.get_string(&doc, csv.child(&doc, csv.ROOT, "a"))
	testing.expect_value(t, s, "3")
	s, _ = csv.get_string(&doc, csv.child(&doc, csv.ROOT, "c"))
	testing.expect_value(t, s, "4")
}
