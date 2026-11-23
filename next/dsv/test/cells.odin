package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// The node of cell `cell` of record `rec`, counting from the first record after the header, by the order a record's
// children come in. `NO_NODE` when the text has no such cell.
cell_at :: proc(doc: ^dsv.Document, rec, cell: int) -> dsv.Node_Index {
	r := dsv.Reader{doc = doc}
	row, p := dsv.element(r, dsv.ROOT, rec)
	if p != .Found {
		return dsv.NO_NODE
	}
	c, _, _ := dsv.children(r, row, context.temp_allocator)
	for k := 0; ; k += 1 {
		_, value, q := dsv.next_child(r, &c)
		if q == .Missing {
			return dsv.NO_NODE
		}
		if k == cell {
			return value
		}
	}
}

// The text of `at` in `doc`: the decoded text of a string, and the bytes of any other scalar as written.
text_of :: proc(doc: ^dsv.Document, at: dsv.Node_Index) -> (text: string, ok: bool) {
	n := doc.nodes[at]
	if n.kind == .String {
		buf := make([]u8, 256, context.temp_allocator)
		return dsv.node_text(doc, at, buf)
	}
	return string(dsv.span_bytes(doc, n.lo, n.n)), true
}

Number_Want :: enum {
	No,
	Int,
	Float,
}

Cell_Case :: struct {
	src:  string,
	spec: dsv.Spec,
	opts: dsv.Dsv_Options,
	tol:  tape.Tolerances,
	rec:  int,
	cell: int,
	text: string,
	kind: tape.Kind,
	num:  Number_Want,
}

