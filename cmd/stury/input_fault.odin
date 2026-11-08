package main

// A text's fault told: as jq's parser tells it in a plain run over the JSON texts of one input, as
// `NAME:LINE:COLUMN: SENTENCE` in any other, or under --stream as the events jq's parser makes of the text before it,
// and the note that shows its line and names the flag that reads it.

import "base:runtime"
import "core:bytes"
import "core:strings"
import core "../../core"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

// jq's message for the fault `f` of `data`, a record of which ends at `end`, in a plain run over the JSON texts of one
// input, and in any other run the fault as `fault_told` tells it.
@(private = "file")
fault_message :: proc(ins: ^Inputs, data: []byte, f: core.Fault, end := -1) -> string {
	o := &ins.run.opts
	if ins.spec != .Json || ins.framing != .Concatenated || o.null_input || len(ins.files) > 1 {
		return fault_told(ins.name, data, f, ins.file_lines, faults_counted(ins, data))
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
	set_note(ins, fault_note(ins.name, data, f, ins.spec, &ins.run.opts, lead_of(ins), runtime.heap_allocator()))
	stop := min(int(f.at), len(data))
	nl := bytes.index_byte(data[stop:], '\n')
	resume := len(data) if nl < 0 else stop + nl + 1
	if !ins.run.opts.stream {
		ins.line, ins.text_end = lines_read(ins, int(f.at) + 1), 0
		msg := fault_message(ins, data, f, end)
		delete(ins.told, runtime.heap_allocator())
		ins.told = strings.clone(msg, runtime.heap_allocator())
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

// Keeps `note` as the note of the input's last fault, which outlives the memory of the values read before it is told.
set_note :: proc(ins: ^Inputs, note: string) {
	delete(ins.note, runtime.heap_allocator())
	ins.note = note
}

// The line count of the open file's data that faults in `data` go on from, or nil for other bytes: faults come in
// order, so each is counted from the one before.
faults_counted :: proc(ins: ^Inputs, data: []byte) -> ^core.Lines {
	return &ins.faults_counted if raw_data(data) == raw_data(ins.data) && len(data) == len(ins.data) else nil
}

// --stream-errors under --seq: the event jq gives at the end of a stream with no separator, its place past `counted`.
abandoned :: proc(ins: ^Inputs, counted: []byte) -> (jq.Value, string, jq.Parse_Status) {
	l, c := ins.parsed.line, ins.parsed.column
	jq.advance(&l, &c, counted)
	ev := jq.new_array(2)
	append(&ev.items, message.build("Unfinished abandoned text at EOF at line %d, column %d", l, c), jq.new_array())
	return ev, "", .Value
}

// The fault of the open file ends the run, told as `tell_fault` tells it.
fail_text :: proc(ins: ^Inputs, fault: core.Fault) -> ! {
	tell_fault(ins, fault)
	finish(ins.run, EXIT_INPUT)
}

// The fault of the open file told as a parse error, after the output before it, as `NAME:LINE:COLUMN: SENTENCE` with
// `fault_note` after.
tell_fault :: proc(ins: ^Inputs, fault: core.Fault) {
	run := ins.run
	flush_some(&run.output, force = true)
	f := literal_cut(ins.data, fault, ins.framing)
	message.write_stderr("stury: parse error: %s\n%s", fault_told(ins.name, ins.data, f, ins.file_lines, faults_counted(ins, ins.data)), fault_note(ins.name, ins.data, f, ins.spec, &run.opts, lead_of(ins)))
}

// The fault `f` of the text `data` of file `name` told as `NAME:LINE:COLUMN: SENTENCE`, its line counted on from the
// `lines` before `data` and through `data` from where `counted` stands, or as `NAME: SENTENCE` when it is at no byte. A fault at the text's end is at its last byte's
// column, or at column 0 of the line after a newline, as jq places it. A record cut short by its line's end is at the
// line's last byte.
fault_told :: proc(name: string, data: []byte, f: core.Fault, lines := 0, counted: ^core.Lines = nil) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.write_fault_message(strings.to_writer(&b), data, f)
	if f.kind in core.AT_NO_BYTE {
		return message.build_temp("%s: %s", name, strings.to_string(b))
	}
	at, past_newline := f.at, false
	if n := u64(len(data)); f.at >= n && n > 0 {
		at, past_newline = n - 1, data[n - 1] == '\n'
	} else if f.kind == .Truncated && f.at > 0 && f.at < n && data[f.at] == '\n' {
		at = f.at - 1
	}
	line, col := core.locate(data, at, counted)
	if past_newline {
		line, col = line + 1, 0
	}
	return message.build_temp("%s:%d:%d: %s", name, line + u64(lines), col, strings.to_string(b))
}

// The fault `f` of the records of `data` framed by `framing`, but under `.Lines` and `.Seq` a word cut short by its
// record's end, where jq ends a literal, is an invalid literal. A string cut short is no word.
literal_cut :: proc(data: []byte, f: core.Fault, framing: core.Framing) -> core.Fault {
	if (framing == .Lines || framing == .Seq) && f.kind == .Truncated && f.detail == 0 && f.rules == &json.RULES && f.at > 0 && int(f.at) < len(data) && 'a' <= data[f.at - 1] | 0x20 && data[f.at - 1] | 0x20 <= 'z' {
		start := bytes.last_index_byte(data[:f.at], '\n' if framing == .Lines else 0x1e) + 1
		if !open_string(data[start:f.at]) {
			return {at = f.at, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Literal)}
		}
	}
	return f
}

// Whether `text`, the start of a record, ends inside a string.
@(private = "file")
open_string :: proc(text: []byte) -> bool {
	open := false
	for i := 0; i < len(text); i += 1 {
		switch {
		case !open:
			open = text[i] == '"'
		case text[i] == '\\':
			i += 1
		case:
			open = text[i] != '"'
		}
	}
	return open
}

// The bytes a fault's note shows on either side of the fault's byte.
NOTE_REACH :: 40

// The bytes of the open window's first line read in an earlier window, which a header heading the window is not.
lead_of :: proc(ins: ^Inputs) -> []byte {
	return nil if ins.headed else ins.lead[:ins.lead_len]
}

// The line of `data` the fault `f` is at with a caret under its byte, or past the last line's end for a fault at the
// text's end, then for the faults whose cure is a flag of stury's own that flag, or "" for a fault at no byte or an
// empty text. A trailing comma and a comment are JSONC's, a nesting past the cap is raised by --max-depth, which the
// hint asks for only when it was not given, and any other fault of a file `name`d for a format other than the JSON it
// was read as is that format's to read. A control byte of the line is shown as a space. The text ends in a newline.
// `lead` is the bytes of data[0]'s line before it.
fault_note :: proc(name: string, data: []byte, f: core.Fault, spec: Maybe(json.Spec), o: ^Opts, lead: []byte = nil, allocator := context.temp_allocator) -> string {
	at := int(f.at)
	hint: string
	dot := strings.last_index_byte(name, '.')
	named, by_name := format_named(name[dot + 1:] if dot >= 0 else "")
	switch {
	case f.kind == .Too_Deep:
		hint = "a larger --max-depth reads it" if o.max_depth != 0 else "--max-depth N raises the nesting limit"
	case f.kind != .Bad_Char || at >= len(data) || spec != .Json:
	case data[at] == '/' && at + 1 < len(data) && (data[at + 1] == '/' || data[at + 1] == '*'):
		hint = "--from jsonc reads comments"
	case data[at] == ']' || data[at] == '}':
		before := at
		for before > 0 && jq.is_space(data[before - 1]) {
			before -= 1
		}
		if before > 0 && data[before - 1] == ',' {
			hint = "--from jsonc reads a trailing comma"
		}
	}
	if hint == "" && by_name && named != .Json && o.from == .Json && !o.seq && len(data) > 0 {
		hint = message.build_temp("--from %s reads it", FORMATS[named].name)
	}
	if f.kind in core.AT_NO_BYTE || len(data) == 0 {
		return ""
	}
	at = min(at, len(data))
	if at == len(data) && data[at - 1] == '\n' {
		at -= 1
	}
	// The line, cut to a screenful around the byte.
	first, last := at, at
	for first > 0 && data[first - 1] != '\n' && at - first < NOTE_REACH {
		first -= 1
	}
	for last < len(data) && data[last] != '\n' && data[last] != '\r' && last - at < NOTE_REACH {
		last += 1
	}
	before := lead[max(len(lead) - NOTE_REACH + at, 0):] if first == 0 else nil
	pad := bytes.repeat({' '}, len(before) + at - first, context.temp_allocator)
	line := make([]byte, len(before) + last - first, context.temp_allocator)
	copy(line, before)
	copy(line[len(before):], data[first:last])
	for &c, i in line {
		if c == '\t' && i < len(pad) {
			pad[i] = '\t'
		} else if c < 0x20 || c == 0x7f {
			c = ' '
		}
	}
	if hint == "" {
		return message.build("%s\n%s^\n", line, pad, allocator = allocator)
	}
	return message.build("%s\n%s^\n(%s)\n", line, pad, hint, allocator = allocator)
}
