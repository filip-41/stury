package csv_tests

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"
import csv "../"

// Edits held to the model: the result reads as the edited table, and every byte outside the edit is the source's.

Edit_Case :: struct {
	d:    csv.Dialect,
	src:  []byte,
	grid: [][]string,
	seed: ^u64,
}

@(test)
test_edits_against_model :: proc(t: ^testing.T) {
	ds := MODEL_DIALECTS
	seed := u64(0xD1B54A32D192ED03)
	for d in ds[:MODEL_FIXED] {
		for iter in 0 ..< 600 {
			grid, src := model_text(&seed, d)
			c := Edit_Case{d, src, grid, &seed}
			ok: bool
			switch iter % 5 {
			case 0:
				ok = edit_set_cell(t, c)
			case 1:
				ok = edit_set_column(t, c)
			case 2:
				ok = edit_remove_row(t, c)
			case 3:
				ok = edit_remove_column(t, c)
			case 4:
				ok = edit_insert_row(t, c)
			}
			if !ok {
				return
			}
			free_all(context.temp_allocator)
		}
	}
}

// `out` is `src` with `src[lo:hi]` swapped for something else.
expect_around :: proc(t: ^testing.T, src, out: []byte, lo, hi: u64, loc := #caller_location) -> bool {
	tail := len(src) - int(hi)
	ok := len(out) >= int(lo) + tail && slice.equal(out[:lo], src[:lo]) && slice.equal(out[len(out) - tail:], src[hi:])
	return testing.expectf(t, ok, "%q became %q: bytes outside [%d, %d) changed", src, out, lo, hi, loc = loc)
}

// The text of a field as written.
raw :: proc(src: []byte, f: csv.Field) -> string {
	return string(src[f.lo:f.hi])
}

// A cell that `d` can spell at column `col` of a data row. Where a first cell may not open with the comment
// byte, it does not.
edit_value :: proc(c: Edit_Case, col: int) -> string {
	return model_cell(c.seed, c.d, model_pool(c.d), col == 0)
}

edit_set_cell :: proc(t: ^testing.T, c: Edit_Case) -> bool {
	rows := len(c.grid) - 1
	if rows == 0 {
		return true
	}
	r, col := int(model_rng(c.seed) % u64(rows)), int(model_rng(c.seed) % u64(len(c.grid[0])))
	// A comment byte may lead the value of a first cell: the edit guards it, or refuses where it cannot.
	value := edit_value(c, col)
	if col == 0 && model_rng(c.seed) % 4 == 0 && c.d.comment != 0 {
		value = "#guarded"
	}
	doc, _ := csv.build(c.src, c.d, allocator = context.temp_allocator)
	f, _ := csv.get_field(&doc, r, col)
	path := fmt.tprintf(".[%d].c%d", r, col)
	out, err := csv.set(c.src, path, value, c.d, allocator = context.temp_allocator)
	if e, refused := err.?; refused {
		unspellable := e.kind == .Encode && e.encode == .Unwritable
		return testing.expectf(t, unspellable && c.d.quoting == .None, "%v %q set %s %q: %v", c.d, c.src, path, value, e)
	}
	grid := slice.clone(c.grid, context.temp_allocator)
	grid[r + 1] = slice.clone(grid[r + 1], context.temp_allocator)
	grid[r + 1][col] = value
	return expect_around(t, c.src, out, f.lo, f.hi) && expect_reads(t, out, c.d, grid)
}

edit_set_column :: proc(t: ^testing.T, c: Edit_Case) -> bool {
	col := int(model_rng(c.seed) % u64(len(c.grid[0])))
	value := edit_value(c, col)
	path := fmt.tprintf(".[].c%d", col)
	out, err := csv.set(c.src, path, value, c.d, allocator = context.temp_allocator)
	if len(c.grid) == 1 {
		e, _ := err.?
		return testing.expectf(t, e.kind == .Not_Found, "%v %q set %s: %v", c.d, c.src, path, err)
	}
	if !testing.expectf(t, err == nil, "%v %q set %s %q: %v", c.d, c.src, path, value, err) {
		return false
	}
	grid := slice.clone(c.grid, context.temp_allocator)
	for r in 1 ..< len(grid) {
		grid[r] = slice.clone(grid[r], context.temp_allocator)
		grid[r][col] = value
	}
	if !expect_reads(t, out, c.d, grid) {
		return false
	}
	// Every other cell keeps its bytes.
	old, _ := csv.build(c.src, c.d, allocator = context.temp_allocator)
	now, _ := csv.build(out, c.d, allocator = context.temp_allocator)
	for r in 0 ..< csv.row_count(&old) {
		for k in 0 ..< len(c.grid[0]) {
			a, _ := csv.get_field(&old, r, k)
			b, _ := csv.get_field(&now, r, k)
			if k != col && !testing.expectf(t, raw(c.src, a) == raw(out, b), "%v %q: cell %d,%d changed", c.d, c.src, r, k) {
				return false
			}
		}
	}
	return true
}