// Every case reads one cell as text, as a kind and as a number. A text is decoded, a quoted or escaped or ill-formed
// cell is text, an unquoted empty cell is null, and `infer` reads `true` and `false` as their kinds and a JSON number as
// a number.
@(test)
cells_read_as_text_kind_and_number :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	infer := dsv.Dsv_Options {
		infer = true,
	}
	utf8: tape.Tolerances = {.Invalid_Utf8}
	row := "a,b,c,d,e,f\n,true,false,1.5,007,\"1\"\n"
	for c in ([]Cell_Case {
			{"a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", .Csv, {}, {}, 0, 0, "x,y", .String, .No},
			{"a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", .Csv, {}, {}, 0, 1, "say \"hi\"", .String, .No},
			{"a\tb\nx\\ty\tz\\\\w\n", .Tsv, {}, {}, 0, 0, "x\ty", .String, .No},
			{"a\tb\nx\\ty\tz\\\\w\n", .Tsv, {}, {}, 0, 1, "z\\w", .String, .No},
			{row, .Csv, {}, {}, 0, 0, "", .Null, .No},
			{row, .Csv, {}, {}, 0, 1, "true", .String, .No},
			{"a\tb\n\t1\n", .Tsv, {}, {}, 0, 0, "", .Null, .No},
			{row, .Csv, infer, {}, 0, 0, "", .Null, .No},
			{row, .Csv, infer, {}, 0, 1, "true", .True, .No},
			{row, .Csv, infer, {}, 0, 2, "false", .False, .No},
			{row, .Csv, infer, {}, 0, 3, "1.5", .Number, .Float},
			{row, .Csv, infer, {}, 0, 4, "007", .String, .No},
			{row, .Csv, infer, {}, 0, 5, "1", .String, .No},
			{"a,b\n\"1\",\"x\"\"y\"\n", .Csv, infer, {}, 0, 1, "x\"y", .String, .No},
			{"a\n\"\"\n", .Csv, infer, {}, 0, 0, "", .String, .No},
			{"a\n\"\"\"\"\n", .Csv, {}, {}, 0, 0, "\"", .String, .No},
			{"a\n\"\"\"\"\"\"\n", .Csv, {}, {}, 0, 0, "\"\"", .String, .No},
			{"a\n\"x\"\"\"\n", .Csv, {}, {}, 0, 0, "x\"", .String, .No},
			{"a\n\"\"\"x\"\n", .Csv, {}, {}, 0, 0, "\"x", .String, .No},
			{"a\n\"p\"\"\"\"q\"\"r\"\n", .Csv, {}, {}, 0, 0, "p\"\"q\"r", .String, .No},
			{"a\n\"two\nlines, and \"\"q\"\"\"\n", .Csv, {}, {}, 0, 0, "two\nlines, and \"q\"", .String, .No},
			{"a\n1\\02\nx\\ty\n", .Tsv, infer, {}, 0, 0, "1\x002", .String, .No},
			{"a\n1\\02\nx\\ty\n", .Tsv, infer, {}, 1, 0, "x\ty", .String, .No},
			{"a\nx\xffy\n", .Csv, {}, utf8, 0, 0, "x�y", .String, .No},
			{"a\tb\nx\xffy\tz\n", .Tsv, {}, utf8, 0, 0, "x�y", .String, .No},
			{"a,b\n1,\"x\xffy\"\n", .Csv, infer, utf8, 0, 0, "1", .Number, .Int},
			{"a,b\n1,\"x\xffy\"\n", .Csv, infer, utf8, 0, 1, "x�y", .String, .No},
			{"a\n2\nx\xffy\n", .Tsv, infer, utf8, 1, 0, "x�y", .String, .No},
			{"1,2,", .Csv, {no_header = true, infer = true}, {}, 0, 2, "", .Null, .No},
			{"a;b\n1;2,3\n", .Csv, {delimiter = ';'}, {}, 0, 1, "2,3", .String, .No},
			{"a|b\n\"q\"|x\\ty\n", .Plain, {delimiter = '|'}, {}, 0, 0, "\"q\"", .String, .No},
			{"a|b\n\"q\"|x\\ty\n", .Plain, {delimiter = '|'}, {}, 0, 1, "x\\ty", .String, .No},
			{"a,b\nx\\ty,z\n", .Tsv, {delimiter = ','}, {}, 0, 0, "x\ty", .String, .No},
			{"a\"b\n1\"2\n", .Plain, {delimiter = '"', infer = true}, {}, 0, 1, "2", .Number, .Int},
			{"a,b\n\"x\n#y\",z#w\n", .Csv, {comment = '#'}, {}, 0, 0, "x\n#y", .String, .No},
			{"a,b\n\"x\n#y\",z#w\n", .Csv, {comment = '#'}, {}, 0, 1, "z#w", .String, .No},
		}) {
		doc, err := dsv.build(transmute([]u8)c.src, c.spec, {format = c.opts, tolerate = c.tol})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err) {
			continue
		}
		node := cell_at(&doc, c.rec, c.cell)
		if !testing.expectf(t, node != dsv.NO_NODE, "%q: no cell %d,%d", c.src, c.rec, c.cell) {
			continue
		}
		text, ok := text_of(&doc, node)
		n, is_number := dsv.node_number(&doc, node)
		testing.expectf(t, ok && text == c.text, "%q %d,%d: text %q, want %q", c.src, c.rec, c.cell, text, c.text)
		testing.expectf(t, doc.nodes[node].kind == c.kind, "%q %d,%d: kind %v, want %v", c.src, c.rec, c.cell, doc.nodes[node].kind, c.kind)
		testing.expectf(t, is_number == (c.num != .No) && (!is_number || (c.num == .Int) == (n.kind == .Int)), "%q %d,%d: number %v %v, want %v", c.src, c.rec, c.cell, n, is_number, c.num)
		if c.num == .Float {
			testing.expect_value(t, n.bits, 0x3ff8000000000000)
		}
	}
}

// A cell that needs no decoding is read with no buffer, one that does is refused by a buffer too short for it, and a
// quoted empty cell in a TSV is the two quote bytes.
@(test)
cells_decode_into_the_buffer_they_are_given :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := dsv.build(transmute([]u8)string("a\n\"\"\nx\\ty\nxy\n"), .Tsv)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	for want, i in ([]string{"\"\"", "x\ty", "xy"}) {
		cell := cell_at(&doc, i, 0)
		_, none_ok := dsv.node_text(&doc, cell, nil)
		testing.expectf(t, none_ok == (want != "x\ty"), "no buffer for %q: %v", want, none_ok)
		buf: [8]u8
		_, short_ok := dsv.node_text(&doc, cell, buf[:1])
		testing.expectf(t, short_ok == (want != "x\ty"), "one byte for %q: %v", want, short_ok)
		text, ok := dsv.node_text(&doc, cell, buf[:])
		testing.expectf(t, ok && text == want, "%q: %q %v", want, text, ok)
	}
}

