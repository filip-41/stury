package dsv_tests

import "base:runtime"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import gen "gen"
import walktest "../../walktest"
import dsv ".."

build :: proc(src: string, $S: dsv.Spec, opts := dsv.Options{}, dups := core.Duplicates.Last) -> (core.Document, core.Document_Error) {
	return dsv.build(transmute([]u8)src, S, opts, dups)
}

// A headed text is an `Array` of `Array` records whose first child is the header row, an `Array` of `Key` cells. The
// header's cells are the document's keys, and a cell's node is its record's node plus one plus its column.
@(test)
node_layout :: proc(t: ^testing.T) {
	src := "a,b\n1,2\n"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, len(doc.nodes), 7)
	if len(doc.nodes) != 7 {
		return
	}
	want := []walktest.Node_Want{
		{0, 7, .Array, .Value},
		{0, 3, .Array, .Key},
		{0, 1, .Plain, .Key},
		{2, 1, .Plain, .Key},
		{4, 3, .Array, .Value},
		{4, 1, .Plain, .Value},
		{6, 1, .Plain, .Value},
	}
	if !walktest.expect_nodes(t, &doc, want) {
		return
	}
	testing.expect_value(t, doc.header, 1)
	testing.expect_value(t, core.length(&doc, 0), 1)
	testing.expect_value(t, core.length(&doc, 1), 2)
	testing.expect_value(t, core.length(&doc, 4), 2)
	testing.expect_value(t, string(core.span(&doc, 0)), src)
	testing.expect_value(t, string(core.span(&doc, 1)), "a,b\n")
	testing.expect_value(t, string(core.span(&doc, 4)), "1,2\n")
	testing.expect_value(t, string(core.span(&doc, 6)), "2")
	rec, ok := core.first_child(&doc, 0)
	testing.expect(t, ok)
	testing.expect_value(t, rec, u32(4))
	cell, mok := core.member(&doc, rec, "b")
	testing.expect(t, mok)
	testing.expect_value(t, cell, u32(6))
	testing.expect(t, core.key_equals(&doc, 3, "b"))
	testing.expect_value(t, core.length(&doc, 0), 1)
}

// Without a header, a record is an `Array` of `Plain` cells.
@(test)
no_header :: proc(t: ^testing.T) {
	doc, err := build("1,2\n3,4\n", .Csv, {no_header = true})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.length(&doc, 0), 2)
	rec, ok := core.first_child(&doc, 0)
	testing.expect(t, ok)
	testing.expect_value(t, doc.nodes[rec].kind, core.Kind.Array)
	testing.expect_value(t, core.length(&doc, rec), 2)
	v, _ := core.first_child(&doc, rec)
	s, _ := core.text(&doc, v, nil)
	testing.expect_value(t, s, "1")
}