edit_remove_row :: proc(t: ^testing.T, c: Edit_Case) -> bool {
	rows := len(c.grid) - 1
	r := int(model_rng(c.seed) % u64(rows + 1))
	path := fmt.tprintf(".[%d]", r)
	out, err := csv.remove(c.src, path, c.d, allocator = context.temp_allocator)
	if r == rows {
		e, _ := err.?
		return testing.expectf(t, e.kind == .Not_Found, "%v %q remove %s: %v", c.d, c.src, path, err)
	}
	if !testing.expectf(t, err == nil, "%v %q remove %s: %v", c.d, c.src, path, err) {
		return false
	}
	recs, _ := collect(c.src, c.d)
	lo, hi := recs[r + 1].at, record_end(c.src, recs[r + 1])
	grid := slice.clone(c.grid, context.temp_allocator)
	grid = slice.concatenate([][][]string{grid[:r + 1], grid[r + 2:]}, context.temp_allocator)
	return expect_around(t, c.src, out, lo, hi) && len(out) == len(c.src) - int(hi - lo) && expect_reads(t, out, c.d, grid)
}

// Where the line break after `rec` ends.
record_end :: proc(src: []byte, rec: csv.Record) -> u64 {
	i := rec.fields[len(rec.fields) - 1].hi
	if i < u64(len(src)) && src[i] == '\r' {
		i += 1
	}
	if i < u64(len(src)) && src[i] == '\n' {
		i += 1
	}
	return i
}

edit_remove_column :: proc(t: ^testing.T, c: Edit_Case) -> bool {
	width := len(c.grid[0])
	col := int(model_rng(c.seed) % u64(width))
	path := fmt.tprintf(".[].c%d", col)
	out, err := csv.remove(c.src, path, c.d, allocator = context.temp_allocator)
	old, _ := csv.build(c.src, c.d, allocator = context.temp_allocator)
	// A record whose next field would open as a comment, and a column that is all there is, are refused.
	refused := width == 1
	if width == 2 {
		for r in 0 ..< csv.row_count(&old) {
			f, _ := csv.get_field(&old, r, 1 - col)
			refused ||= f.lo == f.hi
		}
	}
	if col == 0 && c.d.comment != 0 && width > 1 {
		for r in 0 ..< csv.row_count(&old) {
			f, _ := csv.get_field(&old, r, 1)
			refused ||= f.lo < f.hi && c.src[f.lo] == c.d.comment
		}
		f, _ := csv.get_name(&old, 1)
		refused ||= f[0] == c.d.comment
	}
	if refused {
		e, _ := err.?
		return testing.expectf(t, e.kind == .Unplaceable, "%v %q remove %s: %v", c.d, c.src, path, err)
	}
	if !testing.expectf(t, err == nil, "%v %q remove %s: %v", c.d, c.src, path, err) {
		return false
	}
	grid := slice.clone(c.grid, context.temp_allocator)
	for r in 0 ..< len(grid) {
		grid[r] = slice.concatenate([][]string{c.grid[r][:col], c.grid[r][col + 1:]}, context.temp_allocator)
	}
	if !expect_reads(t, out, c.d, grid) {
		return false
	}
	now, _ := csv.build(out, c.d, allocator = context.temp_allocator)
	for r in 0 ..< csv.row_count(&old) {
		for k in 0 ..< width {
			if k == col {
				continue
			}
			a, _ := csv.get_field(&old, r, k)
			b, _ := csv.get_field(&now, r, k if k < col else k - 1)
			if !testing.expectf(t, raw(c.src, a) == raw(out, b), "%v %q: cell %d,%d changed", c.d, c.src, r, k) {
				return false
			}
		}
	}
	return true
}

