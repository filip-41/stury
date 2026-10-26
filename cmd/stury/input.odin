package main

// Reads the command's input as jq does.
//
// Input as jq 1.8.2 reads it (util.c): the files one after another as a single stream, a file that does not
// open reported and counted, and a text that does not parse told in jq's form. The texts are the library's
// to validate (jq/read.odin): a text ends within its file, and a literal at the first space, quote or bracket.
//
// The library reads a regular file whole, a text at a time. A file that is not a regular one (a pipe, a terminal),
// stdin under --unbuffered, any file under -n, and a regular file past STREAM_FILE_MIN whose first line looks like
// one record (`streams`), it reads a window of whole lines at a time (`next_window`), so a text is answered once its
// line has come, and memory holds a window and the longest text. --seq reads a record from each run of separators to
// the next, --stream makes each text's events (`jq.Events`).

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:slice"
import "core:strings"
import json "../../json"
import scan "../../json/scan"
import "jq"

// The longest piece jq's fgets reads: its 4096-byte buffer, less room to finish a UTF-8 sequence.
FGETS_MAX :: 4091

// How much of a stream its reader takes in at once.
READ_BLOCK :: 1 << 16

RS :: 0x1e // --seq's record separator

@(rodata)
UTF8_BOM := [3]byte{0xef, 0xbb, 0xbf}

@(rodata)
STDIN_ONLY := []string{"-"}

// The file mapped last, which the SIGBUS handler names when it shrinks under its mapping (platform_posix.odin). It is ""
// until a file is mapped.
mapped_input_name: string

Inputs :: struct {
	run:                ^Run,
	files:              []string, // "-" is stdin
	next_file:          int,
	name:               string, // the file opened last, "" before the first
	open:               bool,
	failures:           int, // files that did not open or read
	slurped:            ^jq.Array, // -s: the values so far
	// The library's: the open file, read whole.
	data:               []byte,
	mapped:             bool, // data is the file's mapping (`map_file`), not the heap's
	spent:              [dynamic]Spent, // files read past, which a value may still be read from
	pinned:             bool, // a value read from data may lie in it
	skip:               int, // the byte order mark at its start
	pos:                int, // where its next text starts
	seen:               int, // the byte jq would have read last for the last value
	lines:              struct {
		start, end, count: int,
	}, // fgets_lines' place in data
	bom_done:           bool, // past the stream's start, the one place a byte order mark is dropped
	raw_slurped:        bool, // -R -s: the stream's one string has been read
	at_line, at_column: int, // where data starts, as jq's parser counts lines and columns
	fault_at:           struct {
		at, line, column: int,
	}, // the last fault's place in data, so the next is counted from there (line 0: none yet)
	// A stream, read a window at a time: data is the window's whole lines. Its reader holds the rest.
	may_stream:         bool, // the run reads a stream so; check reads every file whole
	reader:             ^Stream_Reader, // the open file's while more of it may follow the window, else nil
	lines_before:       int, // the lines of the open file before data
	window_lines:       int, // the newlines in data, which its stream's reader counted
	texts_follow:       bool, // a text of the open file had another after it
	lines_tried:        bool, // the open file's lines, or its window's, were read as records (`records_after`)
	line_records:       bool, // some of the open file's lines were read as records
	resume:             bool, // a batch of records left one after reading far: the lines after it are tried again
	line:               int, // -R: jq's current_line, the lines it has read of the open file
	events:             ^jq.Events, // --stream: the events of the text read last, while some are left
	fault_note:         string, // text_fault's caret and flag hint for the message it returned ("" for none)
	fault_events:       [dynamic]jq.Value, // --stream-errors: the events of a faulty text, from `fault_next` on
	fault_next:         int,
	slurp_tail:         bool, // -s --stream-errors: the fault's error event comes after the slurped array, not in it
	bom_broken:         bool, // --seq --stream-errors: the stream began with a cut byte order mark, so jq's parser starts afresh at every call
	cells:              ^Cells, // --from csv or tsv: the open file's text and header
	seq_joined:         bool, // --seq: data is a record and the texts after it, read on from the files after its own (`seq_join`)
	seq_head:           enum u8 {
		Unread, // --seq: the open file's first text is yet to be found
		Bare, // found with no separator before it, and yet to be refused
		Read,
	},
}

