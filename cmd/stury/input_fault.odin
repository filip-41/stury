package main

// Where a faulty text is and what is said of it: its line and column as jq's parser counts them, jq's message for
// it, and where the stream reads on afterwards. --stream and --stream-errors hand the text to `fault_walk`
// (stream_fault.odin), which gives the events before the fault.

import "base:runtime"
import "core:bytes"
import "core:strings"
import json "../../json"
import "jq"
import "message"

// The text data[at:limit] as its framing tells it (`judge_record`), given `read`, what reading it alone reported.
judge_text :: proc(ins: ^Inputs, at, limit: int, read: Maybe(json.Error)) -> (end: int, err: Maybe(json.Error)) {
	o := &ins.run.opts
	framing := json.Framing.JSON_Seq if o.seq else .NDJSON if reads_lines(o) else .None
	opts := json.Record_Opts{read = {dialect = ins.run.read.dialect, limits = ins.run.read.limits}, framing = framing}
	return json.judge_record(ins.data, {bytes = ins.data[at:limit], at = u64(at)}, read, opts)
}

// Where data[at] is, as jq's parser counts lines and columns. The next place asked is counted from this one.
@(private)
text_place :: proc(ins: ^Inputs, at: int) -> (line, column: int) {
	if ins.fault_at.line == 0 || ins.fault_at.at > at {
		ins.fault_at = {ins.skip, ins.at_line, ins.at_column}
	}
	line, column = ins.fault_at.line, ins.fault_at.column
	jq.advance(&line, &column, ins.data[ins.fault_at.at:at])
	ins.fault_at = {at, line, column}
	return
}

// Where data starts to be counted from: past data[:upto], from the last fault's place when it is known, as
// jq does not count the rest of a line it drops.
@(private)
place_past :: proc(ins: ^Inputs, upto: int) {
	start := ins.skip
	if f := ins.fault_at; f.line != 0 && f.at <= upto {
		start, ins.at_line, ins.at_column = f.at, f.line, f.column
	}
	jq.advance(&ins.at_line, &ins.at_column, ins.data[start:upto])
}

// The text at data[at:] faulty: jq's message for it, at its line and column in the stream, and the stream read
// on from the next line, or under --seq from the next record (`limit`), as jq's parser goes on after an error.
// Under --stream-errors the message is an event, `[message, []]`, where `[]` stands for the path.
@(private)
text_fault :: proc(ins: ^Inputs, at, limit: int, found: json.Error, what := "") -> (jq.Value, string, jq.Parse_Status) {
	e := found
	line, column := text_place(ins, at)
	msg: string
	// A later file, or a fmt file, is told at its own line and column, as check tells it.
	if (ins.next_file > 1 || ins.run.name_faults) && !ins.seq_joined {
		at_error := e
		at_error.offset += u64(at)
		msg = fault_in_file(ins.name, ins.data, at_error, what, ins.lines_before)
	} else if reads_lines(&ins.run.opts) { // each line is one text, so a fault at its end is reported at EOF, past the newline
		msg = jq.parse_message(ins.data[at:min(limit + 1, len(ins.data))], e, line, column, what, limit - at)
	} else {
		msg = jq.parse_message(ins.data[at:], e, line, column, what)
	}
	if ins.run.opts.stream_errors && !reads_lines(&ins.run.opts) {
		return stream_errors_fault(ins, at, limit, line, column)
	}
	whole_error := e
	whole_error.offset += u64(at)
	ins.fault_note = fault_context(ins.data, whole_error, &ins.run.opts)
	fault := min(at + int(e.offset), len(ins.data))
	ins.pos, ins.seen = limit, fault
	if !ins.run.opts.seq {
		ins.pos = len(ins.data)
		if k := bytes.index_byte(ins.data[fault:], '\n'); k >= 0 {
			ins.pos = fault + k + 1
		}
	}
	// --stream gives jq's events of what comes before the fault first.
	if ins.run.opts.stream && ins.run.opts.from == .Json && fault > at {
		heap := runtime.heap_allocator()
		ins.fault_walk = fault_walk(ins.data[at:fault], line, column, ins.run.opts.seq, false, false, ins.fault_spare)
		ins.fault_text, ins.fault_end = at, fault
		ins.fault_error, ins.fault_note = strings.clone(msg, heap), strings.clone(ins.fault_note, heap) // to outlive the events' arenas
		return next_value(ins)
	}
	return nil, msg, .Error
}