edit_insert_row :: proc(t: ^testing.T, c: Edit_Case) -> bool {
	rows, width := len(c.grid) - 1, len(c.grid[0])
	at := int(model_rng(c.seed) % u64(rows + 1))
	cells := make([]string, width, context.temp_allocator)
	for k in 0 ..< width {
		cells[k] = edit_value(c, k)
	}
	out, err := csv.insert(c.src, csv.APPEND if at == rows else at, cells, c.d, allocator = context.temp_allocator)
	if !testing.expectf(t, err == nil, "%v %q insert %d %q: %v", c.d, c.src, at, cells, err) {
		return false
	}
	recs, _ := collect(c.src, c.d)
	pos := recs[at + 1].at if at < rows else u64(len(c.src))
	grid := slice.concatenate([][][]string{c.grid[:at + 1], {cells}, c.grid[at + 1:]}, context.temp_allocator)
	around := expect_around(t, c.src, out, pos, pos)
	if at == rows && len(c.src) > 0 && c.src[len(c.src) - 1] != '\n' {
		// The break goes before a record at the end of a text that has none.
		around = testing.expectf(t, slice.equal(out[:len(c.src)], c.src), "%q became %q: the source did not stay a prefix", c.src, out)
	}
	return around && expect_reads(t, out, c.d, grid)
}

@(test)
test_set_values :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,c\n1,2,3\n4,5,6\n")
	expect_set(t, src, ".[0].a", 42, "a,b,c\n42,2,3\n4,5,6\n")
	expect_set(t, src, ".[1][2]", -1.5, "a,b,c\n1,2,3\n4,5,-1.5\n")
	expect_set(t, src, ".[0].b", true, "a,b,c\n1,true,3\n4,5,6\n")
	expect_set(t, src, ".[0].b", "x,y", "a,b,c\n1,\"x,y\",3\n4,5,6\n")
	expect_set(t, src, ".[0].b", "say \"hi\"", "a,b,c\n1,\"say \"\"hi\"\"\",3\n4,5,6\n")
	expect_set(t, src, ".[0].b", "", "a,b,c\n1,\"\",3\n4,5,6\n")
	expect_set(t, src, ".[].c", "z", "a,b,c\n1,2,z\n4,5,z\n")
	expect_set(t, src, ".[].a", Maybe(int)(7), "a,b,c\n7,2,3\n7,5,6\n")
	// A comma in a number's spelling in a `,` dialect cannot occur; a delimiter that is a digit's neighbour can.
	crlf := transmute([]byte)string("a,b\r\n1,2\r\n")
	expect_set(t, crlf, ".[0].b", "q\r\nr", "a,b\r\n1,\"q\r\nr\"\r\n")
	// A text with no final break keeps none.
	bare := transmute([]byte)string("a,b\n1,2")
	expect_set(t, bare, ".[0].b", 3, "a,b\n1,3")
	// The header is the only one whose cells a path cannot name by row.
	_, err := csv.set(src, ".[].a", 1, header = false)
	testing.expect_value(t, err, csv.Path_Error{kind = .Unsupported_Path})
}

@(test)
test_set_dialects :: proc(t: ^testing.T) {
	tsv := transmute([]byte)string("a\tb\n1\t2\n")
	expect_set_in(t, csv.TSV, tsv, ".[0].b", "x\ty\nz\\", "a\tb\n1\tx\\ty\\nz\\\\\n")
	semi := transmute([]byte)string("a;b\n1;2\n")
	expect_set_in(t, csv.Dialect{delimiter = ';', quoting = .None}, semi, ".[0].b", "p,q", "a;b\n1;p,q\n")
	_, err := csv.set(semi, ".[0].b", "p;q", csv.Dialect{delimiter = ';', quoting = .None})
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	commented := transmute([]byte)string("# note\na,b\n1,2\n")
	expect_set_in(t, csv.Dialect{comment = '#'}, commented, ".[0].a", "#x", "# note\na,b\n\"#x\",2\n")
	expect_set_in(t, csv.Dialect{comment = '#'}, commented, ".[0].b", "#x", "# note\na,b\n1,#x\n")
	// A BOM stays the text's own, and a value that opens one does not make a second.
	bom := transmute([]byte)string("\xEF\xBB\xBFa,b\n1,2\n")
	expect_set(t, bom, ".[0].a", "\xEF\xBB\xBFz", "\xEF\xBB\xBFa,b\n\xEF\xBB\xBFz,2\n")
	out, serr := csv.set(bom, ".[0][0]", "\xEF\xBB\xBFz", header = false)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, string(out), "\xEF\xBB\xBF\"\xEF\xBB\xBFz\",b\n1,2\n")
	delete(out)
}