// Each cell of a headed record is one node, so `child_at` indexes a column, and a ragged record's missing columns are
// no cell. `child_at` returns the same members `child_next` walks, for every container.
@(test)
child_at_reader :: proc(t: ^testing.T) {
	doc, err := build("a,b,c\n1,2,3\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	for i in 0 ..< 3 {
		v, ok := core.child_at(&doc, rec, i)
		testing.expect(t, ok)
		testing.expect_value(t, v, rec + 1 + u32(i))
		s, _ := core.text(&doc, v, nil)
		testing.expect_value(t, s, string([]u8{u8('1' + i)}))
	}
	_, ok := core.child_at(&doc, rec, 3)
	testing.expect(t, !ok)
	_, ok = core.child_at(&doc, rec, -1)
	testing.expect(t, !ok)
	// The root holds its header row first, which `child_at` skips, so its member 0 is the first record.
	first, has := core.child_at(&doc, 0, 0)
	testing.expect(t, has)
	testing.expect_value(t, first, rec)
	_, has = core.child_at(&doc, 0, 1)
	testing.expect(t, !has)
	// The header row is an `Array`, so its cells are its children and it skips no leading key.
	key, kok := core.child_at(&doc, doc.header, 2)
	testing.expect(t, kok)
	testing.expect_value(t, key, doc.header + 3)
	core.destroy(&doc)

	// A ragged record has no cell past its last column.
	doc, err = build("a,b,c\n1,2\n", .Csv, {tolerate = {.Ragged}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	if err.kind != .None {
		return
	}
	rec, _ = core.first_child(&doc, 0)
	_, ok = core.child_at(&doc, rec, 1)
	testing.expect(t, ok)
	_, ok = core.child_at(&doc, rec, 2)
	testing.expect(t, !ok)
	v, mok := core.member(&doc, rec, "b")
	testing.expect(t, mok)
	testing.expect_value(t, v, rec + 2)
	core.destroy(&doc)

	// Without a header, every record is an `Array` of cells.
	doc, err = build("1,2\n3,4\n", .Csv, {no_header = true})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ = core.first_child(&doc, 0)
	cell, cok := core.child_at(&doc, rec, 1)
	testing.expect(t, cok)
	testing.expect_value(t, cell, rec + 2)
	_, cok = core.child_at(&doc, rec, 2)
	testing.expect(t, !cok)
}

// Checks that every container's span reaches its `End` and its length is its member count, over CSV and TSV texts,
// headed and unheaded, with quoted cells, CRLF and a last record with no line end.
@(test)
container_spans :: proc(t: ^testing.T) {
	texts := []string{
		"a,b\n1,2\n",
		"a,b\r\n1,2\r\n3,4",
		"a,b\n1,2",
		"a\n\"x,y\"\n",
		"a\tb\n1\t2\n",
		"1,2\n3,4\n",
		"1\t2\n3\t4",
		"",
		"\n\n",
	}
	for text in texts {
		for no_header in ([]bool{false, true}) {
			check_table(t, text, false, no_header)
			check_table(t, text, true, no_header)
		}
	}
}

check_table :: proc(t: ^testing.T, text: string, tsv, no_header: bool) {
	if tsv {
		check_table_spec(t, text, .Tsv, no_header)
	} else {
		check_table_spec(t, text, .Csv, no_header)
	}
}

check_table_spec :: proc(t: ^testing.T, text: string, $S: dsv.Spec, no_header: bool) {
	src := transmute([]u8)text
	log := new(walktest.Log)
	defer free(log)
	regs: core.Hook_Regs
	_, fault := dsv.walk(src, 0, S, {no_header = no_header}, log, &regs, walktest.log_hook)
	doc, err := dsv.build(src, S, {no_header = no_header})
	defer core.destroy(&doc)
	if !testing.expectf(t, (fault == nil) == (err.kind == .None), "%q %v %v: walk %v, build %v", text, S, no_header, fault, err) {
		return
	}
	if err.kind == .None {
		walktest.check_containers(t, &doc, log.tokens[:log.n])
	}
}

// A quoted cell's text drops its quotes, and `""` inside it reads as one `"`. A TSV cell decodes its backslash
// escapes.
@(test)
quoted_and_escaped :: proc(t: ^testing.T) {
	doc, err := build("a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	v, ok := core.member(&doc, rec, "a")
	testing.expect(t, ok)
	buf: [64]u8
	s, _ := core.text(&doc, v, buf[:])
	testing.expect_value(t, s, "x,y")
	v, ok = core.member(&doc, rec, "b")
	testing.expect(t, ok)
	s, _ = core.text(&doc, v, buf[:])
	testing.expect_value(t, s, "say \"hi\"")
	core.destroy(&doc)

	doc, err = build("a\tb\nx\\ty\tz\\\\w\n", .Tsv)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	if err.kind != .None {
		return
	}
	rec, _ = core.first_child(&doc, 0)
	v, ok = core.member(&doc, rec, "a")
	testing.expect(t, ok)
	s, _ = core.text(&doc, v, buf[:])
	testing.expect_value(t, s, "x\ty")
	v, ok = core.member(&doc, rec, "b")
	testing.expect(t, ok)
	s, _ = core.text(&doc, v, buf[:])
	testing.expect_value(t, s, "z\\w")
}

// `resolve` reads a cell as text by default. With `infer` it reads an unquoted empty cell as `.Null`, `true` and
// `false` as `.True` and `.False`, and a JSON number as `.Number`, while a quoted cell stays `.String`.
@(test)
resolve_infer :: proc(t: ^testing.T) {
	src := "a,b,c,d,e,f\n,true,false,1.5,007,\"1\"\n"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	want := []core.Kind{.Null, .True, .False, .Number, .String, .String}
	keys := []string{"a", "b", "c", "d", "e", "f"}
	for w, i in want {
		key := keys[i]
		v, ok := core.member(&doc, rec, key)
		testing.expectf(t, ok, "key %q", key)
		testing.expectf(t, core.kind(&doc, v) == .Plain, "key %q kind %v", key, core.kind(&doc, v))
		got := core.resolve(&doc, v, {infer = true})
		testing.expectf(t, got == w, "key %q: %v, want %v", key, got, w)
	}
	v, _ := core.member(&doc, rec, "d")
	n := core.number(&doc, v)
	testing.expect_value(t, n.kind, core.Number_Kind.Float)
	testing.expect_value(t, n.bits, 0x3ff8000000000000)
	// Without `infer` every cell is a string.
	v, _ = core.member(&doc, rec, "b")
	testing.expect_value(t, core.resolve(&doc, v, {}), core.Kind.String)
}

// A repeated header name is a duplicate under `.Refuse`, at the later cell, and `member` reads the last column by
// default.
@(test)
duplicates :: proc(t: ^testing.T) {
	doc, err := build("a,a\n1,2\n", .Csv, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 2)
	testing.expect_value(t, len(doc.nodes), 0)

	doc, err = build("a,a\n1,2\n", .Csv)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	v, ok := core.member(&doc, rec, "a", .First)
	testing.expect(t, ok)
	s, _ := core.text(&doc, v, nil)
	testing.expect_value(t, s, "1")
	v, ok = core.member(&doc, rec, "a", .Last)
	testing.expect(t, ok)
	s, _ = core.text(&doc, v, nil)
	testing.expect_value(t, s, "2")
	core.destroy(&doc)

	// A TSV cell's quotes are cell bytes, so `"q"` twice is a repeat at the second cell.
	doc, err = build("\"q\"\t\"q\"\n1\t2\n", .Tsv, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 4)
	testing.expect_value(t, len(doc.nodes), 0)
}

// A repeat in a complete header row is reported when a later record faults. The header cells are still the walk's
// tokens, since no document is built.
@(test)
refuse_header_before_fault :: proc(t: ^testing.T) {
	doc, err := build("a,a\n1,2\n3,\"x\n", .Csv, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 2)
	testing.expect_value(t, len(doc.nodes), 0)

	// Both header cells are empty, so the repeat is at the second cell's byte.
	doc, err = build(",\n1,2\n3,\"x\n", .Csv, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 1)
	testing.expect_value(t, len(doc.nodes), 0)
}

// A header repeat found before a later fault carries `.No_Memory` when `duplicate_key` cannot allocate its key table.
@(test)
refuse_fault_header_oom :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 33 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		c := 'a' + u8(i) if i < 26 else 'A' + u8(i - 26)
		if i == 32 {
			c = 'a'
		}
		strings.write_byte(&b, c)
	}
	// The first cell `a` repeats as the 33rd cell, and the unterminated quote in the only record faults.
	strings.write_string(&b, "\n\"x")
	// Allocations 0 and 1 are the node array and the open stack, 2 the header's token buffer, and 3 the key table
	// that 33 cells need.
	f: Failing_Alloc
	f.inner = context.allocator
	f.fail_at = 3
	alloc := runtime.Allocator{procedure = failing_alloc_proc, data = &f}
	doc, err := dsv.build(transmute([]u8)strings.to_string(b), .Csv, {}, .Refuse, alloc)
	testing.expectf(t, err.kind == core.Document_Error_Kind.No_Memory, "fail_at 3: %v at %d", err.kind, err.at)
	core.destroy(&doc)
}

// A record of the wrong width fails the build with `.Walk` and a `Bad_Structure` fault in `inner`.
@(test)
errors :: proc(t: ^testing.T) {
	doc, err := build("a,b\n1,2,3\n", .Csv)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Walk)
	testing.expect_value(t, err.inner.kind, core.Fault_Kind.Bad_Structure)
	testing.expect_value(t, err.inner.at, 7)
	testing.expect_value(t, len(doc.nodes), 0)

	doc, err = build("a,b\n1\n", .Csv)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Walk)
	testing.expect_value(t, err.inner.kind, core.Fault_Kind.Bad_Structure)

	b := strings.builder_make(context.temp_allocator)
	core.render_document(strings.to_writer(&b), transmute([]u8)string("a,b\n1,2,3\n"), err)
	testing.expectf(t, strings.contains(strings.to_string(b), "caused by"), "%q", strings.to_string(b))
}

