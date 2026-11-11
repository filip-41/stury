package main

// --to csv and --to tsv: each output is one record of a table. An object is a row under a header made of the first
// object's keys (sorted under -S), a key it lacks an empty cell. A key the header lacks ends the run, unless
// --grow-header holds every row and writes a header of all keys in first-seen order (sorted under -S) at the end. An
// array or a scalar is a row with no header, and the two shapes do not mix. A cell is a string's text, a number as it
// prints, true, false, or empty for null and NaN. Under --infer a string that would read back as a number, true or false
// is quoted, and TSV, which has no quotes, refuses it. An array or object in a cell ends the run, and so does a row no
// reader reads back: no cell, or one empty cell, is a blank line. When the table has a comment character, an output's
// `.@comment` is written as comment lines above its row, as the library's writer places a document's, and its other
// comments, a cell's and one holding a line end are dropped.

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strings"
import spell "../../core/spell"
import core "../../core"
import "../../core/write"
import records "../../core/records"
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
	infer:  bool, // the table reads back under --infer, so a text that reads as another kind is quoted
	lead:   [dynamic]string, // the comments written above the header, which the input holds
	foot:   [dynamic]string, // the comments written after the last row
	ended:  bool,
}

Held_Row :: struct {
	keys:  []string,
	cells: []write.Scalar,
	notes: []string,
}

table_start :: proc(run: ^Run) -> ^Table {
	o := &run.opts
	heap := runtime.heap_allocator()
	t := new(Table, heap)
	t.format, t.infer = FORMATS[o.to].name, o.cells_out.infer
	t.header.allocator, t.held.allocator, t.lead.allocator, t.foot.allocator = heap, heap, heap, heap
	records.writer_init(&t.wr, {}, cells_written_as(o), allocator = heap)
	return t
}