// A cell opening with a BOM is data except where it opens the text.
@(test)
test_edits_with_a_bom_cell :: proc(t: ^testing.T) {
	tsv := transmute([]byte)string("a\tb\n1\t2\n")
	expect_set_in(t, csv.TSV, tsv, ".[0][1]", "\xEF\xBB\xBFy", "a\tb\n1\t\xEF\xBB\xBFy\n")
	expect_set_in(t, csv.TSV, tsv, ".[0].b", "\xEF\xBB\xBFy", "a\tb\n1\t\xEF\xBB\xBFy\n")
	expect_set(t, transmute([]byte)string("a,b\n1,2\n"), ".[0][1]", "\xEF\xBB\xBFy", "a,b\n1,\xEF\xBB\xBFy\n")
	_, err := csv.set(tsv, ".[0][0]", "\xEF\xBB\xBFy", csv.TSV, header = false)
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	_, err = csv.insert(nil, csv.APPEND, []string{"\xEF\xBB\xBFy"}, csv.TSV, false)
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	out, ierr := csv.insert(tsv, csv.APPEND, []string{"x", "\xEF\xBB\xBFy"}, csv.TSV)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, string(out), "a\tb\n1\t2\nx\t\xEF\xBB\xBFy\n")
	delete(out)
}

// A text that is only a BOM is empty of records: a row goes after the BOM, with no break before it.
@(test)
test_insert_into_a_bom_only_text :: proc(t: ^testing.T) {
	bom := transmute([]byte)string("\xEF\xBB\xBF")
	out, err := csv.insert(bom, csv.APPEND, []string{"a", "b"}, header = false)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "\xEF\xBB\xBFa,b\n")
	delete(out)
}

@(test)
test_set_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	Case :: struct {
		path:  string,
		value: any,
		want:  csv.Path_Error,
	}
	cases := []Case {
		{".[1].a", 1, {kind = .Not_Found}},
		{".[0].zz", 1, {kind = .Not_Found}},
		{".[0][5]", 1, {kind = .Not_Found}},
		{".[0]", 1, {kind = .Unsupported_Path}},
		{".[-1].a", 1, {kind = .Unsupported_Path}},
		{".[0].a.b", 1, {kind = .Unsupported_Path}},
		{".[", 1, {kind = .Bad_Path, offset = 1}},
		{".[0].a", nil, {kind = .Encode, encode = .Unsupported}},
		{".[0].a", []int{1}, {kind = .Encode, encode = .Unsupported}},
		{".[0].a", struct{}{}, {kind = .Encode, encode = .Unsupported}},
	}
	for c in cases {
		out, err := csv.set(src, c.path, c.value)
		testing.expectf(t, out == nil && err == c.want, "set %q: %v, want %v", c.path, err, c.want)
		delete(out)
	}
	// A source that is not CSV is refused whole, whatever the path.
	_, err := csv.set(transmute([]byte)string("a,b\n1\n"), ".[0].a", 1)
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 4})
	// One empty field alone reads back as no record.
	one := transmute([]byte)string("a\nx\n")
	_, err = csv.set(one, ".[0].a", "", csv.Dialect{quoting = .None})
	testing.expect_value(t, err, csv.Path_Error{kind = .Encode, encode = .Unwritable, offset = 2})
	out, err2 := csv.set(one, ".[0].a", "", csv.Dialect{})
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, string(out), "a\n\"\"\n")
	delete(out)
}

Seat :: struct {
	id:   int,
	name: string,
	ok:   bool,
}

Seat_Named :: struct {
	label: string `csv:"name"`,
	id:    int,
}

