package csv_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import csv "../"

// A table of cells and the CSV that spells it: the model the document, `find` and the edits are held to.

MODEL_DIALECTS :: [?]csv.Dialect {
	{},
	csv.TSV,
	{delimiter = ';', quoting = .None},
	{comment = '#'},
	{delimiter = ',', quoting = .None, escapes = .Backslash, comment = '#'},
	{ragged = true},
	{delimiter = '\t', quoting = .None, escapes = .Backslash, comment = '#', ragged = true},
}

// The dialects that keep one width, which the column edits are defined over.
MODEL_FIXED :: 5

model_rng :: proc(s: ^u64) -> u64 {
	s^ ~= s^ << 13
	s^ ~= s^ >> 7
	s^ ~= s^ << 17
	return s^
}

// The cells `d` can spell.
model_pool :: proc(d: csv.Dialect) -> []string {
	delim := d.delimiter if d.delimiter != 0 else ','
	pool := make([dynamic]string, context.temp_allocator)
	append(&pool, "a", "", "x y", "é", "日本", "12", "-3.5", "true", "#h", "lorem ipsum dolor sit amet")
	if d.quoting == .Quotes {
		append(&pool, "q\"uote", "l1\nl2", "c\r\nd", `""`, fmt.tprintf("a%cb", delim))
	} else if d.escapes == .Backslash {
		append(&pool, "nl\nx", `back\slash`, "cr\rx", "tab\tx")
	}
	return pool[:]
}

// A cell of `pool` that reads back as a record's first when `first`: not empty, not a comment.
model_cell :: proc(s: ^u64, d: csv.Dialect, pool: []string, first: bool) -> string {
	for {
		cell := pool[model_rng(s) % u64(len(pool))]
		if !first || cell != "" && (d.comment == 0 || cell[0] != d.comment) {
			return cell
		}
	}
}

// `rows` records of cells, the first a header of unique names, all `width` wide unless `d` is ragged.
model_grid :: proc(s: ^u64, d: csv.Dialect, rows, width: int) -> [][]string {
	pool := model_pool(d)
	grid := make([][]string, rows, context.temp_allocator)
	for r in 0 ..< rows {
		n := width
		if d.ragged {
			n = 1 + int(model_rng(s) % 4)
		}
		grid[r] = make([]string, n, context.temp_allocator)
		for c in 0 ..< n {
			grid[r][c] = fmt.tprintf("c%d", c) if r == 0 else model_cell(s, d, pool, c == 0)
		}
	}
	return grid
}

// `grid` spelled in `d`, with comment lines among its records when `d` has them and every cell quoted at
// random where `d` quotes.
model_spell :: proc(s: ^u64, d: csv.Dialect, grid: [][]string, crlf, final_break, bom: bool) -> []byte {
	b := strings.builder_make(context.temp_allocator)
	br := "\r\n" if crlf else "\n"
	delim := d.delimiter if d.delimiter != 0 else ','
	if bom {
		strings.write_string(&b, "\xEF\xBB\xBF")
	}
	for row, r in grid {
		if d.comment != 0 && model_rng(s) % 6 == 0 {
			strings.write_byte(&b, d.comment)
			strings.write_string(&b, " a note, \"x\"")
			strings.write_string(&b, br)
		}
		for cell, c in row {
			if c > 0 {
				strings.write_byte(&b, delim)
			}
			model_spell_cell(&b, d, cell, model_rng(s) % 8 == 0)
		}
		if r + 1 < len(grid) || final_break {
			strings.write_string(&b, br)
		}
	}
	return b.buf[:]
}