inputs_init :: proc(ins: ^Inputs, run: ^Run, files: []string) {
	o := run.opts
	ins^ = {
		run     = run,
		files   = files,
		spent   = make([dynamic]Spent, runtime.heap_allocator()),
		at_line = 1,
	}
	if o.raw_input {
		// jq's raw reader keeps a byte order mark.
		ins.bom_done = true
		return
	}
	if o.slurp {
		ins.slurped = jq.new_array()
	}
}

// What `input`, `inputs`, `input_filename` and `input_line_number` read.
bind_inputs :: proc(run: ^Run, ins: ^Inputs) {
	run.ip.inputs = {
		data = ins,
		next = proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
			return next_input((^Inputs)(data), own = true)
		},
		position = proc(data: rawptr) -> (string, int) {
			return input_position((^Inputs)(data))
		},
	}
}

// jq's next_input: the next value, or under -s every value as one array once the stream ends, or a parse error as
// soon as there is one. With `prog`, the value is the input `prog` runs on, and holds only what it reads of a large
// text (see `build_root_pieces`). An `own` value, which `input` reads, holds a copy of its text, unless the text is
// most of what was read with it, so that under -n what was read can be freed once read past while the value lives on
// (`retire`).
next_input :: proc(ins: ^Inputs, prog: ^jq.Node = nil, own := false) -> (jq.Value, string, jq.Parse_Status) {
	if ins.slurped == nil {
		return next_value(ins, prog, own)
	}
	for {
		if ins.slurp_tail && ins.fault_next == len(ins.fault_events) - 1 {
			ins.slurp_tail = false
			break
		}
		v, msg, status := next_value(ins, own = own)
		if status == .Error {
			return nil, msg, .Error
		}
		if status == .Value {
			append(&ins.slurped.items, v)
		}
		if status == .More {
			break
		}
	}
	all := ins.slurped
	ins.slurped = nil
	return all, "", .Value
}

