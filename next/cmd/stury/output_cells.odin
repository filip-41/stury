package main

// --to csv and --to tsv: each output is one record of a table. An object is a row under a header made of the first
// object's keys (sorted under -S), a key it lacks an empty cell. A key the header lacks ends the run, unless
// --grow-header holds every row and writes a header of all keys in first-seen order (sorted under -S) at the end. An
// array or a scalar is a row with no header, and the two shapes do not mix. A cell is a string's text, a number as it
// prints, true, false, or empty for null and NaN. An array or object in a cell ends the run, and so does a row no
// reader reads back: no cell, or one empty cell, is a blank line.

import "base:runtime"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import dsv "../../dsv"
import "jq"
import "message"

Table_Shape :: enum u8 {
	Unset,
	Objects,
	Rows,
}

// The run's output table, on the heap, as it outlives each input's arena. The writer's text is a buffer that each row
// moves into the run's output, so the rows go out as the others do.
Table :: struct {
	wr:     records.Writer,
	shape:  Table_Shape,
	header: [dynamic]string,
	held:   [dynamic]Held_Row, // --grow-header: every row, written at the end under the header of every key
	count:  int, // the outputs so far
	format: string,
	ended:  bool,
}

Held_Row :: struct {
	keys:  []string,
	cells: []Maybe(string),
}

table_start :: proc(run: ^Run) -> ^Table {
	o := &run.opts
	heap := runtime.heap_allocator()
	t := new(Table, heap)
	t.format = FORMATS[o.to].name
	t.header.allocator, t.held.allocator = heap, heap
	records.writer_init(&t.wr, {}, dsv.as(.Csv if o.to == .Csv else .Tsv), allocator = heap)
	return t
}

// Writes the output `v` as a table row, or ends the run on what the table refuses.
emit_row :: proc(o: ^Output, v: jq.Value) {
	t := o.table
	t.count += 1
	o.result = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	context.allocator = context.temp_allocator
	keys: [dynamic]string
	cells: [dynamic]Maybe(string)
	object := jq.kind(v) == .Object
	if t.shape != .Unset && object != (t.shape == .Objects) {
		table_fail(o, "output %d is %s: a table is all objects (under a header) or none", t.count, "an object, after arrays or scalars" if object else "not an object, after objects")
	}
	if !object && jq.kind(v) != .Array {
		append(&cells, cell_of(o, v, nil, 0))
	} else {
		it := jq.iterate(v)
		for k, e in jq.next_member(&it) {
			if object && !o.opts.grow_header && t.shape == .Objects && !slice.contains(t.header[:], k) {
				table_fail(o, "output %d has the key %q, which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)", t.count, k)
			}
			append(&keys, k)
			append(&cells, cell_of(o, e, k if object else nil, len(cells) + 1))
		}
	}
	t.shape = .Objects if object else .Rows
	if !object {
		put_row(o, cells[:])
		return
	}
	if o.opts.grow_header {
		heap := runtime.heap_allocator()
		row := Held_Row{make([]string, len(keys), heap), make([]Maybe(string), len(cells), heap)}
		for k, i in keys {
			row.keys[i] = strings.clone(k, heap)
			if s, present := cells[i].?; present {
				row.cells[i] = strings.clone(s, heap)
			}
		}
		append(&t.held, row)
		for k in row.keys {
			if !slice.contains(t.header[:], k) {
				append(&t.header, k)
			}
		}
		return
	}
	object_row(o, keys[:], cells[:])
}

// Writes the output object of `cells` under `keys` as a table row, when every output is such an object of the same
// keys, or ends the run on a row the table refuses.
table_object :: proc(o: ^Output, keys: []string, cells: []Maybe(string)) {
	o.table.count += 1
	o.table.shape = .Objects
	o.result = JQ_OK
	object_row(o, keys, cells)
}

// Writes an object's `cells`, under `keys`, as a row under the header, which the first object's keys make.
@(private = "file")
object_row :: proc(o: ^Output, keys: []string, cells: []Maybe(string)) {
	t := o.table
	fresh := len(t.header) == 0
	if fresh {
		for k in keys {
			append(&t.header, strings.clone(k, runtime.heap_allocator()))
		}
		if o.opts.sort_keys {
			slice.sort(t.header[:])
		}
	}
	row := aligned(t.header[:], keys, cells)
	head := -1
	if fresh {
		head = o.buf.flushed + o.buf.cursor
		write_header(o)
	}
	put_row(o, row, head)
}