Key_Case :: struct {
	src:  string,
	spec: dsv.Spec,
	opts: dsv.Dsv_Options,
	tol:  tape.Tolerances,
	key:  int,
	text: string,
}

// A header cell is a key: its text drops the quotes, it is no number, it reads as a string whatever `infer` is, and
// `member` by its text finds the cell of its column.
@(test)
header_cells_read_as_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	utf8: tape.Tolerances = {.Invalid_Utf8}
	for c in ([]Key_Case {
			{"\"a\",\"b\"\n1,2\n", .Csv, {}, {}, 0, "a"},
			{"12.5,7\n1,2\n", .Csv, {infer = true}, {}, 0, "12.5"},
			{"\xffh\tb\n1\t2\n", .Tsv, {}, utf8, 0, "�h"},
			{"'q'\n1\n", .Csv, {}, {}, 0, "'q'"},
			{"\"q\"\n1\n", .Tsv, {}, {}, 0, "\"q\""},
			{"'q'\tx\n1\t2\n", .Tsv, {}, {}, 0, "'q'"},
			{"\"q\"\tq\n1\t2\n", .Tsv, {}, {}, 0, "\"q\""},
			{"\"q\"\tq\n1\t2\n", .Tsv, {}, {}, 1, "q"},
			{"a,,c\n1,2,3\n", .Csv, {}, {}, 1, ""},
		}) {
		doc, err := dsv.build(transmute([]u8)c.src, c.spec, {format = c.opts, tolerate = c.tol})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err) {
			continue
		}
		r := dsv.Reader{doc = &doc}
		row, _ := dsv.element(r, dsv.ROOT, 0)
		kids, _, _ := dsv.children(r, row, context.temp_allocator)
		key, value: dsv.Node_Index
		for k := 0; k <= c.key; k += 1 {
			key, value, _ = dsv.next_child(r, &kids)
		}
		text, ok := text_of(&doc, key)
		_, is_number := dsv.node_number(&doc, key)
		testing.expectf(t, ok && text == c.text, "%q: key text %q, want %q", c.src, text, c.text)
		testing.expectf(t, doc.nodes[key].role == .Key && doc.nodes[key].kind == .String && !is_number, "%q: key %v", c.src, doc.nodes[key])
		found, p := dsv.member(r, row, c.text, .First)
		testing.expectf(t, p == .Found && found == value, "%q: member %q is %v %v, want %v", c.src, c.text, found, p, value)
	}
}

Member_Case :: struct {
	src:   string,
	tol:   tape.Tolerances,
	name:  string,
	first: string, // the text of the cell `.First` takes, "-" for none
	last:  string,
	count: int, // the members the name groups
}

