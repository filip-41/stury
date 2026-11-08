package main

// --from csv and --from tsv: each file's first record is its header, and each later record is one object keyed by it,
// an empty unquoted cell null. A pipe's windows after its first open with the header's bytes, so each reads as a file.

import "base:runtime"
import "core:bytes"
import "core:slice"
import "core:strings"
import core "../../core"
import records "../../core/records"
import "../../dsv"
import "jq"
import "message"

// The value of the open file's record `rec`, or the fault that ends the run, or with `answered` none, as the column
// route has printed its outputs. The first record built of a file shows whether its header names a column twice, which
// a build takes as the last of the two.
cells_value :: proc(ins: ^Inputs, rec: records.Record) -> (v: jq.Value, msg: string, status: jq.Parse_Status, answered: bool) {
	ins.text_end = int(rec.at) + len(rec.text)
	end := rec.at + u64(len(rec.text))
	end += u64(end < u64(len(ins.data)) && ins.data[end] == '\r')
	ins.prior_end, ins.first_row = ins.rows_end, !ins.header_judged
	ins.rows_end = end + u64(end < u64(len(ins.data)) && ins.data[end] == '\n')
	cols := ins.run.route.columns
	if cols == nil || !ins.header_judged {
		built, err := records.build(&ins.texts, rec, context.allocator)
		doc, fault := jq.judge_build(built, err)
		if f, bad := fault.?; bad {
			v, msg, status = cells_fault(ins, f)
			return
		}
		if !ins.header_judged {
			ins.header_judged = true
			if !ins.last && ins.head == nil {
				// The first record built is the first row, so the header is what lies before it.
				ins.head = bytes.clone(ins.data[:rec.at], runtime.heap_allocator())
			}
			if text, twice := repeated_header(ins.name, ins.data, &doc); twice {
				return nil, text, .Error, false
			}
			if cols != nil {
				place_columns(ins.run, cols, &ins.texts, &doc)
			}
		}
		if cols == nil {
			// The value lies in the file's bytes until its outputs are printed. What the column route prints holds none.
			ins.pinned = true
			return jq.document_value(doc), "", .Value, false
		}
	}
	answer_columns(ins.run, &ins.texts, rec)
	free_all(context.allocator)
	free_all(context.temp_allocator)
	return nil, "", .Value, true
}

// The row `v` `cells_value` built, with the comment lines before it as its `.@comment`: those between the previous row, or
// the header, and the row. The first row of a file also finds the lines before the header, which are the table's.
row_noted :: #force_no_inline proc(ins: ^Inputs, v: ^jq.Value) {
	if !reads_cells(&ins.run.opts) {
		return
	}
	cells := &ins.run.opts.cells_in
	from := int(core.text_start(ins.data, 0))
	switch {
	case !ins.first_row:
		from = max(int(ins.prior_end), len(ins.head) if ins.headed else 0)
	case !cells.no_header:
		lo, hi := dsv.header_span(ins.data, ins.as)
		if ins.next_file == 1 {
			file_notes(ins, comment_lines(ins.data[from:lo], cells.comment), false)
		}
		from = hi
	}
	notes := comment_lines(ins.data[from:], cells.comment)
	if len(notes) > 0 {
		v^ = jq.noted(v^, .Comment, notes)
	}
}

// The comment lines the open file holds after its last record, or all it holds when it has no record, which are the
// table's foot.
cells_foot :: proc(ins: ^Inputs) {
	cells := &ins.run.opts.cells_in
	start := int(core.text_start(ins.data, 0))
	notes: []string
	switch {
	case ins.header_judged:
		notes = comment_lines(ins.data[max(int(ins.rows_end), len(ins.head) if ins.headed else 0):], cells.comment)
	case cells.no_header:
		notes = comment_lines(ins.data[start:], cells.comment)
	case:
		lo, hi := dsv.header_span(ins.data, ins.as)
		notes = slice.concatenate([][]string{comment_lines(ins.data[start:lo], cells.comment), comment_lines(ins.data[hi:], cells.comment)}, context.temp_allocator)
	}
	file_notes(ins, notes, true)
}