// A quoted header cell's span holds its quotes, and its key text drops them.
@(test)
quoted_keys :: proc(t: ^testing.T) {
	src := "\"a\",\"b\"\n1,2\n"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	key := doc.header + 1
	testing.expect_value(t, string(core.span(&doc, key)), "\"a\"")
	testing.expect_value(t, doc.nodes[doc.header].role, core.Role.Key)
	buf: [8]u8
	s, _ := core.text(&doc, key, buf[:])
	testing.expect_value(t, s, "a")
}

// A cell tolerated by `.Invalid_Utf8` reads as U+FFFD, and the header key keeps its own text.
@(test)
invalid_utf8 :: proc(t: ^testing.T) {
	src := "a\nx\xffy\n"
	doc, err := build(src, .Csv, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	cell, _ := core.member(&doc, rec, "a")
	buf: [16]u8
	s, ok := core.text(&doc, cell, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "x\uFFFdy")
	key := doc.header + 1
	testing.expect(t, core.key_equals(&doc, key, "a"))
	testing.expect(t, !core.key_equals(&doc, key, "x\uFFFdy"))

	tsv_src := "a\tb\nx\xffy\tz\n"
	tsv, terr := build(tsv_src, .Tsv, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&tsv)
	testing.expect_value(t, terr.kind, core.Document_Error_Kind.None)
	trec, _ := core.first_child(&tsv, 0)
	tcell, _ := core.member(&tsv, trec, "a")
	s, ok = core.text(&tsv, tcell, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "x\uFFFdy")
	testing.expect(t, core.key_equals(&tsv, tsv.header + 1, "a"))

	// A header cell with ill-formed UTF-8 reads its key text with U+FFFD, and `member` finds the cell by that text.
	tkey_src := "\xffh\tb\n1\t2\n"
	tkey, tkerr := build(tkey_src, .Tsv, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&tkey)
	testing.expect_value(t, tkerr.kind, core.Document_Error_Kind.None)
	kt, kok := core.text(&tkey, tkey.header + 1, buf[:])
	testing.expect(t, kok)
	testing.expect_value(t, kt, "\uFFFdh")
	testing.expect(t, core.key_equals(&tkey, tkey.header + 1, kt))
	krec, _ := core.first_child(&tkey, 0)
	found, fok := core.member(&tkey, krec, kt)
	testing.expect(t, fok && found == krec + 1)
}

// A header of 65 or 70 cells, more than the 64-entry key table on the stack, is built without a duplicate, header only
// and with a record. Past 32 keys the duplicate check allocates its table from `allocator`.
@(test)
refuse_wide_header :: proc(t: ^testing.T) {
	for count in ([]int{65, 70}) {
		for with_record in ([]bool{false, true}) {
			b := strings.builder_make()
			for i in 0 ..< count {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				strings.write_byte(&b, 'a' + u8(i / 26))
				strings.write_byte(&b, 'a' + u8(i % 26))
			}
			if with_record {
				strings.write_byte(&b, '\n')
				for i in 0 ..< count {
					if i > 0 {
						strings.write_byte(&b, ',')
					}
					strings.write_byte(&b, '1')
				}
			}
			doc, err := build(strings.to_string(b), .Csv, {}, .Refuse)
			testing.expectf(t, err.kind == .None, "%d cells, record %v: %v", count, with_record, err)
			core.destroy(&doc)
			strings.builder_destroy(&b)
		}
	}
}

// `number` returns `.Wide` for a container and for a key. `text` and `key_equals` return no text or false for a
// container.
@(test)
readers_refuse_containers :: proc(t: ^testing.T) {
	doc, err := build(",,\n,,\n", .Csv, {no_header = true})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.number(&doc, 0).kind, core.Number_Kind.Wide)
	rec, ok := core.first_child(&doc, 0)
	testing.expect(t, ok)
	testing.expect_value(t, core.number(&doc, rec).kind, core.Number_Kind.Wide)
	_, is_int := core.int_value(&doc, rec)
	testing.expect(t, !is_int)
	core.destroy(&doc)

	doc, err = build("a\n1\n", .Csv)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.number(&doc, doc.header + 1).kind, core.Number_Kind.Wide)
	rec, _ = core.first_child(&doc, 0)
	testing.expect_value(t, core.number(&doc, rec).kind, core.Number_Kind.Wide)
}