@(test)
test_insert_rows :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name,ok\n1,a,true\n2,b,false\n")
	expect_insert(t, src, 0, Seat{3, "c", true}, "id,name,ok\n3,c,true\n1,a,true\n2,b,false\n")
	expect_insert(t, src, 1, Seat{3, "c,d", false}, "id,name,ok\n1,a,true\n3,\"c,d\",false\n2,b,false\n")
	expect_insert(t, src, 2, Seat{3, "c", true}, "id,name,ok\n1,a,true\n2,b,false\n3,c,true\n")
	expect_insert(t, src, csv.APPEND, Seat{3, "c", true}, "id,name,ok\n1,a,true\n2,b,false\n3,c,true\n")
	expect_insert(t, src, csv.APPEND, []string{"3", "c", ""}, "id,name,ok\n1,a,true\n2,b,false\n3,c,\"\"\n")
	// Fields match columns by name, wherever the columns are; a column with no field is empty.
	reordered := transmute([]byte)string("name,x,id\nz,y,1\n")
	expect_insert(t, reordered, csv.APPEND, Seat_Named{"q", 9}, "name,x,id\nz,y,1\nq,,9\n")
	// The new record ends as the first record does, and a text with no final break gets it before the record.
	crlf := transmute([]byte)string("id,name,ok\r\n1,a,true")
	expect_insert(t, crlf, csv.APPEND, Seat{2, "b", false}, "id,name,ok\r\n1,a,true\r\n2,b,false")
	expect_insert(t, crlf, 0, Seat{2, "b", false}, "id,name,ok\r\n2,b,false\r\n1,a,true")
	only_header := transmute([]byte)string("id,name,ok")
	expect_insert(t, only_header, 0, []string{"1", "a", "true"}, "id,name,ok\n1,a,true")
	headerless := transmute([]byte)string("1,a\n2,b\n")
	out, err := csv.insert(headerless, 1, []string{"9", "z"}, header = false)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "1,a\n9,z\n2,b\n")
	delete(out)
	out, err = csv.insert(nil, csv.APPEND, []string{"9", "z"}, header = false)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "9,z\n")
	delete(out)
}

@(test)
test_insert_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("id,name\n1,a\n")
	Case :: struct {
		at:   int,
		row:  any,
		want: csv.Path_Error,
	}
	cases := []Case {
		{-1, []string{"1", "a"}, {kind = .Unplaceable}},
		{2, []string{"1", "a"}, {kind = .Unplaceable}},
		{0, []string{"1"}, {kind = .Bad_Row, offset = 1}},
		{0, []string{"1", "a", "b"}, {kind = .Bad_Row, offset = 3}},
		{0, Seat{}, {kind = .Bad_Row, offset = 2}}, // `ok` names no column
		{0, 5, {kind = .Encode, encode = .Unsupported}},
		{0, nil, {kind = .Encode, encode = .Unsupported}},
	}
	for c in cases {
		out, err := csv.insert(src, c.at, c.row)
		testing.expectf(t, err == c.want, "insert %d %v: %v, want %v", c.at, c.row, err, c.want)
		delete(out)
	}
	// A header is needed to place a row, but not to be found by one.
	_, err := csv.insert(nil, 0, []string{"a"})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable})
	// Ragged texts take rows of any width.
	out, rerr := csv.insert(src, 0, []string{"1"}, csv.Dialect{ragged = true})
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "id,name\n1\n1,a\n")
	delete(out)
	// A comment line cannot be a record: a first cell opening with the comment byte is guarded or refused.
	out, rerr = csv.insert(src, 0, []string{"#x", "a"}, csv.Dialect{comment = '#'})
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "id,name\n\"#x\",a\n1,a\n")
	delete(out)
	_, rerr = csv.insert(src, 0, []string{"#x", "a"}, csv.Dialect{quoting = .None, comment = '#'})
	testing.expect_value(t, rerr, csv.Path_Error{kind = .Encode, encode = .Unwritable})
	// A bad source is refused with the scan's location.
	_, rerr = csv.insert(transmute([]byte)string("a,b\n1\n"), 0, []string{"1", "2"})
	testing.expect_value(t, rerr, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 4})
}

