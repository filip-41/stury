package main

// --from csv and --from tsv: each file's first record is its header, and each later record is one object keyed by it,
// an empty unquoted cell null. A file is read whole, as its records' documents point into all of it.

import core "../../core"
import records "../../core/records"
import "jq"
import "message"

// The value of the open file's record `rec`, or the fault that ends the run, or with `answered` none, as the column
// route has printed its outputs. The first record built of a file shows whether its header names a column twice, which
// a build takes as the last of the two.
cells_value :: proc(ins: ^Inputs, rec: records.Record) -> (v: jq.Value, msg: string, status: jq.Parse_Status, answered: bool) {
	ins.pinned = true
	ins.text_end = int(rec.at) + len(rec.text)
	cols := ins.run.route.columns
	if cols == nil || !ins.header_judged {
		built, err := records.build(&ins.texts, rec, context.allocator)
		doc, fault := jq.judge_build(built, err, rec.at)
		if f, bad := fault.?; bad {
			v, msg, status = cells_fault(ins, f)
			return
		}
		if !ins.header_judged {
			ins.header_judged = true
			if text, twice := repeated_header(ins.name, ins.data, &doc); twice {
				return nil, text, .Error, false
			}
			if cols != nil {
				place_columns(ins.run, cols, &ins.texts, &doc)
			}
		}
		if cols == nil {
			return jq.document_value(doc), "", .Value, false
		}
	}
	answer_columns(ins.run, ins, rec)
	return nil, "", .Value, true
}

// The fault `f` of the open file, told as `NAME:LINE:COLUMN: SENTENCE`. The file is read past.
cells_fault :: proc(ins: ^Inputs, f: core.Fault) -> (jq.Value, string, jq.Parse_Status) {
	msg := fault_told(ins.name, ins.data, f, ins.as, ins.file_lines)
	ins.note = ""
	close_file(ins)
	return nil, msg, .Error
}

// The message for a header that names a column twice, at the second, read from the keys of the record `doc` of the
// text `data` of file `name`.
repeated_header :: proc(name: string, data: []byte, doc: ^core.Document) -> (msg: string, twice: bool) {
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