// A quoted cell is not a number, so `resolve` reads it as `.String` and `number` as `.Wide`.
@(test)
quoted_number :: proc(t: ^testing.T) {
	doc, err := build("n\n\"1\"\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	cell, _ := core.member(&doc, rec, "n")
	testing.expect_value(t, core.resolve(&doc, cell, {infer = true}), core.Kind.String)
	testing.expect_value(t, core.number(&doc, cell).kind, core.Number_Kind.Wide)
}

// A zero-length cell at `len(src)` has no allocation behind it, and no read frees it.
@(test)
empty_tail_cell :: proc(t: ^testing.T) {
	doc, err := build("1,2,", .Csv, {no_header = true})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	cell, _ := core.next_child(&doc, rec, rec + 2)
	testing.expect_value(t, core.resolve(&doc, cell, {infer = true}), core.Kind.Null)
	testing.expect_value(t, core.number(&doc, cell).kind, core.Number_Kind.Wide)
	s, ok := core.text(&doc, cell, nil)
	testing.expect(t, ok)
	testing.expect_value(t, s, "")
}

// A read that decodes a cell allocates nothing from the document's allocator.
@(test)
read_does_not_allocate :: proc(t: ^testing.T) {
	arena: mem.Arena
	backing := make([]u8, 1 << 20, context.allocator)
	defer delete(backing)
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)
	src := transmute([]u8)string("n\n\"" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "1234567890" + "\"\n")
	doc, err := dsv.build(src, .Csv, {}, .Last, alloc)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	cell, _ := core.member(&doc, rec, "n")
	before := arena.offset
	_ = core.number(&doc, cell)
	_ = core.resolve(&doc, cell, {infer = true})
	testing.expect_value(t, arena.offset, before)
}

// Every spec's spelling table has the five read services and an edit table with `record`, `reads` and `record_sep`.
@(test)
spelling_complete :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, doc: ^core.Document) {
		s := doc.spelling
		testing.expect(t, s.text != nil && s.key_equals != nil && s.number != nil && s.resolve != nil && s.close_end != nil)
		testing.expect(t, s.edit != nil && s.edit.record != nil && s.edit.reads != nil && s.edit.record_sep != nil)
	}
	a, ea := build("a\n", .Csv)
	defer core.destroy(&a)
	b, eb := build("a\n", .Tsv)
	defer core.destroy(&b)
	c, ec := build("a\n", .Plain)
	defer core.destroy(&c)
	testing.expect_value(t, ea.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, eb.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, ec.kind, core.Document_Error_Kind.None)
	if ea.kind == .None && eb.kind == .None && ec.kind == .None {
		check(t, &a)
		check(t, &b)
		check(t, &c)
	}
}

