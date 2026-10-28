package main

// Writes --to csv and --to tsv output. Each output is one record of a `csv.Table`: an object a row under a header
// made of the first object's keys (sorted under -S), a key missing from an object an empty cell. A key missing
// from the header ends the run, unless --grow-header is set: then every row is held, and the header lists all keys
// in first-seen order (sorted under -S). An array or a scalar is a row without a header; the two shapes do not
// mix. A cell is a string's text, a number as jq prints it, true, false, or empty for null. An array or object in
// a cell ends the run. So does a record the dialect cannot write: no cells, or one empty cell, is a blank line,
// which reads back as no record.

import "base:runtime"
import "core:math"
import csv "../../csv"
import "jq"
import "message"

// The `Record_Piece.stop` value for a record that cannot be written. The main thread reports it as the sequential
// run would. A fault in the text is 0.
TABLE_STOP :: 1

// The run's CSV output table, heap-allocated, because it outlives each input's arena.
Table :: struct {
	rows:   csv.Table,
	format: string,
	count:  int, // outputs written so far
}

table_make :: proc(o: ^Opts) -> ^Table {
	heap := runtime.heap_allocator()
	t := new(Table, heap)
	t.rows = csv.table_make({dialect = cells_out(o), sort_keys = o.sort_keys}, o.grow_header, allocator = heap)
	t.format = FORMATS[o.to].name
	return t
}

table_free :: proc(t: ^Table) {
	if t != nil {
		csv.destroy(&t.rows)
		free(t, runtime.heap_allocator())
	}
}

// Appends the record of `cells` to the run's output. A refused record cuts the output back to `mark`, when one is
// given, and ends the run; on a pool thread's copy it sets `faulted` instead and returns false, and the caller stops
// for the main thread to end the run.
put_row :: proc(run: ^Run, cells: []Maybe(string), mark := -1) -> bool {
	fault, refused := csv.write_record(&run.out, cells, run.table.rows.opts, at_start = !run.rows_begun).?
	if !refused {
		run.rows_begun = true
		return true
	}
	if mark >= 0 {
		resize(&run.out, mark)
	}
	if run.held {
		run.faulted = true
		return false
	}
	table_fail(run, "%s", row_refusal(run.table, fault.kind))
}

// Appends the row of an object's `cells` under `keys` to the output; the first row is preceded by the header. A
// refused row writes neither (`put_row`).
put_object_row :: proc(run: ^Run, keys: []string, cells: []Maybe(string)) -> bool {
	mark := len(run.out)
	if !run.held && run.table.rows.shape == .Unset {
		open_object_table(run, keys)
	}
	return put_row(run, cells, mark)
}

// Starts a table of objects with a header of `keys` and writes the header record.
open_object_table :: proc(run: ^Run, keys: []string) {
	if e, bad := csv.table_open(&run.table.rows, &run.out, keys, !run.rows_begun).?; bad {
		table_refused(run, e, keys)
	}
	run.rows_begun = true
}

header_writable :: proc(run: ^Run, keys: []string) -> bool {
	names := make([]Maybe(string), len(keys), context.temp_allocator)
	for k, i in keys {
		names[i] = k
	}
	scratch := make([dynamic]byte, context.temp_allocator)
	return csv.write_record(&scratch, names, run.table.rows.opts, at_start = !run.rows_begun) == nil
}

row_refusal :: proc(t: ^Table, err: csv.Marshal_Error_Kind) -> string {
	#partial switch err {
	case .Unwritable:
		// Only a dialect without quoting cannot write a cell that starts with a BOM; CSV quotes it.
		bom := ", and text opening with a byte order mark reads back without it" if t.rows.dialect.quoting != .Quotes else ""
		return message.build_temp("a record cannot be written as %s: no cell, or one empty cell, is a blank line, which reads back as no record%s", t.format, bom)
	case .Bad_Utf8:
		return message.build_temp("a text that is not UTF-8 cannot be written as %s", t.format)
	}
	return message.build_temp("a record cannot be written as %s: %v", t.format, err)
}

// Flushes the output so far, reports a row that cannot be written, and ends the run.
table_fail :: proc(run: ^Run, format: string, args: ..any) -> ! {
	flush_some(run, force = true)
	message.write_stderr("stury: error: %s\n", message.build_temp(format, ..args))
	finish(run, EXIT_INPUT)
}