// The cells of an object row under `header`: each key's cell in the header's order, empty for a key the row lacks.
@(private = "file")
aligned :: proc(header, keys: []string, cells: []Maybe(string)) -> []Maybe(string) {
	row := make([]Maybe(string), len(header), context.temp_allocator)
	for k, i in keys {
		if at, found := slice.linear_search(header, k); found {
			row[at] = cells[i]
		}
	}
	return row
}

// The cell `v` writes as, or the end of the run for an array or object at `key`, or with no key at cell `n` of the row.
@(private = "file")
cell_of :: proc(o: ^Output, v: jq.Value, key: Maybe(string), n: int) -> Maybe(string) {
	switch jq.kind(v) {
	case .Null:
		return nil
	case .False:
		return "false"
	case .True:
		return "true"
	case .String:
		s, _ := jq.string_of(v)
		return s
	case .Number:
		// NaN is an empty cell, as in jq's @csv.
		if n, _ := jq.number_of(v); math.is_nan(n.f) {
			return nil
		}
		return jq.to_json(v)
	case .Array, .Object:
		what := "an object" if jq.kind(v) == .Object else "an array"
		k, keyed := key.?
		at := message.build_temp("at key %q", k) if keyed else message.build_temp("at cell %d", n)
		table_fail(o, "output %d has %s %s: a cell is a text, a number, true, false or null; tojson makes text of %s", o.table.count, what, at, what)
	}
	return nil
}

@(private = "file")
write_header :: proc(o: ^Output) {
	t := o.table
	names := make([]Maybe(string), len(t.header), context.temp_allocator)
	for k, i in t.header {
		names[i] = k
	}
	put_row(o, names)
}

// Writes one record and moves the writer's text into the run's output, or ends the run on a record the writer
// refuses, dropping the output from `head` on when it is not yet flushed: a refused first row takes its header with it.
@(private = "file")
put_row :: proc(o: ^Output, cells: []Maybe(string), head := -1) {
	t := o.table
	if kind := records.write_cells(&t.wr, cells); kind != .None {
		if head >= o.buf.flushed {
			o.buf.cursor = head - o.buf.flushed
		}
		table_fail(o, "%s", row_refusal(t, kind))
	}
	write.put_text(&o.buf, string(records.writer_take(&t.wr)))
	flush_some(o)
}

@(private = "file")
row_refusal :: proc(t: ^Table, kind: core.Typed_Error_Kind) -> string {
	#partial switch kind {
	case .Unwritable:
		// Only TSV cannot write a cell that opens the text with a byte order mark: CSV quotes it.
		bom := ", and text opening with a byte order mark reads back without it" if t.format == "tsv" else ""
		return message.build_temp("a record cannot be written as %s: no cell, or one empty cell, is a blank line, which reads back as no record%s", t.format, bom)
	case .Bad_Utf8:
		return message.build_temp("a text that is not UTF-8 cannot be written as %s", t.format)
	}
	return message.build_temp("a record cannot be written as %s: %v", t.format, kind)
}

// Writes the rows --grow-header held, under the header of every key, once the outputs end. A second call does nothing.
table_end :: proc(o: ^Output) {
	t := o.table
	if t == nil || t.ended {
		return
	}
	t.ended = true
	if len(t.held) == 0 {
		return
	}
	if o.opts.sort_keys {
		slice.sort(t.header[:])
	}
	write_header(o)
	for r in t.held {
		put_row(o, aligned(t.header[:], r.keys, r.cells))
	}
}

// Writes what the table holds, reports `format` and ends the run. A piece's output is marked refused instead.
table_fail :: proc(o: ^Output, format: string, args: ..any) {
	if o.piece {
		o.refused = true
		return
	}
	msg := message.build_temp(format, ..args)
	table_end(o)
	flush_some(o, force = true)
	message.write_stderr("stury: error: %s\n", msg)
	os.exit(EXIT_INPUT)
}