// With a repeated name `.First` takes the first column and `.Last` the last, and the name's group holds every one. A
// wide record's third column and a header cell named "3" share a name, and an empty header cell names its column.
@(test)
members_by_name_follow_the_repeat_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	ragged: tape.Tolerances = {.Ragged}
	for c in ([]Member_Case {
			{"a,a\n1,2\n", {}, "a", "1", "2", 2},
			{"\"a\",b,a\n1,2,3\n", {}, "a", "1", "3", 2},
			{"\"a\"\"\",x,\"a\"\"\"\n1,2,3\n", {}, "a\"", "1", "3", 2},
			{"3,b\n1,2,x\n", ragged, "3", "1", "x", 2},
			{"a,,c\n1,2,3\n", {}, "", "2", "2", 1},
			{"a,b,c\n1,2\n", ragged, "b", "2", "2", 1},
			{"a,b,c\n1,2\n", ragged, "c", "-", "-", 0},
			{"a,b\n1,2,3,4\n5\n", ragged, "4", "4", "4", 1},
		}) {
		doc, err := dsv.build(transmute([]u8)c.src, .Csv, {tolerate = c.tol, dups = .All})
		defer dsv.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", c.src, err)
		r := dsv.Reader{doc = &doc}
		row, _ := dsv.element(r, dsv.ROOT, 0)
		for dups, want in ([]tape.Duplicates{.First, .Last}) {
			column := c.first if want == 0 else c.last
			v, p := dsv.member(r, row, c.name, dups)
			text := "-"
			if p == .Found {
				text, _ = text_of(&doc, v)
			}
			testing.expectf(t, text == column, "%q %q %v: %q %v, want %q", c.src, c.name, dups, text, p, column)
		}
		group, p := dsv.named(r, row, c.name)
		n := 0
		if p == .Found {
			for {
				_, _, q := dsv.next_child(r, &group)
				if q == .Missing {
					break
				}
				n += 1
			}
		}
		testing.expectf(t, n == c.count, "%q %q: %d members, want %d", c.src, c.name, n, c.count)
	}
}

// Over generated texts, a record's children and `member` agree: each header text a record lists finds the cell the
// listing gives it.
@(test)
members_find_every_generated_key :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x4b3)
	defer free_all(context.temp_allocator)
	for _ in 0 ..< testkit.rounds(100) {
		src, spec, opts := random_text()
		doc, err := dsv.build(src, spec, opts)
		defer dsv.destroy(&doc)
		if err != nil || len(doc.nodes) == 0 {
			continue
		}
		r := dsv.Reader{doc = &doc}
		rows, _, _ := dsv.children(r, dsv.ROOT, context.temp_allocator)
		for {
			_, row, p := dsv.next_child(r, &rows)
			if p == .Missing {
				break
			}
			if doc.nodes[row].kind != .Object {
				continue
			}
			kids, _, _ := dsv.children(r, row, context.temp_allocator)
			for {
				key, value, q := dsv.next_child(r, &kids)
				if q == .Missing {
					break
				}
				name, _ := text_of(&doc, key)
				found, fp := dsv.member(r, row, name)
				testing.expectf(t, fp == .Found && found == value, "%q: member %q is %v %v, listed as %v", src, name, found, fp, value)
			}
		}
	}
}

// A record's cells come as far as its text goes. A ragged record has no member past its last cell, a headed record is
// indexed by name and a headless one by place, and the root holds the records alone.
@(test)
a_ragged_record_has_no_cell_past_its_last :: proc(t: ^testing.T) {
	testkit.deadline(t)
	ragged, err := dsv.build(transmute([]u8)string("a,b,c\n1,2\n"), .Csv, {tolerate = {.Ragged}})
	defer dsv.destroy(&ragged)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{doc = &ragged}
	row, _ := dsv.element(r, dsv.ROOT, 0)
	_, past := dsv.element(r, dsv.ROOT, 1)
	testing.expect_value(t, past, tape.Presence.Missing)
	n, _, _ := dsv.length(r, row, context.allocator)
	testing.expect_value(t, n, 2)
	b, bp := dsv.member(r, row, "b")
	text, _ := text_of(&ragged, b)
	testing.expect(t, bp == .Found && text == "2")
	_, cp := dsv.member(r, row, "c")
	testing.expect_value(t, cp, tape.Presence.Missing)

	headless, herr := dsv.build(transmute([]u8)string("1,2\n3,4\n"), .Csv, {format = dsv.Dsv_Options{no_header = true}})
	defer dsv.destroy(&headless)
	testing.expect_value(t, herr, nil)
	hr := dsv.Reader{doc = &headless}
	rows, _, _ := dsv.length(hr, dsv.ROOT, context.allocator)
	testing.expect_value(t, rows, 2)
	second, _ := dsv.element(hr, dsv.ROOT, 1)
	testing.expect_value(t, headless.nodes[second].kind, tape.Kind.Array)
	width, _, _ := dsv.length(hr, second, context.allocator)
	testing.expect_value(t, width, 2)
	_, outside := dsv.element(hr, second, 2)
	testing.expect_value(t, outside, tape.Presence.Missing)
	last, _ := dsv.element(hr, second, -1)
	last_text, _ := text_of(&headless, last)
	testing.expect_value(t, last_text, "4")
	_, named := dsv.member(hr, second, "a")
	testing.expect_value(t, named, tape.Presence.Wrong_Kind)
}