// A header-only text still refuses a repeated name. A trailing empty header cell, or an empty cell between two others,
// is no error.
@(test)
refuse_header_only :: proc(t: ^testing.T) {
	doc, err := build("a,a\n", .Csv, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 2)
	testing.expect_value(t, len(doc.nodes), 0)
	for text in ([]string{"a,", "a,,b"}) {
		doc, err = build(text, .Csv, {}, .Refuse)
		testing.expectf(t, err.kind == .None, "%q: %v", text, err)
		core.destroy(&doc)
	}
	doc, err = build(",", .Csv, {}, .Refuse)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.at, 1)

	// A TSV header cell written `\0` and a raw NUL decode to the same text, with or without a record after.
	for text in ([]string{"\\0\t\x00", "\\0\t\x00\n", "\\0\t\x00\n1\t2\n", "\\0\t\\0\n1\t2\n", "\\0\t\\0"}) {
		doc, err = build(text, .Tsv, {}, .Refuse)
		testing.expectf(t, err.kind == .Duplicate_Key && err.at == 3, "%q: %v at %d", text, err.kind, err.at)
		core.destroy(&doc)
	}
}

// A header-only text keeps its header row and no record, and the root and header row span the whole text.
@(test)
header_only :: proc(t: ^testing.T) {
	src := "a,b\n"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, doc.header, 1)
	testing.expect_value(t, core.length(&doc, 0), 0)
	_, ok := core.first_child(&doc, 0)
	testing.expect(t, !ok)
	testing.expect_value(t, string(core.span(&doc, 0)), src)
	testing.expect_value(t, string(core.span(&doc, 1)), src)
	testing.expect_value(t, core.length(&doc, doc.header), 2)
	for text, i in ([]string{"a", "b"}) {
		cell := doc.header + 1 + u32(i)
		s, _ := core.text(&doc, cell, nil)
		testing.expect_value(t, s, text)
		testing.expect(t, core.key_equals(&doc, cell, text))
	}
	// A text with no record has no header and one root node.
	for text in ([]string{"", "\n\n", "\r\n"}) {
		d, derr := build(text, .Csv)
		testing.expectf(t, derr.kind == .None && d.header == 0 && len(d.nodes) == 1, "%q: %v header %d nodes %d", text, derr, d.header, len(d.nodes))
		testing.expect_value(t, string(core.span(&d, 0)), text)
		core.destroy(&d)
	}
}