model_spell_cell :: proc(b: ^strings.Builder, d: csv.Dialect, cell: string, quote_all: bool) {
	delim := d.delimiter if d.delimiter != 0 else ','
	switch {
	case d.quoting == .Quotes:
		if !quote_all && !strings.contains_any(cell, "\"\r\n") && !strings.contains_rune(cell, rune(delim)) {
			strings.write_string(b, cell)
			return
		}
		strings.write_byte(b, '"')
		for c in transmute([]byte)cell {
			strings.write_byte(b, c)
			if c == '"' {
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '"')
	case d.escapes == .Backslash:
		for c in transmute([]byte)cell {
			switch c {
			case '\t':
				strings.write_string(b, `\t`)
			case '\n':
				strings.write_string(b, `\n`)
			case '\r':
				strings.write_string(b, `\r`)
			case '\\':
				strings.write_string(b, `\\`)
			case:
				strings.write_byte(b, c)
			}
		}
	case:
		strings.write_string(b, cell)
	}
}

// A random table in `d` and its text.
model_text :: proc(s: ^u64, d: csv.Dialect, fixed_width := 0) -> (grid: [][]string, src: []byte) {
	rows := 1 + int(model_rng(s) % 10)
	width := fixed_width if fixed_width > 0 else 1 + int(model_rng(s) % 4)
	grid = model_grid(s, d, rows, width)
	src = model_spell(s, d, grid, model_rng(s) % 2 == 0, model_rng(s) % 2 == 0, model_rng(s) % 8 == 0)
	return
}

// Whether `doc` holds `grid`, the first record being the header.
expect_document :: proc(t: ^testing.T, doc: ^csv.Document, grid: [][]string, src: []byte, loc := #caller_location) -> bool {
	ok := testing.expectf(t, csv.row_count(doc) == len(grid) - 1, "%q: %d rows, want %d", src, csv.row_count(doc), len(grid) - 1, loc = loc)
	for r in 0 ..< min(csv.row_count(doc), len(grid) - 1) {
		cells := csv.row_fields(doc, r)
		ok &= testing.expectf(t, len(cells) == len(grid[r + 1]), "%q: row %d has %d fields, want %d", src, r, len(cells), len(grid[r + 1]), loc = loc)
		for want, c in grid[r + 1] {
			got, found := csv.get_string(doc, r, c)
			ok &= testing.expectf(t, found && got == want, "%q: cell %d,%d is %q (%v), want %q", src, r, c, got, found, want, loc = loc)
		}
	}
	for want, c in grid[0] {
		got, found := csv.get_name(doc, c)
		ok &= testing.expectf(t, found && got == want, "%q: name %d is %q (%v), want %q", src, c, got, found, want, loc = loc)
	}
	return ok
}

// `src` is CSV in `d` that reads as `grid`.
expect_reads :: proc(t: ^testing.T, src: []byte, d: csv.Dialect, grid: [][]string, loc := #caller_location) -> bool {
	if !testing.expectf(t, csv.validate(src, d) == nil, "%v %q: not CSV: %v", d, src, csv.validate(src, d), loc = loc) {
		return false
	}
	doc, err := csv.build(src, d, allocator = context.temp_allocator)
	if !testing.expectf(t, err == nil, "%v %q: build %v", d, src, err, loc = loc) {
		return false
	}
	return expect_document(t, &doc, grid, src, loc)
}

@(test)
test_document_reads_model :: proc(t: ^testing.T) {
	ds := MODEL_DIALECTS
	seed := u64(0x2545F4914F6CDD1D)
	for d in ds {
		for _ in 0 ..< 500 {
			grid, src := model_text(&seed, d)
			doc, err := csv.build(src, d)
			if !testing.expectf(t, err == nil, "%v %q: build %v", d, src, err) {
				return
			}
			if !expect_document(t, &doc, grid, src) {
				csv.document_destroy(&doc)
				return
			}
			widest := 0
			for row in grid {
				widest = max(widest, len(row))
			}
			testing.expectf(t, csv.column_count(&doc) == widest, "%v %q: %d columns, want %d", d, src, csv.column_count(&doc), widest)
			// A second read returns the same text.
			if len(grid) > 1 {
				a, _ := csv.get_string(&doc, 0, 0)
				b, _ := csv.get_string(&doc, 0, 0)
				testing.expectf(t, a == b, "%q: reads differ: %q, %q", src, a, b)
			}
			recs, _ := collect(src, d)
			for rec, r in recs[1:] {
				cells := csv.row_fields(&doc, r)
				testing.expectf(t, fmt.tprint(rec.fields) == fmt.tprint(cells), "%v %q: row %d fields %v, records %v", d, src, r, cells, rec.fields)
			}
			csv.document_destroy(&doc)
			free_all(context.temp_allocator)
		}
	}
}

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