// The faulty text's walk done with: the stream read on past the text as jq's parser goes on, from the next line, or
// under --seq from the next record. Plain --stream's message for the text, else "".
@(private)
end_fault_walk :: proc(ins: ^Inputs) -> string {
	w := ins.fault_walk
	ins.fault_walk, ins.fault_spare = nil, w
	if ins.fault_error != "" { // text_fault has placed the stream past the text
		heap := runtime.heap_allocator()
		msg, note := strings.clone(ins.fault_error), strings.clone(ins.fault_note)
		delete(ins.fault_error, heap)
		delete(ins.fault_note, heap)
		ins.fault_error, ins.fault_note, ins.seen = "", note, ins.fault_end
		return msg
	}
	fault := ins.fault_text + w.at
	ins.seen = fault
	ins.pos = ins.fault_end if ins.run.opts.seq else len(ins.data)
	if w.errored && !ins.run.opts.seq {
		if k := bytes.index_byte(ins.data[fault:], '\n'); k >= 0 {
			ins.pos = fault + k + 1
		}
		// jq drops the rest of the line unread, and does not count it.
		ins.fault_at = {ins.pos, w.line, w.column}
	}
	return ""
}

// --stream-errors under --seq: a stream with no separator at all, which jq reads through to its end and
// then tells it was abandoned.
@(private)
abandoned_text :: proc(ins: ^Inputs, at: int) -> (jq.Value, string, jq.Parse_Status) {
	line, column := text_place(ins, at)
	jq.advance(&line, &column, ins.data[at:])
	ins.pos, ins.seen = len(ins.data), len(ins.data)
	ev := jq.new_array(2)
	append(&ev.items, message.build("Unfinished abandoned text at EOF at line %d, column %d", line, column), jq.new_array())
	return ev, "", .Value
}

// The length of the byte order mark's start that `data` opens with when the mark is cut short, else 0.
@(private)
cut_bom_len :: proc(data: []byte) -> int {
	k := 0
	for k < len(data) && k < len(UTF8_BOM) && data[k] == UTF8_BOM[k] {
		k += 1
	}
	return k if k < len(UTF8_BOM) else 0
}

// --stream-errors: the events of the faulty text at data[at:] as jq's streaming parser makes them, the error's
// last (`fault_walk`), the first returned now and the rest by `next_value`. The stream goes on past the
// fault as jq's does: from the next line, or under --seq from the next record (`end_fault_walk`).
@(private)
stream_errors_fault :: proc(ins: ^Inputs, at, limit, line, column: int) -> (jq.Value, string, jq.Parse_Status) {
	seq := ins.run.opts.seq
	if k := cut_bom_len(ins.data); at == 0 && ins.next_file <= 1 && k > 0 {
		ins.skip, ins.pos, ins.fault_at = k, k, {} // jq drops the bytes of the mark it matched, unread and uncounted
		switch {
		case k == len(ins.data): // nothing follows: the stream is what the mark left
			ins.seq_head = .Unread
		case !seq:
			// jq refuses the stream whole, having read its first line.
			ins.pos = len(ins.data)
			ins.seen = ins.pos
			if nl := bytes.index_byte(ins.data, '\n'); nl >= 0 {
				ins.seen = nl
			}
			return nil, "Malformed BOM", .Error
		case:
			ins.bom_broken, ins.seq_head = true, .Read
		}
		return next_value(ins)
	}
	end := limit if seq else len(ins.data)
	ins.fault_walk = fault_walk(ins.data[at:end], line, column, seq, seq && limit < len(ins.data), ins.bom_broken, ins.fault_spare)
	ins.fault_text, ins.fault_end = at, limit
	return next_value(ins)
}

// A JSONC or JSON5 text the library refuses, which ends the run as `check --from jsonc` reports it.
jsonc_fault :: proc(ins: ^Inputs, e: json.Error, at: int) -> ! {
	e := e
	e.offset += u64(at)
	ins.run.name, ins.run.whole = ins.name, ins.data
	fail_input(ins.run, e)
}