@(test)
test_remove_rows_and_columns :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,c\n1,2,3\n4,5,6\n")
	expect_remove(t, src, ".[0]", "a,b,c\n4,5,6\n")
	expect_remove(t, src, ".[1]", "a,b,c\n1,2,3\n")
	expect_remove(t, src, ".[].a", "b,c\n2,3\n5,6\n")
	expect_remove(t, src, ".[].b", "a,c\n1,3\n4,6\n")
	expect_remove(t, src, ".[].c", "a,b\n1,2\n4,5\n")
	expect_remove(t, src, ".[][1]", "a,c\n1,3\n4,6\n")
	// The last record without a break: the one before it becomes the end, with its break.
	bare := transmute([]byte)string("a,b\n1,2\n3,4")
	expect_remove(t, bare, ".[1]", "a,b\n1,2\n")
	expect_remove(t, bare, ".[0]", "a,b\n3,4")
	crlf := transmute([]byte)string("a,b\r\n1,2\r\n3,4\r\n")
	expect_remove(t, crlf, ".[0]", "a,b\r\n3,4\r\n")
	expect_remove(t, crlf, ".[].b", "a\r\n1\r\n3\r\n")
	quoted := transmute([]byte)string("a,\"b,c\",d\n1,\"2\n3\",4\n")
	expect_remove(t, quoted, ".[0]", "a,\"b,c\",d\n")
	expect_remove(t, quoted, ".[].a", "\"b,c\",d\n\"2\n3\",4\n")
	// Comment lines stay where they were.
	commented := transmute([]byte)string("# top\na,b\n# mid\n1,2\n# low\n3,4\n")
	out, err := csv.remove(commented, ".[0]", csv.Dialect{comment = '#'})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "# top\na,b\n# mid\n# low\n3,4\n")
	delete(out)
}

@(test)
test_remove_refusals :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	Case :: struct {
		path: string,
		want: csv.Path_Error,
	}
	cases := []Case {
		{".[1]", {kind = .Not_Found}},
		{".[].zz", {kind = .Not_Found}},
		{".[][3]", {kind = .Not_Found}},
		{".[0].a", {kind = .Unsupported_Path}},
		{".[0][1]", {kind = .Unsupported_Path}},
		{".[]", {kind = .Unsupported_Path}},
		{".[-1]", {kind = .Unsupported_Path}},
		{".[", {kind = .Bad_Path, offset = 1}},
	}
	for c in cases {
		out, err := csv.remove(src, c.path)
		testing.expectf(t, out == nil && err == c.want, "remove %q: %v, want %v", c.path, err, c.want)
	}
	// The only column cannot go: no record would be left.
	_, err := csv.remove(transmute([]byte)string("a\n1\n"), ".[].a")
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable, offset = 0})
	// A second column that opens with the comment byte would make its record a comment.
	_, err = csv.remove(transmute([]byte)string("a,b\n1,#2\n"), ".[].a", csv.Dialect{comment = '#'})
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable, offset = 4})
	// A removal that would put a BOM at the front refuses.
	_, err = csv.remove(transmute([]byte)string("a,\xEF\xBB\xBFb\n"), ".[].a")
	testing.expect_value(t, err, csv.Path_Error{kind = .Unplaceable})
	_, err = csv.remove(transmute([]byte)string("a,b\n1\n"), ".[0]")
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Source, syntax = .Field_Count, offset = 4})
}

@(test)
test_edits_in_ragged_texts :: proc(t: ^testing.T) {
	d := csv.Dialect{ragged = true}
	src := transmute([]byte)string("a,b,c\n1\n2,3\n4,5,6\n")
	expect_set_in(t, d, src, ".[].c", "z", "a,b,c\n1\n2,3\n4,5,z\n")
	expect_set_in(t, d, src, ".[1].b", 9, "a,b,c\n1\n2,9\n4,5,6\n")
	_, err := csv.set(src, ".[0].b", 9, d)
	testing.expect_value(t, err, csv.Path_Error{kind = .Not_Found})
	// A removal skips a record too short for the column.
	out, rerr := csv.remove(src, ".[].b", d)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "a,c\n1\n2\n4,6\n")
	delete(out)
	out, rerr = csv.remove(src, ".[].c", d)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, string(out), "a,b\n1\n2,3\n4,5\n")
	delete(out)
	expect_remove_in(t, d, src, ".[1]", "a,b,c\n1\n4,5,6\n")
}