// The next value of the stream, or under --stream its next event. A text that does not parse is jq's message
// (`text_fault`).
next_value :: proc(ins: ^Inputs, prog: ^jq.Node = nil, own := false) -> (jq.Value, string, jq.Parse_Status) {
	run := ins.run
	if run.opts.raw_input {
		return next_raw(ins)
	}
	if reads_cells(&run.opts) {
		return next_cells(ins)
	}
	if ins.events != nil {
		if v, ok := jq.next_event(ins.events); ok {
			return v, "", .Value
		}
		ins.events = nil
	}
	if ins.fault_next < len(ins.fault_events) {
		ins.fault_next += 1
		return ins.fault_events[ins.fault_next - 1], "", .Value
	}
	for {
		at, limit, trailing, found := next_text(ins)
		if !found {
			if run.opts.seq && run.opts.stream_errors && ins.seq_head == .Unread {
				ins.seq_head = .Read
				return abandoned_text(ins, len(ins.data))
			}
			return nil, "", .More
		}
		if at == 0 && run.opts.seq && run.opts.stream_errors && cut_bom_len(ins.data) > 0 {
			return stream_errors_fault(ins, at, limit, text_place(ins, at))
		}
		// A record follows a separator: a file's first text without one is refused, as check and the library
		// refuse it, and told, where jq drops it unsaid.
		if ins.seq_head == .Bare {
			ins.seq_head = .Read
			if run.opts.stream_errors { // jq passes over what comes before the first separator, unread
				if limit < len(ins.data) {
					ins.pos = limit
					continue
				}
				return abandoned_text(ins, at)
			}
			return text_fault(ins, at, limit, json.Error{kind = .Bad_Char}, "Text before the first RS")
		}
		if ins.bom_broken {
			return stream_errors_fault(ins, at, limit, text_place(ins, at))
		}
		// A byte order mark past the stream's start is the record's first byte, refused there, as check refuses it.
		if run.opts.seq && bytes.has_prefix(ins.data[at:limit], UTF8_BOM[:]) {
			return text_fault(ins, at, limit, json.Error{kind = .Bad_Char})
		}
		if run.opts.seq && truncated_number(ins.data[at:limit]) {
			return text_fault(ins, at, limit, json.Error{kind = .Truncated, offset = u64(limit - at)}, jq.TRUNCATED_NUMBER_NOTE)
		}
		if trailing && run.opts.from != .Jsonc && limit == len(ins.data) && !own && !run.opts.stream && !run.verbatim {
			if v, ok := build_root_pieces(run, ins.data, at, prog); ok {
				ins.pos, ins.seen, ins.pinned = limit, last_read(ins.data, at, limit), true
				return v, "", .Value
			}
		}
		// --stream's document lives until its last event, past the arena of the call that reads it.
		doc_allocator := runtime.heap_allocator() if run.opts.stream else context.allocator
		// Once a file has shown a second text, its texts are guessed to end their lines: a line that builds
		// whole is one text, which jq reads the same with the newline after it.
		end := limit
		if trailing && ins.texts_follow {
			if k := bytes.index_byte(ins.data[at:limit], '\n'); k >= 0 {
				end = at + k + 1
			}
		}
		d, err := jq.build_rows(ins.data[at:end], run.req.dialect, allocator = doc_allocator)
		if e, bad := err.?; bad && trailing && (e.kind == .Trailing || end < limit) {
			if e.kind == .Trailing {
				ins.texts_follow = true
				end = at + int(e.offset)
			} else {
				end = text_end(ins, at, limit)
			}
			d, err = jq.build_rows(ins.data[at:end], run.req.dialect, allocator = doc_allocator)
		}
		// A --seq record may hold a complete value and then bytes that belong to no record, as `[1]` followed by `]`
		// before the next separator. The library's `split_record` names the value. The walk's fault is the bytes
		// after it, which the next read reports and resyncs past.
		if e, bad := err.?; bad && run.opts.seq && e.offset > 0 {
			if value, _, split := json.split_record(
				ins.data[at:limit],
				{dialect = run.req.dialect, limits = run.req.limits},
			); split {
				if d2, err2 := jq.build_rows(value, run.req.dialect, allocator = doc_allocator); err2 == nil {
					end = at + len(value)
					d, err = d2, nil
				}
			}
		}
		if err == nil {
			ins.pos, ins.seen = end, last_read(ins.data, at, end)
			if run.opts.stream {
				ins.pinned = true
				ins.events = jq.events_start(d)
				v, _ := jq.next_event(ins.events)
				return v, "", .Value
			}
			if own && 2 * len(d.src) < len(ins.data) {
				d.src = slice.clone(d.src)
			} else {
				ins.pinned = true
			}
			return jq.document_value(d), "", .Value
		}
		if read_on(ins, at) {
			continue
		}
		if run.opts.from == .Jsonc {
			jsonc_fault(ins, err.?, at)
		}
		return text_fault(ins, at, limit, err.?)
	}
}

// Whether the --seq record `text`, which starts past its leading whitespace, is a number with nothing after it:
// as it may be cut short, it is refused, by the rule of the library's `.JSON_Seq` framing (`scan.seq_truncated_number`),
// where jq's --stream parser reads it.
truncated_number :: scan.seq_truncated_number