// The bodies of the comment lines that open `span`, up to its first line that is neither blank nor a comment: a line's
// text past its comment byte, without the CR of its line end and one space after the byte.
@(private = "file")
comment_lines :: proc(span: []byte, comment: u8) -> []string {
	notes: [dynamic]string
	for rest := span; len(rest) > 0; {
		line := rest
		if i := bytes.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = nil
		}
		switch {
		case len(line) > 0 && line[0] == comment:
			body := strings.trim_prefix(strings.trim_suffix(string(line[1:]), "\r"), " ")
			append(&notes, strings.clone(body))
		case len(line) > 0 && string(line) != "\r":
			return notes[:]
		}
	}
	return notes[:]
}

// Holds `notes` for the comments of the table the run writes, or for the slurped array's root under -s, as its head
// before the header or its foot after the last record.
@(private = "file")
file_notes :: proc(ins: ^Inputs, notes: []string, foot: bool) {
	if len(notes) == 0 {
		return
	}
	into: ^[dynamic]string
	if ins.slurp {
		into = &ins.foot_notes if foot else &ins.head_notes
	} else if t := ins.run.output.table; t != nil {
		into = &t.foot if foot else &t.lead
	} else {
		return
	}
	heap := runtime.heap_allocator()
	into.allocator = heap
	for n in notes {
		append(into, strings.clone(n, heap))
	}
}

// The slurped array `all` with the comments its files hold outside their records: the first file's before its header as
// `.@comment` and the files' after their last record as `.@comment_foot`.
slurped :: proc(ins: ^Inputs, all: ^jq.Array) -> jq.Value {
	v: jq.Value = all
	if len(ins.head_notes) > 0 {
		v = jq.noted(v, .Comment, ins.head_notes[:])
	}
	if len(ins.foot_notes) > 0 {
		v = jq.noted(v, .Foot, ins.foot_notes[:])
	}
	ins.head_notes, ins.foot_notes = nil, nil
	return v
}

// The fault `f` of the open file, told as `NAME:LINE:COLUMN: SENTENCE`. The file is read past.
cells_fault :: proc(ins: ^Inputs, f: core.Fault) -> (jq.Value, string, jq.Parse_Status) {
	msg := fault_told(ins.name, ins.data, f, ins.file_lines, faults_counted(ins, ins.data))
	set_note(ins, fault_note(ins.name, ins.data, f, nil, &ins.run.opts, lead_of(ins), runtime.heap_allocator()))
	close_file(ins)
	return nil, msg, .Error
}

// The message for a header that names a column twice, at the second, read from the keys of the record `doc` of the
// text `data` of file `name`. A record of a text without a header is an array, which names no column.
repeated_header :: proc(name: string, data: []byte, doc: ^core.Document) -> (msg: string, twice: bool) {
	if core.kind(doc, core.ROOT) != .Object {
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	it := core.pairs(doc, core.ROOT)
	for k in core.pair_next(&it) {
		key := jq.node_string(doc, k)
		for seen in names {
			if seen == key {
				line, col := core.locate(data, doc.nodes[k].lo)
				return message.build_temp("%s:%d:%d: Duplicate header name %q", name, line, col, key), true
			}
		}
		append(&names, key)
	}
	return
}

// A header that names a column twice, told with a newline, or "". A header the format refuses is `validate`'s to tell.
header_fault :: proc(name: string, data: []byte, as: core.As) -> string {
	it := records.open(data, as, .Lines, allocator = runtime.heap_allocator())
	defer records.close(&it)
	rec, more := records.next(&it)
	if !more {
		return ""
	}
	doc, err := records.build(&it, rec, context.temp_allocator)
	if err.kind != .None {
		return ""
	}
	msg, twice := repeated_header(name, data, &doc)
	return message.build_temp("%s\n", msg) if twice else ""
}
