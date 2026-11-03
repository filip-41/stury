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
			if text, twice := repeated_header(ins, &doc); twice {
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
	line, col := core.locate(ins.data, f.at)
	ins.note = ""
	close_file(ins)
	return nil, message.build_temp("%s:%d:%d: %s", ins.name, line + u64(ins.file_lines), col, core.rule_of(f).message), .Error
}

// The message for a header that names a column twice, at the second, read from the keys of the file's record `doc`.
@(private = "file")
repeated_header :: proc(ins: ^Inputs, doc: ^core.Document) -> (msg: string, twice: bool) {
	names := make([dynamic]string, context.temp_allocator)
	it := core.pairs(doc, core.ROOT)
	for k in core.pair_next(&it) {
		name := jq.node_string(doc, k)
		for seen in names {
			if seen == name {
				line, col := core.locate(ins.data, doc.nodes[k].lo)
				return message.build_temp("%s:%d:%d: Duplicate header name %q", ins.name, line, col, name), true
			}
		}
		append(&names, name)
	}
	return
}
