package main

// --to csv and --to tsv: each output is one record of cells. An object is a row under a header, the first object's keys
// (sorted under -S); a key an object lacks is an empty cell, and a key the header lacks ends the run, unless
// --grow-header holds every row and writes a header of all the keys in the order first seen (sorted under -S). An array
// or a scalar is a row with no header, and the two kinds do not mix. A cell is a string's text, a number as jq spells
// it, true or false, or null as an empty cell; an array or object in a cell ends the run. A record the dialect cannot
// spell (no cell, or one empty cell, is a blank line, which reads back as no record) ends it too.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import csv "../../csv"
import "jq"

// What a piece of a pooled job leaves in `Record_Piece.stop` for a record that cannot be written, which the main
// thread reports as the sequential run would; a fault in the text is 0.
TABLE_STOP :: 1

Table_Shape :: enum u8 {
	Unset,
	Objects,
	Rows,
}

// The run's table. Everything it holds but the strings of `held` and `header` is the heap's, as the run is longer
// than each input's arena.
Table :: struct {
	dialect: csv.Dialect,
	format:  string,
	grow:    bool, // --grow-header: the rows are held, and written with the finished header when the run ends
	shape:   Table_Shape,
	count:   int, // the outputs so far
	header:  [dynamic]string,
	slot:    map[string]int, // a header name's cell
	held:    [dynamic][dynamic]Maybe(string),
}

// The table of a run that writes cells.
table_make :: proc(o: ^Opts) -> ^Table {
	heap := runtime.heap_allocator()
	t := new(Table, heap)
	t.dialect, t.format, t.grow = FORMATS[o.to].dialect, FORMATS[o.to].name, o.grow_header
	t.header = make([dynamic]string, heap)
	t.slot = make(map[string]int, heap)
	t.held = make([dynamic][dynamic]Maybe(string), heap)
	return t
}

// The record of `cells` appended to the run's output, which is left as it was when it cannot be written.
put_row :: proc(run: ^Run, cells: []Maybe(string)) -> csv.Marshal_Error {
	err := csv.write_record(&run.out, cells, run.table.dialect, at_start = !run.rows_begun)
	if err == .None {
		run.rows_begun = true
	}
	return err
}

// Why a row was refused, for the message of the run that ends on it.
row_refusal :: proc(t: ^Table, err: csv.Marshal_Error) -> string {
	#partial switch err {
	case .Unwritable:
		// Only an unquoting dialect cannot spell a cell that opens with a BOM; CSV quotes it.
		bom := ", and text opening with a byte order mark reads back without it" if t.dialect.quoting == .None else ""
		return fmt.tprintf("a record cannot be written as %s: no cell, or one empty cell, is a blank line, which reads back as no record%s", t.format, bom)
	case .Bad_Utf8:
		return fmt.tprintf("a text that is not UTF-8 cannot be written as %s", t.format)
	}
	return fmt.tprintf("a record cannot be written as %s: %v", t.format, err)
}