// Where data[at] is, as jq's parser counts lines and columns. The next place asked is counted from this one.
@(private = "file")
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
@(private = "file")
text_fault :: proc(ins: ^Inputs, at, limit: int, found: json.Error, what := "") -> (jq.Value, string, jq.Parse_Status) {
	e := cut_by_next_byte(ins.data, at, limit, found, ins.run.req.dialect, ins.run.req.limits)
	line, column := text_place(ins, at)
	msg: string
	// A later file, or a fmt file, is told at its own line and column, as check tells it.
	if (ins.next_file > 1 || ins.run.name_faults) && !ins.seq_joined {
		at_error := e
		at_error.offset += u64(at)
		msg = fault_in_file(ins.name, ins.data, at_error, what, ins.lines_before)
	} else if ins.run.opts.from == .Ndjson { // each line is one text, so a fault at its end is reported at EOF, past the newline
		msg = jq.parse_message(ins.data[at:min(limit + 1, len(ins.data))], e, line, column, what, limit - at)
	} else {
		msg = jq.parse_message(ins.data[at:], e, line, column, what)
	}
	if ins.run.opts.stream_errors && ins.run.opts.from != .Ndjson {
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
	return nil, msg, .Error
}

// A text that ends inside a literal is `.Truncated` alone, but when a byte follows it (a space, a newline, the
// framing's end) that byte is what ended it, and the library fails the text with it as `.Bad_Literal`, as jq's
// "Invalid literal". The same fault with that byte, which shifts no offset. `e` itself otherwise.
cut_by_next_byte :: scan.cut_by_next_byte

// --stream-errors under --seq: a stream with no separator at all, which jq reads through to its end and
// then tells it was abandoned.
@(private = "file")
abandoned_text :: proc(ins: ^Inputs, at: int) -> (jq.Value, string, jq.Parse_Status) {
	line, column := text_place(ins, at)
	jq.advance(&line, &column, ins.data[at:])
	ins.pos, ins.seen = len(ins.data), len(ins.data)
	ev := jq.new_array(2)
	append(&ev.items, fmt.aprintf("Unfinished abandoned text at EOF at line %d, column %d", line, column), jq.new_array())
	return ev, "", .Value
}

// The length of the byte order mark's start that `data` opens with when the mark is cut short, else 0.
@(private = "file")
cut_bom_len :: proc(data: []byte) -> int {
	k := 0
	for k < len(data) && k < len(UTF8_BOM) && data[k] == UTF8_BOM[k] {
		k += 1
	}
	return k if k < len(UTF8_BOM) else 0
}

// --stream-errors: the events of the faulty text at data[at:] as jq's streaming parser makes them, the error's
// last (`stream_fault`), the first returned now and the rest by `next_value`. The stream goes on past the
// fault as jq's does: from the next line, or under --seq from the next record.
@(private = "file")
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
	events, fault, errored, fault_line, fault_column, late_error := stream_fault(ins.data[at:end], line, column, seq, seq && limit < len(ins.data), ins.bom_broken)
	ins.fault_events, ins.fault_next = events, 0
	ins.slurp_tail = late_error && ins.slurped != nil
	ins.seen = at + fault
	ins.pos = limit if seq else len(ins.data)
	if errored && !seq {
		if k := bytes.index_byte(ins.data[at + fault:], '\n'); k >= 0 {
			ins.pos = at + fault + k + 1
		}
		// jq drops the rest of the line unread, and does not count it.
		ins.fault_at = {ins.pos, fault_line, fault_column}
	}
	return next_value(ins)
}

// -R: the next line of the stream as a string, as jq's raw reader reads it (util.c): the bytes before a newline, a
// line running on from one file into the next, and each piece fgets reads made valid UTF-8 on its own. The last line
// without its newline. Under -s, the whole stream as one string, once.
@(private = "file")
next_raw :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	slurp := ins.run.opts.slurp
	if ins.raw_slurped {
		return nil, "", .More
	}
	line := strings.builder_make()
	read := false
	for {
		if !ins.open || ins.pos == len(ins.data) {
			ins.open = false
			if !open_next(ins) {
				break
			}
			continue
		}
		n, newline := next_piece(ins.data[ins.pos:])
		piece := string(ins.data[ins.pos:][:n])
		ins.pos += n
		ins.line += int(newline)
		read = true
		if newline && !slurp {
			jq.write_valid_utf8(&line, piece[:n - 1])
			return strings.to_string(line), "", .Value
		}
		jq.write_valid_utf8(&line, piece)
	}
	ins.raw_slurped = slurp
	if !read && !slurp {
		return nil, "", .More
	}
	return strings.to_string(line), "", .Value
}