// An empty header cell names its column, and a ragged record has no cell for the columns it lacks.
@(test)
empty_and_ragged_header_cells :: proc(t: ^testing.T) {
	doc, err := build("a,,c\n1,2,3\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	v, ok := core.member(&doc, rec, "")
	testing.expect(t, ok)
	testing.expect_value(t, v, rec + 2)
	testing.expect(t, core.key_equals(&doc, doc.header + 2, ""))
	core.destroy(&doc)

	doc, err = build("a,b,c\n1,2\n", .Csv, {tolerate = {.Ragged}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ = core.first_child(&doc, 0)
	testing.expect_value(t, core.length(&doc, rec), 2)
	v, ok = core.member(&doc, rec, "b")
	testing.expect(t, ok)
	testing.expect_value(t, v, rec + 2)
	_, ok = core.member(&doc, rec, "c")
	testing.expect(t, !ok)
	it := core.member_all(&doc, rec, "c")
	_, ok = core.member_next(&it)
	testing.expect(t, !ok)
	testing.expect_value(t, string(core.span(&doc, rec)), "1,2\n")
	core.destroy(&doc)

	// A record wider than the header is still a fault under `.Ragged`.
	doc, err = build("a,b\n1,2,3\n", .Csv, {tolerate = {.Ragged}})
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Walk)
	testing.expect_value(t, err.inner.kind, core.Fault_Kind.Bad_Structure)
	core.destroy(&doc)
}

// Duplicate header names: `.First` returns the first column, `.Last` the last, and `.All` starts at the first, with
// `member_all` returning both.
@(test)
duplicate_header_modes :: proc(t: ^testing.T) {
	doc, err := build("a,a\n1,2\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	v, ok := core.member(&doc, rec, "a", .First)
	testing.expect(t, ok)
	testing.expect_value(t, v, rec + 1)
	v, ok = core.member(&doc, rec, "a", .Last)
	testing.expect(t, ok)
	testing.expect_value(t, v, rec + 2)
	v, ok = core.member(&doc, rec, "a", .All)
	testing.expect(t, ok)
	testing.expect_value(t, v, rec + 1)
	it := core.member_all(&doc, rec, "a")
	got: [4]u32
	n := 0
	for {
		c, more := core.member_next(&it)
		if !more {
			break
		}
		got[n] = c
		n += 1
	}
	testing.expect_value(t, n, 2)
	testing.expect_value(t, got[0], rec + 1)
	testing.expect_value(t, got[1], rec + 2)
}

// With a BOM, CRLF and a last record without a line end, the root spans the whole text, the header row and each
// record span their exact source bytes after the BOM, and the root's child count is 2.
@(test)
bom_crlf_spans :: proc(t: ^testing.T) {
	src := "\xef\xbb\xbfa,b\r\n1,2\r\n3,4"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, string(core.span(&doc, 0)), src)
	testing.expect_value(t, string(core.span(&doc, doc.header)), "a,b\r\n")
	first, _ := core.first_child(&doc, 0)
	testing.expect_value(t, string(core.span(&doc, first)), "1,2\r\n")
	second, _ := core.next_child(&doc, 0, first)
	testing.expect_value(t, string(core.span(&doc, second)), "3,4")
	testing.expect_value(t, core.length(&doc, 0), 2)
	for rec in ([]u32{first, second}) {
		v, ok := core.member(&doc, rec, "b")
		testing.expect(t, ok)
		testing.expect_value(t, v, rec + 2)
		it := core.children(&doc, rec)
		for i in 0 ..< 2 {
			c, more := core.child_next(&it)
			testing.expect(t, more)
			testing.expect_value(t, c, rec + 1 + u32(i))
		}
	}
	if len(doc.nodes) > 0 {
		testing.expect_value(t, doc.nodes[0].spelling, u16(2))
	}
}

// A dsv key whose text starts and ends with the same quote byte is compared by its text, and `key_equals` and
// `member` agree with `text`.
plain_quoted_check :: proc(t: ^testing.T, src, cell: string, $S: dsv.Spec) {
	doc, err := build(src, S)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
		return
	}
	buf: [64]u8
	kt, ok := core.text(&doc, doc.header + 1, buf[:])
	testing.expectf(t, ok && kt == cell, "%q: key text %q want %q", src, kt, cell)
	testing.expectf(t, core.key_equals(&doc, doc.header + 1, kt), "%q: key_equals(%q) false", src, kt)
	rec, _ := core.first_child(&doc, 0)
	mv, mok := core.member(&doc, rec, kt, .First)
	testing.expectf(t, mok && mv == rec + 1, "%q: member(%q) -> %v %v", src, kt, mv, mok)
}

@(test)
plain_quoted_keys :: proc(t: ^testing.T) {
	plain_quoted_check(t, "'q'\n1\n", `'q'`, .Csv)
	plain_quoted_check(t, "\"q\"\n1\n", `"q"`, .Tsv)
	plain_quoted_check(t, "'q'\tx\n1\t2\n", `'q'`, .Tsv)

	// A quoted `"q"` and a bare `q` are different keys, so `member` finds column 1 for the quoted text and column 2
	// for `q`.
	doc, err := build("\"q\"\tq\n1\t2\n", .Tsv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	v1, ok1 := core.member(&doc, rec, "\"q\"", .First)
	testing.expect(t, ok1)
	s, _ := core.text(&doc, v1, nil)
	testing.expect_value(t, s, "1")
	v2, ok2 := core.member(&doc, rec, "q", .First)
	testing.expect(t, ok2)
	s, _ = core.text(&doc, v2, nil)
	testing.expect_value(t, s, "2")
	it := core.member_all(&doc, rec, "q")
	n := 0
	for {
		_, more := core.member_next(&it)
		if !more {
			break
		}
		n += 1
	}
	testing.expect_value(t, n, 1)
}

// For every column of generated CSV and TSV texts, `key_equals` and `member` find the key's own text.
@(test)
generated_keys_agree :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	for round in 0 ..< 1000 {
		tsv := round % 2 == 1
		gen.text(&text, tsv)
		no_header := round % 3 == 0
		doc: core.Document
		err: core.Document_Error
		if tsv {
			doc, err = build(string(text[:]), .Tsv, {no_header = no_header})
		} else {
			doc, err = build(string(text[:]), .Csv, {no_header = no_header})
		}
		if err.kind != .None {
			core.destroy(&doc)
			continue
		}
		// Each header cell's text is found by `key_equals`, and `member` returns a cell of the record whose header cell
		// decodes to that text, at or before this column.
		root: if !no_header && doc.header != 0 {
			col := 0
			it := core.children(&doc, doc.header)
			for {
				key, more := core.child_next(&it)
				if !more {
					break
				}
				buf: [256]u8
				kt, kok := core.text(&doc, key, buf[:])
				if !testing.expectf(t, kok, "round %d: key text failed", round) {
					break root
				}
				if !testing.expectf(t, core.key_equals(&doc, key, kt), "round %d: key_equals disagrees with text for %q", round, kt) {
					break root
				}
				recs := core.children(&doc, 0)
				for {
					rec, has_rec := core.child_next(&recs)
					if !has_rec {
						break
					}
					if col >= core.length(&doc, rec) {
						continue
					}
					mv, mok := core.member(&doc, rec, kt, .First)
					// A repeated name returns the first column, whose header cell decodes to the same text.
					ok := mok && mv > rec && mv <= rec + 1 + u32(col) && core.key_equals(&doc, doc.header + 1 + (mv - rec - 1), kt)
					if !testing.expectf(t, ok, "round %d: member %q -> %v %v, column %d of record %d", round, kt, mv, mok, col, rec) {
						break root
					}
				}
				col += 1
			}
		}
		core.destroy(&doc)
		free_all(context.temp_allocator)
	}
}

// A caller sets the delimiter and comment byte at run time, and each spec has its own default.
@(test)
dialect_options :: proc(t: ^testing.T) {
	// A CSV text with `;` as its delimiter reads a comma as a cell byte.
	doc, err := build("a;b\n1;2,3\n", .Csv, {delimiter = ';'})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	rec, _ := core.first_child(&doc, 0)
	v, ok := core.member(&doc, rec, "b")
	testing.expect(t, ok)
	s, _ := core.text(&doc, v, nil)
	testing.expect_value(t, s, "2,3")

	// Plain has no quotes and no escapes, so a quote and a backslash are cell bytes, and its default delimiter is a
	// comma.
	plain, perr := build("a|b\n\"q\"|x\\ty\n", .Plain, {delimiter = '|'})
	defer core.destroy(&plain)
	testing.expect_value(t, perr.kind, core.Document_Error_Kind.None)
	prec, _ := core.first_child(&plain, 0)
	pv, pok := core.member(&plain, prec, "a")
	testing.expect(t, pok)
	s, _ = core.text(&plain, pv, nil)
	testing.expect_value(t, s, "\"q\"")
	pv, pok = core.member(&plain, prec, "b")
	testing.expect(t, pok)
	s, _ = core.text(&plain, pv, nil)
	testing.expect_value(t, s, "x\\ty")
	// Plain reads a quote delimiter as text, since it has no quoted field.
	if pd, pderr := build("a\"b\n1\"2\n", .Plain, {delimiter = '"'}); testing.expectf(t, pderr.kind == .None, "quote delimiter: %v", pderr) {
		core.destroy(&pd)
	}

	// TSV reads backslash escapes under any delimiter.
	tsv, terr := build("a,b\nx\\ty,z\n", .Tsv, {delimiter = ','})
	defer core.destroy(&tsv)
	testing.expect_value(t, terr.kind, core.Document_Error_Kind.None)
	trec, _ := core.first_child(&tsv, 0)
	tv, tok := core.member(&tsv, trec, "a")
	testing.expect(t, tok)
	buf: [8]u8
	s, _ = core.text(&tsv, tv, buf[:])
	testing.expect_value(t, s, "x\ty")
}

// A line whose first byte is the comment byte is no record. Elsewhere, or inside a quoted field, the byte is text.
@(test)
comment_lines :: proc(t: ^testing.T) {
	src := "# a,b\n# another\n\na,b\n1,2\n# tail\n"
	doc, err := build(src, .Csv, {comment = '#'})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, doc.header, 1)
	testing.expect_value(t, core.length(&doc, 0), 1)
	rec, _ := core.first_child(&doc, 0)
	v, _ := core.member(&doc, rec, "b")
	s, _ := core.text(&doc, v, nil)
	testing.expect_value(t, s, "2")

	// The comment byte inside a quoted field, or elsewhere in a line, is a cell byte.
	doc2, err2 := build("a,b\n\"x\n#y\",z#w\n", .Csv, {comment = '#'})
	defer core.destroy(&doc2)
	testing.expect_value(t, err2.kind, core.Document_Error_Kind.None)
	rec2, _ := core.first_child(&doc2, 0)
	v2, _ := core.member(&doc2, rec2, "a")
	buf: [16]u8
	s, _ = core.text(&doc2, v2, buf[:])
	testing.expect_value(t, s, "x\n#y")
	v2, _ = core.member(&doc2, rec2, "b")
	s, _ = core.text(&doc2, v2, nil)
	testing.expect_value(t, s, "z#w")

	// A comment line before the header is skipped, and a text ending inside a comment line has no record.
	doc3, err3 := build("# head\na,b\n1,2\n# no line end", .Csv, {comment = '#'})
	defer core.destroy(&doc3)
	testing.expect_value(t, err3.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, doc3.header, 1)
	testing.expect_value(t, core.length(&doc3, 0), 1)
}