// Writes the output `v` as a table row, or ends the run on what the table refuses.
emit_row :: proc(o: ^Output, v: jq.Value) {
	t := o.table
	t.count += 1
	o.result = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	context.allocator = context.temp_allocator
	keys: [dynamic]string
	cells: [dynamic]write.Scalar
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
				unknown_key(o, k)
			}
			append(&keys, k)
			append(&cells, cell_of(o, e, k if object else nil, len(cells) + 1))
		}
	}
	t.shape = .Objects if object else .Rows
	if t.count == 1 && o.opts.cells_out.comment != 0 {
		put_notes(t, o.opts.cells_out.comment, t.lead[:])
	}
	notes := table_comments(o, v, .Comment)
	if !object {
		put_notes(t, o.opts.cells_out.comment, notes)
		put_row(o, cells[:])
		return
	}
	if o.opts.grow_header {
		heap := runtime.heap_allocator()
		row := Held_Row{make([]string, len(keys), heap), make([]write.Scalar, len(cells), heap), make([]string, len(notes), heap)}
		for n, i in notes {
			row.notes[i] = strings.clone(n, heap)
		}
		for k, i in keys {
			row.keys[i] = strings.clone(k, heap)
			#partial switch c in cells[i] {
			case string:
				row.cells[i] = strings.clone(c, heap)
			case write.Number_Literal:
				row.cells[i] = write.Number_Literal{strings.clone(c.text, heap)}
			case:
				row.cells[i] = c
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
	object_row(o, keys[:], cells[:], notes = notes)
}

// Writes the comments of `root`, a text whose array is written as the table's rows, as the library's writer places a
// document's: its `.@comment` now, above the rows, and its `.@comment_foot` after the last row.
table_root :: proc(o: ^Output, root: jq.Value) {
	t := o.table
	if notes := table_comments(o, root, .Comment); len(notes) > 0 {
		put_notes(t, o.opts.cells_out.comment, notes)
		write.put_text(&o.buf, string(records.writer_take(&t.wr)))
		flush_some(o)
	}
	for n in table_comments(o, root, .Comment_Foot) {
		append(&t.foot, strings.clone(n, runtime.heap_allocator()))
	}
}

// The comments of `role` on `v` that the table holds as whole lines: none when it has no comment character, and none
// that hold a line end.
@(private = "file")
table_comments :: proc(o: ^Output, v: jq.Value, role: core.Role) -> []string {
	if o.opts.cells_out.comment == 0 {
		return nil
	}
	bodies, _ := jq.comments(v, role)
	kept := make([dynamic]string, 0, len(bodies), context.temp_allocator)
	for b in bodies {
		if strings.index_any(b, "\r\n") < 0 {
			append(&kept, b)
		}
	}
	return kept[:]
}

// Writes each of `notes` as a comment line, its body after the comment character and a space.
@(private = "file")
put_notes :: proc(t: ^Table, comment: u8, notes: []string) {
	for n in notes {
		line := make([]u8, len(n) + 2, context.temp_allocator)
		line[0], line[1] = comment, ' '
		copy(line[2:], n)
		records.write_text(&t.wr, line)
	}
}

// Writes the output object of `cells` under `keys` as a table row, when every output is such an object of the same
// keys, `ordered` when they are the header's, or ends the run on a row the table refuses.
table_object :: proc(o: ^Output, keys: []string, cells: []write.Scalar, ordered: bool) {
	o.table.count += 1
	o.table.shape = .Objects
	o.result = JQ_OK
	object_row(o, keys, cells, ordered)
}

// Writes an object's `cells`, under `keys`, as a row under the header, which the first object's keys make.
@(private = "file")
object_row :: proc(o: ^Output, keys: []string, cells: []write.Scalar, ordered := false, notes: []string = nil) {
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
	row := cells
	if !ordered && !slice.equal(t.header[:], keys) {
		for k in keys {
			if !slice.contains(t.header[:], k) {
				unknown_key(o, k)
			}
		}
		row = aligned(t.header[:], keys, cells)
	}
	head := -1
	if fresh {
		head = o.buf.flushed + o.buf.cursor
		write_header(o)
	}
	if len(notes) > 0 {
		put_notes(o.table, o.opts.cells_out.comment, notes)
	}
	put_row(o, row, head)
}

// Ends the run on the key `k` of an object, which the header lacks.
@(private = "file")
unknown_key :: proc(o: ^Output, k: string) {
	table_fail(o, "output %d has the key %q, which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)", o.table.count, k)
}

// The cells of an object row under `header`: each key's cell in the header's order, empty for a key the row lacks.
@(private = "file")
aligned :: proc(header, keys: []string, cells: []write.Scalar) -> []write.Scalar {
	row := make([]write.Scalar, len(header), context.temp_allocator)
	for k, i in keys {
		if at, found := slice.linear_search(header, k); found {
			row[at] = cells[i]
		}
	}
	return row
}

// The cell `v` writes as, or the end of the run for an array or object at `key`, or with no key at cell `n` of the row.
@(private = "file")
cell_of :: proc(o: ^Output, v: jq.Value, key: Maybe(string), n: int) -> write.Scalar {
	switch jq.kind(v) {
	case .Null:
		return nil
	case .False:
		return write.Tree_Part.False
	case .True:
		return write.Tree_Part.True
	case .String:
		s, _ := jq.string_of(v)
		return s
	case .Number:
		// NaN is an empty cell, as in jq's @csv.
		if n, _ := jq.number_of(v); math.is_nan(n.f) {
			return nil
		}
		return write.Number_Literal{jq.to_json(v)}
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
	if o.opts.cells_out.no_header {
		return
	}
	names := make([]write.Scalar, len(t.header), context.temp_allocator)
	for k, i in t.header {
		names[i] = k
	}
	put_row(o, names)
}

// Writes one record, after any comment lines the writer holds, and moves the writer's text into the run's output, or
// ends the run on a record the writer refuses, dropping the output from `head` on when it is not yet flushed: a refused
// first row takes its header with it.
@(private = "file")
put_row :: proc(o: ^Output, cells: []write.Scalar, head := -1) {
	t := o.table
	if kind := records.write_cells(&t.wr, cells); kind != .None {
		if head >= o.buf.flushed {
			o.buf.cursor = head - o.buf.flushed
		}
		table_fail(o, "%s", row_refusal(t, kind, cells))
	}
	write.put_text(&o.buf, string(records.writer_take(&t.wr)))
	flush_some(o)
}

// Why the writer refused `cells`, as only the reasons that hold for them: a blank line, a byte order mark that opens
// the text, or under --infer a text that reads back as another kind, which TSV has no quotes for.
@(private = "file")
row_refusal :: proc(t: ^Table, kind: core.Typed_Error_Kind, cells: []write.Scalar) -> string {
	#partial switch kind {
	case .Unwritable:
		tsv := t.format == "tsv"
		reasons := make([dynamic]string, context.temp_allocator)
		if tsv && t.infer && slice.any_of_proc(cells, reads_as_other) {
			append(&reasons, "under --infer a text that reads as a number, true or false has no quotes")
		}
		if tsv && len(cells) > 0 && has_bom(cells[0]) {
			append(&reasons, "a text opening with a byte order mark reads back without it")
		}
		if len(reasons) == 0 {
			append(&reasons, "no cell, or one empty cell, is a blank line, which reads back as no record")
		}
		return message.build_temp("a record cannot be written as %s: %s", t.format, strings.join(reasons[:], ", and ", context.temp_allocator))
	case .Invalid_Utf8:
		return message.build_temp("a text that is not UTF-8 cannot be written as %s", t.format)
	}
	return message.build_temp("a record cannot be written as %s: %v", t.format, kind)
}

@(private = "file")
has_bom :: proc(c: write.Scalar) -> bool {
	s, is_text := c.(string)
	return is_text && strings.has_prefix(s, "\xEF\xBB\xBF")
}

// Whether the cell is a text that reads back, under --infer, as a number, true or false.
@(private = "file")
reads_as_other :: proc(c: write.Scalar) -> bool {
	s, is_text := c.(string)
	if !is_text {
		return false
	}
	_, is_number := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
	return is_number || s == "true" || s == "false"
}

// Writes the rows --grow-header held, under the header of every key, once the outputs end. A second call does nothing.
table_end :: proc(o: ^Output) {
	t := o.table
	if t == nil || t.ended {
		return
	}
	t.ended = true
	if len(t.held) > 0 {
		if o.opts.sort_keys {
			slice.sort(t.header[:])
		}
		write_header(o)
		for r in t.held {
			put_notes(t, o.opts.cells_out.comment, r.notes)
			put_row(o, aligned(t.header[:], r.keys, r.cells))
		}
	}
	if len(t.foot) > 0 {
		put_notes(t, o.opts.cells_out.comment, t.foot[:])
		write.put_text(&o.buf, string(records.writer_take(&t.wr)))
		flush_some(o)
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
	exit_closing_stdout(EXIT_INPUT)
}