// Writes the output `v` as a table row. The interpreter calls it for each output.
print_row :: proc(run: ^Run, v: jq.Value) -> bool {
	t := run.table
	t.count += 1
	run.ret = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	mark := len(run.out)
	keys: []string
	err: Maybe(csv.Table_Error)
	if jq.kind(v) == .Object {
		keys, err = object_row(run, t, v)
	} else {
		err = plain_row(run, t, v)
	}
	if e, bad := err.?; bad {
		table_refused(run, e, keys)
	}
	run.rows_begun = run.rows_begun || len(run.out) > mark
	flush_some(run)
	return true
}

// Ends the run on table error `e`, `keys` the object's keys. A refused record on a pool thread's copy sets
// `faulted` instead, for the main thread to end the run.
@(private = "file")
table_refused :: proc(run: ^Run, e: csv.Table_Error, keys: []string) {
	t := run.table
	switch e.kind {
	case .Mixed_Shapes:
		if t.rows.shape == .Rows {
			table_fail(run, "output %d is an object, after arrays or scalars: a table is all objects (under a header) or none", t.count)
		}
		table_fail(run, "output %d is not an object, after objects: a table is all objects (under a header) or none", t.count)
	case .Unknown_Key:
		table_fail(run, "output %d has the key %q, which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)", t.count, keys[e.key])
	case .Unwritable, .None:
		if run.held {
			run.faulted = true
			return
		}
		table_fail(run, "%s", row_refusal(t, e.record))
	}
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

// Ends the run on the nested cell `v` of a value whose keys so far are `keys`, reporting first the refusal the
// table gives the value before its cells (`csv.table_accepts`), as it met that refusal before the cell.
@(private = "file")
nested_in :: proc(run: ^Run, keys: []string, object: bool, v: jq.Value, where_: string) -> ! {
	if e, bad := csv.table_accepts(&run.table.rows, keys, object).?; bad {
		table_refused(run, e, keys)
	}
	nested_cell(run, v, where_)
}

@(private = "file")
nested_cell :: proc(run: ^Run, v: jq.Value, where_: string) -> ! {
	what := "an object" if jq.kind(v) == .Object else "an array"
	table_fail(run, "output %d has %s %s: a cell is a text, a number, true, false or null; tojson makes text of %s", run.table.count, what, where_, what)
}

// Writes the row of an array's elements or of a scalar.
@(private = "file")
plain_row :: proc(run: ^Run, t: ^Table, v: jq.Value) -> Maybe(csv.Table_Error) {
	if jq.kind(v) != .Array {
		cell, _ := cell_of(v)
		cells := [1]Maybe(string){cell}
		return csv.table_row(&t.rows, &run.out, cells[:], !run.rows_begun)
	}
	cells := make([dynamic]Maybe(string), context.temp_allocator)
	it := jq.iterate(v)
	for _, e in jq.next_member(&it) {
		cell, nested := cell_of(e)
		if nested {
			nested_in(run, nil, false, e, message.build_temp("at cell %d", len(cells) + 1))
		}
		append(&cells, cell)
	}
	return csv.table_row(&t.rows, &run.out, cells[:], !run.rows_begun)
}

// Writes the row of an object's values, returning its keys.
@(private = "file")
object_row :: proc(run: ^Run, t: ^Table, v: jq.Value) -> ([]string, Maybe(csv.Table_Error)) {
	keys := make([dynamic]string, context.temp_allocator)
	cells := make([dynamic]Maybe(string), context.temp_allocator)
	it := jq.iterate(v)
	for k, e in jq.next_member(&it) {
		append(&keys, k)
		cell, nested := cell_of(e)
		if nested {
			nested_in(run, keys[:], true, e, message.build_temp("at key %q", k))
		}
		append(&cells, cell)
	}
	return keys[:], csv.table_object(&t.rows, &run.out, keys[:], cells[:], !run.rows_begun)
}

// Writes the rows held by --grow-header under the header of every key. A refused row ends the run. A second call
// does nothing.
write_held_rows :: proc(run: ^Run) {
	t := run.table
	if t == nil || run.held {
		return
	}
	for {
		more, err := csv.table_finish(&t.rows, &run.out, !run.rows_begun)
		if e, bad := err.?; bad {
			table_fail(run, "%s", row_refusal(t, e.record))
		}
		if !more {
			return
		}
		run.rows_begun = true
		flush_some(run)
	}
}
