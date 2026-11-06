package main

// A text's fault told: as jq's parser tells it, as `NAME:LINE:COLUMN: SENTENCE` for a format of stury's own, or under
// --stream as the events jq's parser makes of the text before it, and the note that names the flag that reads it.

import "base:runtime"
import "core:bytes"
import "core:strings"
import core "../../core"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

// jq's message for the fault `f` of `data`, a record of which ends at `end`, but a later file's fault is told in that
// file, as `fault_told` tells it, since jq's line and column count from the first file's start.
@(private = "file")
fault_message :: proc(ins: ^Inputs, data: []byte, f: core.Fault, end := -1) -> string {
	if ins.next_file > 1 {
		return fault_told(ins.name, data, f, ins.file_lines)
	}
	return jq.parse_message(data, f, ins.parsed.line, ins.parsed.column, end)
}

// The fault `found` of the text at or after data[at:] as jq tells it, or under --stream the events jq's parser makes of
// the text before it. An NDJSON record ends at `end`.
text_fault :: proc(ins: ^Inputs, found: core.Fault, at: int, end := -1) -> (jq.Value, string, jq.Parse_Status) {
	data := ins.data
	if reads_cells(&ins.run.opts) {
		return cells_fault(ins, found)
	}
	if ins.spec != .Json {
		fail_text(ins, found)
	}
	f := literal_cut(data, found, ins.framing)
	ins.note = fault_note(data, f, ins.spec, &ins.run.opts)
	stop := min(int(f.at), len(data))
	nl := bytes.index_byte(data[stop:], '\n')
	resume := len(data) if nl < 0 else stop + nl + 1
	if !ins.run.opts.stream {
		ins.line, ins.text_end = lines_read(ins, int(f.at) + 1), 0
		msg := fault_message(ins, data, f, end)
		// Under --seq the reader goes on at the next record, and jq's parser elsewhere from the line after the fault,
		// which `input` reads next.
		if ins.framing == .Seq {
			return nil, msg, .Error
		}
		records.close(&ins.texts)
		ins.texts = records.open(data, ins.as, ins.framing, u64(resume), runtime.heap_allocator())
		ins.several = true
		return nil, msg, .Error
	}
	// jq's parser gives the events of the bytes before the fault, and with --stream-errors the fault as one, then
	// goes on from the line after the fault, or under --seq at the next record, where the reader is.
	seq, errors := ins.framing == .Seq, ins.run.opts.stream_errors
	if seq {
		rs := bytes.index_byte(data[at:], 0x1e)
		resume = len(data) if rs < 0 else at + rs
	}
	if seq && errors && f.rules == &json.RULES && f.detail == u8(json.Detail.Unframed) {
		// jq passes over what comes before the first separator, and tells a stream with none that it was abandoned.
		if resume < len(data) {
			return next_value(ins, false)
		}
		return abandoned(ins, data)
	}
	text := data[at:resume]
	if !errors {
		text = data[at:max(at, stop)]
		ins.fault_error = strings.clone(fault_message(ins, data, f), runtime.heap_allocator())
	}
	l, c := ins.parsed.line, ins.parsed.column
	jq.advance(&l, &c, data[:at])
	ins.pinned = true
	ins.walk, ins.walk_at = fault_walk(text, l, c, seq && errors, seq && errors && resume < len(data), ins.bom_broken, ins.walk_spare), at
	if !seq && errors {
		records.close(&ins.texts)
		ins.texts = records.open(data, ins.as, ins.framing, u64(resume), runtime.heap_allocator())
		ins.several = true
	} else if !seq {
		close_file(ins)
	}
	return next_value(ins, false)
}

// --stream-errors under --seq: the event jq gives at the end of a stream with no separator, its place past `counted`.
abandoned :: proc(ins: ^Inputs, counted: []byte) -> (jq.Value, string, jq.Parse_Status) {
	l, c := ins.parsed.line, ins.parsed.column
	jq.advance(&l, &c, counted)
	ev := jq.new_array(2)
	append(&ev.items, message.build("Unfinished abandoned text at EOF at line %d, column %d", l, c), jq.new_array())
	return ev, "", .Value
}