// Whether the stream surely holds no more values: the library reads it, the last file is open, and only space is left
// of it. It returns false whenever another value may follow.
stream_ended :: proc(ins: ^Inputs) -> bool {
	o := ins.run.opts
	if ins.events != nil || ins.fault_next < len(ins.fault_events) || o.raw_input || ins.next_file < len(ins.files) || !ins.open || ins.reader != nil {
		return false
	}
	for c in ins.data[ins.pos:] {
		if !jq.is_space(c) {
			return false
		}
	}
	return true
}

// Where the text at data[at:] ends, when another may follow it before `limit`. `limit` when the text is faulty, which
// build_rows then reports. Once a file has shown a second text, the end of each that does not end its line is found
// so: a build sizes its rows by its source, so building the rest of the file to find the end would cost every text the rest
// of the file. A file of one text is built once, unchecked.
@(private = "file")
text_end :: proc(ins: ^Inputs, at, limit: int) -> int {
	src := ins.data[at:limit]
	err := json.validate(src, {dialect = ins.run.req.dialect, limits = ins.run.req.limits})
	if e, bad := err.?; bad && e.kind == .Trailing {
		return at + int(e.offset)
	}
	return limit
}

// A JSONC text the library refuses, which ends the run as `check --from jsonc` reports it.
jsonc_fault :: proc(ins: ^Inputs, e: json.Error, at: int) -> ! {
	e := e
	e.offset += u64(at)
	ins.run.name, ins.run.whole = ins.name, ins.data
	fail_input(ins.run, e)
}

// The input jq is reading, and its line: what `input_filename`, `input_line_number` and an error's
// `(at NAME:N)` tell.
input_position :: proc(ins: ^Inputs) -> (string, int) {
	run := ins.run
	if run.opts.raw_input {
		return ins.name, ins.line
	}
	if reads_cells(&run.opts) {
		return ins.name, cells_line(ins)
	}
	_, count := fgets_lines(ins, ins.seen)
	return ins.name, count
}

// The next text of the stream: where it starts in data, how far it may reach, and whether another text may follow it
// within that. It returns false at the end of the stream. A text reaches to the end of its file, a literal to the
// first space, quote or bracket, under --seq a record to the next separator, under --from ndjson a line, and under --from jsonc
// the whole input, one document.
next_text :: proc(ins: ^Inputs) -> (at, limit: int, trailing, found: bool) {
	seq, ndjson := ins.run.opts.seq, ins.run.opts.from == .Ndjson
	for {
		if !ins.open {
			// A separator seen in an earlier file leaves every later file's text a record, not text before the
			// stream's first separator: --seq reads the files as one stream.
			head := ins.seq_head
			if !open_next(ins) {
				return 0, 0, false, false
			}
			ins.seq_joined = false
			if seq && head == .Read {
				ins.seq_head = .Read
			}
		}
		data := ins.data
		at = ins.pos
		for at < len(data) && (jq.is_space(data[at]) || seq && data[at] == RS) {
			at += 1
		}
		if at == len(data) {
			if seq && ins.seq_head == .Unread && bytes.index_byte(data[ins.pos:], RS) >= 0 {
				ins.seq_head = .Read // a separator among whitespace: the stream is not abandoned, whatever a later window holds
			}
			ins.open, ins.seen = false, len(data)
			continue
		}
		limit = len(data)
		switch {
		case ins.run.opts.from == .Jsonc:
			return at, limit, false, true
		case seq:
			if ins.seq_head == .Unread {
				ins.seq_head = .Bare if bytes.index_byte(data[ins.pos:at], RS) < 0 else .Read
			}
			if k := bytes.index_byte(data[at:], RS); k >= 0 {
				limit = at + k
			} else if read_on(ins, at) {
				continue
			} else if ins.seq_head == .Read && !seq_text_ends(ins, at) && seq_join(ins, at) {
				continue
			}
			return at, limit, false, true
		case ndjson:
			// A byte order mark past the stream's start is a text of its own, which the library refuses.
			if data[at] == UTF8_BOM[0] {
				return at, at + 1, false, true
			}
			if k := bytes.index_byte(data[at:], '\n'); k >= 0 {
				limit = at + k
			}
			return at, limit, false, true
		}
		limit, trailing = text_span(data, at)
		return at, limit, trailing, true
	}
}