// A number reads of no container and no key, and a container has no text.
@(test)
readers_refuse_containers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := dsv.build(transmute([]u8)string(",,\n,,\n"), .Csv, {format = dsv.Dsv_Options{no_header = true}})
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	row, _ := dsv.element({doc = &doc}, dsv.ROOT, 0)
	for node in ([]dsv.Node_Index{dsv.ROOT, row}) {
		_, is_number := dsv.node_number(&doc, node)
		_, has_text := dsv.node_text(&doc, node, nil)
		testing.expectf(t, !is_number && !has_text, "node %d", node)
	}
}

Spelling_Case :: struct {
	cell: string,
	kind: tape.Kind,
}

// With `infer` a cell is a number only when its text is a JSON number, `true` or `false` only when it is that text, and
// a quoted cell is a string whatever it holds. Without `infer` no non-empty cell is anything but a string.
@(test)
infer_reads_each_spelling_as_one_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cells := []Spelling_Case {
		{"0", .Number}, {"-0", .Number}, {"1", .Number}, {"-12", .Number}, {"1.5", .Number}, {"-1.5e3", .Number},
		{"1E+2", .Number}, {"123456789012345678901234567890", .Number}, {"0.000001", .Number},
		{"01", .String}, {"1.", .String}, {".5", .String}, {"+1", .String}, {"-", .String}, {"1e", .String},
		{"1e+", .String}, {"0x10", .String}, {"1_0", .String}, {" 1", .String}, {"1 ", .String}, {"NaN", .String},
		{"Infinity", .String}, {"true", .True}, {"false", .False}, {"True", .String}, {"truex", .String},
		{"tru", .String}, {"f", .String}, {"t", .String}, {"abc", .String}, {"é", .String}, {"\"1\"", .String},
		{"\"1\"\"2\"", .String}, {"\"\"\"1\"\"\"", .String}, {"\"true\"", .String}, {"\"1.5\"", .String},
		{"\"a\"\"b\"", .String},
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "c\n")
	for c in cells {
		strings.write_string(&b, c.cell)
		strings.write_byte(&b, '\n')
	}
	src := transmute([]u8)strings.to_string(b)
	inferred, ierr := dsv.build(src, .Csv, {format = dsv.Dsv_Options{infer = true}})
	defer dsv.destroy(&inferred)
	plain, perr := dsv.build(src, .Csv)
	defer dsv.destroy(&plain)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, perr, nil)
	for c, i in cells {
		cell := cell_at(&inferred, i, 0)
		_, is_number := dsv.node_number(&inferred, cell)
		testing.expectf(t, inferred.nodes[cell].kind == c.kind && is_number == (c.kind == .Number), "%q: %v, want %v", c.cell, inferred.nodes[cell].kind, c.kind)
		testing.expectf(t, plain.nodes[cell_at(&plain, i, 0)].kind == .String, "%q without infer: %v", c.cell, plain.nodes[cell_at(&plain, i, 0)].kind)
	}
}