// The fault of the open file ends the run, told as `NAME:LINE:COLUMN: SENTENCE` with `fault_note` after, a JSON or CSV
// text's as a parse error, as jq calls it, and a JSONC or JSON5 text's as an error.
fail_text :: proc(ins: ^Inputs, fault: core.Fault) -> ! {
	run := ins.run
	flush_some(&run.output, force = true)
	f := literal_cut(ins.data, fault, ins.framing)
	what := "parse error" if reads_cells(&run.opts) || ins.spec == .Json else "error"
	message.write_stderr("stury: %s: %s\n%s", what, fault_told(ins.name, ins.data, f, ins.file_lines), fault_note(ins.data, f, ins.spec, &run.opts))
	finish(run, EXIT_INPUT)
}

// The fault `f` of the text `data` of file `name` told as `NAME:LINE:COLUMN: SENTENCE`, its line counted on from the
// `lines` before `data`, or as `NAME: SENTENCE` when it is at no byte. A JSON-like text's sentence is the one jq's
// messages use (`jq.fault_sentence`).
fault_told :: proc(name: string, data: []byte, f: core.Fault, lines := 0) -> string {
	if f.kind in core.AT_NO_BYTE {
		return message.build_temp("%s: %s", name, core.rule_of(f).message)
	}
	line, col := core.locate(data, f.at)
	sentence := jq.fault_sentence(f, string(data[f.at:])) if f.rules == &json.RULES else core.rule_of(f).message
	return message.build_temp("%s:%d:%d: %s", name, line + u64(lines), col, sentence)
}

// The fault `f` of the records of `data` framed by `framing`, but under `.Lines` and `.Seq` a word cut short by its
// record's end, where jq ends a literal, is an invalid literal.
literal_cut :: proc(data: []byte, f: core.Fault, framing: core.Framing) -> core.Fault {
	if (framing == .Lines || framing == .Seq) && f.kind == .Truncated && f.detail == 0 && f.rules == &json.RULES && f.at > 0 && int(f.at) < len(data) && 'a' <= data[f.at - 1] | 0x20 && data[f.at - 1] | 0x20 <= 'z' {
		return {at = f.at, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Literal)}
	}
	return f
}

// For the faults whose cure is a flag of stury's own, the line of `data` the fault `f` is at, a caret under its byte,
// and the flag, else "". A trailing comma and a comment are JSONC's, and a nesting past the cap is raised by
// --max-depth, which the hint asks for only when it was not given. The text ends in a newline.
fault_note :: proc(data: []byte, f: core.Fault, spec: Maybe(json.Spec), o: ^Opts) -> string {
	at := int(f.at)
	hint: string
	switch {
	case f.kind == .Too_Deep:
		hint = "a larger --max-depth reads it" if o.max_depth != 0 else "--max-depth N raises the nesting limit"
	case f.kind != .Bad_Char || at >= len(data) || spec != .Json:
		return ""
	case data[at] == '/' && at + 1 < len(data) && (data[at + 1] == '/' || data[at + 1] == '*'):
		hint = "--from jsonc reads comments"
	case data[at] == ']' || data[at] == '}':
		before := at
		for before > 0 && jq.is_space(data[before - 1]) {
			before -= 1
		}
		if before == 0 || data[before - 1] != ',' {
			return ""
		}
		hint = "--from jsonc reads a trailing comma"
	case:
		return ""
	}
	at = min(at, len(data) - 1)
	// The line, cut to a screenful around the byte.
	first, last := at, at
	for first > 0 && data[first - 1] != '\n' && at - first < 40 {
		first -= 1
	}
	for last < len(data) && data[last] != '\n' && data[last] != '\r' && last - at < 40 {
		last += 1
	}
	// The note outlives the memory of the input whose events come before it.
	heap := runtime.heap_allocator()
	pad := bytes.repeat({' '}, at - first, heap)
	for &c, i in pad {
		if data[first + i] == '\t' {
			c = '\t'
		}
	}
	return message.build("%s\n%s^\n(%s)\n", data[first:last], pad, hint, allocator = heap)
}
