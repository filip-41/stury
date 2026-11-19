package main

// --to csv and --to tsv: each output is one record of a table. An object is a row under a header made of the first
// object's keys (sorted under -S), a key it lacks an empty cell. A key the header lacks ends the run, unless
// --grow-header holds every row and writes a header of all keys in first-seen order (sorted under -S) at the end. An
// array or a scalar is a row with no header, and the two shapes do not mix. A cell is a string's text, a number as it
// prints, true, false, or empty for null and NaN. Under --infer a string that would read back as a number, true or false
// is quoted, and TSV, which has no quotes, refuses it. An array or object in a cell ends the run, and so does a row no
// reader reads back: no cell, or one empty cell, is a blank line. When the table has a comment character, an output's
// `.@comment` is written as comment lines above its row, one for each line of its body, as the library's writer places a
// document's, and its other comments, a cell's and one holding a control byte a line cannot hold are dropped.

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strings"
import spell "../../core/spell"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import "../../jq"
import "message"

// The run's output table, on the heap, as it outlives each input's arena. The library's writer holds the rows, and its
// text is a buffer that each row moves into the run's output, so the rows go out as the others do.
Table :: struct {
	wr:     records.Writer,
	format: string,
	infer:  bool, // the table reads back under --infer, so a text that reads as another kind is quoted
	ended:  bool,
}

table_start :: proc(run: ^Run) -> ^Table {
	o := &run.opts
	heap := runtime.heap_allocator()
	t := new(Table, heap)
	t.format, t.infer = FORMATS[o.to].name, o.cells_out.infer
	records.writer_init(&t.wr, {}, cells_written_as(o), opts = {sort_keys = o.sort_keys, grow_header = o.grow_header}, allocator = heap)
	return t
}

// Writes the output `v` as a table row, or ends the run on what the table refuses.
emit_row :: proc(o: ^Output, v: core.Value) {
	t := o.table
	o.result = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	context.allocator = context.temp_allocator
	keys: [dynamic]string
	cells: [dynamic]write.Scalar
	object := jq.kind(v) == .Object
	if !object && jq.kind(v) != .Array {
		append(&cells, cell_of(v))
	} else {
		it := jq.iterate(v)
		for k, e in jq.next_member(&it) {
			append(&keys, k)
			append(&cells, cell_of(e))
		}
	}
	notes := table_comments(o, v, .Comment)
	put_written(o, records.write_object(&t.wr, keys[:], cells[:], notes) if object else records.write_row(&t.wr, cells[:], notes))
}

// Writes `doc` as the table's rows, see `records.write_document`, or ends the run on what the table refuses.
table_document :: proc(o: ^Output, doc: ^core.Document) {
	o.table.wr.taken, o.table.wr.taker = put_text, o
	put_written(o, records.write_document(&o.table.wr, doc))
}

// Writes the comment lines of `bodies` now, or holds them for after the table's last row when `foot`, or ends the run
// when they cannot be.
table_notes :: proc(o: ^Output, bodies: []string, foot: bool) {
	lines := make([dynamic]string, context.temp_allocator)
	_, kind := records.comment_lines(bodies, &lines)
	if kind == .None {
		kind = records.hold_notes(&o.table.wr, lines[:]) if foot else records.write_notes(&o.table.wr, lines[:])
	}
	if kind != .None {
		put_written(o, kind)
	}
}

// The lines of the comments of `role` on `v` that the table holds: none when it has no comment character.
@(private = "file")
table_comments :: proc(o: ^Output, v: core.Value, role: core.Role) -> []string {
	if o.opts.cells_out.comment == 0 {
		return nil
	}
	bodies, _ := core.comments(v, role)
	kept := make([dynamic]string, 0, len(bodies), context.temp_allocator)
	if _, kind := records.comment_lines(bodies, &kept); kind != .None {
		put_written(o, kind)
	}
	return kept[:]
}

// Writes the output object of `cells` under `keys` as a table row, when every output is such an object of the same
// keys, `ordered` when they are the header's, or ends the run on a row the table refuses.
table_object :: proc(o: ^Output, keys: []string, cells: []write.Scalar, ordered: bool) {
	o.result = JQ_OK
	put_written(o, records.write_object(&o.table.wr, keys, cells, ordered = ordered))
}

// Moves what the writer wrote into the run's output, or ends the run on the row it refused.
@(private = "file")
put_written :: proc(o: ^Output, kind: core.Typed_Error_Kind) {
	t := o.table
	if kind != .None {
		table_fail(o, "%s", refusal_text(t, kind))
	}
	put_text(o, records.writer_take(&t.wr))
}

// Moves `text`, which the table's writer wrote, into the run's output `out`.
@(private = "file")
put_text :: proc(out: rawptr, text: []u8) {
	o := (^Output)(out)
	write.put_text(&o.buf, string(text))
	flush_some(o)
}

// The sentence for the writer's refusal `kind` of a row, or of the header when its path is empty.
@(private = "file")
refusal_text :: proc(t: ^Table, kind: core.Typed_Error_Kind) -> string {
	err := &t.wr.err
	if err.n_steps == 0 {
		return row_refusal(t, kind, t.wr.cells)
	}
	output := int(err.steps[0].(core.Index)) + 1
	#partial switch kind {
	case .Wrong_Kind:
		return message.build_temp("output %d is %s: a table is all objects (under a header) or none", output, "an object, after arrays or scalars" if err.found == .Object else "not an object, after objects")
	case .Unknown_Field:
		return message.build_temp("output %d has the key %q, which the header lacks (the header is output 1's keys; --grow-header adds keys as they come)", output, string(err.steps[1].(core.Name)))
	case .Unsupported:
		if err.n_steps == 2 && (err.found == .Array || err.found == .Object) {
			what := "an object" if err.found == .Object else "an array"
			at: string
			#partial switch s in err.steps[1] {
			case core.Name:
				at = message.build_temp("at key %q", string(s))
			case core.Index:
				at = message.build_temp("at cell %d", int(s) + 1)
			}
			return message.build_temp("output %d has %s %s: a cell is a text, a number, true, false or null; tojson makes text of %s", output, what, at, what)
		}
	}
	return row_refusal(t, kind, t.wr.cells)
}

// The cell `v` writes as, an array or object as the open of its kind, which the table refuses.
@(private = "file")
cell_of :: proc(v: core.Value) -> write.Scalar {
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
		if f, _, _ := core.double_of(v); math.is_nan(f) {
			return nil
		}
		return write.Number_Literal{jq.to_json(v)}
	case .Array:
		return write.Tree_Part.Open_Array
	case .Object:
		return write.Tree_Part.Open_Object
	}
	return nil
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

// Writes the rows --grow-header held, under the header of every key, and the foot, once the outputs end. A second call
// does nothing.
table_end :: proc(o: ^Output) {
	t := o.table
	if t == nil || t.ended {
		return
	}
	t.ended = true
	put_written(o, records.table_end(&t.wr))
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