// A header cell is a key, so `number` reads it as `.Wide` and `resolve` as `.String`, as for a JSON key node.
@(test)
header_cell_is_a_key :: proc(t: ^testing.T) {
	doc, err := build("12.5,7\n1,2\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	h := doc.header
	testing.expect_value(t, doc.nodes[h + 1].role, core.Role.Key)
	testing.expect_value(t, core.number(&doc, h + 1).kind, core.Number_Kind.Wide)
	testing.expect_value(t, core.resolve(&doc, h + 1, {infer = true}), core.Kind.String)
	buf: [8]u8
	s, ok := core.text(&doc, h + 1, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "12.5")
	testing.expect(t, core.key_equals(&doc, h + 1, "12.5"))
	// A value cell of the record is still a number.
	rec, _ := core.first_child(&doc, 0)
	testing.expect_value(t, core.number(&doc, rec + 1).kind, core.Number_Kind.Int)
}

@(test)
bad_options :: proc(t: ^testing.T) {
	// CSV refuses a quote as delimiter or comment, CR, LF or a non-ASCII byte as either, and a comment equal to the
	// delimiter.
	for opts in ([]dsv.Options{
		{delimiter = '"'},
		{comment = '"'},
		{delimiter = '\n'},
		{delimiter = '\r'},
		{delimiter = 0x80},
		{delimiter = ';', comment = ';'},
		{comment = 0x80},
	}) {
		check_bad_option(t, opts, .Csv)
	}
	// TSV refuses a backslash as delimiter or comment, and `t`, `n`, `r` or `0` as delimiter.
	for opts in ([]dsv.Options{
		{delimiter = '\\'},
		{delimiter = 't'},
		{delimiter = 'n'},
		{delimiter = 'r'},
		{delimiter = '0'},
		{comment = '\\'},
		{delimiter = '\n'},
	}) {
		check_bad_option(t, opts, .Tsv)
	}
	// Plain refuses CR, LF and a non-ASCII byte, and a comment equal to the delimiter.
	for opts in ([]dsv.Options{
		{delimiter = '\n'},
		{delimiter = '\r'},
		{delimiter = 0x80},
		{delimiter = ';', comment = ';'},
	}) {
		check_bad_option(t, opts, .Plain)
	}
}

@(private)
check_bad_option :: proc(t: ^testing.T, opts: dsv.Options, $S: dsv.Spec) {
	src := transmute([]u8)string("a,b\n1,2\n")
	if f, is_bad := dsv.validate(src, S, opts).?; testing.expectf(t, is_bad && f.kind == .Bad_Option && f.at == 0, "%v %v: validate %v", S, opts, f) {
		// A bad option is in `AT_NO_BYTE`, so it names no byte.
		testing.expect(t, f.kind in core.AT_NO_BYTE)
	}
	doc, err := dsv.build(src, S, opts)
	testing.expectf(t, err.kind == .Walk && err.inner.kind == .Bad_Option, "%v %v: build %v", S, opts, err)
	testing.expect_value(t, len(doc.nodes), 0)
}

// A caller's key buffer receives the header's cells and the walk allocates none. With nil the walk allocates its own.
@(test)
caller_key_buffer :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n")
	keys := make([]core.Token, 2)
	defer delete(keys)
	log := new(walktest.Log)
	defer free(log)
	regs: core.Hook_Regs
	_, fault := dsv.walk(src, 0, .Csv, {}, log, &regs, walktest.log_hook, keys)
	testing.expect(t, fault == nil)
	testing.expect_value(t, keys[0], core.Token{0, 1, .Plain, .Key, 0})
	testing.expect_value(t, keys[1], core.Token{2, 1, .Plain, .Key, 0})
	// The walk emits no token for the header row itself, with or without the caller's buffer. Its cells' `Key` tokens
	// start at bytes 0 and 2.
	log^ = {}
	_, fault = dsv.walk(src, 0, .Csv, {}, log, &regs, walktest.log_hook)
	testing.expect(t, fault == nil)
	for tok in log.tokens[:log.n] {
		if tok.role == .Key {
			testing.expectf(t, tok.lo == 0 || tok.lo == 2, "key %v", tok)
		}
	}
}