// Every container of a table counts what its children give, over CSV and TSV texts with and without a header, with
// quoted cells, CR LF and a last record with no line end.
@(test)
lengths_count_the_rows_and_cells :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for text in ([]string{"a,b\n1,2\n", "a,b\r\n1,2\r\n3,4", "a,b\n1,2", "a\n\"x,y\"\n", "a\tb\n1\t2\n", "1,2\n3,4\n", "1\t2\n3\t4", "", "\n\n"}) {
		for no_header in ([]bool{false, true}) {
			for spec in ([]dsv.Spec{.Csv, .Tsv}) {
				src := transmute([]u8)text
				opts := dsv.Options {
					format = dsv.Dsv_Options{no_header = no_header},
				}
				opts.dups = .All
		doc, err := dsv.build(src, spec, opts)
				defer dsv.destroy(&doc)
				verdict := dsv.validate(src, spec, opts)
				if !testing.expectf(t, (err == nil) == (verdict == nil), "%q %v: build %v, validate %v", text, spec, err, verdict) || err != nil {
					continue
				}
				r := dsv.Reader{doc = &doc}
				rows, _, _ := dsv.children(r, dsv.ROOT, context.temp_allocator)
				count := 0
				for {
					_, row, p := dsv.next_child(r, &rows)
					if p == .Missing {
						break
					}
					cells, _, _ := dsv.children(r, row, context.temp_allocator)
					n := 0
					for {
						_, _, q := dsv.next_child(r, &cells)
						if q == .Missing {
							break
						}
						n += 1
					}
					length, _, _ := dsv.length(r, row, context.allocator)
					testing.expectf(t, length == n, "%q %v: a record of %d cells has length %d", text, spec, n, length)
					count += 1
				}
				length, _, _ := dsv.length(r, dsv.ROOT, context.allocator)
				testing.expectf(t, length == count, "%q %v: %d records, length %d", text, spec, count, length)
			}
		}
	}
}

// A header of 65 or 70 cells builds under `.Refuse` as one of fewer, and a header of `MAX_CHILDREN` cells or more builds
// with rows that count every one of their cells.
@(test)
builds_headers_of_every_width :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	line :: proc(b: ^strings.Builder, count: int, name: bool) {
		for i in 0 ..< count {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			if name {
				strings.write_byte(b, 'a' + u8(i / 26 % 26))
				strings.write_byte(b, 'a' + u8(i % 26))
				strings.write_byte(b, 'a' + u8(i / 676))
			} else {
				strings.write_byte(b, '1')
			}
		}
	}
	for count in ([]int{65, 70}) {
		for with_record in ([]bool{false, true}) {
			b := strings.builder_make(context.temp_allocator)
			line(&b, count, true)
			if with_record {
				strings.write_byte(&b, '\n')
				line(&b, count, false)
			}
			doc, err := dsv.build(transmute([]u8)strings.to_string(b), .Csv, {dups = .Refuse})
			testing.expectf(t, err == nil, "%d cells, record %v: %v", count, with_record, err)
			dsv.destroy(&doc)
		}
	}
	for count in ([]int{int(tape.MAX_CHILDREN), int(tape.MAX_CHILDREN) + 1}) {
		b := strings.builder_make(context.temp_allocator)
		line(&b, count, true)
		for _ in 0 ..< 2 {
			strings.write_byte(&b, '\n')
			line(&b, count, false)
		}
		doc, err := dsv.build(transmute([]u8)strings.to_string(b))
		defer dsv.destroy(&doc)
		testing.expect_value(t, err, nil)
		r := dsv.Reader{doc = &doc}
		rows, _, _ := dsv.length(r, dsv.ROOT, context.allocator)
		testing.expect_value(t, rows, 2)
		for k in 0 ..< 2 {
			row, _ := dsv.element(r, dsv.ROOT, k)
			n, _, _ := dsv.length(r, row, context.allocator)
			testing.expectf(t, n == count, "record %d: %d cells, want %d", k, n, count)
		}
	}
}

// Every read takes its memory from the allocator it is given and none from the context's, and leaves nothing allocated
// once its document is destroyed.
@(test)
reads_allocate_from_their_allocator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\n1,2\n3,4\n")
	path := []tape.Step{tape.Index(1), tape.Name("a")}
	demand, _ := dsv.demand_of({path, {tape.Index(0), tape.Name("b")}})
	defer dsv.destroy(&demand)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	context.allocator = mem.panic_allocator()
	context.temp_allocator = mem.panic_allocator()
	testing.expect_value(t, dsv.validate(src, .Csv, {}, alloc), nil)
	doc, err := dsv.build(src, .Csv, {}, alloc)
	testing.expect_value(t, err, nil)
	dsv.destroy(&doc)
	answer, ferr := dsv.find(src, path, .Csv, {}, {}, alloc)
	testing.expect_value(t, ferr, nil)
	testing.expect_value(t, answer.outcome, tape.Presence.Found)
	scanned, serr := dsv.scan(src, &demand, .Csv, {}, {}, alloc)
	testing.expect_value(t, serr, nil)
	dsv.destroy(&scanned)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// A record of a headed table is read by name and a cell is read as neither a record nor a list. An index into a headed