@(test)
test_splice :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	edits := []csv.Edit{{lo = 4, hi = 5, bytes = transmute([]byte)string("10")}, {lo = 6, hi = 7, bytes = transmute([]byte)string("\"x\"")}}
	out, err := csv.splice(src, edits)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), "a,b\n10,\"x\"\n")
	delete(out)
	out, err = csv.splice(src, nil)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(out), string(src))
	delete(out)
	bad := [][]csv.Edit {
		{{lo = 5, hi = 4}},
		{{lo = 0, hi = 99}},
		{{lo = 4, hi = 6}, {lo = 5, hi = 7}},
		{{lo = 6, hi = 7}, {lo = 4, hi = 5}},
	}
	for e in bad {
		_, err = csv.splice(src, e)
		testing.expectf(t, err == csv.Path_Error{kind = .Bad_Edit}, "%v: %v", e, err)
	}
	// An edit that leaves a text that is not CSV is refused, with the fault located in the result.
	_, err = csv.splice(src, []csv.Edit{{lo = 4, hi = 5, bytes = transmute([]byte)string("1,9")}})
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Result, syntax = .Field_Count, offset = 4})
	_, err = csv.splice(src, []csv.Edit{{lo = 0, hi = 0}}, csv.Dialect{delimiter = '"'})
	testing.expect_value(t, err, csv.Path_Error{kind = .Bad_Option})
}

// `set` of `src` at `path` to `value`, in the default dialect, is `want`.
expect_set :: proc(t: ^testing.T, src: []byte, path: string, value: any, want: string, loc := #caller_location) {
	expect_set_in(t, csv.Dialect{}, src, path, value, want, loc)
}

expect_set_in :: proc(t: ^testing.T, d: csv.Dialect, src: []byte, path: string, value: any, want: string, loc := #caller_location) {
	out, err := csv.set(src, path, value, d)
	testing.expectf(t, err == nil && string(out) == want, "set %s of %q: %q %v, want %q", path, src, out, err, want, loc = loc)
	delete(out)
}

expect_insert :: proc(t: ^testing.T, src: []byte, at: int, row: any, want: string, loc := #caller_location) {
	out, err := csv.insert(src, at, row)
	testing.expectf(t, err == nil && string(out) == want, "insert %d into %q: %q %v, want %q", at, src, out, err, want, loc = loc)
	delete(out)
}

expect_remove :: proc(t: ^testing.T, src: []byte, path: string, want: string, loc := #caller_location) {
	expect_remove_in(t, csv.Dialect{}, src, path, want, loc)
}

expect_remove_in :: proc(t: ^testing.T, d: csv.Dialect, src: []byte, path: string, want: string, loc := #caller_location) {
	out, err := csv.remove(src, path, d)
	testing.expectf(t, err == nil && string(out) == want, "remove %s of %q: %q %v, want %q", path, src, out, err, want, loc = loc)
	delete(out)
}

// An allocator that grants `left` allocations from `backing`, refuses the next one, and grants all after.
Budget :: struct {
	backing: mem.Allocator,
	left:    int,
	refused: bool,
}

budget_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	b := (^Budget)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if b.left == 0 {
			b.refused, b.left = true, -1
			return nil, .Out_Of_Memory
		}
		b.left = max(b.left - 1, -1)
	}
	return b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// A refused allocation anywhere in an edit is `.Out_Of_Memory`, never a result missing an edit: each edit runs
// with its k-th allocation refused, k counting up until none is.
@(test)
test_edit_out_of_memory :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b,c\n1,2,3\n4,5,6\n7,8,9\n")
	run :: proc(op: int, src: []byte, allocator: mem.Allocator) -> ([]byte, Maybe(csv.Path_Error)) {
		switch op {
		case 0:
			return csv.set(src, ".[].b", "x", allocator = allocator)
		case 1:
			return csv.remove(src, ".[].b", allocator = allocator)
		case 2:
			return csv.remove(src, ".[1]", allocator = allocator)
		}
		return csv.insert(src, 1, []string{"x", "y", "z"}, allocator = allocator)
	}
	for op in 0 ..< 4 {
		want, werr := run(op, src, context.allocator)
		defer delete(want)
		testing.expect_value(t, werr, nil)
		swept := false
		for k in 0 ..< 1000 {
			b := Budget{backing = context.allocator, left = k}
			out, err := run(op, src, {budget_proc, &b})
			if !b.refused {
				testing.expect_value(t, string(out), string(want))
				delete(out)
				swept = true
				break
			}
			e, ok := err.?
			testing.expectf(t, ok && out == nil && (e.kind == .Out_Of_Memory || e.kind == .Encode && e.encode == .Out_Of_Memory), "op %d at allocation %d: %v, %q", op, k, err, string(out))
			delete(out)
		}
		testing.expect(t, swept, "the sweep never completed")
	}
}
