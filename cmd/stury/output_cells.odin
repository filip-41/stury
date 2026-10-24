package main

// Writes --to csv and --to tsv output. Each output is one record. An object is a row under a header made of the
// first object's keys (sorted under -S). A key missing from an object is an empty cell. A key missing from the
// header ends the run, unless --grow-header is set: then every row is held, and the header lists all keys in
// first-seen order (sorted under -S). An array or a scalar is a row without a header; the two shapes do not mix.
// A cell is a string's text, a number as jq prints it, true, false, or empty for null. An array or object in a
// cell ends the run. So does a record the dialect cannot write: no cells, or one empty cell, is a blank line,
// which reads back as no record.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import csv "../../csv"
import "jq"

// The `Record_Piece.stop` value for a record that cannot be written. The main thread reports it as the sequential
// run would. A fault in the text is 0.
TABLE_STOP :: 1

Table_Shape :: enum u8 {
	Unset,
	Objects,
	Rows,
}

// The run's CSV output table. It is heap-allocated, except the strings of `held` and `header`, because it
// outlives each input's arena.
Table :: struct {
	dialect: csv.Dialect,
	format:  string,
	grow:    bool, // --grow-header: the rows are held, and written with the finished header when the run ends
	shape:   Table_Shape,
	count:   int, // outputs written so far
	header:  [dynamic]string,
	slot:    map[string]int, // header name to cell index
	held:    [dynamic][dynamic]Maybe(string),
}

table_make :: proc(o: ^Opts) -> ^Table {
	heap := runtime.heap_allocator()
	t := new(Table, heap)
	t.dialect, t.format, t.grow = FORMATS[o.to].dialect, FORMATS[o.to].name, o.grow_header
	t.header = make([dynamic]string, heap)
	t.slot = make(map[string]int, heap)
	t.held = make([dynamic][dynamic]Maybe(string), heap)
	return t
}

// Appends the record of `cells` to the run's output. On an error the output is unchanged.
put_row :: proc(run: ^Run, cells: []Maybe(string)) -> csv.Marshal_Error {
	err := csv.write_record(&run.out, cells, run.table.dialect, at_start = !run.rows_begun)
	if err == .None {
		run.rows_begun = true
	}
	return err
}

// Appends the row of an object's `cells` under `keys` to the output; the first row is preceded by the header. A
// refused row writes neither. Returns false when a pool thread's copy refuses the row; the caller stops and the
// main thread ends the run.
put_object_row :: proc(run: ^Run, keys: []string, cells: []Maybe(string)) -> bool {
	t, mark := run.table, len(run.out)
	if !run.held && t.shape == .Unset {
		open_object_table(run, keys)
	}
	err := put_row(run, cells)
	if err == .None {
		return true
	}
	resize(&run.out, mark)
	if run.held {
		run.faulted = true
		return false
	}
	table_fail(run, "%s", row_refusal(t, err))
}

// Starts a table of objects with a header of `keys` and writes the header record.
open_object_table :: proc(run: ^Run, keys: []string) {
	t := run.table
	t.shape = .Objects
	for k in keys {
		add_column(t, k)
	}
	put_header(run, t)
}

header_writable :: proc(run: ^Run, keys: []string) -> bool {
	names := make([]Maybe(string), len(keys), context.temp_allocator)
	for k, i in keys {
		names[i] = k
	}
	scratch := make([dynamic]byte, context.temp_allocator)
	return csv.write_record(&scratch, names, run.table.dialect, at_start = !run.rows_begun) == .None
}

row_refusal :: proc(t: ^Table, err: csv.Marshal_Error) -> string {
	#partial switch err {
	case .Unwritable:
		// Only a dialect without quoting cannot write a cell that starts with a BOM; CSV quotes it.
		bom := ", and text opening with a byte order mark reads back without it" if t.dialect.quoting == .None else ""
		return fmt.tprintf("a record cannot be written as %s: no cell, or one empty cell, is a blank line, which reads back as no record%s", t.format, bom)
	case .Bad_Utf8:
		return fmt.tprintf("a text that is not UTF-8 cannot be written as %s", t.format)
	}
	return fmt.tprintf("a record cannot be written as %s: %v", t.format, err)
}

// Flushes the output so far, reports a row that cannot be written, and ends the run.
table_fail :: proc(run: ^Run, format: string, args: ..any) -> ! {
	flush_some(run, force = true)
	fmt.eprintf("stury: error: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	finish(run, EXIT_INPUT)
}

// Appends `cells` as a record to the output. On the main thread a refusal ends the run. On a pool thread's copy a
// refusal sets `faulted` and returns false; the caller stops and the main thread ends the run.
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

// Writes the output `v` as a table row. The interpreter calls it for each output.
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

// Returns the cell text for `v`: nil for null, `nested` for an array or object.
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
		// NaN is an empty cell, as in jq's @csv.
		if n, _ := jq.number_of(v); math.is_nan(n.f) {
			return nil, false
		}
		return jq.to_json(v), false
	case .Array, .Object:
		return nil, true
	}
	return nil, false
}

@(private = "file")
nested_cell :: proc(run: ^Run, v: jq.Value, where_: string) -> ! {
	what := "an object" if jq.kind(v) == .Object else "an array"
	table_fail(run, "output %d has %s %s: a cell is a text, a number, true, false or null; tojson makes text of %s", run.table.count, what, where_, what)
}

// Writes the row of an array's elements or of a scalar.
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

// Writes the row of an object's values under the header. The first object's keys make the header.
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
	// The header and the first row are one output; a refused row writes neither.
	mark := len(run.out)
	if first {
		put_header(run, t)
	}
	if err := put_row(run, cells[:]); err != .None {
		resize(&run.out, mark)
		table_fail(run, "%s", row_refusal(t, err))
	}
}

@(private = "file")
add_column :: proc(t: ^Table, name: string) -> int {
	at := len(t.header)
	owned := strings.clone(name, runtime.heap_allocator())
	append(&t.header, owned)
	t.slot[owned] = at
	return at
}

// Truncates the header to `columns`, so that a key is added only with an accepted row.
@(private = "file")
drop_columns_from :: proc(t: ^Table, columns: int) {
	for name in t.header[columns:] {
		delete_key(&t.slot, name)
		delete(name, runtime.heap_allocator())
	}
	resize(&t.header, columns)
}

@(private = "file")
put_header :: proc(run: ^Run, t: ^Table) {
	names := make([]Maybe(string), len(t.header), context.temp_allocator)
	for h, i in t.header {
		names[i] = h
	}
	put_checked(run, t, names)
}

// Writes `cells` as a record, ending the run when it is refused.
@(private = "file")
put_checked :: proc(run: ^Run, t: ^Table, cells: []Maybe(string)) {
	if err := put_row(run, cells); err != .None {
		table_fail(run, "%s", row_refusal(t, err))
	}
}

// Holds a row until the header is complete. The text is copied to the heap, because the input's arena is freed
// before the run ends.
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

// Writes the rows held by --grow-header under the header of every key. Returns false, after reporting, when a row
// is refused. A second call does nothing.
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