// Whether the --seq text at data[at:] completes where the file does, so that no byte of the next file can belong
// to it: it reads whole, and its last byte closes it (a container's or string's) or is whitespace. A number or a
// literal with nothing after it may go on in the next file, which is why jq reads on past those.
@(private = "file")
seq_text_ends :: proc(ins: ^Inputs, at: int) -> bool {
	src := ins.data[at:]
	if len(src) == 0 {
		return false
	}
	switch src[len(src) - 1] {
	case ']', '}', '"', ' ', '\t', '\n', '\r':
	case:
		return false
	}
	_, bad := json.validate(src, {dialect = ins.run.req.dialect, limits = ins.run.req.limits}).?
	return !bad
}

// --seq reads its files as one byte stream, as jq does: a record that no separator ends in the open file goes on
// in the next file, and the next, whose bytes continue the record rather than begin a text before the stream's
// first separator. Those files are read now, into one buffer from the record's first byte, which data becomes; the
// texts after the record are read from it too. Nothing is read up front: each file is opened as it is reached, and
// a stream a window at a time. It returns false when no file followed, the data left to the caller.
@(private = "file")
seq_join :: proc(ins: ^Inputs, at: int) -> bool {
	// The record's place in the stream, which jq counts across the files it joins.
	start_line, start_column := text_place(ins, at)
	joined := make([dynamic]byte, 0, len(ins.data) - at + READ_BLOCK, runtime.heap_allocator())
	append(&joined, ..ins.data[at:])
	read_any := false
	last_start := 0 // where the file read last begins in `joined`: `input_line_number` counts from there, as jq does
	for ins.next_file < len(ins.files) && bytes.index_byte(joined[:], RS) < 0 {
		if !open_next(ins) {
			break
		}
		read_any, last_start = true, len(joined)
		if ins.reader == nil {
			append(&joined, ..ins.data)
			continue
		}
		// A file read a window at a time: on until a separator comes or the file ends.
		for {
			append(&joined, ..ins.data)
			if bytes.index_byte(joined[:], RS) >= 0 || ins.reader == nil {
				break
			}
			next_window(ins, len(ins.data), len(ins.data))
		}
	}
	if !read_any {
		return false
	}
	if ins.data != nil { // its bytes are in `joined`; freed or kept as any data read past is (`retire`)
		if ins.run.opts.null_input && !ins.pinned {
			free_data({ins.data, ins.mapped})
		} else {
			append(&ins.spent, Spent{ins.data, ins.mapped})
		}
		ins.pinned = false
	}
	ins.data, ins.mapped = joined[:], false
	ins.open, ins.seq_joined = true, true
	ins.skip, ins.pos, ins.seen, ins.window_lines, ins.texts_follow = 0, 0, 0, 0, false
	ins.at_line, ins.at_column, ins.fault_at = start_line, start_column, {}
	// jq counts `input_line_number` in the file it reads last, from that file's first line.
	ins.lines_before, ins.lines = 0, {start = last_start, end = last_start}
	ins.seq_head = .Read
	return true
}

// How far the text at data[at:] may reach, and whether another may follow it within that: a string, array
// or object to the end of data, a literal to the first space, quote or bracket, and a `]`, `}`, `,` or `:`
// right after it, which the library then refuses with it, as jq does. A byte order mark, which the library
// steps over at a text's start, is a text of its own there, which it refuses.
text_span :: proc(data: []byte, at: int) -> (limit: int, trailing: bool) {
	switch data[at] {
	case '"', '[', '{':
		return len(data), true
	case UTF8_BOM[0]:
		return at + 1, false
	}
	limit = at + 1
	for limit < len(data) && is_literal_byte(data[limit]) {
		limit += 1
	}
	if limit < len(data) {
		switch data[limit] {
		case ']', '}', ',', ':':
			limit += 1
		}
	}
	return limit, false
}