// record, and a name or an index into a cell, are the wrong kind, and a scan keeps the record whole to the readers.
@(test)
a_cell_is_read_by_neither_name_nor_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\n1,2\n")
	doc, err := dsv.build(src)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{doc = &doc}
	row, _ := dsv.element(r, dsv.ROOT, 0)
	_, by_place := dsv.element(r, row, 1)
	testing.expect_value(t, by_place, tape.Presence.Wrong_Kind)
	cell, by_name := dsv.member(r, row, "b")
	text, _ := text_of(&doc, cell)
	testing.expect(t, by_name == .Found && text == "2")
	_, cell_by_name := dsv.member(r, cell, "a")
	testing.expect_value(t, cell_by_name, tape.Presence.Wrong_Kind)
	_, cell_by_place := dsv.element(r, cell, 0)
	testing.expect_value(t, cell_by_place, tape.Presence.Wrong_Kind)

	demand, _ := dsv.demand_of({{tape.Index(0), tape.Name("b")}})
	defer dsv.destroy(&demand)
	scanned, serr := dsv.scan(src, &demand)
	defer dsv.destroy(&scanned)
	testing.expect_value(t, serr, nil)
	sr := dsv.Reader{doc = &scanned}
	kept, _ := dsv.element(sr, dsv.ROOT, 0)
	_, in_kept := dsv.element(sr, kept, 1)
	testing.expect(t, in_kept == .Wrong_Kind)
}

// A header of distinct keys finds every column by name, keys that share a length and their first and last bytes
// included, and a key past a short record's cells answers nothing there.
@(test)
members_find_every_column_by_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	names := []string{"axb", "ayb", "a", "b", "", "q"}
	doc, err := dsv.build(transmute([]u8)string("axb,ayb,a,b,,\"q\"\n1,2,3,4,5,6\n7,8\n"), .Csv, {tolerate = {.Ragged}})
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{doc = &doc}
	long, _ := dsv.element(r, dsv.ROOT, 0)
	short, _ := dsv.element(r, dsv.ROOT, 1)
	for name, col in names {
		cell, p := dsv.member(r, long, name)
		text, _ := text_of(&doc, cell)
		testing.expectf(t, p == .Found && text == fmt.tprintf("%d", col + 1), "%q: %q %v", name, text, p)
		_, in_short := dsv.member(r, short, name)
		testing.expectf(t, (in_short == .Found) == (col < 2), "%q in the short record: %v", name, in_short)
	}
	_, none := dsv.member(r, long, "ab")
	testing.expect_value(t, none, tape.Presence.Missing)
}

// Header names that differ only in their middle are all found, in a header of 200 of them.
@(test)
members_find_names_that_differ_in_the_middle :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	COLUMNS :: 200
	b := strings.builder_make(context.temp_allocator)
	for col in 1 ..= COLUMNS {
		fmt.sbprintf(&b, "%scol_%03d_val", "," if col > 1 else "", col)
	}
	strings.write_byte(&b, '\n')
	for col in 1 ..= COLUMNS {
		fmt.sbprintf(&b, "%s%d", "," if col > 1 else "", col)
	}
	strings.write_byte(&b, '\n')
	doc, err := dsv.build(transmute([]u8)strings.to_string(b))
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{doc = &doc}
	row, _ := dsv.element(r, dsv.ROOT, 0)
	for col in 1 ..= COLUMNS {
		cell, p := dsv.member(r, row, fmt.tprintf("col_%03d_val", col))
		text, _ := text_of(&doc, cell)
		testing.expectf(t, p == .Found && text == fmt.tprintf("%d", col), "column %d: %q %v", col, text, p)
	}
}