// The header row is an `Array` of role `Key` whose cells are role `Key` too. Walking it returns every cell, since its
// cells are columns and the row skips no leading key.
@(test)
header_row_cells :: proc(t: ^testing.T) {
	src := "a,b,c\n1,2,3\n"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	if doc.header == 0 {
		return
	}
	want := []string{"a", "b", "c"}
	it := core.children(&doc, doc.header)
	for s, i in want {
		cell, ok := core.child_next(&it)
		if !testing.expectf(t, ok, "cell %d missing", i) {
			return
		}
		buf: [8]u8
		got, _ := core.text(&doc, cell, buf[:])
		testing.expect_value(t, got, s)
		testing.expect_value(t, doc.nodes[cell].role, core.Role.Key)
	}
	_, more := core.child_next(&it)
	testing.expect(t, !more)
	// The same walk through `first_child`/`next_child`, which steps over a member's key only for a `Map`.
	cell, first := core.first_child(&doc, doc.header)
	testing.expect(t, first)
	got := [3]u32{cell, 0, 0}
	for i in 1 ..< len(got) {
		next, nok := core.next_child(&doc, doc.header, got[i-1])
		if !testing.expectf(t, nok, "next cell %d missing", i) {
			return
		}
		got[i] = next
	}
	_, done := core.next_child(&doc, doc.header, got[len(got) - 1])
	testing.expect(t, !done)
}

// A document stores the delimiter and comment byte it was built with, and an edit writes and judges by them. With a
// zero option the document uses the spec's own delimiter and no comment.
@(test)
dialect_remembered :: proc(t: ^testing.T) {
	plain, perr := build("a|b\n1|2\n", .Plain, {delimiter = '|', comment = '#'})
	defer core.destroy(&plain)
	testing.expect_value(t, perr.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, plain.delimiter, u8('|'))
	testing.expect_value(t, plain.comment, u8('#'))

	csv, cerr := build("a,b\n1,2\n", .Csv)
	defer core.destroy(&csv)
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, csv.delimiter, u8(','))
	testing.expect_value(t, csv.comment, u8(0))

	tsv, terr := build("a\tb\n1\t2\n", .Tsv)
	defer core.destroy(&tsv)
	testing.expect_value(t, terr.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, tsv.delimiter, u8('\t'))
}