// End the run on a row that cannot be written, after the output before it.
table_fail :: proc(run: ^Run, format: string, args: ..any) -> ! {
	flush_some(run, force = true)
	fmt.eprintf("stury: error: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	finish(run, EXIT_INPUT)
}

// `cells` appended as a record to the output of a run on the main thread, or a pool thread's copy: that one
// marks the copy `faulted` for its caller to stop at, and the main thread ends the run. False when it was
// refused.
put_row_or_stop :: proc(run: ^Run, cells: []Maybe(string)) -> bool {
	err := put_row(run, cells)
	if err == .None {
		return true
	}
	if run.held {
		run.faulted = true
		return false
	}
	table_fail(run, "%s", row_refusal(run.table, err))
}

// The output `v` as a record, or a row of the table: the interpreter's way into the table.
print_row :: proc(run: ^Run, v: jq.Value) -> bool {
	t := run.table
	t.count += 1
	run.ret = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	is_object := jq.kind(v) == .Object
	shape := Table_Shape.Objects if is_object else .Rows
	switch {
	case t.shape == .Unset:
		t.shape = shape
	case t.shape != shape && is_object:
		table_fail(run, "output %d is an object, after arrays or scalars: a table is all objects (under a header) or none", t.count)
	case t.shape != shape:
		table_fail(run, "output %d is not an object, after objects: a table is all objects (under a header) or none", t.count)
	}
	if is_object {
		object_row(run, t, v)
	} else {
		plain_row(run, t, v)
	}
	flush_some(run)
	return true
}

// The cell for `v`: its text, nil for null, `nested` for an array or object.
cell_of :: proc(v: jq.Value) -> (cell: Maybe(string), nested: bool) {
	switch jq.kind(v) {
	case .Null:
		return nil, false
	case .False:
		return "false", false
	case .True:
		return "true", false
	case .String:
		s, _ := jq.string_of(v)
		return s, false
	case .Number:
		return jq.to_json(v), false
	case .Array, .Object:
		return nil, true
	}
	return nil, false
}

// A nested value in a cell: the run ends.
@(private = "file")
nested_cell :: proc(run: ^Run, v: jq.Value, where_: string) -> ! {
	what := "an object" if jq.kind(v) == .Object else "an array"
	table_fail(run, "output %d has %s %s: a cell is a text, a number, true, false or null; tojson makes text of %s", run.table.count, what, where_, what)
}

// The row of an array's elements or of a scalar.
@(private = "file")
plain_row :: proc(run: ^Run, t: ^Table, v: jq.Value) {
	if jq.kind(v) != .Array {
		cell, _ := cell_of(v)
		cells := [1]Maybe(string){cell}
		put_checked(run, t, cells[:])
		return
	}
	cells := make([dynamic]Maybe(string), context.temp_allocator)
	it := jq.iterate(v)
	for _, e in jq.next_member(&it) {
		cell, nested := cell_of(e)
		if nested {
			nested_cell(run, e, fmt.tprintf("at cell %d", len(cells) + 1))
		}
		append(&cells, cell)
	}
	put_checked(run, t, cells[:])
}

// The row of an object's values under the header, which the first object makes.
@(private = "file")
object_row :: proc(run: ^Run, t: ^Table, v: jq.Value) {
	first := t.count == 1
	if first {
		names: []string
		if run.opts.sort_keys {
			names = jq.sorted_keys(v)
		} else {
			list := make([dynamic]string, context.temp_allocator)
			it := jq.iterate(v)
			for k in jq.next_member(&it) {
				append(&list, k)
			}
			names = list[:]
		}
		for k in names {
			add_column(t, k)
		}
	}
	cells := make([dynamic]Maybe(string), len(t.header), context.temp_allocator)
	columns := len(t.header)
	it := jq.iterate(v)
	for k, e in jq.next_member(&it) {
		at, known := t.slot[k]
		if !known {
			if !t.grow {
				table_fail(run, "output %d has the key %q, which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)", t.count, k)
			}
			at = add_column(t, k)
			resize(&cells, len(t.header))
		}
		cell, nested := cell_of(e)
		if nested {
			drop_columns_from(t, columns)
			nested_cell(run, e, fmt.tprintf("at key %q", k))
		}
		cells[at] = cell
	}
	if t.grow {
		hold_row(t, cells[:])
		return
	}
	// The header and the first row are one output: a refusal of the row leaves neither.
	mark := len(run.out)
	if first {
		put_header(run, t)
	}
	if err := put_row(run, cells[:]); err != .None {
		resize(&run.out, mark)
		table_fail(run, "%s", row_refusal(t, err))
	}
}

// A cell added to the header, at the end.
@(private = "file")
add_column :: proc(t: ^Table, name: string) -> int {
	at := len(t.header)
	owned := strings.clone(name, runtime.heap_allocator())
	append(&t.header, owned)
	t.slot[owned] = at
	return at
}

// The header as it was when it had `columns`: a key joins it only with an accepted row.
@(private = "file")
drop_columns_from :: proc(t: ^Table, columns: int) {
	for name in t.header[columns:] {
		delete_key(&t.slot, name)
		delete(name, runtime.heap_allocator())
	}
	resize(&t.header, columns)
}

// The header's record put into the output.
@(private = "file")
put_header :: proc(run: ^Run, t: ^Table) {
	names := make([]Maybe(string), len(t.header), context.temp_allocator)
	for h, i in t.header {
		names[i] = h
	}
	put_checked(run, t, names)
}

// `cells` as a record that ends the run when it is refused.
@(private = "file")
put_checked :: proc(run: ^Run, t: ^Table, cells: []Maybe(string)) {
	if err := put_row(run, cells); err != .None {
		table_fail(run, "%s", row_refusal(t, err))
	}
}

// A row held for the finished header, its texts on the heap: the input's arena is emptied before the run ends.
@(private = "file")
hold_row :: proc(t: ^Table, cells: []Maybe(string)) {
	heap := runtime.heap_allocator()
	row := make([dynamic]Maybe(string), len(cells), heap)
	for c, i in cells {
		if text, present := c.?; present {
			row[i] = strings.clone(text, heap)
		}
	}
	append(&t.held, row)
}

// The rows --grow-header held, written under the header of every key: false after a message when one is refused.
// Once only: a run that ends here must not come back.
write_held_rows :: proc(run: ^Run) -> bool {
	t := run.table
	if t == nil || run.held || !t.grow {
		return true
	}
	t.grow = false
	if len(t.held) == 0 {
		return true
	}
	// Under -S the header is every key in byte order, and each row's cells follow it.
	order := make([]int, len(t.header), context.temp_allocator)
	for &at, i in order {
		at = i
	}
	if run.opts.sort_keys {
		names := slice.clone(t.header[:], context.temp_allocator)
		slice.sort(names)
		for name, i in names {
			order[i] = t.slot[name]
		}
		copy(t.header[:], names)
	}
	put_header(run, t)
	cells := make([]Maybe(string), len(t.header), context.temp_allocator)
	for row in t.held {
		for &c, i in cells {
			c = row[order[i]] if order[i] < len(row) else nil
		}
		if err := put_row(run, cells); err != .None {
			flush_some(run, force = true)
			fmt.eprintfln("stury: error: %s", row_refusal(t, err))
			return false
		}
		flush_some(run)
	}
	return true
}
